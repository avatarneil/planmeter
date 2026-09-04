import XCTest
@testable import PlanMeterCore

final class ClaudeParserTests: XCTestCase {
    func testParsesAssistantUsage() {
        let line = """
        {"type":"assistant","timestamp":"2026-09-04T01:40:59.796Z","requestId":"req_1","sessionId":"s1","message":{"id":"msg_1","model":"claude-fable-5-1","usage":{"input_tokens":2,"cache_creation_input_tokens":8341,"cache_read_input_tokens":11471,"output_tokens":379}}}
        """
        let record = ClaudeParser.parse(line: Data(line.utf8))
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.model, "claude-fable-5-1")
        XCTAssertEqual(record?.totals.uncachedInput, 2)
        XCTAssertEqual(record?.totals.cacheCreation, 8341)
        XCTAssertEqual(record?.totals.cachedInput, 11471)
        XCTAssertEqual(record?.totals.output, 379)
        XCTAssertEqual(record?.dedupeKey, "msg_1:req_1")
        XCTAssertEqual(record?.sessionId, "s1")
    }

    func testIgnoresNonAssistantLines() {
        let line = #"{"type":"user","timestamp":"2026-09-04T01:40:59.796Z","message":{"usage":{"input_tokens":5}}}"#
        XCTAssertNil(ClaudeParser.parse(line: Data(line.utf8)))
    }
}

final class CodexParserTests: XCTestCase {
    let meta = #"{"timestamp":"2026-09-04T02:28:23.035Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/tmp"}}"#
    let turn = #"{"timestamp":"2026-09-04T02:28:24.000Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#
    func tokenCount(_ ts: String, input: Int, cached: Int, output: Int, reasoning: Int, plan: String) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":\(reasoning)}},"rate_limits":{"primary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1788903313},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"\(plan)"}}}
        """
    }

    func testCarriesModelAndPlanType() {
        var state = CodexScanState()
        XCTAssertNil(CodexParser.parse(line: Data(meta.utf8), state: &state))
        XCTAssertNil(CodexParser.parse(line: Data(turn.utf8), state: &state))
        let record = CodexParser.parse(line: Data(tokenCount("2026-09-04T02:28:30.000Z", input: 20380, cached: 9984, output: 287, reasoning: 73, plan: "pro").utf8), state: &state)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.model, "gpt-5.6-luna")
        XCTAssertEqual(record?.planType, "pro")
        XCTAssertEqual(record?.sessionId, "sess-1")
        XCTAssertEqual(record?.totals.uncachedInput, 20380 - 9984)
        XCTAssertEqual(record?.totals.cachedInput, 9984)
        XCTAssertEqual(record?.totals.reasoning, 73)
        XCTAssertEqual(state.latestRateLimits?.primary?.usedPercent, 15.0)
        XCTAssertEqual(state.latestRateLimits?.planType, "pro")
    }

    func testDropsConsecutiveDuplicateUsage() {
        var state = CodexScanState()
        _ = CodexParser.parse(line: Data(meta.utf8), state: &state)
        _ = CodexParser.parse(line: Data(turn.utf8), state: &state)
        let first = tokenCount("2026-09-04T02:28:30.000Z", input: 100, cached: 0, output: 10, reasoning: 0, plan: "business")
        XCTAssertNotNil(CodexParser.parse(line: Data(first.utf8), state: &state))
        XCTAssertNil(CodexParser.parse(line: Data(first.utf8), state: &state))
    }

    func testTokenCountBeforeTurnContextIsSkipped() {
        var state = CodexScanState()
        _ = CodexParser.parse(line: Data(meta.utf8), state: &state)
        let early = tokenCount("2026-09-04T02:28:30.000Z", input: 100, cached: 0, output: 10, reasoning: 0, plan: "business")
        XCTAssertNil(CodexParser.parse(line: Data(early.utf8), state: &state))
        _ = CodexParser.parse(line: Data(turn.utf8), state: &state)
        // Same payload after the model is known must still count.
        XCTAssertNotNil(CodexParser.parse(line: Data(early.utf8), state: &state))
    }

    func testForkCopiesAreSuppressed() {
        var state = CodexScanState()
        let forkMeta = #"{"timestamp":"2026-09-04T02:28:23.000Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent"}}"#
        _ = CodexParser.parse(line: Data(forkMeta.utf8), state: &state)
        _ = CodexParser.parse(line: Data(turn.utf8), state: &state)
        let copy = tokenCount("2026-09-04T02:28:23.020Z", input: 500, cached: 0, output: 50, reasoning: 0, plan: "pro")
        XCTAssertNil(CodexParser.parse(line: Data(copy.utf8), state: &state))
        let real = tokenCount("2026-09-04T02:28:40.000Z", input: 600, cached: 0, output: 60, reasoning: 0, plan: "pro")
        XCTAssertNotNil(CodexParser.parse(line: Data(real.utf8), state: &state))
    }
}

final class GrokParserTests: XCTestCase {
    func testSplitsPerModelAndProRatesCost() {
        let line = """
        {"timestamp":1788400000,"params":{"sessionId":"g1","_meta":{"agentTimestampMs":1788400000123},"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":200,"cacheCreationTokens":0,"reasoningTokens":10,"costUsdTicks":20000000000,"modelUsage":{"grok-4":{"inputTokens":800,"outputTokens":80,"cachedReadTokens":200,"cacheCreationTokens":0,"reasoningTokens":10},"grok-4-mini":{"inputTokens":200,"outputTokens":20,"cachedReadTokens":0,"cacheCreationTokens":0,"reasoningTokens":0}}}}}}
        """
        let records = GrokParser.parse(line: Data(line.utf8))
        XCTAssertEqual(records.count, 2)
        let total = records.reduce(0.0) { $0 + ($1.reportedCostUsd ?? 0) }
        XCTAssertEqual(total, 2.0, accuracy: 1e-9)
        XCTAssertEqual(records.first?.timestampMs, 1788400000123)
        XCTAssertEqual(records.map(\.model).sorted(), ["grok-4", "grok-4-mini"])
    }
}

final class PricingTests: XCTestCase {
    func testAliasesBareNamesWhenUnambiguous() {
        let doc: [String: Any] = [
            "openai/gpt-5.6-luna": ["input_cost_per_token": 0.000001, "output_cost_per_token": 0.000008, "cache_read_input_token_cost": 0.0000001],
            "anthropic/claude-fable-5-1": ["input_cost_per_token": 0.00001, "output_cost_per_token": 0.00005],
            "other/claude-fable-5-1": ["input_cost_per_token": 0.00002, "output_cost_per_token": 0.00005],
        ]
        let table = RateTable.from(liteLLMDocument: doc, source: "test", fetchedAt: nil)
        XCTAssertNotNil(table.lookup("gpt-5.6-luna"))
        XCTAssertNil(table.lookup("claude-fable-5-1"), "conflicting rates must not alias")
        XCTAssertNotNil(table.lookup("anthropic/claude-fable-5-1[1m]"))
        XCTAssertNil(table.lookup("<synthetic>"))
        let cost = table.price(model: "gpt-5.6-luna", totals: TokenTotals(uncachedInput: 1_000_000, cachedInput: 1_000_000, output: 1000))
        XCTAssertEqual(cost ?? 0, 1.0 + 0.1 + 0.008, accuracy: 1e-9)
    }
}

final class AggregationTests: XCTestCase {
    func testDayBucketingUsesLocalCalendar() {
        var cells: [CellKey: Cell] = [:]
        let ms: Int64 = 1_788_400_000_000
        var record = UsageRecord(provider: .codex, timestampMs: ms, model: "gpt-5.6-luna", sessionId: "s", totals: TokenTotals(uncachedInput: 10, output: 5), planType: "pro")
        var cell = Cell()
        cell.add(record)
        cells[CellKey(hourStartMs: CellKey.hourStart(forMs: ms), accountId: "codex:plan:pro", model: "gpt-5.6-luna")] = cell
        record.timestampMs = ms + 3_600_000
        var cell2 = Cell()
        cell2.add(record)
        cells[CellKey(hourStartMs: CellKey.hourStart(forMs: ms + 3_600_000), accountId: "codex:plan:pro", model: "gpt-5.6-luna")] = cell2

        let from = Date(timeIntervalSince1970: TimeInterval(ms) / 1000 - 86_400 * 3)
        let to = Date(timeIntervalSince1970: TimeInterval(ms) / 1000 + 86_400)
        let buckets = Aggregation.buckets(cells: cells, rates: RateTable(), from: from, to: to, resolution: .day)
        XCTAssertLessThanOrEqual(buckets.count, 2)
        XCTAssertEqual(Aggregation.total(buckets).totals.total, 30)
        XCTAssertEqual(Aggregation.total(buckets).sessions, buckets.count)
        XCTAssertTrue(buckets.allSatisfy { $0.costSource == .unpriced })
    }
}

final class AccountDiscoveryTests: XCTestCase {
    func testStandaloneClaudeDefaultDoesNotScanGenericProjectsDirectory() {
        let discovery = AccountDiscovery.discover(settings: nil, environment: [:])
        let claudeRoots = discovery.sources
            .filter { $0.provider == .claude }
            .map(\.rootDir)

        XCTAssertEqual(claudeRoots, [NSHomeDirectory() + "/.claude/projects"])
        XCTAssertFalse(claudeRoots.contains(NSHomeDirectory() + "/projects"))
    }

    func testStandaloneDiscoveryUsesProviderHomesWithoutT3Code() {
        let discovery = AccountDiscovery.discover(
            settings: nil,
            environment: [
                "CODEX_HOME": "/tmp/planmeter-codex",
                "CLAUDE_CONFIG_DIR": "/tmp/planmeter-claude",
                "GROK_HOME": "/tmp/planmeter-grok",
                "XDG_DATA_HOME": "/tmp/planmeter-data",
            ]
        )

        XCTAssertEqual(Set(discovery.accounts.map(\.provider)), Set(ProviderKind.allCases))
        XCTAssertEqual(
            discovery.sources.filter { $0.provider == .codex }.map(\.rootDir),
            ["/tmp/planmeter-codex/sessions", "/tmp/planmeter-codex/archived_sessions"]
        )
        XCTAssertEqual(
            discovery.sources.first { $0.provider == .claude }?.rootDir,
            "/tmp/planmeter-claude/projects"
        )
        XCTAssertEqual(
            discovery.sources.first { $0.provider == .grok }?.rootDir,
            "/tmp/planmeter-grok/sessions"
        )
        XCTAssertEqual(discovery.openCodeDatabase, "/tmp/planmeter-data/opencode/opencode.db")
        XCTAssertTrue(discovery.notes.contains { $0.contains("T3 Code is not required") })
    }

    func testConfiguredCodexInstancesIgnoreInheritedCodexHome() {
        let settings = T3Settings(
            instances: [
                T3ProviderInstance(id: "codex", driver: "codex", displayName: "Work Codex"),
                T3ProviderInstance(id: "codex_personal", driver: "codex", displayName: "Personal Codex", shadowHomePath: "/tmp/personal-codex"),
            ],
            settingsPath: URL(fileURLWithPath: "/tmp/settings.json")
        )

        let discovery = AccountDiscovery.discover(
            settings: settings,
            environment: ["CODEX_HOME": "/tmp/inherited-personal-codex"]
        )
        let codexRoots = discovery.sources
            .filter { $0.provider == .codex }
            .map(\.rootDir)

        XCTAssertEqual(codexRoots, [
            NSHomeDirectory() + "/.codex/sessions",
            NSHomeDirectory() + "/.codex/archived_sessions",
        ])
        XCTAssertFalse(codexRoots.contains { $0.contains("inherited-personal-codex") })
    }

    func testT3ProviderInstancesTakePrecedenceWhenPresent() {
        let settings = T3Settings(
            instances: [
                T3ProviderInstance(id: "codex_work", driver: "codex", homePath: "/tmp/t3-codex"),
            ],
            settingsPath: URL(fileURLWithPath: "/tmp/t3-settings.json")
        )

        let discovery = AccountDiscovery.discover(
            settings: settings,
            environment: [
                "CODEX_HOME": "/tmp/standalone-codex",
                "GROK_HOME": "/tmp/standalone-grok",
                "XDG_DATA_HOME": "/tmp/standalone-data",
            ]
        )

        XCTAssertEqual(
            discovery.sources.map(\.rootDir),
            ["/tmp/t3-codex/sessions", "/tmp/t3-codex/archived_sessions"]
        )
        XCTAssertNil(discovery.openCodeDatabase)
        XCTAssertTrue(discovery.notes.contains { $0.contains("/tmp/t3-settings.json") })
    }
}
