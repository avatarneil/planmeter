import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
@testable import PlanMeterCore

final class CursorUsageTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("planmeter-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    static func token(sub: String, exp: TimeInterval = 4_000_000_000) -> String {
        func b64(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(["alg": "HS256", "typ": "JWT"])).\(b64(["sub": sub, "exp": exp, "type": "session"])).c2lnbmF0dXJl"
    }

    /// A VS Code-style `state.vscdb` holding Cursor's auth rows.
    func editorDatabase(at dir: URL, rows: [String: String]) throws -> URL {
        let url = dir.appendingPathComponent("User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil), SQLITE_OK)
        for (key, value) in rows {
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('\(key)', '\(escaped)')", nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    func cliHome(at dir: URL, token: String, email: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["accessToken": token, "refreshToken": "r"]).write(to: dir.appendingPathComponent("auth.json"))
        try JSONSerialization.data(withJSONObject: ["authInfo": ["email": email, "userId": 7]]).write(to: dir.appendingPathComponent("cli-config.json"))
    }

    func t3(_ instances: [T3ProviderInstance]) -> [T3ProviderInstance] { instances }

    // MARK: Discovery

    func testEditorAndCLICopiesOfOneLoginShareAnAccount() throws {
        let editorDir = root.appendingPathComponent("editor")
        let cliDir = root.appendingPathComponent("cli")
        _ = try editorDatabase(at: editorDir, rows: [
            "cursorAuth/accessToken": Self.token(sub: "auth0|user_01WORK"),
            "cursorAuth/cachedEmail": "me@company.example",
            "cursorAuth/stripeMembershipType": "enterprise",
        ])
        try cliHome(at: cliDir, token: Self.token(sub: "google-oauth2|user_01WORK"), email: "me@company.example")
        let result = CursorDiscovery.discover(
            instances: [T3ProviderInstance(id: "cursor", driver: "cursor", displayName: "Work Cursor", accentColorHex: "#123456")],
            usesT3Configuration: true, environment: ["PLANMETER_CURSOR_HOMES": "\(editorDir.path),\(cliDir.path)"], home: root.path)

        XCTAssertEqual(result.accounts.count, 1)
        let account = try XCTUnwrap(result.accounts.first)
        XCTAssertEqual(account.provider, .cursor)
        XCTAssertTrue(account.id.hasPrefix("cursor:user:"))
        XCTAssertFalse(account.id.contains("user_01WORK"), "the raw user id stays out of account ids")
        XCTAssertEqual(account.email, "me@company.example")
        XCTAssertEqual(account.planLabel, "Enterprise")
        XCTAssertEqual(account.suggestedGroup, .work)
        XCTAssertEqual(result.targets.first?.sources.map(\.kind), [.editor, .cli])
        XCTAssertEqual(result.planLimitTargets.first?.provider, .cursor)
        XCTAssertEqual(result.planLimitTargets.first?.authMethod, "editor")
    }

    func testDistinctLoginsBecomeSeparateAccounts() throws {
        let work = root.appendingPathComponent("work")
        let personal = root.appendingPathComponent("personal")
        _ = try editorDatabase(at: work, rows: ["cursorAuth/accessToken": Self.token(sub: "auth0|user_WORK"),
                                                "cursorAuth/cachedEmail": "me@company.example"])
        _ = try editorDatabase(at: personal, rows: ["cursorAuth/accessToken": Self.token(sub: "auth0|user_HOME"),
                                                    "cursorAuth/cachedEmail": "me@gmail.com",
                                                    "cursorAuth/stripeMembershipType": "pro"])
        let result = CursorDiscovery.discover(
            instances: [
                T3ProviderInstance(id: "cursor", driver: "cursor", displayName: "Work Cursor", homePath: work.path),
                T3ProviderInstance(id: "cursor_personal", driver: "cursor", displayName: "Personal Cursor", homePath: personal.path),
                T3ProviderInstance(id: "cursor_off", driver: "cursor", enabled: false, homePath: root.path),
            ],
            usesT3Configuration: true, environment: [:], home: root.path)

        XCTAssertEqual(result.accounts.map(\.displayName), ["Work Cursor", "Personal Cursor"])
        XCTAssertEqual(result.accounts.map(\.suggestedGroup), [.work, .personal])
        XCTAssertEqual(Set(result.accounts.map(\.id)).count, 2)
        XCTAssertEqual(result.accounts[1].planLabel, "Pro")
        XCTAssertTrue(result.notes.contains { $0.contains("2 Cursor logins") })
    }

    func testStandaloneDiscoveryDisambiguatesTwoLoginsInDefaultPlaces() throws {
        let home = root.appendingPathComponent("home")
        #if os(macOS)
        let editor = home.appendingPathComponent("Library/Application Support/Cursor")
        let cli = home.appendingPathComponent(".cursor")
        #else
        let editor = home.appendingPathComponent(".config/Cursor")
        let cli = home.appendingPathComponent(".config/cursor")
        #endif
        _ = try editorDatabase(at: editor, rows: ["cursorAuth/accessToken": Self.token(sub: "auth0|user_A"),
                                                  "cursorAuth/cachedEmail": "a@company.example"])
        try cliHome(at: cli, token: Self.token(sub: "auth0|user_B"), email: "b@gmail.com")
        let result = CursorDiscovery.discover(instances: [], usesT3Configuration: false, environment: [:], home: home.path)
        XCTAssertEqual(result.accounts.map(\.displayName), ["Cursor (a@company.example)", "Cursor (b@gmail.com)"])
    }

    func testUnreadableLoginsAreNotedNotGuessed() throws {
        let encrypted = root.appendingPathComponent("encrypted")
        _ = try editorDatabase(at: encrypted, rows: ["cursorAuth/accessToken": "cursor-safe-storage:v1:djExAAAA"])
        let garbage = root.appendingPathComponent("garbage")
        try cliHome(at: garbage, token: "not-a-jwt", email: "x@example.com")
        let result = CursorDiscovery.discover(instances: [], usesT3Configuration: false,
            environment: ["PLANMETER_CURSOR_HOMES": "\(encrypted.path), \(garbage.path)"], home: root.appendingPathComponent("none").path)
        XCTAssertTrue(result.accounts.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("encrypts its saved login") })
        XCTAssertTrue(result.notes.contains { $0.contains("Could not read the saved Cursor login") })
    }

    func testAccountDiscoveryReplacesTheUnsupportedCursorEntry() throws {
        let editor = root.appendingPathComponent("editor")
        _ = try editorDatabase(at: editor, rows: ["cursorAuth/accessToken": Self.token(sub: "auth0|user_X")])
        let settings = T3Settings(instances: [
            T3ProviderInstance(id: "cursor", driver: "cursor", homePath: editor.path),
            T3ProviderInstance(id: "cursor_work", driver: "cursor", displayName: "Work Cursor", enabled: false),
        ], settingsPath: root.appendingPathComponent("settings.json"))
        let discovery = AccountDiscovery.discover(settings: settings, environment: ["HOME": root.path])
        XCTAssertEqual(discovery.accounts.filter { $0.provider == .cursor }.count, 1)
        XCTAssertEqual(discovery.cursorUsageTargets.count, 1)
        XCTAssertEqual(discovery.unsupported.map(\.reason), ["Disabled in T3 Code."])
        XCTAssertTrue(discovery.planLimitTargets.contains { $0.provider == .cursor })
    }

    // MARK: Encrypted logins (Cursor 3.x)

    func testEncryptedEditorLoginIsFoundByItsMembershipAuthId() throws {
        let plain = root.appendingPathComponent("plain")
        _ = try editorDatabase(at: plain, rows: ["cursorAuth/accessToken": Self.token(sub: "google-oauth2|user_01WORK")])
        let encrypted = root.appendingPathComponent("encrypted")
        _ = try editorDatabase(at: encrypted, rows: [
            // Malformed, so a regression fails here instead of asking the Keychain.
            "cursorAuth/accessToken": "cursor-safe-storage:v1:djEwAAAA",
            "cursorAuth/stripeMembershipAuthId": "google-oauth2|user_01WORK",
            "cursorAuth/cachedEmail": "me@company.example",
            "cursorAuth/stripeMembershipType": "enterprise",
        ])
        let before = CursorDiscovery.discover(instances: [], usesT3Configuration: false,
            environment: ["PLANMETER_CURSOR_HOMES": plain.path], home: root.appendingPathComponent("none").path)
        let after = CursorDiscovery.discover(instances: [], usesT3Configuration: false,
            environment: ["PLANMETER_CURSOR_HOMES": encrypted.path], home: root.appendingPathComponent("none").path)
        XCTAssertEqual(after.accounts.count, 1)
        XCTAssertEqual(after.accounts.first?.id, before.accounts.first?.id, "the same login keeps its account and cached history")
        XCTAssertEqual(after.accounts.first?.email, "me@company.example")
        XCTAssertEqual(after.accounts.first?.planLabel, "Enterprise")
        XCTAssertEqual(after.targets.first?.id, before.targets.first?.id)
        XCTAssertTrue(after.notes.isEmpty)
    }

    func testEncryptedLoginWithoutIdentityExplainsWhyCursorIsMissing() throws {
        let editor = root.appendingPathComponent("editor")
        _ = try editorDatabase(at: editor, rows: ["cursorAuth/accessToken": "cursor-safe-storage:v2:future"])
        let settings = T3Settings(instances: [T3ProviderInstance(id: "cursor", driver: "cursor", homePath: editor.path)],
                                  settingsPath: root.appendingPathComponent("settings.json"))
        let discovery = AccountDiscovery.discover(settings: settings, environment: ["HOME": root.path])
        XCTAssertTrue(discovery.cursorUsageTargets.isEmpty)
        XCTAssertEqual(discovery.unsupported.count, 1)
        XCTAssertTrue(discovery.unsupported[0].reason.contains("encrypts its saved login"), discovery.unsupported[0].reason)
    }

    #if os(macOS)
    func testDecryptsElectronSafeStorageValues() throws {
        // Produced independently with Python's PBKDF2 and `openssl enc -aes-128-cbc`.
        let key = try XCTUnwrap(CursorSafeStorage.deriveKey(password: Data("test-safe-storage-password".utf8)))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "8d980c26091f4ec99749af7dd4090b2e")
        let saved = "cursor-safe-storage:v1:djEwdE8L7nxyrMRcsOhRHXQqKwfLG+7MlPhWkPQz1B3vQ40="
        XCTAssertEqual(try CursorSafeStorage.decrypt(saved, key: key), "header.payload.signature")

        let token = Self.token(sub: "auth0|user_X")
        XCTAssertEqual(try CursorSafeStorage.decrypt(try CursorSafeStorage.encrypt(token, key: key), key: key), token)

        let wrong = try XCTUnwrap(CursorSafeStorage.deriveKey(password: Data("other".utf8)))
        XCTAssertThrowsError(try CursorSafeStorage.decrypt(saved, key: wrong)) { XCTAssertEqual($0 as? CursorError, .unreadable) }
        XCTAssertThrowsError(try CursorSafeStorage.decrypt("cursor-safe-storage:v1:!!", key: key)) { XCTAssertEqual($0 as? CursorError, .unreadable) }
        XCTAssertThrowsError(try CursorSafeStorage.decrypt("cursor-safe-storage:v1:djExAAAAAAAAAAAAAAAAAAAAAA==", key: key)) {
            XCTAssertEqual($0 as? CursorError, .encrypted, "v11 is Linux's libsecret scheme")
        }
    }
    #endif

    func testExpiredLoginIsReportedAtRequestTime() throws {
        XCTAssertThrowsError(try CursorCredentials.credential(token: Self.token(sub: "auth0|user_X", exp: 100), email: nil, membership: nil,
                                                              now: Date(timeIntervalSince1970: 1_000))) { error in
            XCTAssertEqual(error as? CursorError, .expired)
        }
        let credential = try CursorCredentials.credential(token: Self.token(sub: "auth0|user_X"), email: nil, membership: nil)
        XCTAssertEqual(credential.userId, "user_X")
        let request = try CursorAPI.request(path: "/api/usage-summary", body: nil, credential: credential)
        XCTAssertEqual(request.url?.host, "cursor.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_X%3A%3A\(credential.token)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        let post = try CursorAPI.request(path: "/api/dashboard/get-filtered-usage-events", body: ["page": 1], credential: credential)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
    }

    // MARK: Usage log

    func testParsesUsageEventsWithStringNumbers() throws {
        let page = try CursorUsage.parsePage([
            "totalUsageEventsCount": 3,
            "usageEventsDisplay": [
                ["timestamp": "1763500000000", "model": "claude-4.6-opus-high-thinking", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
                 "tokenUsage": ["inputTokens": 1200, "outputTokens": 340, "cacheWriteTokens": 50, "cacheReadTokens": "9000", "totalCents": 121.41],
                 "chargedCents": 124.73, "isTokenBasedCall": true, "usageEventId": "evt_1", "conversationId": "conv_1"],
                ["timestamp": "1763500001000", "model": "composer-2", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
                 "tokenUsage": ["inputTokens": 10, "outputTokens": 5], "chargedCents": 0],
                // A request-counted event with nothing to chart.
                ["timestamp": "1763500002000", "model": "default", "requestsCosts": 1],
            ],
        ])
        XCTAssertEqual(page.rows, 3)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.events.count, 2)
        let first = page.events[0]
        XCTAssertEqual(first.timestampMs, 1_763_500_000_000)
        XCTAssertEqual(first.totals, TokenTotals(uncachedInput: 1200, cachedInput: 9000, cacheCreation: 50, output: 340))
        XCTAssertEqual(first.costUsd ?? 0, 1.2141, accuracy: 1e-9)
        XCTAssertEqual(first.key, "id:evt_1")
        XCTAssertEqual(first.conversationId, "conv_1")
        XCTAssertNil(page.events[1].eventId)
        // No token cost: the charged amount (here plan-included, $0) stands.
        XCTAssertEqual(page.events[1].costUsd, 0)
        XCTAssertThrowsError(try CursorUsage.parsePage(["error": "not_authenticated"]))
    }

    func testIncrementalRefreshMergesAndCaches() async throws {
        let target = CursorUsageTarget(id: String(AntigravityIdentity.sha256Hex("cursor:user_X").prefix(16)), accountId: "cursor:user:x",
                                       name: "Cursor", sources: [CursorCredentialSource(kind: .cli, path: "/unused")])
        let credential = try CursorCredentials.credential(token: Self.token(sub: "auth0|user_X"), email: nil, membership: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sinceMs = nowMs - 7 * 86_400_000
        let log = EventLog(events: (0..<700).map { i in
            CursorUsageEvent(timestampMs: sinceMs + Int64(i) * 600_000, model: i % 2 == 0 ? "gpt-5.5" : "composer-2",
                             inputTokens: 100, outputTokens: 10, costCents: 1)
        })
        let cacheURL = root.appendingPathComponent("cursor-usage.json")
        let usage = CursorUsage(cacheURL: cacheURL, credentials: { _ in credential }, fetchPage: { _, start, end, page in
            await log.page(start: start, end: end, page: page, size: CursorUsage.pageSize)
        })

        let first = await usage.load(targets: [target], sinceMs: sinceMs, now: now)
        XCTAssertEqual(first.first?.status, .ok)
        XCTAssertEqual(first.first?.events.count, 700)
        let requests = await log.requests
        XCTAssertEqual(requests.map(\.page), [1, 2], "two pages of 500")

        // Within five minutes the cached reading is reused.
        _ = await usage.load(targets: [target], sinceMs: sinceMs, now: now.addingTimeInterval(60))
        let reused = await log.requests.count
        XCTAssertEqual(reused, 2)

        // A later refresh asks only for recent history and keeps the rest.
        await log.append(CursorUsageEvent(timestampMs: nowMs + 3_000_000, model: "gpt-5.5", inputTokens: 5, costCents: 2))
        let later = now.addingTimeInterval(3_600)
        let second = await usage.load(targets: [target], sinceMs: sinceMs + 3_600_000, now: later)
        XCTAssertEqual(second.first?.events.count, 701)
        let last = await log.requests.last
        XCTAssertEqual(last?.start, nowMs - CursorUsage.overlapMs)

        // A new process starts from the disk cache, and a failure keeps it as stale.
        let offline = CursorUsage(cacheURL: cacheURL, credentials: { _ in credential }, fetchPage: { _, _, _, _ in throw CursorError.signedOut })
        let stale = await offline.load(targets: [target], sinceMs: sinceMs, now: later)
        XCTAssertEqual(stale.first?.status, .partial)
        XCTAssertEqual(stale.first?.events.count, 701)
        XCTAssertTrue(stale.first?.message?.hasPrefix("Stale reading.") == true)
        let cached = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(cached.contains(credential.token), "credentials never reach the cache")
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        #endif
    }

    func testProcessWithoutKeychainAccessShowsTheAppsNewestReading() async throws {
        let target = CursorUsageTarget(id: String(AntigravityIdentity.sha256Hex("cursor:user_X").prefix(16)), accountId: "cursor:user:x",
                                       name: "Cursor", sources: [CursorCredentialSource(kind: .editor, path: "/unused")])
        let credential = try CursorCredentials.credential(token: Self.token(sub: "auth0|user_X"), email: nil, membership: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sinceMs = Int64(now.timeIntervalSince1970 * 1000) - 86_400_000
        let cacheURL = root.appendingPathComponent("cursor-usage.json")
        let mcp = CursorUsage(cacheURL: cacheURL, credentials: { _ in throw CursorError.keychainUnavailable },
                              fetchPage: { _, _, _, _ in XCTFail("no key, no request"); return CursorEventPage(events: [], rows: 0, total: 0) })
        // Started before the app had read anything.
        let empty = await mcp.load(targets: [target], sinceMs: sinceMs, now: now)
        XCTAssertEqual(empty.first?.status, .failed)
        XCTAssertTrue(empty.first?.message?.contains("doesn't show the Keychain prompt") == true)

        // The app (which has the key) writes a reading to the shared cache.
        let app = CursorUsage(cacheURL: cacheURL, credentials: { _ in credential }, fetchPage: { _, _, _, _ in
            CursorEventPage(events: [CursorUsageEvent(timestampMs: sinceMs + 60_000, model: "gpt-5.5", inputTokens: 10, costCents: 1)],
                            rows: 1, total: 1)
        })
        _ = await app.load(targets: [target], sinceMs: sinceMs, now: now.addingTimeInterval(60))

        let shared = await mcp.load(targets: [target], sinceMs: sinceMs, force: true, now: now.addingTimeInterval(120))
        XCTAssertEqual(shared.first?.status, .partial)
        XCTAssertEqual(shared.first?.events.count, 1)
        XCTAssertTrue(shared.first?.message?.hasPrefix("Showing the PlanMeter app's last Cursor reading.") == true)
    }

    func testLoginNowSignedInAsSomeoneElseIsRejected() async throws {
        let target = CursorUsageTarget(id: "0000000000000000", accountId: "cursor:user:0", name: "Cursor",
                                       sources: [CursorCredentialSource(kind: .cli, path: "/unused")])
        let other = try CursorCredentials.credential(token: Self.token(sub: "auth0|user_OTHER"), email: nil, membership: nil)
        let usage = CursorUsage(cacheURL: nil, credentials: { _ in other }, fetchPage: { _, _, _, _ in
            XCTFail("must not fetch for a different login")
            return CursorEventPage(events: [], rows: 0, total: 0)
        })
        let snapshot = await usage.load(targets: [target], sinceMs: 0).first
        XCTAssertEqual(snapshot?.status, .failed)
    }

    func testProjectionAddsCellsAndSourceRows() {
        let target = CursorUsageTarget(id: "abc", accountId: "cursor:user:abc", name: "Work Cursor", sources: [])
        var snapshot = CursorUsageSnapshot(target: target)
        snapshot.fetchedAt = Date()
        snapshot.status = .ok
        snapshot.events = [
            CursorUsageEvent(timestampMs: 120_000, model: "gpt-5.5", inputTokens: 100, outputTokens: 10, costCents: 50, conversationId: "conv"),
            CursorUsageEvent(timestampMs: 130_000, model: "gpt-5.5", inputTokens: 1, outputTokens: 1, costCents: 25),
            CursorUsageEvent(timestampMs: 200_000, model: "composer-2", outputTokens: 7),
        ]
        let merged = CursorUsageProjection.merging([snapshot], into: ScanOutput())
        let cell = merged.cells[CellKey(startMs: 120_000, accountId: "cursor:user:abc", model: "gpt-5.5")]
        XCTAssertEqual(cell?.records, 2)
        XCTAssertEqual(cell?.reportedCostUsd ?? 0, 0.75, accuracy: 1e-9)
        let unpriced = merged.cells[CellKey(startMs: 180_000, accountId: "cursor:user:abc", model: "composer-2")]
        XCTAssertEqual(unpriced?.unpricedTotals.output, 7)
        XCTAssertEqual(merged.sources.map(\.path), ["cursor.com usage · Work Cursor"])
        XCTAssertEqual(merged.sources.first?.scannedFiles, 3)
        XCTAssertEqual(merged.threads.map(\.sessionId), ["conv"])
        XCTAssertEqual(cell?.sessionIds, ["conv"])
    }

    // MARK: Plan limits

    func testDecodesUsageSummary() throws {
        let target = PlanLimitTarget(accountId: "cursor:user:x", provider: .cursor, tokenPath: "/x", authMethod: "editor")
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try CursorPlanLimits.decode([
            "billingCycleStart": "2026-11-01T00:00:00.000Z",
            "billingCycleEnd": "2026-12-01T00:00:00.000Z",
            "membershipType": "pro_plus",
            "isUnlimited": false,
            "individualUsage": [
                "plan": ["enabled": true, "used": 1500, "limit": 2000, "remaining": 500,
                         "autoPercentUsed": 12.5, "apiPercentUsed": 80, "totalPercentUsed": 75],
                "onDemand": ["enabled": true, "used": 2309, "limit": NSNull(), "remaining": NSNull()],
            ] as [String: Any],
            "teamUsage": ["onDemand": ["enabled": true, "used": 500, "limit": 1000]],
        ], target: target, now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.plan, "Pro+")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Monthly · Included", "Monthly · Auto + Composer", "Monthly · API models", "Team on-demand"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [75, 12.5, 80, 50])
        XCTAssertEqual(snapshot.windows[0].windowMinutes, 30 * 1440)
        XCTAssertEqual(snapshot.windows[0].resetsAt?.timeIntervalSince1970, 1_796_083_200)
        XCTAssertEqual(snapshot.message, "On-demand: $23.09 this cycle, no limit set.")

        let derived = try CursorPlanLimits.decode(["individualUsage": ["plan": ["used": 50, "limit": 200]]], target: target, now: now)
        XCTAssertEqual(derived.windows.first?.usedPercent, 25)
        XCTAssertNil(derived.windows.first?.resetsAt)
        XCTAssertThrowsError(try CursorPlanLimits.decode(["error": "not_authenticated"], target: target, now: now))
    }
}

/// A fake usage log answering page requests like the dashboard route.
actor EventLog {
    struct Request { var start: Int64; var end: Int64; var page: Int }
    var events: [CursorUsageEvent]
    var requests: [Request] = []

    init(events: [CursorUsageEvent]) { self.events = events }

    func append(_ event: CursorUsageEvent) { events.append(event) }

    func page(start: Int64, end: Int64, page: Int, size: Int) -> CursorEventPage {
        requests.append(Request(start: start, end: end, page: page))
        let matching = events.filter { $0.timestampMs >= start && $0.timestampMs < end }.sorted { $0.timestampMs > $1.timestampMs }
        let slice = Array(matching.dropFirst((page - 1) * size).prefix(size))
        return CursorEventPage(events: slice, rows: slice.count, total: matching.count)
    }
}
