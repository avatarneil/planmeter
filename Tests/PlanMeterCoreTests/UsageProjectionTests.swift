import XCTest
@testable import PlanMeterCore

final class UsageProjectionTests: XCTestCase {
    let fixture = CodexDailyUsageTests()
    var account: Account { Account.placeholder(id: fixture.target.localAccountId!) }
    var from: Date { fixture.now.addingTimeInterval(-86_400) }
    var to: Date { fixture.now }
    let rates = RateTable(rates: ["test": ModelRate(input: 0.01, output: 0.02, cacheRead: 0.001, cacheCreation: 0.01)])
    var newYork: Calendar {
        var calendar = UsageCoverage.utcCalendar
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func cell(_ id: String? = nil, at date: Date? = nil, cost: Double = 9, session: String = "s1") -> (CellKey, Cell) {
        let key = CellKey(hourStartMs: Int64((date ?? from).timeIntervalSince1970 * 1000), accountId: id ?? account.id, model: "test")
        return (key, Cell(totals: TokenTotals(uncachedInput: 400, cachedInput: 100), reportedCostUsd: cost, records: 2, sessionIds: [session]))
    }
    func project(_ snapshots: [CodexDailyUsageSnapshot], cells rows: [(CellKey, Cell)]? = nil, from start: Date? = nil, to end: Date? = nil,
                 calendar: Calendar = UsageCoverage.utcCalendar) -> UsageProjection.Result {
        UsageProjection.buckets(cells: Dictionary(rows ?? [cell()], uniquingKeysWith: { $1 }), rates: rates, snapshots: snapshots,
                                accounts: [account, Account.placeholder(id: "claude:other")], from: start ?? from, to: end ?? to,
                                resolution: .day, calendar: calendar)
    }

    func testWorkspaceReplacesOverlappingLocalCostAndTokensWhileRetainingOtherProviders() throws {
        let result = project([try fixture.snapshot()], cells: [cell(), cell("claude:other", cost: 3)])
        let byAccount = Aggregation.byAccount(result.buckets)
        let usage = try XCTUnwrap(byAccount[account.id])
        XCTAssertEqual(usage.costUsd, 1.6875, accuracy: 0.0000001)
        XCTAssertEqual(usage.totals.total, 160)
        XCTAssertEqual(usage.totals.cachedInput, 110)
        XCTAssertEqual(usage.sessions, 1)
        XCTAssertEqual(usage.cacheSavingsUsd, 0.9, accuracy: 0.0000001) // From the replaced local usage.
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
        let next = cell(at: to, cost: 5)
        let result = project([try fixture.snapshot()], cells: [cell(), next], to: to.addingTimeInterval(86_400))
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
        XCTAssertEqual(try XCTUnwrap(byModel["auto-review"]?.costUsd), 0.75, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(byModel["luna"]?.costUsd), 0.3, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(byModel["voice"]?.costUsd), 0.0375, accuracy: 0.000000001)
        XCTAssertEqual(Aggregation.total(project([snapshot]).buckets).costUsd, 1.0875, accuracy: 0.000000001)
    }

    func testWithoutLocalActivityAFullProviderDayStaysOnItsCalendarDate() throws {
        let from = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let result = project([try fixture.snapshot()], cells: [], from: from, to: from.addingTimeInterval(86_400), calendar: newYork)
        XCTAssertTrue(result.buckets.allSatisfy { $0.periodStart == from })
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875)
    }

    func testProviderDayIsSharedAcrossLocalDaysByTheUsageItReplaces() throws {
        // UTC October 1 spans 8pm September 30 to 8pm October 1 in New York.
        let utcDay = from
        let evening = cell(at: utcDay.addingTimeInterval(2 * 3600), cost: 1, session: "late")  // 10pm Sep 30 local
        let morning = cell(at: utcDay.addingTimeInterval(14 * 3600), cost: 3, session: "day")  // 10am Oct 1 local
        let sep30 = newYork.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let oct1 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let result = project([try fixture.snapshot()], cells: [evening, morning], from: sep30, to: oct1.addingTimeInterval(86_400), calendar: newYork)
        let byDay = Dictionary(grouping: result.buckets, by: \.periodStart).mapValues(Aggregation.total)
        XCTAssertEqual(try XCTUnwrap(byDay[sep30]).costUsd, 1.6875 / 4, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(byDay[oct1]).costUsd, 1.6875 * 3 / 4, accuracy: 0.0000001)
        // Each token field is shared separately, so counts round per field.
        XCTAssertEqual(Double(try XCTUnwrap(byDay[sep30]).totals.total), 40, accuracy: 2)
        XCTAssertEqual((byDay[sep30]?.totals.total ?? 0) + (byDay[oct1]?.totals.total ?? 0), 160)
        XCTAssertEqual(byDay[sep30]?.sessions, 1)
        XCTAssertTrue(result.buckets.allSatisfy { $0.costSource == .workspaceCredits })
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875, accuracy: 0.0000001)
    }

    func testHoursAfterProviderFreshnessKeepTheirLocalUsage() throws {
        var snapshot = try fixture.snapshot()
        snapshot.dataFreshness = "2026-10-01T12:00:00Z"
        let reported = cell(at: from.addingTimeInterval(3 * 3600), cost: 2)
        let recent = cell(at: from.addingTimeInterval(15 * 3600), cost: 4, session: "s2")
        let result = project([snapshot], cells: [reported, recent])
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875 + 4, accuracy: 0.0000001)
        XCTAssertEqual(result.buckets.filter { $0.costSource != .workspaceCredits }.map(\.costUsd), [4])
    }

    func testEarlyHoursOfAProviderDayBelongToThePreviousLocalEvening() throws {
        // At 12:50am in New York, UTC October 2 has been reported through 3am UTC (11pm local).
        var snapshot = try fixture.snapshot()
        snapshot.days[0].date = "2026-10-02"
        snapshot.fromDay = "2026-10-02"; snapshot.toDay = "2026-10-02"
        snapshot.dataFreshness = "2026-10-02T03:00:00Z"
        let oct1 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let oct2 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let today = project([snapshot], cells: [], from: oct2, to: oct2.addingTimeInterval(50 * 60), calendar: newYork)
        XCTAssertEqual(Aggregation.total(today.buckets).costUsd, 0)
        XCTAssertTrue(today.workspaceAccountIds.isEmpty)
        let yesterday = project([snapshot], cells: [], from: oct1, to: oct2, calendar: newYork)
        XCTAssertEqual(Aggregation.total(yesterday.buckets).costUsd, 1.6875)
    }

    func testProductAndReasoningDetailKeepsSharedChartTotalsUnchanged() throws {
        var snapshot = try fixture.snapshot()
        let baseline = Aggregation.total(project([snapshot]).buckets)
        let standard = try XCTUnwrap(snapshot.days[0].textModels?.first { $0.speed == "standard" })
        var work = standard
        work.product = "work"; work.reasoningEffort = "low"; work.surface = "work"
        work.credits /= 2; work.uncachedInputTokens /= 2; work.cachedInputTokens /= 2
        work.outputTokens /= 2; work.totalTokens /= 2
        var codex = work
        codex.product = "codex"; codex.reasoningEffort = "medium"; codex.surface = "unknown"
        snapshot.days[0].textModels = [work, codex] + (snapshot.days[0].textModels ?? []).filter { $0.speed != "standard" }
        XCTAssertNotEqual(work.id, codex.id)
        let total = Aggregation.total(project([snapshot]).buckets)
        XCTAssertEqual(total.costUsd, baseline.costUsd, accuracy: 0.000000001)
        XCTAssertEqual(total.totals, baseline.totals)
    }

    func testSharesOfTokenTotalsSumExactly() {
        let totals = TokenTotals(uncachedInput: 7, cachedInput: 11, cacheCreation: 3, output: 5, reasoning: 2)
        let cuts = [0, 1.0 / 3, 0.5, 0.9, 1]
        var sum = TokenTotals.zero
        for (a, b) in zip(cuts, cuts.dropFirst()) { sum.add(totals.share(from: a, to: b)) }
        XCTAssertEqual(sum, totals)
    }
}
