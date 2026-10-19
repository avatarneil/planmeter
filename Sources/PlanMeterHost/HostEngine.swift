import Foundation
import PlanMeterCore
import PlanMeterRemote

/// The headless counterpart of the Mac's `AppModel` data layer: discovers
/// accounts, scans transcripts, loads Codex account-wide readings, keeps
/// pricing fresh, and answers remote reports. Every number comes from the same
/// `PlanMeterCore` functions the app, CLI, and MCP server use, in the same
/// order as `AppModel.refresh`, so a Mac and a Linux box reading the same
/// transcripts report the same totals.
@MainActor
public final class HostEngine: RemoteReportSource {
    /// How often usage is rescanned while idle (the Mac app's interval).
    public static let autoRefreshInterval: TimeInterval = 30
    /// Scan far enough back for the widest range (90 days), plus a day of
    /// slack for time zones and files touched after their sessions ended.
    public static let scanDays = 91

    /// The pieces of a refresh, injectable for tests.
    public struct Loader: Sendable {
        public var discover: @Sendable () -> Discovery
        public var scan: @Sendable (Discovery, Int64, ScanCache) async -> ScanOutput
        public var threadCatalog: @Sendable (Discovery) -> [String: ThreadLink]
        public var accountUsage: @Sendable ([CodexUsageTarget], Bool) async -> [AccountUsageSnapshot]
        public var dailyUsage: @Sendable ([CodexUsageTarget], Bool) async -> [CodexDailyUsageSnapshot]
        public var cloudUsage: @Sendable ([CodexUsageTarget], Bool) async -> [CodexCloudUsageSnapshot]
        public var loadCachedRates: @Sendable () -> RateTable?
        public var fetchRates: @Sendable () async throws -> RateTable

        public init(discover: @escaping @Sendable () -> Discovery,
                    scan: @escaping @Sendable (Discovery, Int64, ScanCache) async -> ScanOutput,
                    threadCatalog: @escaping @Sendable (Discovery) -> [String: ThreadLink],
                    accountUsage: @escaping @Sendable ([CodexUsageTarget], Bool) async -> [AccountUsageSnapshot],
                    dailyUsage: @escaping @Sendable ([CodexUsageTarget], Bool) async -> [CodexDailyUsageSnapshot],
                    cloudUsage: @escaping @Sendable ([CodexUsageTarget], Bool) async -> [CodexCloudUsageSnapshot],
                    loadCachedRates: @escaping @Sendable () -> RateTable?,
                    fetchRates: @escaping @Sendable () async throws -> RateTable) {
            self.discover = discover
            self.scan = scan
            self.threadCatalog = threadCatalog
            self.accountUsage = accountUsage
            self.dailyUsage = dailyUsage
            self.cloudUsage = cloudUsage
            self.loadCachedRates = loadCachedRates
            self.fetchRates = fetchRates
        }

        /// The real thing. `pricingCache` is where fetched prices are kept;
        /// `offline` skips every network call (Codex account-wide readings and
        /// the pricing refresh) and reports from local data only.
        public static func live(pricingCache: URL, offline: Bool = false) -> Loader {
            Loader(
                discover: { AccountDiscovery.discover(settings: T3Settings.load()) },
                scan: { discovery, sinceMs, cache in
                    await Scanner.scan(sources: discovery.sources, openCodeDatabase: discovery.openCodeDatabase, sinceMs: sinceMs, cache: cache)
                },
                threadCatalog: { ThreadCatalog.load(discovery: $0) },
                accountUsage: { targets, force in offline ? [] : await CodexAccountUsage.shared.load(targets: targets, force: force) },
                dailyUsage: { targets, force in offline ? [] : await CodexDailyUsage.shared.load(targets: targets, force: force) },
                cloudUsage: { targets, force in offline ? [] : await CodexCloudUsage.shared.load(targets: targets, force: force) },
                loadCachedRates: { PricingLoader.loadCached(appCachePath: pricingCache.path) },
                fetchRates: {
                    if offline { throw HostEngineError.offline }
                    return try await PricingLoader.fetch(cacheURL: pricingCache)
                }
            )
        }
    }

    public enum HostEngineError: Error, LocalizedError {
        case offline
        public var errorDescription: String? { "Network access is off (--offline)." }
    }

    // MARK: State (mirrors AppModel)

    public var discovery = Discovery()
    public var cells: [CellKey: Cell] = [:] {
        didSet {
            hourCells = Aggregation.rollup(cells, stepMs: 3_600_000)
            cellAccountIds = Set(hourCells.keys.map(\.accountId))
            mixedCells = nil
        }
    }
    /// Minute cells merged by hour: hour and day views don't need minute detail.
    public private(set) var hourCells: [CellKey: Cell] = [:]
    private var cellAccountIds: Set<String> = []
    private var mixedCells: [CellKey: Cell]?
    public var threadCells: [ThreadCellEntry] = []
    public var accountUsage: [AccountUsageSnapshot] = []
    public var dailyUsage: [CodexDailyUsageSnapshot] = [] { didSet { mixedCells = nil } }
    public var cloudUsage: [CodexCloudUsageSnapshot] = []
    public var threadCatalog: [String: ThreadLink] = [:]
    public var rateLimits: [String: RateLimitSnapshot] = [:]
    public var sources: [SourceReport] = []
    public var rates = RateTable()
    public var groupOverrides: [String: PlanGroup]
    public private(set) var isScanning = false
    public var lastScan: Date?
    public private(set) var lastError: String?
    public private(set) var pricingError: String?
    public private(set) var isRefreshingPricing = false

    public let serverName: String
    public var reportServerName: String { serverName }
    /// Test seam for "now" in reports and `todayTotal`.
    public var clock: @MainActor () -> Date = { Date() }
    /// Activity lines (scan results, pricing), for the daemon's log.
    public var onLog: (@MainActor (String) -> Void)?

    private let loader: Loader
    private let cache: ScanCache
    private var scanTask: Task<Void, Never>?
    private var nextPricingRefresh = Date.distantPast
    private var loops: [Task<Void, Never>] = []
    private var started = false
    private var stopped = false

    public init(serverName: String, scanCache: URL, loader: Loader, groupOverrides: [String: PlanGroup] = [:]) {
        self.serverName = serverName
        self.cache = ScanCache(url: scanCache)
        self.loader = loader
        self.groupOverrides = groupOverrides
    }

    // MARK: Lifecycle

    /// Loads caches, scans once, then keeps usage (every 30 s) and pricing
    /// (every six hours, retrying failures after five minutes) fresh.
    public func start() async {
        guard !started else { return }
        started = true
        await cache.load()
        rates = loader.loadCachedRates() ?? RateTable()
        await refresh()
        guard !stopped else { return }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                if let self, Date() >= self.nextPricingRefresh { await self.refreshPricing() }
                do { try await Task.sleep(nanoseconds: 60 * 1_000_000_000) } catch { return }
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(HostEngine.autoRefreshInterval * 1_000_000_000)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        })
    }

    /// Stops the refresh loops and writes the scan cache.
    public func stop() async {
        stopped = true
        for loop in loops { loop.cancel() }
        loops.removeAll()
        await scanTask?.value
        await cache.save(force: true)
    }

    /// Rescans. A call during a scan waits for that scan instead of starting
    /// another; `forceAccountUsage` then runs one more pass with fresh
    /// account-wide readings.
    public func refresh(forceAccountUsage: Bool = false) async {
        if let running = scanTask {
            await running.value
            guard forceAccountUsage else { return }
            // Another caller may have started the next pass meanwhile.
            if let next = scanTask { await next.value; return }
        }
        let task = Task {
            await self.performRefresh(forceAccountUsage: forceAccountUsage)
            self.scanTask = nil
        }
        scanTask = task
        await task.value
    }

    private func performRefresh(forceAccountUsage: Bool) async {
        isScanning = true
        defer { isScanning = false }
        lastError = nil
        discovery = loader.discover()
        let targets = discovery.codexUsageTargets
        func retarget<S>(_ snapshots: [S], target: WritableKeyPath<S, CodexUsageTarget>) -> [S] {
            snapshots.compactMap { snapshot in
                let current = snapshot[keyPath: target]
                guard let match = targets.first(where: { $0.id == current.id && $0.home == current.home && $0.plan == current.plan }) else { return nil }
                var snapshot = snapshot
                snapshot[keyPath: target] = match
                return snapshot
            }
        }
        accountUsage = retarget(accountUsage, target: \.target)
        dailyUsage = retarget(dailyUsage, target: \.target)
        cloudUsage = retarget(cloudUsage, target: \.target)
        let sinceMs = Int64((Date().timeIntervalSince1970 - TimeInterval(Self.scanDays) * 86_400) * 1000)
        let output = await loader.scan(discovery, sinceMs, cache)
        cells = output.cells
        threadCells = output.threads
        threadCatalog = loader.threadCatalog(discovery)
        rateLimits = output.rateLimits
        sources = output.sources
        lastScan = output.scannedAt
        async let daily = loader.dailyUsage(targets, forceAccountUsage)
        async let cloud = loader.cloudUsage(targets, forceAccountUsage)
        accountUsage = await loader.accountUsage(targets, forceAccountUsage)
        dailyUsage = await daily
        cloudUsage = await cloud
        let combined = CodexCloudProjection.merging(cloudUsage, into: output)
        cells = combined.cells
        threadCells = combined.threads
        sources = combined.sources
        threadCatalog = CodexCloudProjection.catalog(cloudUsage, local: threadCatalog)
        let failed = sources.filter { $0.status == .failed }
        if !failed.isEmpty {
            lastError = failed.map { "\($0.provider.displayName) \($0.path): \($0.message ?? $0.status.rawValue)" }.joined(separator: "; ")
        }
    }

    public func refreshPricing() async {
        guard !isRefreshingPricing else { return }
        isRefreshingPricing = true
        defer { isRefreshingPricing = false }
        do {
            let fresh = try await loader.fetchRates()
            guard !Task.isCancelled else { return }
            rates = fresh
            pricingError = nil
            nextPricingRefresh = Date().addingTimeInterval(6 * 3600)
            onLog?("pricing refreshed from \(fresh.source) (\(fresh.knownModels) models)")
        } catch HostEngineError.offline {
            nextPricingRefresh = .distantFuture
        } catch {
            guard !Task.isCancelled else { return }
            nextPricingRefresh = Date().addingTimeInterval(300)
            pricingError = "Pricing refresh failed; keeping cached prices. \(error.localizedDescription)"
            onLog?(pricingError!)
        }
    }

    // MARK: Reports (mirrors AppModel)

    public func projectedUsage(from: Date, to: Date, resolution: Resolution) -> UsageProjection.Result {
        UsageProjection.buckets(cells: projectionCells(for: resolution, from: from), rates: rates, snapshots: dailyUsage, accounts: accounts,
                                from: from, to: to, resolution: resolution)
    }

    /// Hour cells suffice for hour and day views, except where a boundary can fall
    /// inside an hour: a window starting mid-hour, a workspace reading's freshness,
    /// or a half-hour time zone's midnight. Those keep minute cells, so every
    /// granularity has the same totals. Same rule as `AppModel`.
    public func projectionCells(for resolution: Resolution, from: Date) -> [CellKey: Cell] {
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

    /// Configured accounts plus placeholders for any attribution key the scan
    /// produced that no configured account claims.
    public var accounts: [Account] {
        var known = discovery.accounts
        let ids = Set(known.map(\.id))
        for id in cellAccountIds.subtracting(ids).sorted() {
            known.append(Account.placeholder(id: id))
        }
        return known
    }

    public func account(for id: String) -> Account {
        accounts.first { $0.id == id } ?? Account.placeholder(id: id)
    }

    public func group(for account: Account) -> PlanGroup {
        groupOverrides[account.id] ?? account.suggestedGroup
    }

    /// Spend since local midnight.
    public var todayTotal: Aggregate {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: clock())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return Aggregation.total(projectedUsage(from: start, to: end, resolution: .day).buckets)
    }

    /// A remote reply for `request`, rescanning first when the last scan is
    /// more than 30 seconds old (a phone refresh should see fresh numbers, but
    /// not hammer the disk). Same rule as the Mac app; before the first scan
    /// has finished, waits for it rather than answering with nothing.
    public func reply(for request: RemoteRequest) async -> RemoteReply {
        if let last = lastScan {
            if Date().timeIntervalSince(last) > Self.autoRefreshInterval, !isScanning { await refresh() }
        } else if started || scanTask != nil {
            await refresh()
        }
        return RemoteReportBuilder.reply(for: request, model: self, now: clock())
    }
}
