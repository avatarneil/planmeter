import XCTest
@testable import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeter

final class WorkspaceUsageTests: XCTestCase {
    @MainActor
    func testFocusedInspectionKeepsPartialAndCompleteReadingsSeparateFromSharedUsage() async throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let fetched = now.addingTimeInterval(300)
        let date = "2026-10-01"
        let target = CodexUsageTarget(id: "workspace:member", name: "Work", home: "/tmp/unused", email: "member@example.com",
            plan: "business", serviceAccountId: "workspace", localAccountId: "codex:plan:business")
        func creditFeed(_ breakdown: String, dates: [String], credits: Int, freshness: String) -> [String: Any] {
            let key = breakdown == "product" ? "work" : "test"
            return ["breakdown": breakdown, "series": [["key": key, "label": key.capitalized]],
                    "data_freshness_ts": freshness, "data": dates.map { ["date": $0, "values": [key: credits]] }]
        }
        func tokenFeed(dates: [String], credits: Int, tokens: Int, freshness: String) -> [String: Any] {
            ["units": "credits", "group_by": "day", "data_freshness_ts": freshness,
             "data": dates.map { ["date": $0, "models": [["model": "test", "speed": "standard", "credits": credits,
                 "uncached_text_input_tokens": tokens, "cached_text_input_tokens": 0,
                 "text_output_tokens": 0, "text_total_tokens": tokens]]] }]
        }
        let dates = ["2026-09-30", date]
        let oldFreshness = "2026-10-01T10:00:00Z"
        let newFreshness = "2026-10-01T11:00:00Z"
        let shared = try CodexDailyUsage.decode(
            products: creditFeed("product", dates: dates, credits: 25, freshness: oldFreshness),
            modelCredits: creditFeed("model", dates: dates, credits: 25, freshness: oldFreshness),
            tokens: tokenFeed(dates: dates, credits: 25, tokens: 110, freshness: oldFreshness),
            estimate: ["estimated_usage_usd_micros": 40_000], target: target, from: dates[0], to: date, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        for tokensAvailable in [false, true] {
            let focused = try CodexDailyUsage.decode(
                products: creditFeed("product", dates: [date], credits: 50, freshness: newFreshness),
                modelCredits: creditFeed("model", dates: [date], credits: 50, freshness: newFreshness),
                tokens: tokensAvailable ? tokenFeed(dates: [date], credits: 50, tokens: 220, freshness: newFreshness) : nil,
                estimate: ["estimated_usage_usd_micros": 80_000], target: target, from: date, to: date, now: fetched)
            let reader = CodexDailyUsage { _, _, _ in focused }
            let model = AppModel()
            var account = Account.placeholder(id: "codex:plan:business")
            account.suggestedGroup = .work
            model.discovery = Discovery(accounts: [account])
            model.lastScan = now
            model.cells[CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000)),
                accountId: account.id, model: "test")] = Cell(totals: TokenTotals(uncachedInput: 500), reportedCostUsd: 99)
            model.dailyUsage = [shared]
            model.recompute(now: now)
            XCTAssertEqual(model.total.costUsd, 1)

            let result = await model.inspectWorkspaceDay(target: target, date: date, usage: reader)
            let detail = try XCTUnwrap(result)
            XCTAssertEqual(try encoder.encode(detail), try encoder.encode(focused))
            XCTAssertEqual(detail.estimatedCostUsd, 4)
            XCTAssertEqual(detail.fetchedAt, fetched)
            XCTAssertEqual(detail.dataFreshness, newFreshness)
            XCTAssertEqual(detail.status, tokensAvailable ? .ok : .partial)
            XCTAssertEqual(detail.days[0].textModels?.first?.totalTokens, tokensAvailable ? 220 : nil)
            XCTAssertEqual(try encoder.encode(model.dailyUsage), try encoder.encode([shared]))

            model.recompute(now: now)
            XCTAssertEqual(model.total.costUsd, 1)
            XCTAssertEqual(model.total.totals.total, 110)
            let expectedMenu = model.menuBarSpendGroups.contains(model.group(for: account)) ? 1.0 : 0.0
            XCTAssertEqual(try XCTUnwrap(model.desktopSnapshot(now: now)).cost, expectedMenu)
            let summary = RemoteReportBuilder.summary(model: model, days: 1, now: now)
            XCTAssertEqual(summary.total.costUsd, 1)
            XCTAssertEqual(summary.total.tokens, 110)
            let timeline = RemoteReportBuilder.timeline(model: model, days: 1, resolution: .hour, now: now)
            XCTAssertEqual(timeline.points.reduce(0) { $0 + $1.costUsd }, 1)
        }
    }

    @MainActor
    func testWorkspaceUsageFlowsThroughDashboardDrilldownsMenuWidgetsAndRemoteReports() throws {
        let model = AppModel()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        var account = Account.placeholder(id: "codex:plan:business")
        account.suggestedGroup = .work
        model.discovery = Discovery(accounts: [account])
        model.lastScan = now
        model.cells[CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000)), accountId: account.id, model: "test")] = Cell(totals: TokenTotals(uncachedInput: 500), reportedCostUsd: 99)
        let target = CodexUsageTarget(id: "workspace:member", name: "Work", home: "/tmp/unused", email: "member@example.com", plan: "business", serviceAccountId: "workspace", localAccountId: account.id)
        let products: [String: Any] = ["breakdown": "product", "series": [["key": "work", "label": "Work"]], "data": [["date": "2026-10-01", "values": ["work": 25]]]]
        let tokens: [String: Any] = ["units": "credits", "group_by": "day", "data": [["date": "2026-10-01", "models": [["model": "test", "speed": "standard", "credits": 25, "uncached_text_input_tokens": 20, "cached_text_input_tokens": 80, "text_output_tokens": 10, "text_total_tokens": 110]]]]]
        model.dailyUsage = [try CodexDailyUsage.decode(products: products, modelCredits: nil, tokens: tokens, estimate: ["estimated_usage_usd_micros": 40_000], target: target, from: "2026-10-01", to: "2026-10-01", now: now)]
        model.recompute(now: now)
        XCTAssertEqual(model.chartResolution, .day)
        XCTAssertEqual(model.total.costUsd, 1)
        XCTAssertEqual(model.total.totals.total, 110)
        XCTAssertEqual(model.groupSummaries.first { $0.group == model.group(for: account) }?.aggregate.costUsd, 1)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .account(account.id))).costUsd, 1)
        let expectedSelected = model.menuBarSpendGroups.contains(model.group(for: account)) ? 1.0 : 0.0
        XCTAssertEqual(model.menuBarTotal.costUsd, expectedSelected)
        let widget = try XCTUnwrap(model.desktopSnapshot(now: now))
        XCTAssertEqual(widget.cost, expectedSelected)
        XCTAssertEqual(widget.detail?.hourly, false)
        XCTAssertEqual(widget.detail?.trend.reduce(0) { $0 + $1.cost }, expectedSelected)
        let summary = RemoteReportBuilder.summary(model: model, days: 1, now: now)
        XCTAssertEqual(summary.total.costUsd, 1)
        XCTAssertEqual(summary.total.tokens, 110)
        XCTAssertEqual(summary.usesProviderDates, true)
        let timeline = RemoteReportBuilder.timeline(model: model, days: 1, resolution: .hour, now: now)
        XCTAssertEqual(timeline.resolution, "day")
        XCTAssertEqual(timeline.points.reduce(0) { $0 + $1.costUsd }, 1)
        XCTAssertEqual(timeline.periods.count, 1)
        XCTAssertEqual(RemoteReportBuilder.models(model: model, days: 1, filter: nil, now: now).reduce(0) { $0 + $1.totals.costUsd }, 1)
        model.range = .day
        model.recompute(now: now)
        XCTAssertEqual(model.chartResolution, .hour)
        XCTAssertEqual(model.total.costUsd, 99)
        XCTAssertTrue(model.usageNote.contains("calendar days"))
    }
}
