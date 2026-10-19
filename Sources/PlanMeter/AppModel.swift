import Foundation
import Observation
import PlanMeterCore
import PlanMeterHost
import PlanMeterRemote
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case lastHour = "1h"
    case today = "Today"
    case day = "24h"
    case week = "7 days"
    case month = "30 days"
    case quarter = "90 days"

    // Keep the existing spend-limit keys so saved limits survive range changes.
    var id: String {
        switch self {
        case .lastHour: return "lastHour"
        case .today: return "today"
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .quarter: return "quarter"
        }
    }

    var displayName: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .today: return "Today"
        case .day: return "Last 24 Hours"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        case .quarter: return "Last 90 Days"
        }
    }

    /// Chart granularities that keep each range readable (at most ~1,500 periods).
    var granularities: [Resolution] {
        switch self {
        case .lastHour: return [.minute, .fiveMinutes]
        case .today, .day: return [.minute, .fiveMinutes, .fifteenMinutes, .hour]
        case .week: return [.fifteenMinutes, .hour, .day]
        case .month: return [.hour, .day]
        case .quarter: return [.day]
        }
    }

    var defaultGranularity: Resolution {
        switch self {
        case .lastHour: return .minute
        case .today, .day: return .hour
        default: return .day
        }
    }

    /// Totals for a range: day buckets need a local-midnight start.
    var totalsResolution: Resolution {
        switch self {
        case .lastHour: return .fiveMinutes
        case .day: return .hour
        default: return .day
        }
    }

    var dayCount: Int {
        switch self {
        case .lastHour, .today, .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    func window(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        switch self {
        case .lastHour:
            // Sixty minutes ending at the next five-minute boundary, so every
            // offered granularity has whole buckets.
            let end = (floor(now.timeIntervalSince1970 / 300) + 1) * 300
            return (Date(timeIntervalSince1970: end - 3600), Date(timeIntervalSince1970: end))
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .day:
            return ReportWindow.rollingDay(now: now)
        default:
            let today = calendar.startOfDay(for: now)
            let to = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            let from = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
            return (from, to)
        }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cost = "Cost"
    case tokens = "Tokens"
    var id: String { rawValue }
}

struct GroupSummary: Identifiable {
    var group: PlanGroup
    var aggregate: Aggregate
    var accounts: [(account: Account, aggregate: Aggregate)]
    var id: PlanGroup { group }
}

@Observable
@MainActor
final class AppModel {
    /// One session-wide range for the dashboard, popover, and widgets.
    var range: TimeRange = .today { didSet { recompute() } }
    var metric: Metric = .cost
    var discovery = Discovery()
    var cells: [CellKey: Cell] = [:] {
        didSet {
            hourCells = Aggregation.rollup(cells, stepMs: 3_600_000)
            cellAccountIds = Set(hourCells.keys.map(\.accountId))
            mixedCells = nil
        }
    }
    /// Minute cells merged by hour: hour and day views don't need minute detail,
    /// and the smaller set keeps frequent refreshes cheap.
    @ObservationIgnored private(set) var hourCells: [CellKey: Cell] = [:]
    /// Accounts seen in the scan, kept so `accounts` doesn't walk every minute cell.
    @ObservationIgnored private var cellAccountIds: Set<String> = []
    /// Hour cells, with minute cells for workspace accounts; see `projectionCells`.
    @ObservationIgnored private var mixedCells: [CellKey: Cell]?
    /// The chosen chart granularity per range, persisted.
    var granularities: [String: Resolution] = AppModel.loadGranularities() {
        didSet { if persistsGranularities { UserDefaults.standard.set(granularities.mapValues(\.rawValue), forKey: AppModel.granularitiesKey) } }
    }
    /// Snapshot runs choose a granularity without changing saved preferences.
    @ObservationIgnored var persistsGranularities = true
    var threadCells: [ThreadCellEntry] = []
    var accountUsage: [AccountUsageSnapshot] = []
    var dailyUsage: [CodexDailyUsageSnapshot] = [] { didSet { mixedCells = nil } }
    var cloudUsage: [CodexCloudUsageSnapshot] = []
    var threadCatalog: [String: ThreadLink] = [:]
    var rateLimits: [String: RateLimitSnapshot] = [:]
    var sources: [SourceReport] = []
    var rates = RateTable()
    var buckets: [Bucket] = []
    var workspaceAccountIds: Set<String> = []
    var isScanning = false
    var lastScan: Date?
    var lastError: String?
    var pricingError: String?
    var isRefreshingPricing = false
    var desktopWidgetError: String?
    var groupOverrides: [String: PlanGroup] = GroupOverrides.load() { didSet { GroupOverrides.save(groupOverrides); publishDesktopWidget() } }
    var menuBarSpendGroups: Set<PlanGroup> = AppModel.loadMenuBarSpendGroups() {
        didSet {
            guard !menuBarSpendGroups.isEmpty else {
                menuBarSpendGroups = oldValue
                return
            }
            AppModel.saveMenuBarSpendGroups(menuBarSpendGroups)
            publishDesktopWidget()
        }
    }
    var menuBarSpendThresholds = SpendThreshold.load(from: GroupOverrides.defaults()) {
        didSet { SpendThreshold.save(menuBarSpendThresholds, to: GroupOverrides.defaults()); publishDesktopWidget() }
    }
    var menuBarSpendThreshold: SpendThreshold? {
        menuBarSpendThresholds[range.id]
    }
    var usageDetail: UsageScope?
    var showAccounts = false
    var showRemote = false
    let remote = RemoteState()
    let cloudSync = CloudSyncState()

    private let cache = ScanCache()
    private var started = false
    private var nextPricingRefresh = Date.distantPast
    private var pricingRefreshLoop: Task<Void, Never>?
    private var refreshLoop: Task<Void, Never>?

    /// How often the menu bar figure is refreshed while the app sits idle.
    static let autoRefreshInterval: Duration = .seconds(30)
    private static let menuBarSpendGroupsKey = "menuBarSpendGroups"

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        remote.dataProvider = { [weak self] request in
            guard let self else { return RemoteReply(error: "server not ready") }
            // A phone refresh should see fresh numbers, but not hammer the disk.
            if let last = self.lastScan, Date().timeIntervalSince(last) > 30, !self.isScanning {
                await self.refresh()
            }
            return RemoteReportBuilder.reply(for: request, model: self)
        }
        if remote.isEnabled { remote.start() }
        // `--pairing-link`: print a fresh pairing URL once the tailnet listener
        // is up. Lets a phone (or a simulator via `simctl openurl`) pair
        // without scanning the QR code. The link is a secret; it only goes to
        // the terminal that launched the app.
        if CommandLine.arguments.contains("--pairing-link") {
            Task { @MainActor [remote] in
                for _ in 0..<50 where !remote.isListening {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard remote.isListening else {
                    FileHandle.standardError.write(Data("pairing-link: remote listener did not start (\(remote.status))\n".utf8))
                    return
                }
                // Resolve Tailscale Serve first so the web link uses the HTTPS
                // origin when it is available.
                await remote.refreshHTTPSStatus(ensure: remote.httpsEnabled)
                remote.newInvite()
                if let invite = remote.invite {
                    // Unbuffered so a caller reading the log sees it immediately.
                    // The loopback variant carries the same token, for a
                    // simulator on this Mac, which cannot reach the tailnet IP.
                    var local = invite
                    local.serverHost = "127.0.0.1"
                    var lines = "pairing-link: \(invite.url.absoluteString)\npairing-link-local: \(local.url.absoluteString)\n"
                    if let web = remote.webPairingURL(for: invite) { lines += "pairing-link-web: \(web.absoluteString)\n" }
                    FileHandle.standardOutput.write(Data(lines.utf8))
                }
            }
        }
        await cache.load()
        rates = PricingLoader.loadCached() ?? RateTable()
        await refresh()
        // Render cached prices immediately, then refresh on every launch (including updates).
        // Retry failures in five minutes; keep long-running menu bar apps fresh every six hours.
        pricingRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, Date() >= self.nextPricingRefresh { await self.refreshPricing() }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.autoRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func refresh(forceAccountUsage: Bool = false) async {
        if isScanning { return }
        isScanning = true
        defer { isScanning = false }
        lastError = nil
        let settings = T3Settings.load()
        discovery = AccountDiscovery.discover(settings: settings)
        accountUsage = accountUsage.compactMap { snapshot in
            guard let target = discovery.codexUsageTargets.first(where: {
                $0.id == snapshot.target.id && $0.home == snapshot.target.home && $0.plan == snapshot.target.plan
            }) else { return nil }
            var snapshot = snapshot
            snapshot.target = target
            return snapshot
        }
        dailyUsage = dailyUsage.compactMap { snapshot in
            guard let target = discovery.codexUsageTargets.first(where: {
                $0.id == snapshot.target.id && $0.home == snapshot.target.home && $0.plan == snapshot.target.plan
            }) else { return nil }
            var snapshot = snapshot
            snapshot.target = target
            return snapshot
        }
        cloudUsage = cloudUsage.compactMap { snapshot in
            guard let target = discovery.codexUsageTargets.first(where: {
                $0.id == snapshot.target.id && $0.home == snapshot.target.home && $0.plan == snapshot.target.plan
            }) else { return nil }
            var snapshot = snapshot
            snapshot.target = target
            return snapshot
        }
        // Scan far enough back for the widest range, plus a day of slack for
        // time zones and files that were touched after their sessions ended.
        let sinceMs = Int64((Date().timeIntervalSince1970 - TimeInterval(TimeRange.quarter.dayCount + 1) * 86_400) * 1000)
        let output = await Scanner.scan(sources: discovery.sources, openCodeDatabase: discovery.openCodeDatabase, sinceMs: sinceMs, cache: cache)
        cells = output.cells
        threadCells = output.threads
        threadCatalog = ThreadCatalog.load(discovery: discovery)
        rateLimits = output.rateLimits
        sources = output.sources
        lastScan = output.scannedAt
        recompute()
        async let daily = CodexDailyUsage.shared.load(targets: discovery.codexUsageTargets, force: forceAccountUsage)
        async let cloud = CodexCloudUsage.shared.load(targets: discovery.codexUsageTargets, force: forceAccountUsage)
        accountUsage = await CodexAccountUsage.shared.load(targets: discovery.codexUsageTargets, force: forceAccountUsage)
        dailyUsage = await daily
        cloudUsage = await cloud
        let combined = CodexCloudProjection.merging(cloudUsage, into: output)
        cells = combined.cells
        threadCells = combined.threads
        sources = combined.sources
        threadCatalog = CodexCloudProjection.catalog(cloudUsage, local: threadCatalog)
        recompute()
    }

    var coverage: [UsageReconciliation] {
        UsageCoverage.reconcile(accountUsage, entries: threadCells, rates: rates, days: range.dayCount)
    }

    func coverageThreads(accountId: String) -> [ThreadSpend] {
        let window = Report.window(days: range.dayCount, calendar: UsageCoverage.utcCalendar)
        return ThreadCatalog.link(UsageCoverage.threads(threadCells, rates: rates, from: window.from, to: window.to), catalog: threadCatalog)
            .filter { $0.accountId == accountId }
    }

    func threads(in scope: UsageScope? = nil) -> [ThreadSpend] {
        let window = range.window()
        let ids = scope.map { Set(accounts(in: $0).map(\.id)) }
        return ThreadCatalog.link(UsageCoverage.threads(threadCells, rates: rates, from: window.from, to: window.to), catalog: threadCatalog).filter {
            ids == nil || ids!.contains($0.accountId)
        }
    }

    func refreshPricing() async {
        guard !isRefreshingPricing else { return }
        isRefreshingPricing = true
        defer { isRefreshingPricing = false }
        do {
            let fresh = try await PricingLoader.fetch()
            guard !Task.isCancelled else { return }
            rates = fresh
            pricingError = nil
            nextPricingRefresh = Date().addingTimeInterval(6 * 3600)
            recompute()
        } catch {
            guard !Task.isCancelled else { return }
            nextPricingRefresh = Date().addingTimeInterval(300)
            pricingError = "Pricing refresh failed; keeping cached prices. \(error.localizedDescription)"
        }
    }

    func recompute(now: Date = Date()) {
        let window = range.window(now: now)
        let result = projectedUsage(from: window.from, to: window.to, resolution: chartResolution)
        buckets = result.buckets
        workspaceAccountIds = result.workspaceAccountIds
        publishDesktopWidget(now: now)
        Task { await cloudSync.publish(model: self) }
    }

    var hasWorkspaceUsage: Bool { UsageProjection.available(dailyUsage, accounts: accounts) }
    /// The selected granularity for the current range.
    var granularity: Resolution {
        get { granularities[range.id].flatMap { range.granularities.contains($0) ? $0 : nil } ?? range.defaultGranularity }
        set {
            granularities[range.id] = newValue
            recompute()
        }
    }
    var chartResolution: Resolution { granularity }
    var usageNote: String {
        if !workspaceAccountIds.isEmpty { return "Workspace credits include Work, Codex, and Chat; text tokens cover Work and Codex. They replace overlapping local estimates for the hours the provider has reported, following local activity minute by minute. Credits without timing (Chat, voice, image) form a lighter, even baseline across those hours. Newer hours use local estimates until the provider catches up. Sessions cover known threads; cache savings use standard model rates." }
        if cloudUsage.contains(where: { $0.turns.contains(where: { $0.totals != nil }) }) {
            return "Local usage and dated cloud turns · Costs use service estimates where available, otherwise API-equivalent token prices; cloud aggregates use turn completion time"
        }
        return "Local transcript usage · API-equivalent estimates"
    }

    func projectedUsage(from: Date, to: Date, resolution: Resolution) -> UsageProjection.Result {
        UsageProjection.buckets(cells: projectionCells(for: resolution, from: from), rates: rates, snapshots: dailyUsage, accounts: accounts,
                                from: from, to: to, resolution: resolution)
    }

    /// Hour cells suffice for hour and day views, except where a boundary can fall
    /// inside an hour: a window starting mid-hour, a workspace reading's freshness,
    /// or a half-hour time zone's midnight. Those keep minute cells, so every
    /// granularity has the same totals.
    func projectionCells(for resolution: Resolution, from: Date) -> [CellKey: Cell] {
        guard (resolution.stepMs ?? .max) >= 3_600_000, TimeZone.current.secondsFromGMT() % 3600 == 0,
              from.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0 else { return cells }
        let workspace = Set(dailyUsage.compactMap(\.target.localAccountId))
        guard !workspace.isEmpty else { return hourCells }
        if let mixedCells { return mixedCells }
        var mixed = hourCells.filter { !workspace.contains($0.key.accountId) }
        for (key, cell) in cells where workspace.contains(key.accountId) { mixed[key] = cell }
        mixedCells = mixed
        return mixed
    }

    static let granularitiesKey = "chartGranularities"

    private static func loadGranularities() -> [String: Resolution] {
        let raw = UserDefaults.standard.dictionary(forKey: granularitiesKey) as? [String: String] ?? [:]
        return raw.compactMapValues(Resolution.init(rawValue:))
    }

    func inspectWorkspaceDay(target: CodexUsageTarget, date: String, usage: CodexDailyUsage = .shared) async -> CodexDailyUsageSnapshot? {
        let snapshot = await usage.loadDay(targets: [target], date: date).first
        guard !Task.isCancelled, let snapshot, snapshot.fetchedAt != nil,
              dailyUsage.contains(where: { $0.target == target }), snapshot.days.contains(where: { $0.date == date }) else { return nil }
        // Focused readings keep their own conversion, freshness, and partial
        // status. Only a range refresh replaces shared dashboard analytics.
        return snapshot
    }

    // MARK: Accounts and groups

    /// Configured accounts plus placeholders for any attribution key the scan
    /// produced that no configured account claims.
    var accounts: [Account] {
        var known = discovery.accounts
        let ids = Set(known.map(\.id))
        for id in cellAccountIds.subtracting(ids).sorted() {
            known.append(Account.placeholder(id: id))
        }
        return known
    }

    func account(for id: String) -> Account {
        accounts.first { $0.id == id } ?? Account.placeholder(id: id)
    }

    func group(for account: Account) -> PlanGroup {
        groupOverrides[account.id] ?? account.suggestedGroup
    }

    func setGroup(_ group: PlanGroup?, for account: Account) {
        if let group, group != account.suggestedGroup {
            groupOverrides[account.id] = group
        } else {
            groupOverrides.removeValue(forKey: account.id)
        }
    }

    var groupSummaries: [GroupSummary] {
        let byAccount = Aggregation.byAccount(buckets)
        var out: [GroupSummary] = []
        for group in PlanGroup.allCases {
            let members = accounts.filter { self.group(for: $0) == group }
            var agg = Aggregate()
            var rows: [(account: Account, aggregate: Aggregate)] = []
            for account in members {
                let a = byAccount[account.id] ?? Aggregate()
                rows.append((account, a))
                for b in buckets where b.accountId == account.id { agg.add(b) }
            }
            rows.sort { $0.aggregate.costUsd > $1.aggregate.costUsd || ($0.aggregate.costUsd == $1.aggregate.costUsd && $0.aggregate.totals.total > $1.aggregate.totals.total) }
            if group == .other && members.isEmpty { continue }
            out.append(GroupSummary(group: group, aggregate: agg, accounts: rows))
        }
        return out
    }

    var total: Aggregate { Aggregation.total(buckets) }

    /// Spend since local midnight, independent of the selected range, for
    /// the remote summary's dedicated Today total.
    var todayTotal: Aggregate {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return Aggregation.total(projectedUsage(from: start, to: end, resolution: .day).buckets)
    }

    /// The selected groups' spend from the same buckets as the visible usage.
    /// The popover's breakdown continues to show every plan group.
    var menuBarTotal: Aggregate {
        let selectedAccountIds = Set(accounts.lazy.filter { self.menuBarSpendGroups.contains(self.group(for: $0)) }.map(\.id))
        return Aggregation.total(buckets.filter { selectedAccountIds.contains($0.accountId) })
    }

    private static func loadMenuBarSpendGroups() -> Set<PlanGroup> {
        guard let values = GroupOverrides.defaults().stringArray(forKey: menuBarSpendGroupsKey) else {
            return Set(PlanGroup.allCases)
        }
        let groups = Set(values.compactMap(PlanGroup.init(rawValue:)))
        return groups.isEmpty ? Set(PlanGroup.allCases) : groups
    }

    private static func saveMenuBarSpendGroups(_ groups: Set<PlanGroup>) {
        let defaults = GroupOverrides.defaults()
        defaults.set(groups.map(\.rawValue).sorted(), forKey: menuBarSpendGroupsKey)
        defaults.synchronize()
    }

    func accounts(in scope: UsageScope) -> [Account] {
        accounts.filter { scope.includes($0, group: group(for: $0)) }
    }

    func buckets(in scope: UsageScope) -> [Bucket] {
        let ids = Set(accounts(in: scope).map(\.id))
        return buckets.filter { ids.contains($0.accountId) }
    }

    func title(for scope: UsageScope) -> String {
        switch scope {
        case .account(let id): return account(for: id).displayName
        case .provider(let provider): return provider == .codex && !workspaceAccountIds.isEmpty ? "Codex / ChatGPT" : provider.displayName
        case .group(let group): return group.displayName
        }
    }

    /// A configured accent color when it is unique among accounts; otherwise
    /// use a distinct palette color so series stay tellable apart in the chart.
    func color(for account: Account) -> Color {
        let all = accounts
        if let hex = account.accentColorHex?.lowercased(),
           all.filter({ $0.accentColorHex?.lowercased() == hex }).count == 1,
           let color = Color(hex: hex) {
            return color
        }
        let index = all.firstIndex { $0.id == account.id } ?? 0
        return Palette.series[index % Palette.series.count]
    }

}

/// The remote report builder reads the dashboard's own state, so phones see
/// exactly what the Mac shows.
extension AppModel: RemoteReportSource {
    var reportServerName: String { remote.serverName }
}
