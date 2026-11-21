import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Cursor keeps no token counts on disk: the editor's chat records carry zeroed
// `tokenCount` fields and the CLI stores none. Usage therefore comes from the
// cursor.com dashboard routes the Cursor editor's own account page uses, signed
// in with the login Cursor already saved. The token is read for each request and
// never copied, refreshed, or written; only the usage events are cached.

// MARK: - Logins

/// Where a Cursor login's access token is saved.
public enum CursorCredentialKind: String, Codable, Hashable, Sendable {
    /// The Cursor editor's `state.vscdb` (`cursorAuth/accessToken`).
    case editor
    /// The Cursor CLI's `auth.json` (`accessToken`), used off macOS and when the
    /// CLI cannot reach the Keychain.
    case cli
}

public struct CursorCredentialSource: Codable, Hashable, Sendable {
    public var kind: CursorCredentialKind
    public var path: String

    public init(kind: CursorCredentialKind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// One Cursor login, identified by its stable user ID. Several saved copies of
/// the same login (the editor and the CLI) share a target.
public struct CursorUsageTarget: Codable, Hashable, Sendable, Identifiable {
    /// A hash of the login's user ID; the raw ID never leaves the request.
    public var id: String
    public var accountId: String
    public var name: String
    public var email: String?
    public var membership: String?
    /// In order of preference; the first readable one signs the requests.
    public var sources: [CursorCredentialSource]

    public init(id: String, accountId: String, name: String, email: String? = nil, membership: String? = nil, sources: [CursorCredentialSource]) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.email = email
        self.membership = membership
        self.sources = sources
    }
}

struct CursorCredential: Sendable {
    var token: String
    var userId: String
    var expiresAt: Date?
    var email: String?
    var membership: String?
}

enum CursorError: Error, Equatable {
    case missing, encrypted, unreadable, expired, signedOut, http, invalid
    case keychainMissing, keychainDenied, keychainUnavailable, keychainNeedsApproval

    var message: String {
        switch self {
        case .missing: return "No saved Cursor login. Sign in to Cursor, then refresh."
        case .encrypted: return "This Cursor version encrypts its saved login in a form PlanMeter can't decrypt here; it reads only Cursor's macOS Keychain encryption."
        case .keychainMissing: return "Cursor's saved login is encrypted, but its \"Cursor Safe Storage\" Keychain key is missing. Open Cursor to recreate it, then refresh."
        case .keychainDenied: return "Cursor encrypts its saved login, and Keychain access to its \"Cursor Safe Storage\" key was not allowed. Choose Allow Keychain Access in PlanMeter to ask again."
        case .keychainUnavailable: return "Cursor encrypts its saved login, and planmeter-mcp doesn't show the Keychain prompt needed to read its key."
        case .keychainNeedsApproval: return "Cursor encrypts its saved login. Choose Allow Keychain Access to let PlanMeter read its key from the Keychain."
        case .unreadable: return "Could not read the saved Cursor login."
        case .expired: return "The saved Cursor login has expired. Open Cursor (or run `cursor-agent login`) to renew it, then refresh."
        case .signedOut: return "cursor.com rejected the saved login. Sign in to Cursor again, then refresh."
        case .http: return "Could not reach cursor.com. Refresh to retry."
        case .invalid: return "cursor.com returned an unexpected reply; the dashboard routes may have changed."
        }
    }
}

/// Who a saved login belongs to, read without decrypting anything.
struct CursorIdentity: Sendable, Equatable {
    var userId: String
    var email: String?
    var membership: String?
}

enum CursorCredentials {
    static let editorKeys = ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType",
                             "cursorAuth/stripeMembershipAuthId"]

    static func read(_ source: CursorCredentialSource, now: Date = Date()) throws -> CursorCredential {
        var token: String?
        var email: String?
        var membership: String?
        switch source.kind {
        case .editor:
            let values = try editorValues(path: source.path)
            token = values["cursorAuth/accessToken"]
            email = values["cursorAuth/cachedEmail"]
            membership = values["cursorAuth/stripeMembershipType"]
            if let saved = token, CursorSafeStorage.isEncrypted(saved) {
                token = try CursorSafeStorage.decrypt(saved)
            }
        case .cli:
            guard let data = FileManager.default.contents(atPath: source.path) else { throw CursorError.missing }
            guard let root = JSON.object(data) else { throw CursorError.unreadable }
            token = JSON.string(root["accessToken"]) ?? JSON.string(root["access_token"])
            let config = URL(fileURLWithPath: source.path).deletingLastPathComponent().appendingPathComponent("cli-config.json")
            if let data = FileManager.default.contents(atPath: config.path), let root = JSON.object(data),
               let auth = JSON.object(root["authInfo"]) {
                email = JSON.string(auth["email"])
            }
        }
        guard let raw = token?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { throw CursorError.missing }
        if CursorSafeStorage.isEncrypted(raw) { throw CursorError.encrypted }
        return try credential(token: raw, email: email, membership: membership, now: now)
    }

    /// The login's owner, for discovery. An encrypted editor login is named by
    /// `cursorAuth/stripeMembershipAuthId`, the same `<provider>|<user id>` as
    /// the token's `sub`, so finding accounts never needs the Keychain.
    static func identity(_ source: CursorCredentialSource) throws -> CursorIdentity {
        if source.kind == .editor {
            let values = try editorValues(path: source.path)
            guard let token = values["cursorAuth/accessToken"], !token.isEmpty else { throw CursorError.missing }
            // Without that row, fall through and decrypt the token instead.
            if CursorSafeStorage.isEncrypted(token), let subject = values["cursorAuth/stripeMembershipAuthId"],
               let userId = userId(subject: subject) {
                return CursorIdentity(userId: userId, email: values["cursorAuth/cachedEmail"],
                                      membership: values["cursorAuth/stripeMembershipType"])
            }
        }
        // Identity only: expiry is checked again on every request, and an
        // expired login still names its account.
        let credential = try read(source, now: .distantPast)
        return CursorIdentity(userId: credential.userId, email: credential.email, membership: credential.membership)
    }

    /// `sub` is `<identity provider>|<user id>`; the dashboard wants the user id.
    static func userId(subject: String) -> String? {
        let userId = subject.split(separator: "|").last.map(String.init) ?? subject
        guard !userId.isEmpty, userId.utf8.count <= 200,
              userId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return userId
    }

    static func credential(token: String, email: String?, membership: String?, now: Date = Date()) throws -> CursorCredential {
        guard token.utf8.count <= 8_192, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
              let claims = JWT.payload(token), let subject = JSON.string(claims["sub"]),
              let userId = userId(subject: subject) else { throw CursorError.unreadable }
        let expiresAt = JSON.double(claims["exp"]).map { Date(timeIntervalSince1970: $0) }
        if let expiresAt, expiresAt.timeIntervalSince(now) < 60 { throw CursorError.expired }
        return CursorCredential(token: token, userId: userId, expiresAt: expiresAt, email: email, membership: membership)
    }

    /// Reads a few `ItemTable` rows from the editor's VS Code-style database,
    /// read-only. The editor writes it constantly, so a busy database is retried briefly.
    static func editorValues(path: String) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { throw CursorError.missing }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CursorError.unreadable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let placeholders = editorKeys.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw CursorError.unreadable }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, key) in editorKeys.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), key, -1, transient)
        }
        var values: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: keyText)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard count > 0, count <= 65_536, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: bytes, count: count)
            if let text = decodeText(data) { values[key] = text }
        }
        return values
    }

    /// Values are usually UTF-8; some builds store BOM-less UTF-16LE.
    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes.count % 2 == 0, stride(from: 1, to: bytes.count, by: 2).allSatisfy({ bytes[$0] == 0 }) {
            return String(data: data, encoding: .utf16LittleEndian)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Some keys are JSON-encoded strings.
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\""),
           let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? String {
            text = decoded
        }
        return text.isEmpty ? nil : text
    }
}

// MARK: - Discovery

public enum CursorDiscovery {
    public struct Result: Sendable {
        public var accounts: [Account] = []
        public var targets: [CursorUsageTarget] = []
        public var planLimitTargets: [PlanLimitTarget] = []
        public var notes: [String] = []
        /// Why the first saved login that exists could not be used, for when no
        /// account was found.
        public var failureReason: String?
    }

    /// The editor's database and the CLI's `auth.json` in their standard places.
    static func defaultSources(environment: [String: String], home: String, includeEnvironmentConfigDir: Bool) -> [CursorCredentialSource] {
        var sources: [CursorCredentialSource] = []
        #if os(macOS)
        sources.append(CursorCredentialSource(kind: .editor, path: "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
        if includeEnvironmentConfigDir, let dir = environment["CURSOR_CONFIG_DIR"].flatMap(nonEmptyPath) {
            sources.append(CursorCredentialSource(kind: .cli, path: "\(dir)/auth.json"))
        }
        sources.append(CursorCredentialSource(kind: .cli, path: "\(home)/.cursor/auth.json"))
        #else
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.config"
        sources.append(CursorCredentialSource(kind: .editor, path: "\(config)/Cursor/User/globalStorage/state.vscdb"))
        if includeEnvironmentConfigDir, let dir = environment["CURSOR_CONFIG_DIR"].flatMap(nonEmptyPath) {
            sources.append(CursorCredentialSource(kind: .cli, path: "\(dir)/auth.json"))
        }
        sources.append(CursorCredentialSource(kind: .cli, path: "\(config)/cursor/auth.json"))
        #endif
        return sources
    }

    /// A custom home can be an editor `--user-data-dir`, a CLI config folder, or
    /// an `XDG_CONFIG_HOME` holding either.
    static func homeSources(_ root: String) -> [CursorCredentialSource] {
        [
            CursorCredentialSource(kind: .editor, path: "\(root)/User/globalStorage/state.vscdb"),
            CursorCredentialSource(kind: .editor, path: "\(root)/Cursor/User/globalStorage/state.vscdb"),
            CursorCredentialSource(kind: .editor, path: "\(root)/state.vscdb"),
            CursorCredentialSource(kind: .cli, path: "\(root)/auth.json"),
            CursorCredentialSource(kind: .cli, path: "\(root)/cursor/auth.json"),
        ]
    }

    public static func discover(instances: [T3ProviderInstance], usesT3Configuration: Bool,
                                environment: [String: String], home: String, now: Date = Date()) -> Result {
        var result = Result()
        let cursorInstances = instances.filter { $0.driver == "cursor" && $0.enabled }
        var candidates: [(instance: T3ProviderInstance, sources: [CursorCredentialSource])] = []
        if usesT3Configuration {
            for instance in cursorInstances {
                let sources = instance.homePath.flatMap(nonEmptyPath).map(homeSources)
                    ?? defaultSources(environment: environment, home: home, includeEnvironmentConfigDir: false)
                candidates.append((instance, sources))
            }
        } else {
            candidates.append((T3ProviderInstance(id: "cursor", driver: "cursor"),
                               defaultSources(environment: environment, home: home, includeEnvironmentConfigDir: true)))
        }
        // PlanMeter's own list of extra logins (for example a second editor
        // started with `--user-data-dir`), honored with or without T3 Code.
        let extra = (environment["PLANMETER_CURSOR_HOMES"] ?? "").split(separator: ",").compactMap { nonEmptyPath(String($0)) }
        if !extra.isEmpty, usesT3Configuration ? !cursorInstances.isEmpty : true {
            for root in extra {
                candidates.append((T3ProviderInstance(id: "cursor:\(root)", driver: "cursor"), homeSources(root)))
            }
        }

        struct Login { var userId: String; var instance: T3ProviderInstance; var sources: [CursorCredentialSource]; var email: String?; var membership: String? }
        var logins: [Login] = []
        var seenPaths: Set<String> = []
        for candidate in candidates {
            for source in candidate.sources {
                let path = URL(fileURLWithPath: source.path).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: path), seenPaths.insert(path).inserted else { continue }
                let normalized = CursorCredentialSource(kind: source.kind, path: path)
                do {
                    let credential = try CursorCredentials.identity(normalized)
                    if let index = logins.firstIndex(where: { $0.userId == credential.userId }) {
                        logins[index].sources.append(normalized)
                        if logins[index].email == nil { logins[index].email = credential.email }
                        if logins[index].membership == nil { logins[index].membership = credential.membership }
                    } else {
                        logins.append(Login(userId: credential.userId, instance: candidate.instance, sources: [normalized],
                                            email: credential.email, membership: credential.membership))
                    }
                } catch {
                    let error = (error as? CursorError) ?? .unreadable
                    guard error != .missing else { continue }
                    result.notes.append("Cursor login at \(path): \(error.message)")
                    if result.failureReason == nil { result.failureReason = error.message }
                }
            }
        }

        let perInstance = Dictionary(grouping: logins, by: { $0.instance.id }).mapValues(\.count)
        for login in logins {
            let hash = String(AntigravityIdentity.sha256Hex("cursor:\(login.userId)").prefix(16))
            let accountId = Account.cursorId(user: hash)
            var name = login.instance.displayName ?? "Cursor"
            if (perInstance[login.instance.id] ?? 0) > 1 || logins.filter({ ($0.instance.displayName ?? "Cursor") == name }).count > 1 {
                name += " (\(login.email ?? login.sources[0].kind.rawValue))"
            }
            let plan = login.membership.map(CursorPlanLimits.planLabel)
            result.accounts.append(Account(
                id: accountId,
                provider: .cursor,
                displayName: name,
                email: login.email,
                planLabel: plan,
                accentColorHex: login.instance.accentColorHex,
                suggestedGroup: GroupHeuristics.suggest(displayName: name, email: login.email, plan: login.membership),
                sourceDescription: "cursor.com usage for the login saved in " + login.sources.map(\.path).joined(separator: "; ")
            ))
            result.targets.append(CursorUsageTarget(id: hash, accountId: accountId, name: name, email: login.email,
                                                    membership: login.membership, sources: login.sources))
            result.planLimitTargets.append(PlanLimitTarget(accountId: accountId, provider: .cursor,
                                                           tokenPath: login.sources[0].path, email: login.email,
                                                           authMethod: login.sources[0].kind.rawValue))
        }
        if logins.count > 1 {
            result.notes.append("Found \(logins.count) Cursor logins; each is shown as its own account.")
        }
        return result
    }

    static func nonEmptyPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : PathUtil.expand(trimmed)
    }
}

// MARK: - Dashboard API

enum CursorAPI {
    static let origin = "https://cursor.com"

    static func request(path: String, body: [String: Any]?, credential: CursorCredential) throws -> URLRequest {
        guard let url = URL(string: origin + path) else { throw CursorError.invalid }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WorkosCursorSessionToken=\(credential.userId)%3A%3A\(credential.token)", forHTTPHeaderField: "Cookie")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The dashboard's CSRF check wants its own origin on POSTs.
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/dashboard", forHTTPHeaderField: "Referer")
        }
        return request
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.portableDataWithoutRedirects(for: request)
        } catch {
            throw CursorError.http
        }
        guard let http = response as? HTTPURLResponse else { throw CursorError.http }
        if http.statusCode == 401 || http.statusCode == 403 { throw CursorError.signedOut }
        guard http.statusCode == 200 else { throw CursorError.http }
        guard data.count <= 32_000_000, let json = JSON.object(data) else { throw CursorError.invalid }
        return json
    }

    /// Numbers arrive as JSON numbers or numeric strings depending on the field.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !JSON.isBoolean(number), number.doubleValue.isFinite { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite { return parsed }
        return nil
    }

    static func count(_ value: Any?) -> Int {
        guard let value = number(value), value > 0, value < 1e15 else { return 0 }
        return Int(value)
    }
}

// MARK: - Usage events

/// One metered request from Cursor's usage log.
public struct CursorUsageEvent: Codable, Hashable, Sendable {
    public var timestampMs: Int64
    public var model: String
    public var kind: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    /// `tokenUsage.totalCents`: the model's API-rate cost before Cursor's fee.
    public var costCents: Double?
    /// What Cursor charged against the plan or on-demand budget, including its fee.
    public var chargedCents: Double?
    /// `usageEventId`, when the log provides one.
    public var eventId: String?
    /// The chat the request belonged to, used as its session.
    public var conversationId: String?

    public init(timestampMs: Int64, model: String, kind: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0, costCents: Double? = nil, chargedCents: Double? = nil,
                eventId: String? = nil, conversationId: String? = nil) {
        self.timestampMs = timestampMs
        self.model = model
        self.kind = kind
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.costCents = costCents
        self.chargedCents = chargedCents
        self.eventId = eventId
        self.conversationId = conversationId
    }

    /// De-duplicates overlapping pages: the event ID, or the content without one.
    public var key: String {
        if let eventId { return "id:\(eventId)" }
        return [String(timestampMs), model, kind ?? "", String(inputTokens), String(outputTokens), String(cacheWriteTokens),
         String(cacheReadTokens), costCents.map { String($0) } ?? "-"].joined(separator: "|")
    }

    public var totals: TokenTotals {
        TokenTotals(uncachedInput: inputTokens, cachedInput: cacheReadTokens, cacheCreation: cacheWriteTokens, output: outputTokens)
    }

    /// API-rate dollars, matching the token-price estimates of other providers.
    /// Falls back to the charged amount when the log omits the token cost.
    public var costUsd: Double? {
        guard let cents = costCents ?? chargedCents, cents.isFinite, cents >= 0 else { return nil }
        return cents / 100
    }

    static func decode(_ entry: [String: Any]) -> CursorUsageEvent? {
        guard let timestamp = CursorAPI.number(entry["timestamp"]), timestamp > 0, timestamp < 1e14 else { return nil }
        let model = JSON.string(entry["model"]).map { String($0.prefix(200)) } ?? "Cursor model unavailable"
        let usage = JSON.object(entry["tokenUsage"]) ?? [:]
        let event = CursorUsageEvent(
            timestampMs: Int64(timestamp),
            model: model,
            kind: JSON.string(entry["kind"]),
            inputTokens: CursorAPI.count(usage["inputTokens"]),
            outputTokens: CursorAPI.count(usage["outputTokens"]),
            cacheWriteTokens: CursorAPI.count(usage["cacheWriteTokens"]),
            cacheReadTokens: CursorAPI.count(usage["cacheReadTokens"]),
            costCents: CursorAPI.number(usage["totalCents"]).flatMap { $0 >= 0 ? $0 : nil },
            chargedCents: CursorAPI.number(entry["chargedCents"]).flatMap { $0 >= 0 ? $0 : nil },
            eventId: JSON.string(entry["usageEventId"]).flatMap { $0.utf8.count <= 200 ? $0 : nil },
            conversationId: JSON.string(entry["conversationId"]).flatMap { $0.utf8.count <= 200 ? $0 : nil }
        )
        // Request-counted events without tokens or cost carry nothing to chart.
        guard !event.totals.isEmpty || (event.costUsd ?? 0) > 0 else { return nil }
        return event
    }
}

public struct CursorUsageSnapshot: Codable, Sendable, Identifiable {
    public var target: CursorUsageTarget
    public var events: [CursorUsageEvent] = []
    /// Events are complete from this time on; earlier ones may be missing.
    public var completeFromMs: Int64?
    public var fetchedAt: Date?
    public var status: SourceStatus = .missing
    public var message: String?
    public var id: String { target.id }

    public init(target: CursorUsageTarget) {
        self.target = target
    }
}

struct CursorEventPage: Sendable {
    var events: [CursorUsageEvent]
    var rows: Int
    var total: Int?
}

/// Reads each login's usage log at most once per five minutes, keeping what it
/// has fetched on disk so later refreshes only ask for recent events.
public actor CursorUsage {
    public static let shared = CursorUsage()
    static let pageSize = 500
    static let maxPages = 60
    /// Re-read this much recent history on each refresh: events can be logged
    /// after the request that caused them.
    static let overlapMs: Int64 = 6 * 3_600_000
    static let retentionMs: Int64 = 95 * 86_400_000

    typealias PageFetcher = @Sendable (CursorCredential, _ startMs: Int64, _ endMs: Int64, _ page: Int) async throws -> CursorEventPage

    private let cacheURL: URL?
    private let fetchPage: PageFetcher
    private let credentials: @Sendable (CursorCredentialSource) throws -> CursorCredential
    private var cached: [String: CursorUsageSnapshot] = [:]
    private var attempted: [String: Date] = [:]
    private var loaded = false

    init(cacheURL: URL? = PlanMeterPaths.stateDirectory().appendingPathComponent("cursor-usage.json"),
         credentials: @escaping @Sendable (CursorCredentialSource) throws -> CursorCredential = { try CursorCredentials.read($0) },
         fetchPage: @escaping PageFetcher = { try await CursorUsage.livePage(credential: $0, startMs: $1, endMs: $2, page: $3) }) {
        self.cacheURL = cacheURL
        self.credentials = credentials
        self.fetchPage = fetchPage
    }

    public func load(targets: [CursorUsageTarget], sinceMs: Int64, force: Bool = false, now: Date = Date()) async -> [CursorUsageSnapshot] {
        loadCache()
        var result: [CursorUsageSnapshot] = []
        var changed = false
        for target in targets {
            if !force, let date = attempted[target.id], now.timeIntervalSince(date) < 300, var snapshot = cached[target.id] {
                snapshot.target = target
                result.append(snapshot)
                continue
            }
            attempted[target.id] = now
            let snapshot = await refresh(target: target, sinceMs: sinceMs, now: now)
            cached[target.id] = snapshot
            changed = true
            result.append(snapshot)
        }
        if changed { saveCache() }
        return result
    }

    private func refresh(target: CursorUsageTarget, sinceMs: Int64, now: Date) async -> CursorUsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var previous = cached[target.id]
        previous?.target = target
        previous?.events.removeAll { $0.timestampMs < nowMs - Self.retentionMs }
        do {
            let credential = try credential(for: target)
            // Ask again from just before the newest known event when the cache
            // already covers the window; otherwise read the whole window.
            var startMs = sinceMs
            if let previous, previous.fetchedAt != nil, let complete = previous.completeFromMs, complete <= sinceMs {
                let fetched = Int64((previous.fetchedAt ?? now).timeIntervalSince1970 * 1000)
                startMs = max(sinceMs, min(fetched, nowMs) - Self.overlapMs)
            }
            let endMs = nowMs + 60_000
            var fresh: [String: CursorUsageEvent] = [:]
            var truncated = true
            for page in 1...Self.maxPages {
                let reply = try await fetchPage(credential, startMs, endMs, page)
                for event in reply.events where event.timestampMs >= startMs { fresh[event.key] = event }
                if reply.rows < Self.pageSize || (reply.total.map { page * Self.pageSize >= $0 } ?? false) {
                    truncated = false
                    break
                }
            }
            var snapshot = CursorUsageSnapshot(target: target)
            let kept = (previous?.events ?? []).filter { $0.timestampMs < startMs }
            snapshot.events = (kept + fresh.values).sorted { $0.timestampMs < $1.timestampMs }
            snapshot.fetchedAt = now
            if truncated {
                // Page order is not documented, so nothing older than the
                // window is assumed complete.
                snapshot.completeFromMs = nil
                snapshot.status = .partial
                snapshot.message = "Cursor usage is incomplete: more than \(Self.maxPages * Self.pageSize) events in the requested window."
            } else {
                snapshot.completeFromMs = startMs == sinceMs ? sinceMs : min(previous?.completeFromMs ?? sinceMs, sinceMs)
                snapshot.status = .ok
            }
            return snapshot
        } catch {
            let reason = (error as? CursorError)?.message ?? CursorError.http.message
            // A process that may not read the Keychain shows the app's newest
            // reading, which the app keeps writing to the shared cache.
            if (error as? CursorError) == .keychainUnavailable, var shared = readCache()[target.id],
               let fetched = shared.fetchedAt, fetched > (previous?.fetchedAt ?? .distantPast) {
                shared.target = target
                previous = shared
            }
            if var stale = previous, stale.fetchedAt != nil {
                stale.status = .partial
                stale.message = ((error as? CursorError) == .keychainUnavailable
                    ? "Showing the PlanMeter app's last Cursor reading. " : "Stale reading. ") + reason
                return stale
            }
            var snapshot = CursorUsageSnapshot(target: target)
            snapshot.status = .failed
            snapshot.message = reason
            return snapshot
        }
    }

    private func credential(for target: CursorUsageTarget) throws -> CursorCredential {
        var firstError: CursorError?
        for source in target.sources {
            do {
                let credential = try credentials(source)
                // A copy now signed in as someone else must not be reported
                // as this account.
                let hash = String(AntigravityIdentity.sha256Hex("cursor:\(credential.userId)").prefix(16))
                guard hash == target.id else { continue }
                return credential
            } catch {
                if firstError == nil { firstError = (error as? CursorError) ?? .unreadable }
            }
        }
        throw firstError ?? CursorError.signedOut
    }

    static func livePage(credential: CursorCredential, startMs: Int64, endMs: Int64, page: Int) async throws -> CursorEventPage {
        let request = try CursorAPI.request(path: "/api/dashboard/get-filtered-usage-events", body: [
            "startDate": String(startMs), "endDate": String(endMs), "page": page, "pageSize": pageSize,
        ], credential: credential)
        return try parsePage(await CursorAPI.send(request, session: .shared))
    }

    static func parsePage(_ json: [String: Any]) throws -> CursorEventPage {
        let rows: [[String: Any]]
        if let list = json["usageEventsDisplay"] as? [[String: Any]] {
            rows = list
        } else if json["usageEventsDisplay"] == nil, JSON.object(json["error"]) == nil, json["error"] == nil {
            rows = []
        } else {
            throw CursorError.invalid
        }
        let total = CursorAPI.number(json["totalUsageEventsCount"]).map { Int(max(0, min($0, 1e9))) }
        return CursorEventPage(events: rows.compactMap(CursorUsageEvent.decode), rows: rows.count, total: total)
    }

    // MARK: Disk cache (usage only; never credentials)

    private struct CacheDocument: Codable {
        var version: Int
        var snapshots: [CursorUsageSnapshot]
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        cached.merge(readCache()) { current, _ in current }
    }

    private func readCache() -> [String: CursorUsageSnapshot] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let doc = try? JSONDecoder().decode(CacheDocument.self, from: data), doc.version == 1 else { return [:] }
        return Dictionary(doc.snapshots.map { ($0.target.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let doc = CacheDocument(version: 1, snapshots: cached.values.filter { $0.fetchedAt != nil }.sorted { $0.target.id < $1.target.id })
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

// MARK: - Projection

public enum CursorUsageProjection {
    /// Cursor events become ordinary usage cells for their login's account.
    public static func merging(_ snapshots: [CursorUsageSnapshot], into local: ScanOutput) -> ScanOutput {
        var result = local
        for snapshot in snapshots {
            var folded = 0
            for event in snapshot.events {
                let key = CellKey(startMs: CellKey.minuteStart(forMs: event.timestampMs), accountId: snapshot.target.accountId, model: event.model)
                let session = event.conversationId ?? ""
                let record = UsageRecord(provider: .cursor, timestampMs: event.timestampMs, model: event.model, sessionId: session,
                                         totals: event.totals, reportedCostUsd: event.costUsd, dedupeKey: event.key)
                var cell = result.cells[key] ?? Cell()
                cell.add(record)
                result.cells[key] = cell
                if !session.isEmpty {
                    var threadCell = Cell()
                    threadCell.add(record)
                    result.threads.append(ThreadCellEntry(sessionId: session, key: key, cell: threadCell,
                                                          sourcePath: "cursor://conversations/\(session)"))
                }
                folded += 1
            }
            result.sources.append(SourceReport(provider: .cursor, path: "cursor.com usage · \(snapshot.target.name)",
                status: snapshot.status, scannedFiles: folded, reusedFiles: 0, skippedFiles: 0, message: snapshot.message))
        }
        return result
    }
}

// MARK: - Plan limits

/// Reads the billing cycle's included usage and on-demand spend from
/// `usage-summary`, the same reading as Cursor's dashboard.
public enum CursorPlanLimits {
    static func read(target: PlanLimitTarget, session: URLSession = .shared, now: Date = Date()) async -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot(target: target)
        guard let path = target.tokenPath else {
            snapshot.message = CursorError.missing.message
            return snapshot
        }
        let source = CursorCredentialSource(kind: CursorCredentialKind(rawValue: target.authMethod ?? "") ?? .editor, path: path)
        do {
            let credential = try CursorCredentials.read(source, now: now)
            let request = try CursorAPI.request(path: "/api/usage-summary", body: nil, credential: credential)
            snapshot = try decode(await CursorAPI.send(request, session: session), target: target, now: now)
        } catch {
            snapshot = PlanLimitSnapshot(target: target)
            snapshot.status = .failed
            snapshot.message = ((error as? CursorError) ?? .http).message
        }
        return snapshot
    }

    static func decode(_ json: [String: Any], target: PlanLimitTarget, now: Date = Date()) throws -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot(target: target)
        snapshot.plan = JSON.string(json["membershipType"]).map(planLabel)
        let start = PlanLimits.date(json["billingCycleStart"])
        let end = PlanLimits.date(json["billingCycleEnd"])
        let minutes = start.flatMap { start in end.map { Int(($0.timeIntervalSince(start) / 60).rounded()) } }.flatMap { $0 > 0 ? $0 : nil }
        let individual = JSON.object(json["individualUsage"])
        guard individual != nil || json["membershipType"] != nil || json["billingCycleEnd"] != nil else { throw CursorError.invalid }
        var notes: [String] = []

        if let plan = JSON.object(individual?["plan"]), JSON.bool(plan["enabled"]) != false {
            let used = CursorAPI.number(plan["used"])
            let limit = CursorAPI.number(plan["limit"])
            let total = CursorAPI.number(plan["totalPercentUsed"]) ?? used.flatMap { used in limit.flatMap { $0 > 0 ? used / $0 * 100 : nil } }
            if let total {
                snapshot.windows.append(PlanLimitWindow(id: "plan", label: "Monthly · Included", usedPercent: clamp(total), windowMinutes: minutes, resetsAt: end))
            }
            if let auto = CursorAPI.number(plan["autoPercentUsed"]) {
                snapshot.windows.append(PlanLimitWindow(id: "plan-auto", label: "Monthly · Auto + Composer", usedPercent: clamp(auto), windowMinutes: minutes, resetsAt: end))
            }
            if let api = CursorAPI.number(plan["apiPercentUsed"]) {
                snapshot.windows.append(PlanLimitWindow(id: "plan-api", label: "Monthly · API models", usedPercent: clamp(api), windowMinutes: minutes, resetsAt: end))
            }
        }
        for (id, label, owner) in [("on-demand", "On-demand", individual), ("team-on-demand", "Team on-demand", JSON.object(json["teamUsage"]))] {
            guard let onDemand = JSON.object(owner?["onDemand"]), JSON.bool(onDemand["enabled"]) == true else { continue }
            let used = CursorAPI.number(onDemand["used"]) ?? 0
            if let limit = CursorAPI.number(onDemand["limit"]), limit > 0 {
                snapshot.windows.append(PlanLimitWindow(id: id, label: label, usedPercent: clamp(used / limit * 100), windowMinutes: minutes, resetsAt: end))
            } else if used > 0 {
                notes.append("\(label): \(String(format: "$%.2f", used / 100)) this cycle, no limit set.")
            }
        }
        if JSON.bool(json["isUnlimited"]) == true { notes.insert("Unlimited plan.", at: 0) }
        if snapshot.windows.isEmpty && notes.isEmpty { notes.append("No usage windows reported.") }
        snapshot.message = notes.isEmpty ? nil : notes.joined(separator: " ")
        snapshot.status = .ok
        snapshot.fetchedAt = now
        return snapshot
    }

    public static func planLabel(_ membership: String) -> String {
        switch membership.lowercased() {
        case "free": return "Free"
        case "free_trial": return "Pro trial"
        case "pro": return "Pro"
        case "pro_plus", "pro-plus": return "Pro+"
        case "ultra": return "Ultra"
        case "business", "team", "teams": return "Teams"
        case "enterprise": return "Enterprise"
        default: return membership.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func clamp(_ percent: Double) -> Double { max(0, min(100, percent)) }
}
