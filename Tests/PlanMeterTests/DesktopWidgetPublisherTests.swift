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
    }
}
