import XCTest
@testable import PlanMeterCore
import PlanMeterHost
import PlanMeterRemote
@testable import PlanMeter

/// The daemon's `HostEngine` and the Mac's `AppModel` must answer every remote
/// request identically for the same inputs: same accounting, same windows,
/// same bytes on the wire.
final class HostParityTests: XCTestCase {
    struct Scenario {
        var now: Date
        var accounts: [Account]
        var targets: [CodexUsageTarget]
        var rates: RateTable
        var scan: ScanOutput
        var daily: [CodexDailyUsageSnapshot]
        var cloud: [CodexCloudUsageSnapshot]
    }

    /// Ninety-five days of mixed usage: priced and unpriced models, provider
    /// costs, an unclaimed account, workspace credits, a cloud turn, limits.
    static func scenario() throws -> Scenario {
        let now = UsageCoverage.utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10, minute: 30))!
        var work = Account.placeholder(id: "codex:plan:business")
        work.suggestedGroup = .work
        work.email = "member@example.com"
        work.accentColorHex = "#ff8800"
        var personal = Account(id: "claude:home:/tmp/claude", provider: .claude, displayName: "Claude Personal", email: "me@example.com", planLabel: "Max", suggestedGroup: .personal, sourceDescription: "test")
        personal.organization = "Me"
        let rates = RateTable.from(liteLLMDocument: ["test-model": ["input_cost_per_token": 0.000003, "output_cost_per_token": 0.000015, "cache_read_input_token_cost": 0.0000003]], source: "LiteLLM", fetchedAt: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var cells: [CellKey: Cell] = [:]
        for offsetMin in stride(from: -60 * 24 * 95, through: 0, by: 37) {
            let ms = nowMs + Int64(offsetMin) * 60_000
            let start = ms / 60_000 * 60_000
            let i = abs(offsetMin)
            cells[CellKey(startMs: start, accountId: personal.id, model: i % 3 == 0 ? "test-model" : "mystery-model")] = Cell(totals: TokenTotals(uncachedInput: 100 + i % 50, cachedInput: i % 70, output: 10 + i % 9), unpricedTotals: TokenTotals(uncachedInput: 100 + i % 50, cachedInput: i % 70, output: 10 + i % 9), records: 1, sessionIds: ["s\(i % 5)"])
            if i % 2 == 0 {
                cells[CellKey(startMs: start, accountId: work.id, model: "test")] = Cell(totals: TokenTotals(uncachedInput: 500), reportedCostUsd: Double(i % 7) * 0.25, records: 1, sessionIds: ["w\(i % 3)"])
            }
            if i % 5 == 0 {
                cells[CellKey(startMs: start, accountId: "codex:plan:plus", model: "test-model")] = Cell(totals: TokenTotals(uncachedInput: 50, output: 5), unpricedTotals: TokenTotals(uncachedInput: 50, output: 5), records: 1, sessionIds: ["p"])
            }
        }
        // Usage minutes before the wall clock, so both hosts' "today" is non-zero.
        cells[CellKey(startMs: Int64(Date().timeIntervalSince1970 * 1000) / 60_000 * 60_000 - 60_000, accountId: personal.id, model: "test-model")] = Cell(totals: TokenTotals(uncachedInput: 1000, output: 100), unpricedTotals: TokenTotals(uncachedInput: 1000, output: 100), records: 1, sessionIds: ["today"])
        let target = CodexUsageTarget(id: "workspace:member", name: "Work", home: "/tmp/unused", email: "member@example.com", plan: "business", serviceAccountId: "workspace", localAccountId: work.id)
        let products: [String: Any] = ["breakdown": "product", "series": [["key": "work", "label": "Work"]], "data_freshness_ts": "2026-10-01T06:00:00Z", "data": [["date": "2026-09-30", "values": ["work": 25]], ["date": "2026-10-01", "values": ["work": 40]]]]
        let tokens: [String: Any] = ["units": "credits", "group_by": "day", "data": [["date": "2026-09-30", "models": [["model": "test", "speed": "standard", "credits": 25, "uncached_text_input_tokens": 20, "cached_text_input_tokens": 80, "text_output_tokens": 10, "text_total_tokens": 110]]], ["date": "2026-10-01", "models": [["model": "test", "speed": "standard", "credits": 40, "uncached_text_input_tokens": 30, "cached_text_input_tokens": 90, "text_output_tokens": 15, "text_total_tokens": 135]]]]]
        let daily = try CodexDailyUsage.decode(products: products, modelCredits: nil, tokens: tokens, estimate: ["estimated_usage_usd_micros": 40_000], target: target, from: "2026-09-30", to: "2026-10-01", now: now)
        let turn = CodexCloudTurnUsage(reference: CodexThreadReference(id: "00000000-0000-4000-8000-000000000001", title: "Cloud task", origin: "cloud"), turnId: "00000000-0000-4000-8000-000000000002", startedAt: now.addingTimeInterval(-3600 * 30), completedAt: now.addingTimeInterval(-3600 * 29), model: "test", totals: TokenTotals(uncachedInput: 20, cachedInput: 80, output: 10), serviceCostUsd: 1.25, responseIds: ["response-1"])
        var cloud = CodexCloudUsageSnapshot(target: target)
        cloud.turns = [turn]; cloud.fetchedAt = now; cloud.status = .ok
        let scan = ScanOutput(cells: cells, rateLimits: ["business": RateLimitSnapshot(planType: "business", timestampMs: nowMs - 600_000, primary: RateLimitWindow(usedPercent: 42.5, windowMinutes: 300, resetsAt: Int64(now.timeIntervalSince1970) + 3600), secondary: RateLimitWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: Int64(now.timeIntervalSince1970) + 86400 * 3), hasCredits: false, unlimitedCredits: nil, creditsBalance: nil), "plus": RateLimitSnapshot(planType: "plus", timestampMs: nowMs, primary: nil, secondary: nil, hasCredits: true, unlimitedCredits: nil, creditsBalance: "5")], sources: [SourceReport(provider: .claude, path: "/tmp/claude", status: .ok, scannedFiles: 3, reusedFiles: 1, skippedFiles: 0), SourceReport(provider: .codex, path: "/tmp/codex", status: .missing, scannedFiles: 0, reusedFiles: 0, skippedFiles: 0, message: "Directory not found.")], scannedAt: now)
        return Scenario(now: now, accounts: [work, personal], targets: [target], rates: rates, scan: scan, daily: [daily], cloud: [cloud])
    }

    static func requests() -> [(String, RemoteRequest)] {
        var requests: [(String, RemoteRequest)] = []
        for d in [1, 7, 30, 90] { requests.append(("summary-\(d)", .init(method: .summary, days: d))) }
        requests.append(("summary-m60", .init(method: .summary, days: 1, minutes: 60)))
        requests.append(("summary-m5", .init(method: .summary, minutes: 1)))
        for d in [1, 30] { requests.append(("models-\(d)", .init(method: .models, days: d))) }
        requests.append(("models-filter", .init(method: .models, days: 30, account: "claude")))
        requests.append(("models-m60", .init(method: .models, minutes: 60)))
        for r in ["minute", "5m", "15m", "hour", "day", "bogus"] { requests.append(("timeline-1-\(r)", .init(method: .timeline, days: 1, resolution: r))) }
        for r in ["hour", "day", "15m"] { requests.append(("timeline-7-\(r)", .init(method: .timeline, days: 7, resolution: r))) }
        requests.append(("timeline-90-day", .init(method: .timeline, days: 90, resolution: "day")))
        requests.append(("timeline-400", .init(method: .timeline, days: 400)))
        requests.append(("timeline-m60", .init(method: .timeline, resolution: "minute", minutes: 60)))
        requests.append(("limits", .init(method: .limits)))
        requests.append(("accounts", .init(method: .accounts)))
        return requests
    }

    @MainActor
    func testHostEngineMatchesAppModelForEveryRequest() async throws {
        let s = try Self.scenario()
        // What AppModel.refresh leaves behind for this scan.
        let model = AppModel()
        model.discovery = Discovery(accounts: s.accounts)
        model.rates = s.rates
        let merged = CodexCloudProjection.merging(s.cloud, into: s.scan)
        model.cells = merged.cells
        model.threadCells = merged.threads
        model.rateLimits = merged.rateLimits
        model.sources = merged.sources
        model.lastScan = s.scan.scannedAt
        model.dailyUsage = s.daily
        model.cloudUsage = s.cloud
        model.recompute(now: s.now)

        // The engine gets the raw pieces and runs its own refresh.
        var configured = Discovery(accounts: s.accounts)
        configured.codexUsageTargets = s.targets
        let discovery = configured
        let loader = HostEngine.Loader(
            discover: { discovery },
            scan: { _, _, _ in s.scan },
            threadCatalog: { _ in [:] },
            accountUsage: { _, _ in [] },
            dailyUsage: { _, _ in s.daily },
            cloudUsage: { _, _ in s.cloud },
            loadCachedRates: { s.rates },
            fetchRates: { throw HostEngine.HostEngineError.offline }
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = HostEngine(serverName: model.remote.serverName, scanCache: dir.appendingPathComponent("scan-cache.json"), loader: loader)
        engine.rates = s.rates
        // Both hosts take "today" from the wall clock, like AppModel.todayTotal.
        await engine.refresh()
        XCTAssertEqual(engine.accounts.map(\.id), model.accounts.map(\.id))

        for (name, request) in Self.requests() {
            let fromMac = try RemoteJSON.encoder.encode(RemoteReportBuilder.reply(for: request, model: model, now: s.now))
            let fromDaemon = try RemoteJSON.encoder.encode(RemoteReportBuilder.reply(for: request, model: engine, now: s.now))
            XCTAssertEqual(String(decoding: fromDaemon, as: UTF8.self), String(decoding: fromMac, as: UTF8.self), name)
        }
        // Sanity: the scenario exercises real numbers.
        let summary = try XCTUnwrap(RemoteReportBuilder.summary(model: engine, days: 1, now: s.now) as RemoteSummary?)
        XCTAssertGreaterThan(summary.total.costUsd, 1)
        XCTAssertEqual(engine.todayTotal, model.todayTotal)
    }

    func testSharedDefinitionsMatchTheMacRanges() {
        XCTAssertEqual(HostSettings.rangeIds, TimeRange.allCases.map(\.id))
        let now = Date(timeIntervalSince1970: 1_790_000_123)
        XCTAssertTrue(ReportWindow.rollingDay(now: now) == TimeRange.day.window(now: now))
        XCTAssertEqual(Format.windowName(minutes: 300), RateLimitLabel.windowName(minutes: 300))
    }
}
