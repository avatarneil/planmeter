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
        let key = CellKey(startMs: Int64((date ?? from).timeIntervalSince1970 * 1000), accountId: id ?? account.id, model: "test")
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

    func testWithoutLocalActivityAReadingSpreadsOverItsReportedHours() throws {
        // UTC October 1 is 8pm–midnight September 30 and midnight–8pm October 1 in New York.
        let sep30 = newYork.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let oct1 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let result = project([try fixture.snapshot()], cells: [], from: sep30, to: oct1.addingTimeInterval(86_400), calendar: newYork)
        let byDay = Dictionary(grouping: result.buckets, by: \.periodStart).mapValues(Aggregation.total)
        XCTAssertEqual(try XCTUnwrap(byDay[sep30]).costUsd, 1.6875 * 4 / 24, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(byDay[oct1]).costUsd, 1.6875 * 20 / 24, accuracy: 0.0000001)
        XCTAssertEqual(Aggregation.total(result.buckets).totals.total, 160)
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
        // Text usage follows local usage (1:3); voice credits have no local trace
        // and spread over the reported hours (4:20).
        XCTAssertEqual(try XCTUnwrap(byDay[sep30]).costUsd, 1.65 / 4 + 0.0375 * 4 / 24, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(byDay[oct1]).costUsd, 1.65 * 3 / 4 + 0.0375 * 20 / 24, accuracy: 0.0000001)
        // Each token field is shared separately, so counts round per field.
        XCTAssertEqual(Double(try XCTUnwrap(byDay[sep30]).totals.total), 40, accuracy: 2)
        XCTAssertEqual((byDay[sep30]?.totals.total ?? 0) + (byDay[oct1]?.totals.total ?? 0), 160)
        XCTAssertEqual(byDay[sep30]?.sessions, 1)
        XCTAssertTrue(result.buckets.allSatisfy { $0.costSource.isWorkspace })
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875, accuracy: 0.0000001)
    }

    func testHoursAfterProviderFreshnessKeepTheirLocalUsage() throws {
        var snapshot = try fixture.snapshot()
        snapshot.creditsFreshness = "2026-10-01T12:00:00Z"
        let reported = cell(at: from.addingTimeInterval(3 * 3600), cost: 2)
        let recent = cell(at: from.addingTimeInterval(15 * 3600), cost: 4, session: "s2")
        let result = project([snapshot], cells: [reported, recent])
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875 + 4, accuracy: 0.0000001)
        XCTAssertEqual(result.buckets.filter { !$0.costSource.isWorkspace }.map(\.costUsd), [4])
    }

    func testEarlyHoursOfAProviderDayBelongToThePreviousLocalEvening() throws {
        // At 12:50am in New York, UTC October 2 has been reported through 3am UTC (11pm local).
        var snapshot = try fixture.snapshot()
        snapshot.days[0].date = "2026-10-02"
        snapshot.fromDay = "2026-10-02"; snapshot.toDay = "2026-10-02"
        snapshot.creditsFreshness = "2026-10-02T03:00:00Z"
        let oct1 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let oct2 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let today = project([snapshot], cells: [], from: oct2, to: oct2.addingTimeInterval(50 * 60), calendar: newYork)
        XCTAssertEqual(Aggregation.total(today.buckets).costUsd, 0)
        XCTAssertTrue(today.workspaceAccountIds.isEmpty)
        let yesterday = project([snapshot], cells: [], from: oct1, to: oct2, calendar: newYork)
        XCTAssertEqual(Aggregation.total(yesterday.buckets).costUsd, 1.6875)
    }

    func testMissingFreshnessCoversOnlyUntilTheReadingWasFetched() throws {
        var snapshot = try fixture.snapshot()
        snapshot.creditsFreshness = nil
        snapshot.dataFreshness = nil
        snapshot.fetchedAt = from.addingTimeInterval(12 * 3600)
        let result = project([snapshot], cells: [cell(at: from.addingTimeInterval(3 * 3600), cost: 2), cell(at: from.addingTimeInterval(15 * 3600), cost: 4, session: "s2")])
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875 + 4, accuracy: 0.0000001)
    }

    func testCreditFreshnessBoundsCoverageWhenOtherFeedsLag() throws {
        var snapshot = try fixture.snapshot()
        snapshot.dataFreshness = "2026-10-01T06:00:00Z" // A lagging token feed.
        snapshot.creditsFreshness = "2026-10-01T12:00:00Z"
        let result = project([snapshot], cells: [cell(at: from.addingTimeInterval(9 * 3600), cost: 2)])
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875, accuracy: 0.0000001) // Credits already cover 9am.
    }

    func testUnpricedLocalModelsShareByTokensAndKeepTheirRecords() throws {
        let sep30 = newYork.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let oct1 = newYork.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let evening = cell(at: from.addingTimeInterval(2 * 3600), cost: 1, session: "late")
        let tokens = TokenTotals(uncachedInput: 99_500)
        let newModel = (CellKey(startMs: Int64(from.addingTimeInterval(14 * 3600).timeIntervalSince1970 * 1000), accountId: account.id, model: "brand-new"),
                        Cell(totals: tokens, unpricedTotals: tokens, records: 50, sessionIds: ["day"]))
        let result = project([try fixture.snapshot()], cells: [evening, newModel], from: sep30, to: oct1.addingTimeInterval(86_400), calendar: newYork)
        let byDay = Dictionary(grouping: result.buckets, by: \.periodStart).mapValues(Aggregation.total)
        XCTAssertEqual(try XCTUnwrap(byDay[oct1]).costUsd, 1.65 * 0.995 + 0.0375 * 20 / 24, accuracy: 0.0000001)
        XCTAssertEqual(Aggregation.total(result.buckets).records, 52)
        XCTAssertEqual(Aggregation.total(result.buckets).sessions, 2)
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875, accuracy: 0.0000001)
    }

    func testLocalPiecesPartitionReportedHoursAcrossTimeZonesAndDaylightSaving() throws {
        for zone in ["America/New_York", "Asia/Kolkata", "Pacific/Kiritimati", "America/Santiago", "Australia/Lord_Howe", "Pacific/Chatham"] {
            var calendar = UsageCoverage.utcCalendar
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var start = Int64(try XCTUnwrap(UsageCoverage.utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1))).timeIntervalSince1970 * 1000)
            for _ in 0..<366 {
                let pieces = UsageProjection.localPieces(start: start, end: start + 86_400_000, calendar: calendar)
                XCTAssertEqual(pieces.first?.from, start, zone)
                XCTAssertEqual(pieces.last?.to, start + 86_400_000, zone)
                for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.to, b.from, zone) }
                for piece in pieces {
                    let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: TimeInterval(piece.from) / 1000)))
                    XCTAssertEqual(piece.day, interval.start, zone)
                    XCTAssertLessThanOrEqual(Double(piece.to) / 1000, interval.end.timeIntervalSince1970, zone)
                }
                start += 86_400_000
            }
        }
    }

    func testMinuteResolutionKeepsTextWithLocalUsageAndSpreadsUntimedCreditsEvenly() throws {
        let morning = cell(at: from.addingTimeInterval(3 * 3600 + 7 * 60), cost: 1, session: "a")
        let afternoon = cell(at: from.addingTimeInterval(15 * 3600 + 42 * 60), cost: 3, session: "b")
        let result = UsageProjection.buckets(cells: Dictionary([morning, afternoon], uniquingKeysWith: { $1 }), rates: rates,
                                             snapshots: [try fixture.snapshot()], accounts: [account], from: from, to: to,
                                             resolution: .minute, calendar: UsageCoverage.utcCalendar)
        let text = result.buckets.filter { $0.costSource == .workspaceCredits }
        XCTAssertEqual(Set(text.map(\.periodStart)), [morning.0.startMs, afternoon.0.startMs].map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }.reduce(into: Set<Date>()) { $0.insert($1) })
        XCTAssertEqual(Aggregation.total(text.filter { $0.periodStart == Date(timeIntervalSince1970: TimeInterval(morning.0.startMs) / 1000) }).costUsd, 1.65 / 4, accuracy: 0.0000001)
        let baseline = result.buckets.filter { $0.costSource == .workspaceBaseline }
        XCTAssertEqual(Set(baseline.map(\.periodStart)).count, 1440) // Voice credits: one even share per minute.
        XCTAssertEqual(try XCTUnwrap(baseline.first).costUsd, 0.0375 / 1440, accuracy: 0.000000001)
        XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875, accuracy: 0.0000001)
        XCTAssertEqual(Aggregation.total(result.buckets).totals.total, 160)
        XCTAssertEqual(Aggregation.total(result.buckets).sessions, 2)
    }

    func testEveryResolutionConservesTheSameTotals() throws {
        let cells = [cell(at: from.addingTimeInterval(2 * 3600 + 33 * 60), cost: 1, session: "late"),
                     cell(at: from.addingTimeInterval(14 * 3600 + 5 * 60), cost: 3, session: "day"),
                     cell(at: from.addingTimeInterval(30 * 3600), cost: 5, session: "next")]
        let start = newYork.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        var totals: [Double] = []
        for resolution in Resolution.allCases {
            let result = UsageProjection.buckets(cells: Dictionary(cells, uniquingKeysWith: { $1 }), rates: rates, snapshots: [try fixture.snapshot()],
                                                 accounts: [account], from: start, to: start.addingTimeInterval(3 * 86_400),
                                                 resolution: resolution, calendar: newYork)
            totals.append(Aggregation.total(result.buckets).costUsd)
            XCTAssertEqual(Aggregation.total(result.buckets).totals.total, 160 + 500, "\(resolution)")
        }
        for total in totals { XCTAssertEqual(total, 1.6875 + 5, accuracy: 0.0000001) }
    }

    func testWindowsThatCutABucketCountOnlyTheirShareAtEveryResolution() throws {
        // A reading with no local trace spreads evenly; a window starting at 13:25
        // must not pick up credit from 13:00–13:25 in its first hourly bucket.
        let windowStart = from.addingTimeInterval(13 * 3600 + 25 * 60)
        for zone in ["UTC", "Asia/Kolkata", "America/St_Johns"] {
            var calendar = UsageCoverage.utcCalendar
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for resolution in Resolution.allCases where resolution != .day {
                let result = UsageProjection.buckets(cells: [:], rates: rates, snapshots: [try fixture.snapshot()], accounts: [account],
                                                     from: windowStart, to: windowStart.addingTimeInterval(3600), resolution: resolution, calendar: calendar)
                XCTAssertEqual(Aggregation.total(result.buckets).costUsd, 1.6875 / 24, accuracy: 0.0000001, "\(zone) \(resolution)")
            }
        }
    }

    func testZeroCreditDaysDrawNoEmptyBuckets() throws {
        var zero = try fixture.snapshot()
        zero.days[0].products = [DailyCreditValue(key: "codex", label: "Codex", credits: 0)]
        zero.days[0].modelCredits = []
        zero.days[0].textModels = []
        let result = UsageProjection.buckets(cells: [:], rates: rates, snapshots: [zero], accounts: [account], from: from, to: to,
                                             resolution: .minute, calendar: UsageCoverage.utcCalendar)
        XCTAssertTrue(result.buckets.isEmpty)
        XCTAssertEqual(result.workspaceAccountIds, [account.id])
    }

    func testSubDayReportWindowsHonorCoarserBuckets() {
        XCTAssertEqual(Report.bounded(.hour, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86_400)), .hour)
        XCTAssertEqual(Report.bounded(.minute, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7 * 86_400)), .fifteenMinutes)
        // The window itself doesn't depend on the bucket size, so totals and timelines agree.
        let w = Report.window(minutes: 60, now: Date(timeIntervalSince1970: 1_790_000_123))
        XCTAssertEqual(w.to.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertEqual(w.to.timeIntervalSince(w.from), 3600)
    }

    func testASessionSpanningManyMinuteBucketsCountsOnce() {
        let cells = Dictionary((0..<3).map { cell(at: from.addingTimeInterval(TimeInterval($0) * 60), cost: 1, session: "same") }, uniquingKeysWith: { $1 })
        let buckets = Aggregation.buckets(cells: cells, rates: rates, from: from, to: to, resolution: .minute, calendar: UsageCoverage.utcCalendar)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(Aggregation.total(buckets).sessions, 1)
    }

    func testFixedStepPeriodsAlignToTheirStep() {
        // 1_790_000_100 is a 15-minute boundary; 1_790_000_400 is 5 minutes later.
        let ms: Int64 = 1_790_000_483_456
        XCTAssertEqual(Resolution.minute.periodStart(forMs: ms).timeIntervalSince1970, 1_790_000_460)
        XCTAssertEqual(Resolution.fiveMinutes.periodStart(forMs: ms).timeIntervalSince1970, 1_790_000_400)
        XCTAssertEqual(Resolution.fifteenMinutes.periodStart(forMs: ms).timeIntervalSince1970, 1_790_000_100)
        let from = Date(timeIntervalSince1970: 1_790_000_483)
        let periods = Aggregation.periods(from: from, to: from.addingTimeInterval(3600), resolution: .fifteenMinutes)
        XCTAssertEqual(periods.first?.timeIntervalSince1970, 1_790_000_100)
        XCTAssertEqual(periods.count, 5)
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
