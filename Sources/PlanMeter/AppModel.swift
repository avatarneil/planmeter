import Foundation
import Observation
import PlanMeterCore
import PlanMeterRemote
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case day = "24h"
    case week = "7 days"
    case month = "30 days"
    case quarter = "90 days"

    // Keep the existing spend-limit keys so saved limits survive range changes.
    var id: String {
        switch self {
        case .today: return "today"
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .quarter: return "quarter"
        }
    }

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .day: return "Last 24 Hours"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        case .quarter: return "Last 90 Days"
        }
    }

    var resolution: Resolution { self == .today || self == .day ? .hour : .day }

    var dayCount: Int {
        switch self {
        case .today, .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    func window(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .day:
            let hour = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
            return (hour.addingTimeInterval(-23 * 3600), hour.addingTimeInterval(3600))
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
    var cells: [CellKey: Cell] = [:]
    var rateLimits: [String: RateLimitSnapshot] = [:]
    var sources: [SourceReport] = []
    var rates = RateTable()
    var buckets: [Bucket] = []
    var isScanning = false
    var lastScan: Date?
    var lastError: String?
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

    private let cache = ScanCache()
    private var started = false
    private var refreshLoop: Task<Void, Never>?

    /// How often the menu bar figure is refreshed while the app sits idle.
    static let autoRefreshInterval: Duration = .seconds(5 * 60)
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
        if rates.isEmpty || (rates.fetchedAt.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true) {
            await refreshPricing()
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.autoRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        if isScanning { return }
        isScanning = true
        lastError = nil
        let settings = T3Settings.load()
        discovery = AccountDiscovery.discover(settings: settings)
        // Scan far enough back for the widest range, plus a day of slack for
        // time zones and files that were touched after their sessions ended.
        let sinceMs = Int64((Date().timeIntervalSince1970 - TimeInterval(TimeRange.quarter.dayCount + 1) * 86_400) * 1000)
        let output = await Scanner.scan(sources: discovery.sources, openCodeDatabase: discovery.openCodeDatabase, sinceMs: sinceMs, cache: cache)
        cells = output.cells
        rateLimits = output.rateLimits
        sources = output.sources
        lastScan = output.scannedAt
        isScanning = false
        recompute()
    }

    func refreshPricing() async {
        do {
            rates = try await PricingLoader.fetch()
            recompute()
        } catch {
            lastError = "Pricing refresh failed: \(error.localizedDescription)"
        }
    }

    func recompute(now: Date = Date()) {
        let window = range.window(now: now)
        buckets = Aggregation.buckets(cells: cells, rates: rates, from: window.from, to: window.to,
                                      resolution: range.resolution)
        publishDesktopWidget(now: now)
    }

    // MARK: Accounts and groups

    /// Configured accounts plus placeholders for any attribution key the scan
    /// produced that no configured account claims.
    var accounts: [Account] {
        var known = discovery.accounts
        let ids = Set(known.map(\.id))
        let seen = Set(cells.keys.map(\.accountId))
        for id in seen.subtracting(ids).sorted() {
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
        return Aggregation.total(Aggregation.buckets(cells: cells, rates: rates, from: start, to: end, resolution: .day))
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
        case .provider(let provider): return provider.displayName
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
