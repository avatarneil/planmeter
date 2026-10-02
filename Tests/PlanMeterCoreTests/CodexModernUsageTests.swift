import XCTest
@testable import PlanMeterCore

final class CodexModernUsageTests: XCTestCase {
    func line(_ type: String, _ payload: [String: Any], timestamp: String = "2026-10-02T00:01:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": timestamp, "payload": payload])
    }

    func meta(_ id: String = "thread", parent: String? = nil) throws -> Data {
        var payload: [String: Any] = ["id": id]
        if let parent { payload["forked_from_id"] = parent }
        return try line("session_meta", payload, timestamp: "2026-10-02T00:00:00Z")
    }

    func context(_ turn: String, model: String = "test-model") throws -> Data {
        try line("turn_context", ["turn_id": turn, "model": model])
    }

    func usage(_ input: Int = 100, cached: Int = 20, output: Int = 10, write: Int = 0, reasoning: Int = 5) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write,
         "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]
    }

    func modern(_ response: String, turn: String = "turn", thread: String = "thread", tokens: [String: Any]? = nil,
                timestamp: String = "2026-10-02T00:01:00Z") throws -> Data {
        try line("token_usage_record", ["thread_id": thread, "turn_id": turn, "session_id": "process-session",
            "root_turn_id": "root-turn", "response_id": response, "usage": tokens ?? usage(),
            "turn_token_usage": usage(999_000), "thread_token_usage": usage(5_000_000)], timestamp: timestamp)
    }

    func legacy(_ tokens: [String: Any]? = nil, plan: String? = "pro", timestamp: String = "2026-10-02T00:01:00Z") throws -> Data {
        var payload: [String: Any] = ["type": "token_count", "info": ["last_token_usage": tokens ?? usage(), "total_token_usage": usage(5_000_000)]]
        if let plan {
            payload["rate_limits"] = ["plan_type": plan, "primary": ["used_percent": 15.0, "window_minutes": 300, "resets_at": 1_790_899_200]]
        }
        return try line("event_msg", payload, timestamp: timestamp)
    }

    func document(_ lines: [Data]) -> Data {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        return data
    }

    func records(_ lines: [Data]) -> (records: [UsageRecord], state: CodexScanState) {
        let data = document(lines)
        var state = CodexParser.preparedState(data: data)
        var records: [UsageRecord] = []
        data.forEachLine { if let value = CodexParser.parse(line: $0, state: &state) { records.append(value) } }
        return (records, state)
    }

    func scanEntry(_ lines: [Data]) throws -> FileScanEntry {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = document(lines)
        try data.write(to: file)
        return try XCTUnwrap(Scanner.parseFile(TranscriptFile(path: file.path, size: Int64(data.count), mtimeMs: 0),
                                             source: ScanSource(provider: .codex, rootDir: file.deletingLastPathComponent().path)))
    }

    func testExactResponseUsageSuppressesMirrorAndNeverAddsCumulativeCounters() throws {
        let lines = try [meta(), context("turn"), modern("response", tokens: usage(write: 10)), legacy(usage(write: 10))]
        let parsed = records(lines)
        XCTAssertEqual(parsed.records.count, 1)
        let record = try XCTUnwrap(parsed.records.first)
        XCTAssertEqual(record.totals, TokenTotals(uncachedInput: 70, cachedInput: 20, cacheCreation: 10, output: 10, reasoning: 5))
        XCTAssertEqual(record.planType, "pro", "The following rate-limit event supplies the first modern response's plan.")
        XCTAssertEqual(record.model, "test-model")
        XCTAssertEqual(record.dedupeKey, "thread:response")
        XCTAssertEqual(parsed.state.latestRateLimits?.planType, "pro", "Mirrors must still update subscription limits.")
        let entry = try scanEntry(lines)
        XCTAssertEqual(entry.cells.first?.key.accountId, "codex:plan:pro")
        XCTAssertEqual(entry.cells.reduce(0) { $0 + $1.cell.totals.total }, 110)
        XCTAssertEqual(entry.threads.reduce(0) { $0 + $1.cell.totals.total }, 110)
    }

    func testEqualResponsesBothCountWhileRepeatedResponseIDsCountOnce() throws {
        let parsed = records(try [meta(), context("turn"), modern("first"), legacy(), modern("second"), legacy(), modern("first"), legacy()])
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records.reduce(0) { $0 + $1.totals.total }, 220)
    }

    func testLegacyPrefixAndLegacyOnlyTurnsSurviveModernCoveredTurns() throws {
        let parsed = records(try [meta(), context("upgraded-turn"), legacy(usage(10, cached: 0)), modern("modern", turn: "upgraded-turn"),
            legacy(usage(200)), legacy(usage(500)), // Estimated/mismatched mirrors in an authoritative modern turn.
            context("legacy-only-turn"), legacy()])
        XCTAssertEqual(parsed.records.count, 3)
        XCTAssertEqual(parsed.records.map { $0.totals.total }, [20, 110, 110])
    }

    func testForkParentHistoryIsExcludedAndChildExactResponseCountsImmediately() throws {
        let lines = try [meta("child", parent: "parent"), context("parent-turn"),
            legacy(timestamp: "2026-09-01T00:00:00Z"), legacy(usage(200), timestamp: "2026-09-02T00:00:00Z"),
            modern("inherited", turn: "parent-turn", thread: "parent"), legacy(usage(300)),
            context("child-turn"), modern("own", turn: "child-turn", thread: "child", timestamp: "2026-10-02T00:00:00.100Z"), legacy()]
        let parsed = records(lines)
        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(parsed.records.first?.sessionId, "child")
        XCTAssertEqual(parsed.records.first?.dedupeKey, "child:own")
        // A truncated copied modern prefix must not suppress a child's later legacy-only turn.
        let legacyChild = records(try [meta("child", parent: "parent"), context("parent-turn"),
            modern("inherited", turn: "parent-turn", thread: "parent"), context("child-legacy"), legacy()])
        XCTAssertEqual(legacyChild.records.count, 1)
    }

    func testMatchingFutureContextRecoversCompactionModelAndMissingModelRetainsTokens() throws {
        let recovered = records(try [meta(), modern("compaction", turn: "future-turn"), legacy(), context("future-turn", model: "auto-review")])
        XCTAssertEqual(recovered.records.first?.model, "auto-review")
        XCTAssertEqual(recovered.records.first?.totals.total, 110)
        let unknown = records(try [meta(), modern("unattributed"), legacy(plan: nil)])
        XCTAssertEqual(unknown.records.first?.model, "Codex model unavailable")
        XCTAssertNil(unknown.records.first?.planType)
        XCTAssertEqual(unknown.records.first?.totals.total, 110)
        let unmatched = records(try [meta(), context("older-turn", model: "old-model"), modern("unmatched", turn: "new-turn"), legacy()])
        XCTAssertEqual(unmatched.records.first?.model, "Codex model unavailable", "Another turn's model cannot price an unmatched response.")
    }

    func testHistoricalPlansAndModelChangesUseTheirMatchingTurnMetadata() throws {
        let parsed = records(try [meta(), context("personal", model: "first-model"), modern("personal", turn: "personal"), legacy(plan: "pro"),
            context("work", model: "second-model"), modern("work", turn: "work"), legacy(plan: "business"),
            context("work", model: "rerouted-model"), modern("rerouted", turn: "work"), legacy(plan: "business")])
        XCTAssertEqual(parsed.records.map(\.planType), ["pro", "business", "business"])
        XCTAssertEqual(parsed.records.map(\.model), ["first-model", "second-model", "rerouted-model"])
    }

    func testMalformedCountersSubsetsAndOverflowAreRejectedWithoutIntTraps() throws {
        for bad: Any in [true, -1, "100", 1.5, Double.infinity, UInt64.max, Double(Int.max)] {
            var values = usage(); values["input_tokens"] = bad
            XCTAssertNil(CodexParser.tokenTotals(values, requireTotal: true))
        }
        var overflow = usage(); overflow["input_tokens"] = Int.max / 2 + 1; overflow["output_tokens"] = Int.max / 2 + 1
        XCTAssertNil(CodexParser.tokenTotals(overflow, requireTotal: true))
        XCTAssertNil(CodexParser.tokenTotals(usage(cached: 90, write: 20), requireTotal: true))
        XCTAssertNil(CodexParser.tokenTotals(usage(reasoning: 11), requireTotal: true))
        var wrongTotal = usage(); wrongTotal["total_tokens"] = 111
        XCTAssertNil(CodexParser.tokenTotals(wrongTotal, requireTotal: true))
        var absentTotal = usage(); absentTotal.removeValue(forKey: "total_tokens")
        XCTAssertNil(CodexParser.tokenTotals(absentTotal, requireTotal: true))
        XCTAssertNotNil(CodexParser.tokenTotals(absentTotal, requireTotal: false), "Legacy payloads may omit total_tokens.")
        var boolOutput = usage(); boolOutput["output_tokens"] = true
        XCTAssertNil(CodexParser.tokenTotals(boolOutput, requireTotal: false))
        let malformed = records(try [meta(), context("turn"), modern("bad", tokens: wrongTotal)])
        XCTAssertTrue(malformed.records.isEmpty)
        let recovered = records(try [meta(), context("turn"), modern("bad", tokens: wrongTotal), legacy()])
        XCTAssertEqual(recovered.records.count, 1, "Invalid modern records cannot suppress usable legacy usage.")
        XCTAssertNil(recovered.records.first?.dedupeKey)
        XCTAssertEqual(recovered.records.first?.totals.total, 110)
        let invalidTimestamp = records(try [meta(), context("turn"), modern("bad-time", timestamp: "invalid"), legacy()])
        XCTAssertEqual(invalidTimestamp.records.count, 1)
    }

    func testRepeatedContextForSameLegacyTurnKeepsDuplicateSuppression() throws {
        let parsed = records(try [meta(), context("turn"), legacy(), context("turn"), legacy(), context("next-turn"), legacy()])
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records.reduce(0) { $0 + $1.totals.total }, 220)
    }

    func testCacheVersionInvalidatesLegacyOnlyResultsAndWarmScanRetainsExactUsage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = document(try [meta(), context("turn"), modern("response"), legacy()])
        let file = dir.appendingPathComponent("rollout.jsonl")
        try data.write(to: file)
        let source = ScanSource(provider: .codex, rootDir: dir.path)
        let listed = try XCTUnwrap(Scanner.listFiles(root: dir.path, sinceMs: 0, fileName: nil)?.first)
        let old = FileScanEntry(size: listed.size, mtimeMs: listed.mtimeMs, cells: [], rateLimits: nil, malformed: 0)
        let cacheURL = dir.appendingPathComponent("cache.json")
        try JSONEncoder().encode(ScanCacheDocument(version: 4, files: [listed.path: old])).write(to: cacheURL)
        let cache = ScanCache(url: cacheURL)
        await cache.load()
        let cold = await Scanner.scan(sources: [source], openCodeDatabase: nil, sinceMs: 0, cache: cache)
        XCTAssertEqual(cold.sources.first?.scannedFiles, 1)
        XCTAssertEqual(cold.cells.values.reduce(0) { $0 + $1.totals.total }, 110)
        let next = ScanCache(url: cacheURL)
        await next.load()
        let warm = await Scanner.scan(sources: [source], openCodeDatabase: nil, sinceMs: 0, cache: next)
        XCTAssertEqual(warm.sources.first?.reusedFiles, 1)
        XCTAssertEqual(warm.cells.values.reduce(0) { $0 + $1.totals.total }, 110)
        XCTAssertEqual(warm.threads.reduce(0) { $0 + $1.cell.totals.total }, 110)
    }
}
