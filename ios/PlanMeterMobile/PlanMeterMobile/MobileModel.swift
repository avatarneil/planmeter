import Foundation
import LocalAuthentication
import Observation
import PlanMeterRemote
import PlanMeterWatchShared
import SwiftUI
import UIKit

enum MobileRange: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        }
    }
    var resolution: String { self == .day ? "hour" : "day" }
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

    var range: MobileRange = .month { didSet { Task { await refresh() } } }
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
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        WatchRelay.shared.onRefreshRequest = { [weak self] in
            guard let self else { return nil }
            await self.refresh()
            return self.watchPayload()
        }
        WatchRelay.shared.activate()
        if isLocked { await unlock() }
        #if DEBUG
        // `--pair-url <planmeter://…>`: pair at launch without the system's
        // "Open in PlanMeter?" prompt. Debug builds only; used by simulator
        // automation (`simctl launch … --pair-url …`).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pair-url"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            await handle(url: url)
        }
        #endif
        await refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if !self.isLocked { await self.refresh() }
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if requireBiometrics { isLocked = true }
        case .active:
            if isLocked { Task { await unlock() } } else { Task { await refresh() } }
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
        summary = nil
        timeline = nil
        limits = nil
        models = []
        lastUpdated = nil
    }

    static var platformName: String {
        let d = UIDevice.current
        return "\(d.model) · \(d.systemName) \(d.systemVersion)"
    }

    var deviceId: String { server?.deviceId ?? DeviceId.derive(fromPublicKey: signer.publicKeyRaw) }

    // MARK: Data

    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let days = range.rawValue
            async let s = client.call(RemoteRequest(method: .summary, days: days))
            async let t = client.call(RemoteRequest(method: .timeline, days: days, resolution: range.resolution))
            async let l = client.call(RemoteRequest(method: .limits))
            async let m = client.call(RemoteRequest(method: .models, days: days))
            let (sr, tr, lr, mr) = try await (s, t, l, m)
            summary = sr.summary
            timeline = tr.timeline
            limits = lr.limits
            models = mr.models ?? []
            lastUpdated = Date()
            error = nil
            if let payload = watchPayload() { WatchRelay.shared.push(payload) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Compact summary for the watch, derived from what the phone just fetched.
    func watchPayload() -> WatchPayload? {
        guard let summary else { return nil }
        func group(_ name: String) -> RemoteGroupUsage? { summary.groups.first { $0.group == name } }
        let personal = group("personal")
        let work = group("work")
        let other = group("other")
        let accounts = summary.groups.flatMap { g in
            g.accounts.map { WatchPayload.Account(name: $0.account.name, group: g.group, provider: $0.account.provider, costUsd: $0.totals.costUsd, tokens: $0.totals.tokens) }
        }
        .sorted { $0.costUsd > $1.costUsd }
        let limitRows = (limits?.accounts ?? []).flatMap { entry in
            entry.windows.map { WatchPayload.Limit(account: entry.account.name, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        return WatchPayload(
            updatedAt: Date(),
            days: summary.days,
            serverName: summary.serverName,
            personalCostUsd: personal?.totals.costUsd ?? 0,
            workCostUsd: work?.totals.costUsd ?? 0,
            otherCostUsd: other?.totals.costUsd ?? 0,
            personalTokens: personal?.totals.tokens ?? 0,
            workTokens: work?.totals.tokens ?? 0,
            todayCostUsd: summary.todayCostUsd,
            accounts: accounts,
            limits: limitRows
        )
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
