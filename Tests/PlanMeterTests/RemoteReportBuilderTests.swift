import XCTest
import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeter

final class RemoteReportBuilderTests: XCTestCase {
    @MainActor
    func testOneDayRequestsIncludePreviousDayAcrossAllReports() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T09:30:00Z"))
        let hour = now.addingTimeInterval(-30 * 60)
        let model = AppModel()
        let account = Account.placeholder(id: "remote-window-test")
        model.discovery = Discovery(accounts: [account])
        for (offset, cost) in [(-24, 1000.0), (-23, 10.0), (-12, 20.0), (0, 30.0), (1, 2000.0)] {
            let date = hour.addingTimeInterval(Double(offset) * 3600)
            model.cells[CellKey(hourStartMs: Int64(date.timeIntervalSince1970 * 1000), accountId: account.id, model: "test")] = Cell(reportedCostUsd: cost)
        }
        model.recompute(now: now)

        let summary = try XCTUnwrap(RemoteReportBuilder.reply(for: .init(method: .summary, days: 1), model: model, now: now).summary)
        let timeline = try XCTUnwrap(RemoteReportBuilder.reply(for: .init(method: .timeline, days: 1, resolution: "hour"), model: model, now: now).timeline)
        let rows = try XCTUnwrap(RemoteReportBuilder.reply(for: .init(method: .models, days: 1), model: model, now: now).models)

        XCTAssertEqual(summary.from, hour.addingTimeInterval(-23 * 3600))
        XCTAssertEqual(summary.to, hour.addingTimeInterval(3600))
        XCTAssertEqual(summary.total.costUsd, 60)
        XCTAssertEqual(summary.groups.flatMap(\.accounts).reduce(0) { $0 + $1.totals.costUsd }, 60)
        XCTAssertEqual(summary.todayCostUsd, model.todayTotal.costUsd)
        XCTAssertEqual(timeline.periods.count, 24)
        XCTAssertEqual(timeline.periods.first, summary.from)
        XCTAssertEqual(timeline.periods.last, hour)
        XCTAssertEqual(timeline.points.count, 3)
        XCTAssertEqual(timeline.points.reduce(0) { $0 + $1.costUsd }, 60)
        XCTAssertTrue(timeline.points.allSatisfy { timeline.periods.contains($0.period) })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.totals.costUsd, 60)
    }

    @MainActor
    func testOneDayRemains24HoursAcrossMidnightAndDaylightSavingChanges() throws {
        let model = AppModel()
        for timestamp in ["2026-09-07T00:00:00Z", "2026-09-07T04:01:00Z", "2026-03-08T16:30:00Z", "2026-11-01T17:30:00Z"] {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
            let result = RemoteReportBuilder.buckets(model: model, days: 1, now: now)
            XCTAssertEqual(result.to.timeIntervalSince(result.from), 24 * 3600, timestamp)
            XCTAssertLessThanOrEqual(result.from, now.addingTimeInterval(-23 * 3600), timestamp)
            XCTAssertGreaterThan(result.to, now, timestamp)
            XCTAssertLessThanOrEqual(result.to.timeIntervalSince(now), 3600, timestamp)
            let timeline = RemoteReportBuilder.timeline(model: model, days: 1, resolution: .hour, now: now)
            XCTAssertEqual(timeline.periods.count, 24, timestamp)
        }
    }

    @MainActor
    func testLongerRangesKeepCalendarDayWindows() throws {
        let model = AppModel()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T09:30:00Z"))
        for days in [7, 30, 90] {
            let expected = Report.window(days: days, now: now)
            let result = RemoteReportBuilder.buckets(model: model, days: days, now: now)
            XCTAssertEqual(result.from, expected.from)
            XCTAssertEqual(result.to, expected.to)
            XCTAssertEqual(RemoteReportBuilder.timeline(model: model, days: days, resolution: .day, now: now).periods.count, days)
        }
    }
}
