import XCTest
@testable import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeter

final class WorkspaceUsageTests: XCTestCase {
    @MainActor
    func testFocusedInspectionKeepsPartialAndCompleteReadingsSeparateFromSharedUsage() async throws {
        // 10:30 UTC is inside UTC October 1 and never exactly local midnight, in every time zone.
        let now = UsageCoverage.utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10, minute: 30))!
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
        let dates = [date]
        // Both readings report all of UTC October 1, so they cover the local usage.
        let oldFreshness = "2026-10-02T00:00:00Z"
        let newFreshness = "2026-10-02T01:00:00Z"
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
            model.cells[CellKey(startMs: CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000)),
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
        // 10:30 UTC is inside UTC October 1 and never exactly local midnight, in every time zone.
        let now = UsageCoverage.utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10, minute: 30))!
        var account = Account.placeholder(id: "codex:plan:business")
        account.suggestedGroup = .work
        model.discovery = Discovery(accounts: [account])
        model.lastScan = now
        model.cells[CellKey(startMs: CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000)), accountId: account.id, model: "test")] = Cell(totals: TokenTotals(uncachedInput: 500), reportedCostUsd: 99)
        let target = CodexUsageTarget(id: "workspace:member", name: "Work", home: "/tmp/unused", email: "member@example.com", plan: "business", serviceAccountId: "workspace", localAccountId: account.id)
        // Reported through the end of UTC October 1, so the reading covers the local usage.
        let products: [String: Any] = ["breakdown": "product", "series": [["key": "work", "label": "Work"]], "data_freshness_ts": "2026-10-02T00:00:00Z", "data": [["date": "2026-10-01", "values": ["work": 25]]]]
        let tokens: [String: Any] = ["units": "credits", "group_by": "day", "data": [["date": "2026-10-01", "models": [["model": "test", "speed": "standard", "credits": 25, "uncached_text_input_tokens": 20, "cached_text_input_tokens": 80, "text_output_tokens": 10, "text_total_tokens": 110]]]]]
        model.dailyUsage = [try CodexDailyUsage.decode(products: products, modelCredits: nil, tokens: tokens, estimate: ["estimated_usage_usd_micros": 40_000], target: target, from: "2026-10-01", to: "2026-10-01", now: now)]
        model.recompute(now: now)
        XCTAssertEqual(model.chartResolution, .hour) // Workspace readings no longer force daily buckets.
        XCTAssertEqual(model.total.costUsd, 1)
        // The reading follows the replaced local usage into its hour.
        let hour = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        XCTAssertEqual(Aggregation.total(model.buckets.filter { $0.periodStart == hour }).costUsd, 1)
        XCTAssertEqual(model.total.totals.total, 110)
        XCTAssertEqual(model.groupSummaries.first { $0.group == model.group(for: account) }?.aggregate.costUsd, 1)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .account(account.id))).costUsd, 1)
        let expectedSelected = model.menuBarSpendGroups.contains(model.group(for: account)) ? 1.0 : 0.0
        XCTAssertEqual(model.menuBarTotal.costUsd, expectedSelected)
        let widget = try XCTUnwrap(model.desktopSnapshot(now: now))
        XCTAssertEqual(widget.cost, expectedSelected)
        XCTAssertEqual(widget.detail?.hourly, true)
        XCTAssertEqual(widget.detail?.trend.reduce(0) { $0 + $1.cost }, expectedSelected)
        let summary = RemoteReportBuilder.summary(model: model, days: 1, now: now)
        XCTAssertEqual(summary.total.costUsd, 1)
        XCTAssertEqual(summary.total.tokens, 110)
        XCTAssertNil(summary.usesProviderDates) // One day is the rolling 24 hours for every account.
        let timeline = RemoteReportBuilder.timeline(model: model, days: 1, resolution: .hour, now: now)
        XCTAssertEqual(timeline.resolution, "hour")
        XCTAssertEqual(timeline.points.reduce(0) { $0 + $1.costUsd }, 1, accuracy: 0.0000001)
        XCTAssertEqual(timeline.periods.count, 24)
        let minutes = RemoteReportBuilder.timeline(model: model, days: 1, minutes: 60, resolution: .minute, now: now)
        XCTAssertEqual(minutes.resolution, "minute")
        XCTAssertEqual(minutes.minutes, 60)
        XCTAssertEqual(minutes.periods.count, 60)
        XCTAssertEqual(RemoteReportBuilder.models(model: model, days: 1, filter: nil, now: now).reduce(0) { $0 + $1.totals.costUsd }, 1)
        // Every granularity agrees, including mid-hour freshness on hour cells.
        var midHour = model.dailyUsage[0]
        midHour.creditsFreshness = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        model.dailyUsage = [midHour]
        model.cells[CellKey(startMs: Int64(now.timeIntervalSince1970 * 1000) - 60_000 - 1_000 * 60 * 5, accountId: account.id, model: "test")] = Cell(reportedCostUsd: 2)
        model.cells[CellKey(startMs: Int64(now.timeIntervalSince1970 * 1000) + 60_000 * 3, accountId: account.id, model: "test")] = Cell(reportedCostUsd: 4)
        let day = Report.window(days: 1, now: now)
        let totals = Resolution.allCases.map { Aggregation.total(model.projectedUsage(from: day.from, to: day.to, resolution: $0).buckets).costUsd }
        for total in totals { XCTAssertEqual(total, totals[0], accuracy: 0.0000001) }
        model.dailyUsage = [midHour]
        model.range = .day
        model.recompute(now: now)
        XCTAssertEqual(model.chartResolution, .hour)
        XCTAssertGreaterThan(model.total.costUsd, 1) // Usage after the provider's freshness stays local.
        XCTAssertTrue(model.usageNote.contains("baseline"))
    }
}
