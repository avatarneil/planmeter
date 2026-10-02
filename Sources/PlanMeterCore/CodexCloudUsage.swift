import Foundation

/// A provider turn, dated by its completion (or start while it is running).
/// The provider does not expose the individual response timestamps here.
public struct CodexCloudTurnUsage: Codable, Sendable, Identifiable {
    public var reference: CodexThreadReference
    public var turnId: String
    public var startedAt: Date
    /// False when the only supplied date is completion; startedAt then holds
    /// that same known date so an undated start cannot invent an earlier hour.
    public var startedAtIsKnown: Bool = true
    public var completedAt: Date?
    public var model: String?
    public var totals: TokenTotals?
    public var serviceCostUsd: Double?
    public var credits: Double?
    public var responseIds: [String]
    public var id: String { "\(reference.id):\(turnId)" }

    public init(reference: CodexThreadReference, turnId: String, startedAt: Date, completedAt: Date? = nil,
                model: String? = nil, totals: TokenTotals? = nil, serviceCostUsd: Double? = nil,
                credits: Double? = nil, responseIds: [String] = []) {
        self.reference = reference; self.turnId = turnId; self.startedAt = startedAt; self.completedAt = completedAt
        self.model = model; self.totals = totals; self.serviceCostUsd = serviceCostUsd; self.credits = credits
        self.responseIds = responseIds
    }
}

public struct CodexCloudUsageSnapshot: Codable, Sendable, Identifiable {
    public var target: CodexUsageTarget
    public var turns: [CodexCloudTurnUsage] = []
    public var fetchedAt: Date?
    public var status: SourceStatus = .missing
    public var message: String?
    public var threadsAttempted: Int = 0
    public var threadsUnavailable: Int = 0
    public var quotas: [CodexCloudThreadQuota] = []
    public var id: String { target.id }
    public init(target: CodexUsageTarget) { self.target = target }
}

/// Purchased credits and quota percentages are separate from token usage and
/// estimated dollar cost. Percentages apply to the provider's limit windows.
public struct CodexCloudThreadQuota: Codable, Sendable {
    public var threadId: String
    public var weeklyLimitPercent: Double?
    public var fiveHourLimitPercent: Double?
    public var balanceUsageCredits: String?
    public var dataStatus: String?
    public var usageSource: String?
}

/// Uses the same normal ChatGPT login and cloud history transport as the Mac
/// app. It never starts, resumes, or subscribes to an agent thread.
public actor CodexCloudUsage {
    public static let shared = CodexCloudUsage()
    typealias Reader = @Sendable (CodexUsageTarget) async -> CodexCloudUsageSnapshot
    private let reader: Reader
    private var cached: [String: CodexCloudUsageSnapshot] = [:]
    private var attempted: [String: Date] = [:]
    private struct Flight { var generation: UUID; var task: Task<CodexCloudUsageSnapshot, Never> }
    private var inFlight: [String: Flight] = [:]

    init(reader: @escaping Reader = { await CodexCloudUsage.read(target: $0) }) { self.reader = reader }

    public func load(targets: [CodexUsageTarget], force: Bool = false) async -> [CodexCloudUsageSnapshot] {
        var result: [CodexCloudUsageSnapshot] = []
        for target in targets {
            let key = "\(target.id):\(target.home):\(target.plan)"
            if !force, let date = attempted[key], Date().timeIntervalSince(date) < 300, var value = cached[key] {
                value.target = target; result.append(value); continue
            }
            attempted[key] = Date()
            let reader = self.reader
            let flight = inFlight[key] ?? Flight(generation: UUID(), task: Task { await reader(target) })
            inFlight[key] = flight
            var fresh = await flight.task.value
            guard inFlight[key]?.generation == flight.generation else {
                var value = cached[key] ?? fresh; value.target = target; result.append(value); continue
            }
            inFlight[key] = nil
            if fresh.status != .missing, let previous = cached[key], previous.fetchedAt != nil {
                if fresh.fetchedAt == nil {
                    fresh = previous; fresh.target = target; fresh.status = .partial
                    fresh.message = "Stale cloud usage. Refresh failed."
                } else if fresh.status == .partial {
                    // A bounded page or transient settlement gap must not erase
                    // previously verified turns from this same service login.
                    var turns = Dictionary(uniqueKeysWithValues: previous.turns.map { ($0.id, $0) })
                    for turn in fresh.turns {
                        if let old = turns[turn.id], (turn.totals == nil && old.totals != nil)
                            || (turn.serviceCostUsd == nil && old.serviceCostUsd != nil) { continue }
                        turns[turn.id] = turn
                    }
                    let since = Date().addingTimeInterval(-90 * 86_400)
                    fresh.turns = turns.values.filter { ($0.completedAt ?? $0.startedAt) >= since }.sorted { $0.startedAt < $1.startedAt }
                    if fresh.quotas.isEmpty { fresh.quotas = previous.quotas }
                }
            }
            cached[key] = fresh
            result.append(fresh)
        }
        return result
    }

    static func read(target: CodexUsageTarget, now: Date = Date(), timeout: TimeInterval = 25) async -> CodexCloudUsageSnapshot {
        var snapshot = CodexCloudUsageSnapshot(target: target)
        do {
            let credential = try validatedCredential(target)
            let rpc = CloudUsageRPC(credential: credential, accountId: target.serviceAccountId, timeout: min(25, max(1, timeout)))
            defer { rpc.close() }
            _ = try await rpc.request("initialize", params: [
                "clientInfo": ["name": "planmeter", "version": "0.3.3"], "capabilities": ["experimentalApi": true],
            ])
            try await rpc.notify("initialized", params: [:])
            var references = Dictionary(uniqueKeysWithValues: CodexThreadUsage.references(target: target, limit: 100)
                .filter { $0.origin == "cloud" }.map { ($0.id, $0) })
            var truncated = false
            // Cloud Aeon rows can have a null source. The backend's explicit
            // source-kind filter legitimately omits those rows even though the
            // ordinary default inventory returns them. Always union both.
            do {
                let page = try await rpc.request("thread/list", params: ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc"])
                for var reference in try decodeReferences(page) {
                    reference = mergeReference(reference, cached: references[reference.id])
                    references[reference.id] = reference
                }
                if try nextCursor(page) != nil { truncated = true }
            } catch { truncated = true }
            // Supplement with hidden subagent kinds. The sidebar cache alone
            // is partial, and Personal may have no cached cloud entries.
            var cursor: String?
            for _ in 0..<2 {
                var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc",
                    "sourceKinds": ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]]
                if let cursor { params["cursor"] = cursor }
                do {
                    let page = try await rpc.request("thread/list", params: params)
                    for var reference in try decodeReferences(page) {
                        reference = mergeReference(reference, cached: references[reference.id])
                        references[reference.id] = reference
                    }
                    let next = try nextCursor(page)
                    if next == nil { cursor = nil; break }
                    guard next != cursor else { throw CloudUsageError.invalid }
                    cursor = next
                    if references.count >= 100 { truncated = true; break }
                } catch {
                    // Known exact cloud IDs remain usable when inventory is
                    // unavailable or a backend does not support source filters.
                    truncated = true
                    if references.isEmpty {
                        let page = try await rpc.request("thread/list", params: ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc"])
                        for reference in try decodeReferences(page) { references[reference.id] = reference }
                        cursor = try nextCursor(page)
                    }
                    break
                }
            }
            if cursor != nil || references.count > 100 { truncated = true }
            for filtered in [false, true] {
                guard references.count < 100, rpc.remaining > 6 else { truncated = true; break }
                do {
                    var params: [String: Any] = ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "archived": true]
                    if filtered {
                        params["sourceKinds"] = ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"]
                    }
                    let archived = try await rpc.request("thread/list", params: params)
                    for var reference in try decodeReferences(archived) {
                        reference = mergeReference(reference, cached: references[reference.id])
                        references[reference.id] = reference
                    }
                    if try nextCursor(archived) != nil || references.count > 100 { truncated = true }
                } catch { truncated = true }
            }
            let selected = Array(references.values.sorted {
                // Active subagent tasks precede long-lived heartbeat threads.
                if ($0.parentThreadId != nil) != ($1.parentThreadId != nil) { return $0.parentThreadId != nil }
                return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0)
            }.prefix(100))
            let consumer = !["business", "enterprise", "team", "edu"].contains(target.plan)
            var quotaUnavailable = false
            if consumer, !selected.isEmpty, rpc.remaining > 2 {
                let body: [String: Any] = ["threads": selected.map {
                    ["thread_id": $0.id, "created_at": NSNull(), "descendant_thread_ids": []] as [String: Any]
                }]
                if let response = try? await rpc.quotas(body), let quotas = try? decodeQuotas(response, references: selected) {
                    snapshot.quotas = quotas
                } else { quotaUnavailable = true }
            }
            let since = now.addingTimeInterval(-90 * 86_400)
            var turns: [CodexCloudTurnUsage] = []
            var olderPages: [(CodexThreadReference, String)] = []
            // Pipeline independent first pages so one busy long-lived dot does
            // not consume the refresh before other tasks can be inspected.
            for start in stride(from: 0, to: selected.count, by: 8) {
                guard rpc.remaining > 8, turns.count < 3_000 else { truncated = true; break }
                let batch = Array(selected[start..<min(start + 8, selected.count)])
                snapshot.threadsAttempted += batch.count
                do {
                    let pages = try await rpc.requests(batch.map { reference in
                        ("thread/turns/list", ["threadId": reference.id, "limit": 100, "sortDirection": "desc", "itemsView": "notLoaded"] as [String: Any])
                    })
                    for (reference, page) in zip(batch, pages) {
                        guard let page else { snapshot.threadsUnavailable += 1; truncated = true; continue }
                        do {
                            let rows = try decodeTurns(page, reference: reference, now: now)
                            if rows.count != (page["data"] as? [[String: Any]])?.count { truncated = true }
                            let dated = rows.filter { ($0.completedAt ?? $0.startedAt) >= since }
                            let capacity = max(0, 3_000 - turns.count)
                            if dated.count > capacity { truncated = true }
                            turns.append(contentsOf: dated.prefix(capacity))
                            if let next = try nextCursor(page), dated.count == rows.count { olderPages.append((reference, next)) }
                        } catch { snapshot.threadsUnavailable += 1; truncated = true }
                    }
                } catch { snapshot.threadsUnavailable += batch.count; truncated = true; break }
            }
            for (reference, initialCursor) in olderPages {
                guard rpc.remaining > 8, turns.count < 3_000 else { truncated = true; break }
                var cursor: String? = initialCursor
                do {
                    for _ in 0..<2 {
                        var params: [String: Any] = ["threadId": reference.id, "limit": 100, "sortDirection": "desc", "itemsView": "notLoaded"]
                        if let cursor { params["cursor"] = cursor }
                        let page = try await rpc.request("thread/turns/list", params: params)
                        let rows = try decodeTurns(page, reference: reference, now: now)
                        if rows.count != (page["data"] as? [[String: Any]])?.count { truncated = true }
                        let dated = rows.filter { ($0.completedAt ?? $0.startedAt) >= since }
                        let capacity = max(0, 3_000 - turns.count)
                        if dated.count > capacity { truncated = true }
                        turns.append(contentsOf: dated.prefix(capacity))
                        let next = try nextCursor(page)
                        if next == nil || dated.count < rows.count { cursor = nil; break }
                        guard next != cursor else { throw CloudUsageError.invalid }
                        cursor = next
                        if rpc.remaining <= 8 || turns.count >= 3_000 { break }
                    }
                    if cursor != nil { truncated = true }
                } catch { snapshot.threadsUnavailable += 1; truncated = true }
            }
            var unique: [String: CodexCloudTurnUsage] = [:]
            for turn in turns { unique[turn.id] = turn }
            turns = unique.values.sorted { $0.startedAt > $1.startedAt }
            var estimatesUnavailable = false
            // The provider limits each query to 100 turns as well as threads.
            for start in stride(from: 0, to: turns.count, by: 100) {
                guard rpc.remaining > 1 else { truncated = true; estimatesUnavailable = true; break }
                let indices = start..<min(start + 100, turns.count)
                let batch = indices.map { turns[$0] }
                do {
                    let body: [String: Any] = ["threads": Dictionary(grouping: batch, by: { $0.reference.id }).map { id, values in
                        ["thread_id": id, "turn_ids": values.map(\.turnId)] as [String: Any]
                    }, "include_settled_response_ids": true]
                    let response = try await rpc.estimates(body)
                    let decoded = try applyEstimates(response, turns: batch)
                    for (index, value) in zip(indices, decoded) { turns[index] = value }
                } catch CloudUsageError.permission {
                    // Personal can expose cloud history while withholding the
                    // billing ledger. Preserve unknown amounts as unknown.
                    estimatesUnavailable = true; break
                } catch { estimatesUnavailable = true; truncated = true }
            }
            _ = try validatedCredential(target)
            snapshot.turns = turns.sorted { $0.startedAt < $1.startedAt }
            snapshot.fetchedAt = Date()
            let missing = turns.contains { $0.totals == nil || $0.model == nil || $0.serviceCostUsd == nil
                || ($0.responseIds.isEmpty && ($0.totals?.total ?? 0) > 0) }
            snapshot.status = truncated || estimatesUnavailable || missing || quotaUnavailable ? .partial : .ok
            if estimatesUnavailable {
                snapshot.message = "Cloud turn history is available, but this login could not read every turn's model, tokens, and billing estimate."
            } else if truncated {
                snapshot.message = "Cloud usage is partial: the bounded refresh did not read every thread or turn."
            } else if missing {
                snapshot.message = "Some cloud turns have no settled model or token usage yet."
            } else if quotaUnavailable {
                snapshot.message = "Cloud turns are available, but quota usage could not be read for this login."
            } else {
                snapshot.message = "Cloud usage is dated by turn completion, or start while a turn is running."
            }
        } catch CloudUsageError.identity {
            snapshot = CodexCloudUsageSnapshot(target: target)
            snapshot.message = "Codex login changed or differs from the discovered account. Refresh account discovery."
        } catch {
            snapshot = CodexCloudUsageSnapshot(target: target)
            snapshot.status = .failed
            snapshot.message = "Cloud usage could not be read with this Codex login."
        }
        return snapshot
    }

    static func decodeReferences(_ result: [String: Any]) throws -> [CodexThreadReference] {
        guard let rows = result["data"] as? [[String: Any]], rows.count <= 100 else { throw CloudUsageError.invalid }
        var seen: Set<String> = []
        return try rows.map { row in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil, seen.insert(id).inserted else { throw CloudUsageError.invalid }
            let parent = row["parentThreadId"] as? String
            if let parent, UUID(uuidString: parent) == nil { throw CloudUsageError.invalid }
            let updated = try timestamp(row["updatedAt"])
            return CodexThreadReference(id: id, title: boundedString(row["name"]), parentThreadId: parent,
                origin: "cloud", updatedAt: updated?.timeIntervalSince1970, kind: boundedString(row["threadSource"]))
        }
    }

    static func mergeReference(_ fresh: CodexThreadReference, cached: CodexThreadReference?) -> CodexThreadReference {
        guard let cached, cached.id == fresh.id else { return fresh }
        var value = fresh
        value.title = fresh.title ?? cached.title
        // Aeon attachments encode a logical parent even when the native Codex
        // thread has no parent. Retain the exact account-scoped attachment.
        value.parentThreadId = fresh.parentThreadId ?? cached.parentThreadId
        value.kind = fresh.kind ?? cached.kind
        return value
    }

    static func decodeTurns(_ result: [String: Any], reference: CodexThreadReference, now: Date = Date()) throws -> [CodexCloudTurnUsage] {
        guard let rows = result["data"] as? [[String: Any]], rows.count <= 100 else { throw CloudUsageError.invalid }
        var seen: Set<String> = []
        return try rows.compactMap { row in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil, seen.insert(id).inserted else { throw CloudUsageError.invalid }
            let suppliedStart = try timestamp(row["startedAt"])
            let completed = try timestamp(row["completedAt"])
            guard let started = suppliedStart ?? completed else { return nil }
            guard started <= now.addingTimeInterval(300) else { throw CloudUsageError.invalid }
            if let completed, completed < started || completed > now.addingTimeInterval(300) { throw CloudUsageError.invalid }
            var turn = CodexCloudTurnUsage(reference: reference, turnId: id, startedAt: started, completedAt: completed)
            turn.startedAtIsKnown = suppliedStart != nil
            return turn
        }
    }

    /// Exact thread/turn IDs join history to billing; model names or titles
    /// never establish identity. Cached input is part of input, not additional.
    static func applyEstimates(_ result: [String: Any], turns: [CodexCloudTurnUsage]) throws -> [CodexCloudTurnUsage] {
        guard Set(turns.map(\.id)).count == turns.count,
              let threads = result["threads"] as? [[String: Any]], threads.count <= turns.count else { throw CloudUsageError.invalid }
        var expected = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        var seen: Set<String> = []
        var seenThreads: Set<String> = []
        for thread in threads {
            guard let id = thread["thread_id"] as? String, seenThreads.insert(id).inserted,
                  turns.contains(where: { $0.reference.id == id }), let rows = thread["turns"] as? [[String: Any]], rows.count <= turns.count else { throw CloudUsageError.invalid }
            for row in rows {
                guard let turnId = row["turn_id"] as? String, var turn = expected["\(id):\(turnId)"], seen.insert(turn.id).inserted else { throw CloudUsageError.invalid }
                turn.model = boundedString(row["model"])
                let input = try count(row["input_tokens"]), cached = try count(row["cached_input_tokens"])
                let output = try count(row["output_tokens"]), total = try count(row["total_tokens"]), net = try count(row["net_new_input_tokens"])
                if let input, let cached, let output {
                    let sum = input.addingReportingOverflow(output)
                    guard cached <= input, !sum.overflow, total == nil || total == sum.partialValue,
                          net == nil || net == input - cached else { throw CloudUsageError.invalid }
                    turn.totals = TokenTotals(uncachedInput: input - cached, cachedInput: cached, output: output)
                } else if [input, cached, output, total, net].contains(where: { $0 != nil }) { throw CloudUsageError.invalid }
                let usd = try count(row["estimated_usage_usd_micros"]), credits = try count(row["estimated_usage_credits_micros"])
                // Preserve the provider's estimate even when its settlement
                // list is missing. The snapshot remains partial in that case.
                turn.serviceCostUsd = usd.map { Double($0) / 1_000_000 }
                turn.credits = credits.map { Double($0) / 1_000_000 }
                if let raw = row["settled_response_ids"], !(raw is NSNull) {
                    guard let ids = raw as? [String], ids.count <= 10_000, Set(ids).count == ids.count,
                          ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw CloudUsageError.invalid }
                    turn.responseIds = ids
                }
                expected[turn.id] = turn
            }
        }
        return turns.map { expected[$0.id]! }
    }

    static func decodeQuotas(_ result: [String: Any], references: [CodexThreadReference]) throws -> [CodexCloudThreadQuota] {
        guard let rows = result["threads"] as? [[String: Any]], rows.count <= references.count else { throw CloudUsageError.invalid }
        let known = Set(references.map(\.id))
        var seen: Set<String> = []
        return try rows.map { row in
            guard let id = row["thread_id"] as? String, known.contains(id), seen.insert(id).inserted else { throw CloudUsageError.invalid }
            var credits: String?
            if let raw = row["balance_usage_credits"], !(raw is NSNull) {
                guard let text = raw as? String, text.utf8.count <= 100, let number = Double(text), number.isFinite else { throw CloudUsageError.invalid }
                credits = text
            }
            return CodexCloudThreadQuota(threadId: id, weeklyLimitPercent: try quotaNumber(row["weekly_limit_percent"]),
                fiveHourLimitPercent: try quotaNumber(row["five_hour_limit_percent"]), balanceUsageCredits: credits,
                dataStatus: boundedString(row["data_status"]), usageSource: boundedString(row["usage_source"]))
        }
    }
    private static func quotaNumber(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let number: Double?
        if let text = value as? String, text.utf8.count <= 100 { number = Double(text) }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else { throw CloudUsageError.invalid }
        guard let number, number.isFinite, number >= 0 else { throw CloudUsageError.invalid }
        return number
    }
    private static func validatedCredential(_ target: CodexUsageTarget) throws -> String {
        do { return try CodexDailyUsage.credential(target: target) } catch { throw CloudUsageError.identity }
    }

    private static func nextCursor(_ result: [String: Any]) throws -> String? {
        guard let value = result["nextCursor"], !(value is NSNull) else { return nil }
        guard let cursor = value as? String, !cursor.isEmpty, cursor.utf8.count <= 4_096 else { throw CloudUsageError.invalid }
        return cursor
    }
    private static func count(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { throw CloudUsageError.invalid }
        return number.intValue
    }
    private static func timestamp(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 32_503_680_000 else { throw CloudUsageError.invalid }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
    private static func boundedString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256 else { return nil }
        return value
    }
}

private enum CloudUsageError: Error { case invalid, closed, timeout, permission, identity }

private final class CloudUsageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One sequential JSON-RPC connection, with an account-wide deadline. The bearer
/// is only sent to fixed official origins and is never retained in snapshots.
private final class CloudUsageRPC: @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let credential: String
    private let accountId: String
    private let deadline: Date
    private var timer: Task<Void, Never>?
    private var nextId = 0
    var remaining: TimeInterval { deadline.timeIntervalSinceNow }

    init(credential: String, accountId: String, timeout: TimeInterval) {
        self.credential = credential; self.accountId = accountId
        deadline = Date().addingTimeInterval(timeout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(12, timeout)
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: CloudUsageRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: URL(string: "wss://codex-cloud-backend.chatgpt.com/")!)
        request.timeoutInterval = min(12, timeout)
        request.setValue("codex-app-server, codex-client.desktop, openai-bearer." + credential, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4_000_000
        socket.resume()
        let session = session, socket = socket
        timer = Task.detached {
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        }
    }
    func close() {
        timer?.cancel(); timer = nil
        socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
    func notify(_ method: String, params: [String: Any]) async throws {
        guard remaining > 0 else { throw CloudUsageError.timeout }
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        try await socket.send(.data(data))
    }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let result = try await requests([(method, params)]).first ?? nil else { throw CloudUsageError.invalid }
        return result
    }
    func requests(_ requests: [(String, [String: Any])]) async throws -> [[String: Any]?] {
        guard remaining > 0, requests.count <= 8 else { throw CloudUsageError.timeout }
        var pending: [Int: Int] = [:]
        var results = Array<[String: Any]?>(repeating: nil, count: requests.count)
        for (index, request) in requests.enumerated() {
            nextId += 1; let id = nextId; pending[id] = index
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": request.0, "params": request.1])
            try await socket.send(.data(data))
        }
        while !pending.isEmpty, remaining > 0 {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw CloudUsageError.invalid }
                guard data.count <= 4_000_000, let response = JSON.object(data) else { throw CloudUsageError.invalid }
                guard response["method"] == nil, response["result"] != nil || response["error"] != nil,
                      let id = response["id"] as? Int, let index = pending.removeValue(forKey: id) else { continue }
                if response["error"] == nil { results[index] = JSON.object(response["result"]) }
            } catch {
                if results.contains(where: { $0 != nil }) { return results }
                throw error
            }
        }
        return results
    }
    func estimates(_ body: [String: Any]) async throws -> [String: Any] {
        try await fetch(body, path: "thread-estimates/query")
    }
    func quotas(_ body: [String: Any]) async throws -> [String: Any] {
        try await fetch(body, path: "thread_usage/query_v2")
    }
    private func fetch(_ body: [String: Any], path: String) async throws -> [String: Any] {
        guard remaining > 0 else { throw CloudUsageError.timeout }
        guard ["thread-estimates/query", "thread_usage/query_v2"].contains(path) else { throw CloudUsageError.invalid }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = min(12, remaining)
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex_cli_rs/0.160.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudUsageError.invalid }
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudUsageError.permission }
        guard response.statusCode == 200 else { throw CloudUsageError.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_000_000 else { throw CloudUsageError.invalid }
            data.append(byte)
        }
        guard let result = JSON.object(data) else { throw CloudUsageError.invalid }
        return result
    }
}
