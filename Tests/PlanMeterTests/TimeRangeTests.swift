import XCTest
import PlanMeterCore
@testable import PlanMeter

final class TimeRangeTests: XCTestCase {
    func testTodayUsesLocalMidnightAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        for (month, day, hoursSinceMidnight) in [(3, 8, 11.5), (11, 1, 13.5)] {
            let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12, minute: 30)))
            let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let window = TimeRange.today.window(now: now, calendar: calendar)
            XCTAssertEqual(window.from, midnight)
            XCTAssertEqual(window.to, now)
            XCTAssertEqual(window.to.timeIntervalSince(window.from), hoursSinceMidnight * 3600)
            XCTAssertLessThan(TimeRange.day.window(now: now, calendar: calendar).from, window.from)
        }
        XCTAssertEqual(TimeRange.today.resolution, .hour)
    }

    func testSpendLimitKeysRemainCompatibleWithSavedPreferences() {
        XCTAssertEqual(TimeRange.today.id, "today")
        XCTAssertEqual(TimeRange.day.id, "day")
        XCTAssertEqual(TimeRange.week.id, "week")
        XCTAssertEqual(TimeRange.month.id, "month")
        XCTAssertEqual(TimeRange.quarter.id, "quarter")
    }

    @MainActor
    func testRangeSelectionUpdatesAllUsageSurfacesWithoutRescanning() async throws {
        let model = AppModel()
        XCTAssertEqual(model.range, .today)
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let hour = CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000))
        let previousHour = midnight.addingTimeInterval(-3600)
        let previousHourMs = Int64(previousHour.timeIntervalSince1970 * 1000)
        let history: [(Int64, Double)] = [
            (hour, 10),
            (previousHourMs, 20),
            (Int64(calendar.date(byAdding: .day, value: -3, to: midnight)!.timeIntervalSince1970 * 1000), 30),
            (Int64(calendar.date(byAdding: .day, value: -15, to: midnight)!.timeIntervalSince1970 * 1000), 40),
            (Int64(calendar.date(byAdding: .day, value: -60, to: midnight)!.timeIntervalSince1970 * 1000), 50),
            (Int64(calendar.date(byAdding: .day, value: -100, to: midnight)!.timeIntervalSince1970 * 1000), 9000),
        ]
        model.discovery = Discovery(accounts: PlanGroup.allCases.enumerated().map { index, group in
            var account = Account.placeholder(id: "range-test-\(index)")
            account.provider = index == 0 ? .claude : .codex
            account.suggestedGroup = group
            return account
        })
        for (index, account) in model.accounts.enumerated() {
            for (timestamp, cost) in history {
                model.cells[CellKey(hourStartMs: timestamp, accountId: account.id, model: "test")] =
                    Cell(reportedCostUsd: cost * Double(index + 1))
            }
        }
        model.lastScan = now.addingTimeInterval(-120)
        let savedLimits = model.menuBarSpendThresholds
        let expectedDayCost: Double = previousHourMs >= hour - 23 * 3_600_000 ? 30 : 10
        let selections: [(TimeRange, Double)] = [
            (.today, 10), (.day, expectedDayCost), (.week, 60), (.month, 100), (.quarter, 150), (.today, 10),
        ]

        for (range, costPerUnit) in selections {
            model.range = range
            XCTAssertEqual(model.total.costUsd, costPerUnit * 6, range.rawValue)
            var selectedCost = 0.0
            for (index, account) in model.accounts.enumerated() {
                let expected = costPerUnit * Double(index + 1)
                let group = model.group(for: account)
                let summary = try XCTUnwrap(model.groupSummaries.first { $0.group == group })
                XCTAssertEqual(summary.aggregate.costUsd, expected)
                XCTAssertEqual(summary.accounts.first?.aggregate.costUsd, expected)
                XCTAssertEqual(Aggregation.total(model.buckets(in: .account(account.id))).costUsd, expected)
                XCTAssertEqual(Aggregation.total(model.buckets(in: .group(group))).costUsd, expected)
                if model.menuBarSpendGroups.contains(group) { selectedCost += expected }
            }
            XCTAssertEqual(Aggregation.total(model.buckets(in: .provider(.codex))).costUsd, costPerUnit * 5)
            XCTAssertEqual(model.menuBarTotal.costUsd, selectedCost)
            XCTAssertEqual(model.menuBarSpendThreshold, savedLimits[range.id])
            let snapshot = try XCTUnwrap(model.desktopSnapshot(now: now))
            XCTAssertEqual(snapshot.cost, selectedCost)
            XCTAssertEqual(snapshot.rangeID, range.id)
            XCTAssertEqual(snapshot.rangeName, range.displayName)
            XCTAssertEqual(snapshot.limit, savedLimits[range.id]?.limit)
            XCTAssertEqual(snapshot.detail?.hourly, range == .today || range == .day)
            XCTAssertEqual(snapshot.scannedAt, now.addingTimeInterval(-120))
        }
    }

    @MainActor
    func testTodayRefreshUpdatesSpendAndRollsOverAtMidnight() async throws {
        let model = AppModel()
        let calendar = Calendar.current
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 23, minute: 30)))
        let afterMidnight = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: beforeMidnight))
        var account = Account.placeholder(id: "today-refresh-test")
        account.suggestedGroup = try XCTUnwrap(model.menuBarSpendGroups.first)
        model.discovery = Discovery(accounts: [account])
        let beforeKey = CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(beforeMidnight.timeIntervalSince1970 * 1000)),
                                accountId: account.id, model: "test")
        model.cells[beforeKey] = Cell(reportedCostUsd: 10)
        model.recompute(now: beforeMidnight)
        XCTAssertEqual(model.total.costUsd, 10)
        XCTAssertEqual(model.menuBarTotal.costUsd, 10)

        model.cells[beforeKey] = Cell(reportedCostUsd: 15)
        model.recompute(now: beforeMidnight)
        XCTAssertEqual(model.total.costUsd, 15)
        XCTAssertEqual(model.menuBarTotal.costUsd, 15)

        model.recompute(now: afterMidnight)
        XCTAssertEqual(model.range, .today)
        XCTAssertEqual(model.total.costUsd, 0)
        XCTAssertEqual(model.menuBarTotal.costUsd, 0)

        let afterKey = CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(afterMidnight.timeIntervalSince1970 * 1000)),
                               accountId: account.id, model: "test")
        model.cells[afterKey] = Cell(reportedCostUsd: 3)
        model.recompute(now: afterMidnight)
        XCTAssertEqual(model.total.costUsd, 3)
        XCTAssertEqual(model.menuBarTotal.costUsd, 3)
    }
}
