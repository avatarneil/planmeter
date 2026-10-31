import SQLite3
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
            "provider_a/custom-model": ["input_cost_per_token": 0.00001, "output_cost_per_token": 0.00005],
            "provider_b/custom-model": ["input_cost_per_token": 0.00002, "output_cost_per_token": 0.00005],
            "gemini/gemini-4-argon": ["input_cost_per_token": 0.000002, "output_cost_per_token": 0.00001, "cache_read_input_token_cost": 0.0000001],
            "kyma/gemini-4-argon": ["input_cost_per_token": 0.0000054, "output_cost_per_token": 0.000027, "cache_read_input_token_cost": 0.00000027],
            "gemini-3.1-pro-preview": ["input_cost_per_token": 0.000002, "output_cost_per_token": 0.000012, "cache_read_input_token_cost": 0.0000002],
            "kyma/gemini-3.1-pro": ["input_cost_per_token": 0.0000027, "output_cost_per_token": 0.0000162, "cache_read_input_token_cost": 0.00000027],
            "deepinfra/google/gemini-3.1-pro": ["input_cost_per_token": 0.000002, "output_cost_per_token": 0.000012],
            "anthropic/claude-fable-5-1": ["input_cost_per_token": 0.00001, "output_cost_per_token": 0.00005],
        ]
        let table = RateTable.from(liteLLMDocument: doc, source: "test", fetchedAt: nil)
        XCTAssertNotNil(table.lookup("gpt-5.6-luna"))
        XCTAssertNil(table.lookup("custom-model"), "conflicting third-party rates without an authoritative prefix must not alias")
        XCTAssertEqual(table.lookup("gemini-4-argon")?.input, 0.000002)
        XCTAssertEqual(table.lookup("gemini-4-argon-trial")?.input, 0.000002)
        XCTAssertEqual(table.lookup("gemini-4-argon-high")?.input, 0.000002)
        XCTAssertEqual(table.lookup("gemini-3.1-pro")?.cacheRead, 0.0000002)
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
        cells[CellKey(startMs: CellKey.hourStart(forMs: ms), accountId: "codex:plan:pro", model: "gpt-5.6-luna")] = cell
        record.timestampMs = ms + 3_600_000
        var cell2 = Cell()
        cell2.add(record)
        cells[CellKey(startMs: CellKey.hourStart(forMs: ms + 3_600_000), accountId: "codex:plan:pro", model: "gpt-5.6-luna")] = cell2

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
                "ANTIGRAVITY_DATA_DIR": "/tmp/planmeter-antigravity",
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
            discovery.sources.first { $0.provider == .antigravity }?.rootDir,
            "/tmp/planmeter-antigravity/conversations"
        )
        XCTAssertEqual(
            discovery.sources.first { $0.provider == .grok }?.rootDir,
            "/tmp/planmeter-grok/sessions"
        )
        XCTAssertEqual(discovery.openCodeDatabase, "/tmp/planmeter-data/opencode/opencode.db")
        XCTAssertTrue(discovery.notes.contains { $0.contains("T3 Code is not required") })
    }

    func testT3AntigravityInstancesResolveIsolatedProfilesAndIdentity() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceId = "antigravity_personal_antigravity"
        let hash = AntigravityIdentity.sha256Hex(instanceId)
        XCTAssertEqual(hash, "4f20aa79804c2288c23e9a352ffe0def4c8676e75c537951cc33173f676850e6")

        let acpDir = tempDir
            .appendingPathComponent("providers/antigravity")
            .appendingPathComponent(hash)
            .appendingPathComponent("antigravity-acp")
        let conversationsDir = acpDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        try Data("""
        {"auth":{"type":"oauth-personal"},"gcp":{"project":"personal-gcp"}}
        """.utf8).write(to: acpDir.appendingPathComponent("settings.json"))
        try Data("""
        {"active":"dev@gmail.com"}
        """.utf8).write(to: acpDir.appendingPathComponent("google_accounts.json"))

        let settings = T3Settings(
            instances: [
                T3ProviderInstance(
                    id: instanceId,
                    driver: "antigravity",
                    displayName: "Personal Antigravity",
                    accentColorHex: "#f66286",
                    authMethod: "oauth-personal"
                ),
            ],
            settingsPath: tempDir.appendingPathComponent("settings.json")
        )

        let discovery = AccountDiscovery.discover(settings: settings, environment: [:])
        let account = try XCTUnwrap(discovery.accounts.first { $0.provider == .antigravity })
        XCTAssertEqual(account.displayName, "Personal Antigravity")
        XCTAssertEqual(account.email, "dev@gmail.com")
        XCTAssertEqual(account.organization, "personal-gcp")
        XCTAssertEqual(account.accentColorHex, "#f66286")
        XCTAssertEqual(account.suggestedGroup, .personal)
        XCTAssertTrue(discovery.unsupported.isEmpty)
        XCTAssertEqual(
            discovery.sources.filter { $0.provider == .antigravity }.map(\.rootDir),
            [conversationsDir.standardizedFileURL.path]
        )
    }

    func testAntigravityReaderAndScannerParseProtoTrajectoryAndEffortPricing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let conversationsDir = tempDir.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionId = "9d856927-db31-4527-baa5-9d7b52f35023"
        let dbURL = conversationsDir.appendingPathComponent("\(sessionId).db")

        // Build protobuf wire helper functions for test fixture construction.
        func varintField(_ field: Int, _ value: UInt64) -> Data {
            var out = Data()
            func appendVarint(_ v: UInt64) {
                var n = v
                while n >= 0x80 {
                    out.append(UInt8((n & 0x7F) | 0x80))
                    n >>= 7
                }
                out.append(UInt8(n))
            }
            appendVarint(UInt64((field << 3) | 0))
            appendVarint(value)
            return out
        }
        func bytesField(_ field: Int, _ payload: Data) -> Data {
            var out = Data()
            func appendVarint(_ v: UInt64) {
                var n = v
                while n >= 0x80 {
                    out.append(UInt8((n & 0x7F) | 0x80))
                    n >>= 7
                }
                out.append(UInt8(n))
            }
            appendVarint(UInt64((field << 3) | 2))
            appendVarint(UInt64(payload.count))
            out.append(payload)
            return out
        }
        func stringField(_ field: Int, _ text: String) -> Data {
            bytesField(field, Data(text.utf8))
        }

        func concat(_ parts: [Data]) -> Data {
            var out = Data()
            for part in parts { out.append(part) }
            return out
        }

        // Timestamp proto: 1_760_000_000 seconds -> 1_760_000_000_000 ms
        let timestampProto = varintField(1, 1_760_000_000)

        // Usage proto:
        // field 1: modelId (1026 -> claude-opus-4-6)
        // field 2: uncachedInput (1200)
        // field 3: output (300)
        // field 4: cacheCreation (100)
        // field 5: cachedInput (400)
        // field 9: reasoning (50)
        // field 10: responseOutput (250)
        // field 11: requestId ("req-1")
        let usage1 = concat([
            varintField(1, 1026),
            varintField(2, 1200),
            varintField(3, 300),
            varintField(4, 100),
            varintField(5, 400),
            varintField(9, 50),
            varintField(10, 250),
            stringField(11, "req-1"),
        ])

        // Matching step usage with higher counts for the same requestId ("req-1");
        // union-find merges generation + step candidates sharing key 11 ("req-1") and takes max.
        let usage1Step = concat([
            varintField(1, 1026),
            varintField(2, 1500),
            varintField(3, 350),
            varintField(4, 100),
            varintField(5, 500),
            varintField(9, 50),
            varintField(10, 300),
            stringField(11, "req-1"),
        ])

        let genInner = concat([
            varintField(3, 1026),
            bytesField(4, usage1),
            stringField(19, "MODEL_PLACEHOLDER_M26"),
        ])
        let genRoot = bytesField(1, genInner)

        let stepRoot = concat([
            bytesField(8, timestampProto),
            bytesField(9, usage1Step),
            bytesField(24, varintField(1, 1026)),
        ])

        // Create SQLite database with gen_metadata and steps tables
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let createSQL = """
        CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
        CREATE TABLE steps (idx INTEGER, metadata BLOB);
        """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)
        func insertBlob(_ table: String, _ column: String, _ idx: Int, _ blob: Data) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO \(table) (idx, \(column)) VALUES (?, ?);", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, Int64(idx))
            _ = blob.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 2, rawBuffer.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        insertBlob("gen_metadata", "data", 5, genRoot)
        insertBlob("steps", "metadata", 5, stepRoot)
        sqlite3_close(db)

        let records = try XCTUnwrap(AntigravityReader.parseDatabase(path: dbURL.path, fallbackTimestampMs: 1_700_000_000_000))
        XCTAssertEqual(records.count, 1)
        let rec = records[0]
        XCTAssertEqual(rec.provider, .antigravity)
        XCTAssertEqual(rec.sessionId, sessionId)
        XCTAssertEqual(rec.model, "claude-opus-4-6")
        XCTAssertEqual(rec.timestampMs, 1_760_000_000_000)
        XCTAssertEqual(rec.totals.uncachedInput, 1500)
        XCTAssertEqual(rec.totals.cachedInput, 500)
        XCTAssertEqual(rec.totals.cacheCreation, 100)
        XCTAssertEqual(rec.totals.output, 350)

        // Verify RateTable strips effort suffixes (-low, -medium, -high)
        let table = RateTable(rates: [
            "gemini-3.1-pro": ModelRate(input: 0.00000125, output: 0.000005, cacheRead: 0.0000003, cacheCreation: 0),
        ], source: "test")
        XCTAssertNotNil(table.lookup("gemini-3.1-pro-high"))
        XCTAssertNotNil(table.lookup("gemini-3.1-pro-low"))

        // Verify Scanner + ThreadCatalog integration
        let summaryDBURL = tempDir.appendingPathComponent("conversation_summaries.db")
        var sumDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(summaryDBURL.path, &sumDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(sumDB, "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT); INSERT INTO conversation_summaries VALUES ('\(sessionId)', 'Antigravity Test Thread');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(sumDB)

        let accountId = Account.antigravityId(conversationsDir: conversationsDir.path)
        let source = ScanSource(provider: .antigravity, rootDir: conversationsDir.path, fixedAccountId: accountId)
        let cache = ScanCache(url: tempDir.appendingPathComponent("cache.json"))
        let scanOut = await Scanner.scan(sources: [source], openCodeDatabase: nil, sinceMs: 0, cache: cache)
        XCTAssertEqual(scanOut.cells.count, 1)
        XCTAssertEqual(scanOut.threads.count, 1)

        let discovery = Discovery(accounts: [], sources: [source])
        let catalog = ThreadCatalog.load(discovery: discovery, t3Database: tempDir.appendingPathComponent("nonexistent.sqlite").path)
        XCTAssertEqual(catalog["antigravity:\(sessionId)"]?.title, "Antigravity Test Thread")
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
