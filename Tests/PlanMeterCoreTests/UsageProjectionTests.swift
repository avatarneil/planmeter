import XCTest
@testable import PlanMeterCore

final class UsageProjectionTests: XCTestCase {
    let fixture = CodexDailyUsageTests()
    var account: Account { Account.placeholder(id: fixture.target.localAccountId!) }
    var from: Date { fixture.now.addingTimeInterval(-86_400) }
    var to: Date { fixture.now }

    func local(_ id: String? = nil, date: Date? = nil, cost: Double = 9) -> Bucket {
        Bucket(periodStart: date ?? from, accountId: id ?? account.id, model: "test", totals: TokenTotals(uncachedInput: 500),
               costUsd: cost, cacheSavingsUsd: 2, costSource: .modelPriced, records: 2, sessions: 1)
    }
    func project(_ snapshots: [CodexDailyUsageSnapshot], local rows: [Bucket]? = nil, to end: Date? = nil) -> UsageProjection.Result {
        UsageProjection.buckets(local: rows ?? [local()], snapshots: snapshots,
                                accounts: [account, Account.placeholder(id: "claude:other")], from: from, to: end ?? to, calendar: UsageCoverage.utcCalendar)
    }

    func testWorkspaceReplacesOverlappingLocalCostAndTokensWhileRetainingOtherProviders() throws {
        let result = project([try fixture.snapshot()], local: [local(), local("claude:other", cost: 3)])
        let byAccount = Aggregation.byAccount(result.buckets)
        let usage = try XCTUnwrap(byAccount[account.id])
        XCTAssertEqual(usage.costUsd, 1.6875, accuracy: 0.0000001)
        XCTAssertEqual(usage.totals.total, 160)
        XCTAssertEqual(usage.totals.cachedInput, 110)
        XCTAssertEqual(usage.sessions, 1)
        XCTAssertEqual(usage.cacheSavingsUsd, 2)
        XCTAssertEqual(byAccount["claude:other"]?.costUsd, 3)
        XCTAssertEqual(result.workspaceAccountIds, [account.id])
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 4.6875, accuracy: 0.0000001)
    }

    func testModelCostsAndTokensRemainIndependentAndSumToAuthoritativeDailyCost() throws {
        let result = project([try fixture.snapshot()])
        let models = Aggregation.byModel(result.buckets)
        XCTAssertEqual(models["test"]?.totals.total, 160)
        XCTAssertEqual(models["test"]?.costUsd, 1.65)
        XCTAssertEqual(models["voice"]?.totals.total, 0)
        XCTAssertEqual(models["voice"]?.costUsd, 0.0375)
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875)
    }

    func testMissingDaysRetainLocalUsageButExplicitZeroReplacesIt() throws {
        let next = local(date: to, cost: 5)
        let result = project([try fixture.snapshot()], local: [local(), next], to: to.addingTimeInterval(86_400))
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 6.6875)
        var zero = try fixture.snapshot()
        zero.days[0].products = [DailyCreditValue(key: "codex", label: "Codex", credits: 0)]
        zero.days[0].modelCredits = []
        zero.days[0].textModels = []
        let projected = project([zero])
        XCTAssertEqual(Aggregation.total(projected.buckets).costUsd, 0)
        XCTAssertEqual(Aggregation.total(projected.buckets).totals.total, 0)
        XCTAssertEqual(projected.workspaceAccountIds, [account.id])
    }

    func testAmbiguousUnconfiguredAndDuplicateAccountReadingsCannotReplaceLocals() throws {
        var snapshot = try fixture.snapshot()
        XCTAssertEqual(Aggregation.total(project([snapshot, snapshot]).buckets).costUsd, 9)
        snapshot.target.localAccountId = nil
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 9)
        snapshot.target.localAccountId = "unconfigured"
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 9)
    }

    func testUnavailableUSDOrTextIOKeepsLocalMetricsAndMissingModelsKeepFullCost() throws {
        var snapshot = try fixture.snapshot()
        snapshot.estimatedUsdPerCredit = nil
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 9)
        snapshot = try fixture.snapshot(); snapshot.days[0].textModels = nil
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 9)
        snapshot = try fixture.snapshot(); snapshot.days[0].modelCredits = nil
        let rows = project([snapshot]).buckets
        XCTAssertEqual(Aggregation.total(rows).costUsd, 1.6875)
        XCTAssertEqual(Aggregation.total(rows).totals.total, 160)
        XCTAssertEqual(rows.first { $0.model == "Additional workspace credits" }?.costUsd, 0.0375)
    }

    func testMeteredTaskCreditsStayWithTokensWhenBillingModelGroupsUseOtherNames() throws {
        var snapshot = try fixture.snapshot()
        snapshot.days[0].products = [DailyCreditValue(key: "work", label: "Work", credits: 14.5)]
        snapshot.days[0].modelCredits = [DailyCreditValue(key: "luna", label: "Luna", credits: 14), DailyCreditValue(key: "voice", label: "Voice", credits: 0.5)]
        snapshot.days[0].textModels = [
            DailyModelTokens(model: "auto-review", speed: "standard", credits: 10, uncachedInputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1),
            DailyModelTokens(model: "luna", speed: "standard", credits: 4, uncachedInputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1)]
        let byModel = Aggregation.byModel(project([snapshot]).buckets)
        XCTAssertEqual(byModel["auto-review"]?.costUsd, 0.75)
        XCTAssertEqual(byModel["luna"]?.costUsd, 0.3)
        XCTAssertEqual(byModel["voice"]?.costUsd, 0.0375)
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 1.0875, accuracy: 0.000000001)
    }

    func testProjectionDisplaysProviderLabelsOnCalendarDatesAcrossTimeZones() throws {
        var calendar = UsageCoverage.utcCalendar
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let from = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let result = UsageProjection.buckets(local: [], snapshots: [try fixture.snapshot()], accounts: [account],
            from: from, to: from.addingTimeInterval(86_400), calendar: calendar)
        XCTAssertTrue(result.buckets.allSatisfy { $0.periodStart == from })
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875)
    }
}
