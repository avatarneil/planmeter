import XCTest
import SQLite3
@testable import PlanMeterCore

final class AccountUsageTests: XCTestCase {
    let target = CodexUsageTarget(id: "service:user@example.com", name: "Test", home: "/tmp", email: "user@example.com",
        plan: "pro", serviceAccountId: "service", localAccountId: "codex:plan:pro")
    let now = Date(timeIntervalSince1970: 1_790_899_200) // 2026-10-02 UTC

    func entry(account: String = "codex:plan:pro", session: String = "one", input: Int = 100, cost: Double = 2) -> ThreadCellEntry {
        let key = CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(now.timeIntervalSince1970 * 1000)), accountId: account, model: "test")
        return ThreadCellEntry(sessionId: session, key: key,
            cell: Cell(totals: TokenTotals(uncachedInput: input), reportedCostUsd: cost, records: 1, sessionIds: [session]), sourcePath: "/tmp/transcript.jsonl")
    }

    func snapshot(tokens: Int = 250) -> AccountUsageSnapshot {
        var snapshot = AccountUsageSnapshot(target: target)
        snapshot.days = [AccountUsageDay(startDate: "2026-10-02", tokens: tokens)]
        snapshot.fetchedAt = now
        snapshot.status = .ok
        return snapshot
    }

    func testCoverageNeverAddsAccountTokensOrPricesDifference() {
        let entries = [entry(), entry(session: "two", input: 50, cost: 1)]
        let row = UsageCoverage.reconcile([snapshot()], entries: entries, rates: RateTable(), days: 1, now: now)[0]
        XCTAssertEqual(row.accountTokens, 250)
        XCTAssertEqual(row.knownThreadTokens, 150)
        XCTAssertEqual(row.differenceTokens, 100)
        XCTAssertEqual(row.knownThreadCostUsd, 3)
        XCTAssertEqual(row.knownThreads, 2)
        let rows = UsageCoverage.threads(entries, rates: RateTable(), from: now, to: now.addingTimeInterval(86400))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.costUsd }, 3)
    }

    func testNegativeDifferenceIsNotClamped() {
        let row = UsageCoverage.reconcile([snapshot(tokens: 50)], entries: [entry()], rates: RateTable(), days: 1, now: now)[0]
        XCTAssertEqual(row.differenceTokens, -50)
    }

    func testAccountTokensWithoutMatchedThreadsHaveNoCostEstimate() {
        let row = UsageCoverage.reconcile([snapshot()], entries: [], rates: RateTable(), days: 1, now: now)[0]
        XCTAssertEqual(row.accountTokens, 250)
        XCTAssertEqual(row.knownThreadTokens, 0)
        XCTAssertEqual(row.knownThreads, 0)
        XCTAssertEqual(row.differenceTokens, 250)
        XCTAssertNil(row.knownThreadCostUsd)
    }

    func testSparseAndMissingReadingsAreNotZero() {
        let sparse = UsageCoverage.reconcile([snapshot()], entries: [entry()], rates: RateTable(), days: 2, now: now)[0]
        XCTAssertEqual(sparse.accountTokens, 250)
        XCTAssertEqual(sparse.missingDays, ["2026-10-01"])
        XCTAssertNil(sparse.differenceTokens)
        let missing = UsageCoverage.reconcile([AccountUsageSnapshot(target: target)], entries: [entry()], rates: RateTable(), days: 1, now: now)[0]
        XCTAssertNil(missing.accountTokens)
        XCTAssertNil(missing.differenceTokens)
    }

    func testAmbiguousPlanHasNoInventedThreadMatch() {
        var value = snapshot()
        value.target.localAccountId = nil
        let row = UsageCoverage.reconcile([value], entries: [entry()], rates: RateTable(), days: 1, now: now)[0]
        XCTAssertEqual(row.accountTokens, 250)
        XCTAssertNil(row.knownThreadTokens)
        XCTAssertNil(row.differenceTokens)
    }

    func testIdenticalSessionIDsAcrossProvidersStaySeparateAndTitleDoesNotMatch() {
        let entries = [entry(), entry(account: "claude:home:test")]
        let rows = UsageCoverage.threads(entries, rates: RateTable(), from: now, to: now.addingTimeInterval(86400))
        XCTAssertEqual(rows.count, 2)
        let linked = ThreadCatalog.link(rows, catalog: ["codex:one": ThreadLink(title: "Same title", chatId: "chat-1")])
        XCTAssertEqual(linked.first { $0.provider == .codex }?.chatId, "chat-1")
        XCTAssertNil(linked.first { $0.provider == .claude }?.chatId)
    }

    func testAccountPayloadRejectsInvalidDaysCountsAndDuplicateDays() throws {
        let valid: [String: Any] = ["summary": ["lifetimeTokens": 123], "dailyUsageBuckets": [["startDate": "2026-10-02", "tokens": 123]]]
        let decoded = try CodexAccountUsage.decode(valid, target: target, now: now)
        XCTAssertEqual(decoded.days.first?.tokens, 123)
        XCTAssertEqual(decoded.fetchedAt, now)
        for value in [-1, 1.5, true] as [Any] {
            XCTAssertThrowsError(try CodexAccountUsage.decode(["summary": [:], "dailyUsageBuckets": [["startDate": "2026-10-02", "tokens": value]]], target: target))
        }
        XCTAssertThrowsError(try CodexAccountUsage.decode(["summary": [:], "dailyUsageBuckets": [["startDate": "2026-02-31", "tokens": 1]]], target: target))
        XCTAssertThrowsError(try CodexAccountUsage.decode(["summary": [:], "dailyUsageBuckets": [["startDate": "2026-10-02", "tokens": 1], ["startDate": "2026-10-02", "tokens": 1]]], target: target))
        XCTAssertThrowsError(try CodexAccountUsage.decode(["summary": [:]], target: target))
    }

    func testScannerRetainsDistinctThreadSpendAcrossWarmCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("transcript.jsonl")
        let lines = ["a", "b"].enumerated().map { index, session in
            """
            {"type":"assistant","timestamp":"2026-10-02T00:00:00Z","sessionId":"\(session)","message":{"id":"\(session)","model":"test","usage":{"input_tokens":\((index + 1) * 100),"output_tokens":10}}}
            """
        }.joined(separator: "\n")
        try Data(lines.utf8).write(to: file)
        let source = ScanSource(provider: .claude, rootDir: dir.path, fixedAccountId: "claude:home:test")
        let cacheURL = dir.appendingPathComponent("cache.json")
        let cache = ScanCache(url: cacheURL)
        let cold = await Scanner.scan(sources: [source], openCodeDatabase: nil, sinceMs: 0, cache: cache)
        let newCache = ScanCache(url: cacheURL)
        await newCache.load()
        let warm = await Scanner.scan(sources: [source], openCodeDatabase: nil, sinceMs: 0, cache: newCache)
        XCTAssertEqual(warm.sources.first?.reusedFiles, 1)
        for scan in [cold, warm] {
            let rows = UsageCoverage.threads(scan.threads, rates: RateTable(), from: now, to: now.addingTimeInterval(86400))
            XCTAssertEqual(rows.first { $0.sessionId == "a" }?.tokens, 110)
            XCTAssertEqual(rows.first { $0.sessionId == "b" }?.tokens, 210)
            XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, scan.cells.values.reduce(0) { $0 + $1.totals.total })
        }
    }

    func testRPCFailureAndTimeoutAreBoundedAndSanitized() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexec sleep 5\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var t = target
        t.home = dir.path
        let start = Date()
        let failed = CodexAccountUsage.read(target: t, executableURL: script, timeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(failed.fetchedAt)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.message?.contains("timed out") == true)
        try Data("#!/bin/sh\nprintf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"secret-token\"}}'\n".utf8).write(to: script)
        let error = CodexAccountUsage.read(target: t, executableURL: script, timeout: 1)
        XCTAssertEqual(error.status, .failed)
        XCTAssertFalse(error.message?.contains("secret-token") == true)
    }

    func testRPCUsesIsolatedLoginAndReadMethodsOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var t = target
        t.home = dir.path
        let claims: [String: Any] = ["email": t.email, "https://api.openai.com/auth": ["chatgpt_account_id": t.serviceAccountId, "chatgpt_plan_type": t.plan]]
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth: [String: Any] = ["tokens": ["id_token": "e30.\(encoded).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: dir.appendingPathComponent("auth.json"))
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/usr/bin/env python3
        import json,os,sys
        home=os.environ['CODEX_HOME']
        for line in sys.stdin:
            r=json.loads(line)
            with open(home+'/requests.jsonl','a') as f: f.write(line)
            if 'id' not in r: continue
            method=r['method']
            if method=='initialize': result={}
            elif method=='account/read': result={'account':{'type':'chatgpt','email':'user@example.com','planType':'pro'},'workspaceRouting':{'chatgptAccountId':'service'}}
            elif method=='account/usage/read': result={'summary':{},'dailyUsageBuckets':[{'startDate':'2026-10-02','tokens':250}]}
            else: sys.exit(1)
            print(json.dumps({'method':'notification','params':{}}),flush=True)
            data=(json.dumps({'id':r['id'],'result':result})+'\\n').encode()
            os.write(1,data[:8]);os.write(1,data[8:])
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = CodexAccountUsage.read(target: t, executableURL: script, timeout: 3)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.days.first?.tokens, 250)
        let requests = try String(contentsOf: dir.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { JSON.object(Data($0.utf8))?["method"] as? String }
        XCTAssertEqual(requests, ["initialize", "initialized", "account/read", "account/usage/read"])
        t.email = "other@example.com"
        let wrongIdentity = CodexAccountUsage.read(target: t, executableURL: script, timeout: 3)
        XCTAssertNil(wrongIdentity.fetchedAt)
        XCTAssertEqual(wrongIdentity.status, .failed)
    }

    func testPollingAndStaleReadings() async {
        final class Reads: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func read(_ target: CodexUsageTarget) -> AccountUsageSnapshot {
                lock.lock(); defer { lock.unlock() }
                count += 1
                var value = AccountUsageSnapshot(target: target)
                if count == 1 {
                    value.status = .ok
                    value.fetchedAt = Date()
                    value.days = [AccountUsageDay(startDate: "2026-10-02", tokens: 250)]
                } else {
                    value.status = .failed
                    value.message = "Timeout"
                }
                return value
            }
        }
        let reads = Reads()
        let reader = CodexAccountUsage(reader: { reads.read($0) })
        let first = await reader.load(targets: [target])
        _ = await reader.load(targets: [target])
        XCTAssertEqual(reads.count, 1)
        let stale = await reader.load(targets: [target], force: true)
        XCTAssertEqual(stale[0].days, first[0].days)
        XCTAssertEqual(stale[0].fetchedAt, first[0].fetchedAt)
        XCTAssertEqual(stale[0].status, .partial)
        XCTAssertTrue(stale[0].message?.contains("Stale") == true)
        let row = UsageCoverage.reconcile(stale, entries: [entry()], rates: RateTable(), days: 1, now: now)[0]
        XCTAssertNil(row.differenceTokens)
    }

    func testDiscoveryUsesShadowLoginAndSuppressesSamePlanReconciliation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var instances: [T3ProviderInstance] = []
        for name in ["one", "two"] {
            let home = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let claims: [String: Any] = ["email": "\(name)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": name, "chatgpt_plan_type": "pro"]]
            let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "e30.\(encoded).sig"]]).write(to: home.appendingPathComponent("auth.json"))
            instances.append(T3ProviderInstance(id: name, driver: "codex", homePath: dir.path, shadowHomePath: home.path))
        }
        let settings = T3Settings(instances: instances, settingsPath: dir.appendingPathComponent("settings.json"))
        let discovery = AccountDiscovery.discover(settings: settings, environment: ["CODEX_HOME": "/wrong"])
        XCTAssertEqual(discovery.codexUsageTargets.count, 2)
        XCTAssertEqual(Set(discovery.codexUsageTargets.map(\.home)), Set(instances.compactMap(\.shadowHomePath)))
        XCTAssertTrue(discovery.codexUsageTargets.allSatisfy { $0.localAccountId == nil })
        XCTAssertEqual(discovery.sources.filter { $0.provider == .codex }.count, 2)
    }

    func testT3CatalogReadsExactRuntimeCursorMappings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE projection_threads (thread_id TEXT, title TEXT);
        CREATE TABLE provider_session_runtime (thread_id TEXT, provider_name TEXT, resume_cursor_json TEXT);
        INSERT INTO projection_threads VALUES ('chat-1', 'Named chat');
        INSERT INTO provider_session_runtime VALUES ('chat-1', 'codex', '{"threadId":"codex-1"}');
        INSERT INTO provider_session_runtime VALUES ('chat-1', 'claudeAgent', '{"sessionId":"claude-1"}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let catalog = ThreadCatalog.load(discovery: Discovery(), t3Database: url.path)
        XCTAssertEqual(catalog["codex:codex-1"]?.chatId, "chat-1")
        XCTAssertEqual(catalog["claude:claude-1"]?.chatId, "chat-1")
        XCTAssertEqual(catalog["codex:codex-1"]?.title, "Named chat")
        XCTAssertNil(catalog["codex:claude-1"])
    }
}
