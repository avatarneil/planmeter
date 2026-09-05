import XCTest
import PlanMeterCore
@testable import PlanMeter

final class DesktopWidgetPublisherTests: XCTestCase {
    @MainActor
    func testWidgetMatchesMenuBarSelectionAndPreservesScanTime() async throws {
        let model = AppModel()
        XCTAssertNil(model.desktopSnapshot())
        let now = Date()
        let hour = CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000))
        // Read the configured selection without changing persisted preferences.
        // Populate every group so any selection exercises the same total path.
        model.discovery = Discovery(accounts: PlanGroup.allCases.enumerated().map { index, group in
            var account = Account.placeholder(id: "desktop-widget-test-\(index)")
            account.provider = index == 0 ? .claude : .codex
            account.suggestedGroup = group
            return account
        })
        for (index, account) in model.accounts.enumerated() {
            model.cells[CellKey(hourStartMs: hour, accountId: account.id, model: "test")] = Cell(reportedCostUsd: Double((index + 1) * 10))
            model.cells[CellKey(hourStartMs: hour - 100 * 86_400_000, accountId: account.id, model: "test")] = Cell(reportedCostUsd: 9000)
        }
        model.lastScan = now.addingTimeInterval(-120)
        let snapshot = try XCTUnwrap(model.desktopSnapshot(now: now))
        XCTAssertEqual(snapshot.cost, model.menuBarTotal.costUsd)
        XCTAssertEqual(snapshot.providers.reduce(0) { $0 + $1.cost }, snapshot.cost)
        XCTAssertEqual(snapshot.groups, model.menuBarSpendGroups.map(\.displayName).sorted())
        XCTAssertEqual(snapshot.limit, model.menuBarSpendThreshold?.limit)
        XCTAssertEqual(snapshot.scannedAt, model.lastScan)
        XCTAssertEqual(snapshot.rangeID, model.menuBarSpendRange.rawValue)
        XCTAssertLessThan(snapshot.cost, 100)
        let detail = try XCTUnwrap(snapshot.detail)
        XCTAssertEqual(detail.trend.reduce(0) { $0 + $1.cost }, snapshot.cost, accuracy: 0.00001)
        XCTAssertEqual(detail.accounts.reduce(0) { $0 + $1.cost }, snapshot.cost, accuracy: 0.00001)
        XCTAssertEqual(detail.trend.map(\.date), detail.trend.map(\.date).sorted())
        XCTAssertEqual(detail.accounts.count, model.accounts.filter { model.menuBarSpendGroups.contains(model.group(for: $0)) }.count)
    }
    @MainActor
    func testEmptyPeriodsAreIncludedInTrend() async throws {
        let model = AppModel()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12, minute: 30))!
        model.lastScan = now
        let snapshot = try XCTUnwrap(model.desktopSnapshot(now: now))
        let detail = try XCTUnwrap(snapshot.detail)
        XCTAssertGreaterThan(detail.trend.count, 1)
        XCTAssertTrue(detail.trend.allSatisfy { $0.cost == 0 })
        XCTAssertTrue(detail.trend.allSatisfy { $0.date < now })
    }

}
