import XCTest
@testable import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeter

final class CloudUsageTests: XCTestCase {
    @MainActor
    func testDatedCloudSpendFlowsThroughDashboardWidgetsAndCompanionReports() throws {
        let model = AppModel()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        var account = Account.placeholder(id: "codex:plan:business")
        account.suggestedGroup = .work
        model.discovery = Discovery(accounts: [account])
        model.lastScan = now
        let target = CodexUsageTarget(id: "workspace:member", name: "Work", home: "/tmp/unused", email: "member@example.com",
            plan: "business", serviceAccountId: "workspace", localAccountId: account.id)
        let turn = CodexCloudTurnUsage(reference: CodexThreadReference(id: "00000000-0000-4000-8000-000000000001",
            title: "Cloud task", origin: "cloud"), turnId: "00000000-0000-4000-8000-000000000002",
            startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-60), model: "test",
            totals: TokenTotals(uncachedInput: 20, cachedInput: 80, output: 10), serviceCostUsd: 1.25, responseIds: ["response-1"])
        var cloud = CodexCloudUsageSnapshot(target: target)
        cloud.turns = [turn]; cloud.fetchedAt = now; cloud.status = .ok
        let combined = CodexCloudProjection.merging([cloud], into: ScanOutput())
        model.cloudUsage = [cloud]
        model.cells = combined.cells; model.threadCells = combined.threads
        model.recompute(now: now)
        XCTAssertEqual(model.chartResolution, .hour)
        XCTAssertEqual(model.total.costUsd, 1.25)
        XCTAssertEqual(model.total.totals.total, 110)
        XCTAssertEqual(model.groupSummaries.first { $0.group == .work }?.aggregate.costUsd, 1.25)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .account(account.id))).costUsd, 1.25)
        let expectedMenu = model.menuBarSpendGroups.contains(.work) ? 1.25 : 0
        XCTAssertEqual(model.menuBarTotal.costUsd, expectedMenu)
        XCTAssertEqual(try XCTUnwrap(model.desktopSnapshot(now: now)).cost, expectedMenu)
        let summary = RemoteReportBuilder.summary(model: model, days: 1, now: now)
        XCTAssertEqual(summary.total.costUsd, 1.25)
        XCTAssertEqual(summary.total.tokens, 110)
        XCTAssertNil(summary.usesProviderDates)
        let timeline = RemoteReportBuilder.timeline(model: model, days: 1, resolution: .hour, now: now)
        XCTAssertEqual(timeline.points.reduce(0) { $0 + $1.costUsd }, 1.25)
        XCTAssertEqual(RemoteReportBuilder.models(model: model, days: 1, filter: nil, now: now).reduce(0) { $0 + $1.totals.costUsd }, 1.25)
    }
}
