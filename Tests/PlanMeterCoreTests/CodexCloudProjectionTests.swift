import XCTest
@testable import PlanMeterCore

final class CodexCloudProjectionTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_790_874_000)
    let thread = "00000000-0000-4000-8000-000000000001"
    var target: CodexUsageTarget {
        CodexUsageTarget(id: "account:member", name: "Work", home: "/tmp/unused", email: "member@example.com",
            plan: "business", serviceAccountId: "account", localAccountId: "codex:plan:business")
    }
    func turn(_ id: String = "turn-1", response: String = "response-1", cost: Double? = 1) -> CodexCloudTurnUsage {
        CodexCloudTurnUsage(reference: CodexThreadReference(id: thread, title: "Cloud task", origin: "cloud"),
            turnId: id, startedAt: date.addingTimeInterval(-3600), completedAt: date, model: "test",
            totals: TokenTotals(uncachedInput: 20, cachedInput: 80, output: 10),
            serviceCostUsd: cost, credits: 25, responseIds: [response])
    }
    func snapshot(_ turns: [CodexCloudTurnUsage]) -> CodexCloudUsageSnapshot {
        var result = CodexCloudUsageSnapshot(target: target)
        result.turns = turns; result.fetchedAt = date; result.status = .ok
        return result
    }

    func testDatedTurnTokensAndServiceCostReachChartsAndKnownThreads() throws {
        let result = CodexCloudProjection.merging([snapshot([turn()])], into: ScanOutput())
        let rates = RateTable()
        let from = date.addingTimeInterval(-1), to = date.addingTimeInterval(3600)
        let buckets = Aggregation.buckets(cells: result.cells, rates: rates, from: from, to: to, resolution: .hour)
        XCTAssertEqual(Aggregation.total(buckets).totals.total, 110)
        XCTAssertEqual(Aggregation.total(buckets).costUsd, 1)
        XCTAssertEqual(buckets.first?.costSource, .providerReported)
        let threads = UsageCoverage.threads(result.threads, rates: rates, from: from, to: to)
        XCTAssertEqual(threads.first?.tokens, 110)
        XCTAssertEqual(threads.first?.costUsd, 1)
        let catalog = CodexCloudProjection.catalog([snapshot([turn()])], local: [:])
        XCTAssertEqual(ThreadCatalog.link(threads, catalog: catalog).first?.title, "Cloud task")
    }

    func testExactLocalThreadWinsWithoutAddingCloudAggregate() {
        var local = ScanOutput()
        let key = CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(date.timeIntervalSince1970 * 1000)),
            accountId: target.localAccountId!, model: "test")
        let cell = Cell(totals: TokenTotals(output: 7), reportedCostUsd: 0.5)
        local.cells[key] = cell
        local.threads = [ThreadCellEntry(sessionId: thread, key: key, cell: cell, sourcePath: "/tmp/rollout")]
        let result = CodexCloudProjection.merging([snapshot([turn()])], into: local)
        XCTAssertEqual(result.cells[key]?.totals.total, 7)
        XCTAssertEqual(result.cells[key]?.reportedCostUsd, 0.5)
        XCTAssertEqual(result.threads.count, 1)
    }

    func testDuplicateTurnsAndSharedSettledResponsesAreNotCountedTwice() {
        let result = CodexCloudProjection.merging([snapshot([turn(), turn(), turn("turn-2")])], into: ScanOutput())
        XCTAssertEqual(result.threads.count, 1)
        XCTAssertEqual(result.cells.values.reduce(0) { $0 + $1.totals.total }, 110)
        XCTAssertEqual(result.sources.last?.status, .partial)
    }

    func testUnavailableUsageAndAmbiguousAccountsNeverBecomeZeroDollarReadings() {
        var unavailable = turn()
        unavailable.model = nil; unavailable.totals = nil; unavailable.serviceCostUsd = nil
        XCTAssertTrue(CodexCloudProjection.merging([snapshot([unavailable])], into: ScanOutput()).cells.isEmpty)
        var ambiguous = snapshot([turn()])
        ambiguous.target.localAccountId = nil
        XCTAssertTrue(CodexCloudProjection.merging([ambiguous], into: ScanOutput()).cells.isEmpty)
        var second = snapshot([turn("turn-2", response: "response-2")])
        second.target.id = "other-login"
        XCTAssertTrue(CodexCloudProjection.merging([snapshot([turn()]), second], into: ScanOutput()).cells.isEmpty)
    }

    func testExplicitZeroServiceChargeRemainsProviderReported() {
        let result = CodexCloudProjection.merging([snapshot([turn(cost: 0)])], into: ScanOutput())
        XCTAssertEqual(result.cells.values.first?.reportedCostUsd, 0)
        XCTAssertEqual(result.cells.values.first?.totals.total, 110)
        XCTAssertTrue(result.cells.values.first?.unpricedTotals.isEmpty == true)
    }

    func testTokenlessChargeAndUnknownModelCountersRemainVisible() {
        var charge = turn()
        charge.totals = nil; charge.model = nil
        let result = CodexCloudProjection.merging([snapshot([charge])], into: ScanOutput())
        XCTAssertEqual(result.cells.values.first?.reportedCostUsd, 1)
        XCTAssertEqual(result.cells.values.first?.totals.total, 0)
        var unknown = turn()
        unknown.model = nil; unknown.serviceCostUsd = nil
        let tokens = CodexCloudProjection.merging([snapshot([unknown])], into: ScanOutput())
        XCTAssertEqual(tokens.cells.values.first?.totals.total, 110)
        XCTAssertEqual(tokens.cells.values.first?.unpricedTotals.total, 110)
        XCTAssertEqual(tokens.cells.keys.first?.model, "Codex model unavailable")
    }
}
