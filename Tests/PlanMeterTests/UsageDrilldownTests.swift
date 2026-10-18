import XCTest
import PlanMeterCore
@testable import PlanMeter

final class UsageDrilldownTests: XCTestCase {
    func testStackHitSelectsExactSeriesAndIgnoresEmptySpace() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = UsageScope.account("first")
        let second = UsageScope.account("second")
        let end = date.addingTimeInterval(3600)
        let points = [
            ChartPoint(period: date, end: end, scope: first, value: 10),
            ChartPoint(period: date, end: end, scope: .account("zero"), value: 0, lowerBound: 10),
            ChartPoint(period: date, end: end, scope: second, value: 20, lowerBound: 10),
        ]
        XCTAssertEqual(ChartPoint.selected(in: points, date: date, value: 5), first)
        XCTAssertEqual(ChartPoint.selected(in: points, date: date.addingTimeInterval(1800), value: 10), second)
        XCTAssertEqual(ChartPoint.selected(in: points, date: date, value: 29), second)
        XCTAssertNil(ChartPoint.selected(in: points, date: date, value: 31))
        XCTAssertNil(ChartPoint.selected(in: points, date: date, value: -1))
        XCTAssertNil(ChartPoint.selected(in: points, date: end, value: 5))
        // Minute buckets select by their own one-minute span.
        let minute = [ChartPoint(period: date, end: date.addingTimeInterval(60), scope: first, value: 1, baseline: true)]
        XCTAssertEqual(ChartPoint.selected(in: minute, date: date.addingTimeInterval(59), value: 0.5), first)
        XCTAssertNil(ChartPoint.selected(in: minute, date: date.addingTimeInterval(61), value: 0.5))
        XCTAssertNotEqual(minute[0].series, first.id)
    }

    @MainActor
    func testProviderAndAccountDrilldownUseStableIDsAndGroupOverrides() async {
        let model = AppModel()
        var personal = Account.placeholder(id: "claude:personal-test")
        personal.provider = .claude
        personal.displayName = "Same name"
        personal.suggestedGroup = .personal
        var work = Account.placeholder(id: "claude:work-test")
        work.provider = .claude
        work.displayName = "Same name"
        work.suggestedGroup = .work
        var codex = Account.placeholder(id: "codex:test")
        codex.provider = .codex
        codex.suggestedGroup = .work
        model.discovery = Discovery(accounts: [personal, work, codex])
        let date = Date()
        func bucket(_ account: Account, cost: Double) -> Bucket {
            Bucket(periodStart: date, accountId: account.id, model: "test-model", totals: .zero,
                   costUsd: cost, cacheSavingsUsd: 0, costSource: .providerReported, records: 1, sessions: 1)
        }
        model.buckets = [bucket(personal, cost: 10), bucket(work, cost: 20), bucket(codex, cost: 40)]
        XCTAssertEqual(Aggregation.total(model.buckets(in: .provider(.claude))).costUsd, 30)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .account(personal.id))).costUsd, 10)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .account(work.id))).costUsd, 20)
        XCTAssertEqual(Aggregation.total(model.buckets(in: .group(.work))).costUsd, 60)
        XCTAssertTrue(model.buckets(in: .account("missing")).isEmpty)
        // Group matching honors the supplied resolved group, not the suggested one.
        XCTAssertTrue(UsageScope.group(.work).includes(personal, group: .work))
        XCTAssertFalse(UsageScope.group(.personal).includes(personal, group: .work))
    }
}
