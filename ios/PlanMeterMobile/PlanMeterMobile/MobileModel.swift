import CloudKit
import Foundation
import LocalAuthentication
import Observation
import PlanMeterRemote
import PlanMeterWatchShared
import SwiftUI
import UIKit
import WidgetKit

enum MobileRange: Int, CaseIterable, Identifiable {
    case hour = 0
    case day = 1
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        }
    }
    var days: Int { max(1, rawValue) }
    var minutes: Int? { self == .hour ? 60 : nil }

    /// Bucket sizes a Mac serves over a direct connection.
    var granularities: [String] {
        switch self {
        case .hour: return ["minute", "5m"]
        case .day: return ["5m", "15m", "hour"]
        case .week: return ["15m", "hour", "day"]
        case .month: return ["hour", "day"]
        case .quarter: return ["day"]
        }
    }
    var defaultGranularity: String {
        switch self {
        case .hour: return "minute"
        case .day: return "hour"
        default: return "day"
        }
    }

    static func label(granularity: String) -> String {
        switch granularity {
        case "minute": return "1 min"
        case "5m": return "5 min"
        case "15m": return "15 min"
        case "hour": return "1 hour"
        default: return "1 day"
        }
    }
}

/// Keychain first; if the process lacks keychain entitlements (unsigned
/// simulator builds return errSecMissingEntitlement), fall back to a file in
/// the app container, which iOS still protects with data protection.
struct FallbackSecretStore: SecretStore {
    let primary: SecretStore
    let secondary: SecretStore

    func read(_ key: String) throws -> Data? {
        if let data = try? primary.read(key) { return data }
        return try secondary.read(key)
    }

    func write(_ key: String, _ data: Data) throws {
        do { try primary.write(key, data) } catch { try secondary.write(key, data) }
    }

    func delete(_ key: String) throws {
        try? primary.delete(key)
        try secondary.delete(key)
    }
}

@Observable
@MainActor
final class MobileModel {
    // Persistence: keychain, this device only, with a container-file fallback.
    private let store: SecretStore = FallbackSecretStore(
        primary: KeychainSecretStore(service: "com.neilgoldader.planmeter.mobile"),
        secondary: FileSecretStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PlanMeter", isDirectory: true))
    )
    private static let serverKey = "server.json"
    private static let deviceKey = "device-key.json"

    private(set) var signer: DeviceSigningKey
    private(set) var deviceKeyIsEnclave: Bool
    private(set) var server: PairedServer?
    private var client: RemoteClient?

    var usesCloud = UserDefaults.standard.bool(forKey: "cloudSync.enabled") {
        didSet {
            UserDefaults.standard.set(usesCloud, forKey: "cloudSync.enabled")
            clearReports()
            cloudSnapshots = []
            subscriptionReady = false
            Task { await refresh() }
        }
    }
    var cloudSnapshots: [CloudSnapshot] = []
    var selectedCloudMac = UserDefaults.standard.string(forKey: "cloudSync.selectedMac") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedCloudMac, forKey: "cloudSync.selectedMac")
            applyCloudSelection()
        }
    }
    private let cloudStore = CloudSnapshotStore()
    private let cloudAccount = CloudAccountGuard()
    private var cloudAccountSeeded = false
    private var subscriptionReady = false
    private var subscriptionRetryAfter = Date.distantPast
    var pushRegistrationStatus = "Registering for background notifications…"
    var backgroundSyncStatus = "Background updates are managed by iOS."
    private var isForeground = false
    @ObservationIgnored nonisolated(unsafe) private var accountObserver: NSObjectProtocol?
    private var refreshGeneration = 0
    var range: MobileRange = .month {
        didSet {
            if usesCloud { applyCloudSelection() }
            else { Task { await refresh() } }
        }
    }
    /// Chosen bucket size per range, persisted.
    var granularities: [String: String] = UserDefaults.standard.dictionary(forKey: "granularities") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(granularities, forKey: "granularities") }
    }
    /// The chosen bucket size if this source offers it, otherwise the closest default.
    var granularity: String {
        get {
            let available = availableGranularities
            if let chosen = granularities[String(range.rawValue)], available.contains(chosen) { return chosen }
            return available.contains(range.defaultGranularity) ? range.defaultGranularity : available.last ?? range.defaultGranularity
        }
        set {
            granularities[String(range.rawValue)] = newValue
            if usesCloud { applyCloudSelection() }
            else { Task { await refresh() } }
        }
    }
    /// iCloud snapshots carry fixed timelines; finer buckets come from those that exist.
    var availableGranularities: [String] {
        guard usesCloud else { return range.granularities }
        guard let snapshot = cloudSnapshots.first(where: { $0.id == selectedCloudMac }) else { return [range.defaultGranularity] }
        let sources = [(try? snapshot.report(days: range.days, minutes: range.minutes))?.timeline, range.minutes == nil ? snapshot.fineTimeline(days: range.days) : nil]
            .compactMap { $0?.resolution }
        return range.granularities.filter { target in sources.contains { $0 == target || RemoteTimeline.coarsens($0, to: target) } }
    }
    /// The 1h range needs a Mac that publishes it to iCloud or serves sub-day windows.
    var availableRanges: [MobileRange] {
        if usesCloud, let snapshot = cloudSnapshots.first(where: { $0.id == selectedCloudMac }) {
            return MobileRange.allCases.filter { $0 != .hour || (try? snapshot.report(days: 1, minutes: 60)) != nil }
        }
        return MobileRange.allCases.filter { $0 != .hour || directSupportsMinutes }
    }
    /// False once a directly connected Mac answers a sub-day request with a whole day (older versions).
    private(set) var directSupportsMinutes = true
    /// The last hour by minute and today by 15 minutes, for the watch.
    private var activity: (lastHour: [RemoteTimeline.GroupBar]?, today: [RemoteTimeline.GroupBar]?) = (nil, nil)
    /// The watch and widgets always describe a day or longer, even while 1h is shown here.
    private var watchSummary: RemoteSummary?
    private var watchTimeline: RemoteTimeline?
    var summary: RemoteSummary?
    var timeline: RemoteTimeline?
    var limits: RemoteLimits?
    var models: [RemoteModelRow] = []
    var isLoading = false
    var isPairing = false
    var error: String?
    var lastUpdated: Date?

    var requireBiometrics: Bool = UserDefaults.standard.bool(forKey: "requireBiometrics") {
        didSet { UserDefaults.standard.set(requireBiometrics, forKey: "requireBiometrics") }
    }
    var isLocked = false
    var showSettings = false
    var complicationPreferences = ComplicationPreferences.load() {
        didSet {
            complicationPreferences.save()
            // Settings must reach the watch even when the Mac/network is unavailable.
            if var payload = watchPayload() ?? WatchPayload.load() {
                payload.complicationPreferences = complicationPreferences
                payload.save()
                WatchRelay.shared.activate()
                WatchRelay.shared.push(payload)
            }
        }
    }

    private var refreshLoop: Task<Void, Never>?
    private var started = false

    init() {
        if let blob = try? store.readCodable(KeyBlob.self, Self.deviceKey), let key = try? SigningKeys.load(blob) {
            signer = key
            if case .enclave = blob { deviceKeyIsEnclave = true } else { deviceKeyIsEnclave = false }
        } else {
            let made = SigningKeys.make()
            signer = made.key
            if case .enclave = made.blob { deviceKeyIsEnclave = true } else { deviceKeyIsEnclave = false }
            try? store.writeCodable(made.blob, Self.deviceKey)
        }
        server = try? store.readCodable(PairedServer.self, Self.serverKey)
        if let server { client = RemoteClient(server: server, signer: signer) }
        isLocked = requireBiometrics
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.usesCloud else { return }
                // This also fires without an account switch; keep showing usage
                // unless a different account is signed in or it can't be checked.
                self.subscriptionReady = false
                if await self.cloudAccountChanged() {
                    self.clearReports()
                    self.cloudSnapshots = []
                    self.selectedCloudMac = ""
                }
                await self.refresh()
            }
        }
    }

    deinit { if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) } }

    private func cloudAccountChanged() async -> Bool {
        guard let identifier = try? await cloudStore.accountIdentifier() else { return true }
        guard cloudAccount.verify(identifier) == .changed else { return false }
        cloudAccount.reset()
        _ = cloudAccount.verify(identifier)
        return true
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        prepareRelay()
        isForeground = UIApplication.shared.applicationState == .active
        guard isForeground else { return }
        if isLocked { await unlock() }
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pair-url"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            await handle(url: url)
        }
        #endif
        await refresh()
        startForegroundRefresh()
    }

    private func prepareRelay() {
        WatchRelay.shared.onRefreshRequest = { [weak self] in
            guard let self else { return nil }
            await self.refresh()
            return self.isLocked ? nil : self.watchPayload()
        }
        WatchRelay.shared.activate()
    }

    private func startForegroundRefresh() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if self.isForeground && !self.isLocked && !self.isLoading { await self.refresh() }
            }
        }
    }

    /// Background launches never prompt for authentication or bypass the app lock.
    func refreshInBackground() async -> Bool {
        guard !requireBiometrics, !isLoading, usesCloud || client != nil else { return false }
        prepareRelay()
        await refresh()
        return !Task.isCancelled && error == nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isForeground = false
            refreshLoop?.cancel()
            if requireBiometrics { isLocked = true }
        case .active:
            isForeground = true
            startForegroundRefresh()
            Task {
                if isLocked { await unlock() }
                await refresh()
            }
        default:
            break
        }
    }

    func unlock() async {
        guard requireBiometrics else { isLocked = false; return }
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // No passcode set: cannot enforce, so do not brick the app.
            isLocked = false
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock PlanMeter")
            isLocked = !ok
        } catch {
            isLocked = true
        }
    }

    // MARK: Pairing

    func handle(url: URL) async {
        guard let invite = PairingInvite(url: url) else {
            error = "That link is not a PlanMeter pairing code."
            return
        }
        await pair(invite: invite)
    }

    func pair(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let invite = PairingInvite(url: url) else {
            error = "Could not read that pairing link."
            return
        }
        await pair(invite: invite)
    }

    func pair(invite: PairingInvite) async {
        isPairing = true
        error = nil
        defer { isPairing = false }
        do {
            let paired = try await RemoteClient.pair(invite: invite, deviceName: UIDevice.current.name, platform: Self.platformName, signer: signer)
            try store.writeCodable(paired, Self.serverKey)
            usesCloud = false
            server = paired
            client = RemoteClient(server: paired, signer: signer)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unpair() {
        try? store.delete(Self.serverKey)
        server = nil
        client = nil
        if !usesCloud { clearReports() }
    }

    private func clearPublishedSummary() {
        WatchPayload.clear()
        WidgetCenter.shared.reloadAllTimelines()
        WatchRelay.shared.clear()
    }

    private func clearReports() {
        clearPublishedSummary()
        refreshGeneration += 1
        isLoading = false
        summary = nil
        timeline = nil
        limits = nil
        models = []
        lastUpdated = nil
        error = nil
        watchSummary = nil
        watchTimeline = nil
        activity = (nil, nil)
    }

    func applyCloudSelection() {
        guard usesCloud else { return }
        summary = nil
        timeline = nil
        limits = nil
        models = []
        lastUpdated = nil
        guard let snapshot = cloudSnapshots.first(where: { $0.id == selectedCloudMac }) else {
            clearPublishedSummary()
            return
        }
        guard availableRanges.contains(range) else {
            range = .day // e.g. a Mac that doesn't publish the last hour yet.
            return
        }
        do {
            let report = try snapshot.report(days: range.days, minutes: range.minutes)
            summary = report.summary
            timeline = Self.timeline(granularity, report: report.timeline, fine: range.minutes == nil ? snapshot.fineTimeline(days: range.days) : nil)
            let watchReport = range.minutes == nil ? report : try? snapshot.report(days: 1)
            watchSummary = watchReport?.summary
            watchTimeline = watchReport?.timeline
            limits = report.limits
            models = report.models ?? []
            activity = snapshot.activity()
            lastUpdated = snapshot.generatedAt
            publishSummary()
        } catch {
            clearPublishedSummary()
            self.error = error.localizedDescription
        }
    }

    static var platformName: String {
        let d = UIDevice.current
        return "\(d.model) · \(d.systemName) \(d.systemVersion)"
    }

    var deviceId: String { server?.deviceId ?? DeviceId.derive(fromPublicKey: signer.publicKeyRaw) }

    // MARK: Data

    func refresh() async {
        guard !isLocked, !Task.isCancelled, usesCloud || client != nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer { if generation == refreshGeneration { isLoading = false } }
        do {
            if usesCloud {
                let snapshots = try await cloudStore.fetch()
                guard generation == refreshGeneration, !isLocked, !Task.isCancelled else { return }
                cloudSnapshots = snapshots
                if selectedCloudMac.isEmpty, let first = snapshots.first { selectedCloudMac = first.id }
                error = nil
                applyCloudSelection()
                if !cloudAccountSeeded, let identifier = try? await cloudStore.accountIdentifier() {
                    // These snapshots came from the current account; remember it so a
                    // later change notification can tell a real switch apart.
                    cloudAccountSeeded = true
                    if cloudAccount.verify(identifier) == .changed {
                        cloudAccount.reset()
                        _ = cloudAccount.verify(identifier)
                    }
                    guard generation == refreshGeneration, !isLocked, !Task.isCancelled else { return }
                }
                if !subscriptionReady && Date() >= subscriptionRetryAfter {
                    do {
                        try await cloudStore.subscribeToChanges()
                        guard generation == refreshGeneration, usesCloud, !Task.isCancelled else { return }
                        subscriptionReady = true
                        backgroundSyncStatus = "iCloud change notifications enabled."
                    } catch {
                        guard generation == refreshGeneration, usesCloud, !Task.isCancelled else { return }
                        subscriptionRetryAfter = Date().addingTimeInterval(300)
                        backgroundSyncStatus = "Change notifications unavailable; refresh will retry. \(error.localizedDescription)"
                    }
                }
                return
            }
            guard let client else { return }
            let days = range.days, minutes = range.minutes
            let watch = WatchRelay.shared.hasWatchApp
            async let s = client.call(RemoteRequest(method: .summary, days: days, minutes: minutes))
            async let t = client.call(RemoteRequest(method: .timeline, days: days, resolution: granularity, minutes: minutes))
            async let l = client.call(RemoteRequest(method: .limits))
            async let m = client.call(RemoteRequest(method: .models, days: days, minutes: minutes))
            // The watch's compact charts, and its day summary while 1h is shown here.
            // Older Macs ignore sub-day windows and finer buckets, so replies are validated.
            async let lastHour = watch ? Self.optionalCall(client, RemoteRequest(method: .timeline, days: 1, resolution: "minute", minutes: 60)) : nil
            async let today = watch ? Self.optionalCall(client, RemoteRequest(method: .timeline, days: 1, resolution: "5m")) : nil
            async let daySummary = minutes != nil ? Self.optionalCall(client, RemoteRequest(method: .summary, days: 1)) : nil
            async let dayTimeline = minutes != nil ? Self.optionalCall(client, RemoteRequest(method: .timeline, days: 1, resolution: "hour")) : nil
            let (sr, tr, lr, mr) = try await (s, t, l, m)
            let (hourReply, todayReply, dayReply, dayTimelineReply) = await (lastHour, today, daySummary, dayTimeline)
            guard generation == refreshGeneration, !isLocked, !Task.isCancelled else { return }
            if minutes != nil, sr.summary?.minutes != minutes {
                // An older Mac answered with a whole day; don't label it as an hour.
                directSupportsMinutes = false
                range = .day
                return
            }
            summary = sr.summary
            timeline = tr.timeline
            watchSummary = minutes == nil ? sr.summary : dayReply?.summary
            watchTimeline = minutes == nil ? tr.timeline : dayTimelineReply?.timeline
            activity = (hourReply?.timeline.flatMap { $0.minutes == 60 && $0.resolution == "minute" ? $0.groupBars() : nil },
                        todayReply?.timeline.flatMap { Self.timeline("15m", report: $0, fine: nil) }
                            .flatMap { $0.resolution == "15m" ? $0.groupBars(on: Date()) : nil })
            limits = lr.limits
            models = mr.models ?? []
            lastUpdated = Date()
            error = nil
            publishSummary()
        } catch {
            guard generation == refreshGeneration, !isLocked, !Task.isCancelled else { return }
            if usesCloud, let cloudError = error as? CloudSyncError, case .signedOut = cloudError {
                clearReports()
                cloudSnapshots = []
            }
            self.error = error.localizedDescription
        }
    }

    private func publishSummary() {
        guard let payload = watchPayload() else { return }
        payload.save()
        WidgetCenter.shared.reloadAllTimelines()
        WatchRelay.shared.push(payload)
    }

    /// Compact summary for widgets and the watch, derived from the latest report.
    func watchPayload() -> WatchPayload? {
        guard let summary = watchSummary else { return nil }
        let timeline = watchTimeline
        func group(_ name: String) -> RemoteGroupUsage? { summary.groups.first { $0.group == name } }
        let personal = group("personal")
        let work = group("work")
        let other = group("other")
        let accounts = summary.groups.flatMap { g in
            g.accounts.map { WatchPayload.Account(name: $0.account.name, group: g.group, provider: $0.account.provider, costUsd: $0.totals.costUsd, tokens: Int64($0.totals.tokens)) }
        }
        .sorted { $0.costUsd > $1.costUsd }
        let limitRows = (limits?.accounts ?? []).flatMap { entry in
            entry.windows.map { WatchPayload.Limit(account: entry.account.name, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        // Timeline points are bucketed usage, independent of the selected report range.
        // Use calendar today, never the rolling 24-hour group totals.
        let todayByGroup = timeline?.costByGroup(on: summary.generatedAt)
        var payload = WatchPayload(
            updatedAt: summary.generatedAt,
            days: summary.days,
            serverName: summary.serverName,
            personalCostUsd: personal?.totals.costUsd ?? 0,
            workCostUsd: work?.totals.costUsd ?? 0,
            otherCostUsd: other?.totals.costUsd ?? 0,
            personalTokens: Int64(personal?.totals.tokens ?? 0),
            workTokens: Int64(work?.totals.tokens ?? 0),
            todayCostUsd: summary.todayCostUsd,
            accounts: accounts,
            limits: limitRows,
            todayCostByGroup: todayByGroup,
            complicationPreferences: complicationPreferences,
            cloudMacID: usesCloud ? selectedCloudMac : nil,
            usesProviderDates: summary.usesProviderDates
        )
        func bars(_ groups: [RemoteTimeline.GroupBar]) -> [WatchPayload.Bar] {
            groups.map { WatchPayload.Bar(start: $0.start, costs: $0.costs, baselines: $0.baselines) }.map(\.compacted)
        }
        payload.lastHour = activity.lastHour.map(bars)
        payload.today = activity.today.map(bars)
        return payload
    }

    private static func optionalCall(_ client: RemoteClient, _ request: RemoteRequest) async -> RemoteReply? {
        try? await client.call(request)
    }

    /// The report's timeline, or a finer published one, at the chosen bucket size.
    static func timeline(_ granularity: String, report: RemoteTimeline?, fine: RemoteTimeline?) -> RemoteTimeline? {
        for source in [report, fine].compactMap({ $0 }) {
            if source.resolution == granularity { return source }
            if let rebucketed = source.rebucketed(to: granularity) { return rebucketed }
        }
        return report
    }

    // MARK: Presentation helpers

    func color(for accountId: String) -> Color {
        let accounts = timeline?.accounts ?? summary?.groups.flatMap { $0.accounts.map(\.account) } ?? []
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return .gray }
        let account = accounts[index]
        if let hex = account.accentColorHex, accounts.filter({ $0.accentColorHex == hex }).count == 1, let c = Color(hex: hex) { return c }
        return Palette.series[index % Palette.series.count]
    }
}
