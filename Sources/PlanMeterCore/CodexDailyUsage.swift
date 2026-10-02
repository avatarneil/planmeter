import Foundation

public struct DailyCreditValue: Codable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var credits: Double
    public var id: String { key }
}

public struct DailyModelTokens: Codable, Sendable, Identifiable {
    public var model: String
    public var speed: String
    public var credits: Double
    public var uncachedInputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var id: String { "\(model):\(speed)" }
}

public struct CodexDailyUsageDay: Codable, Sendable, Identifiable {
    public var date: String
    public var products: [DailyCreditValue]?
    public var modelCredits: [DailyCreditValue]?
    /// The text-token feed covers Work and Codex; voice/image/Chat credits can
    /// appear only in the credit feed. Never equate these two scopes.
    public var textModels: [DailyModelTokens]?
    public var id: String { date }
    public var credits: Double? { products.map { $0.reduce(0) { $0 + $1.credits } } }
}

public struct CodexDailyUsageSnapshot: Codable, Sendable, Identifiable {
    public var target: CodexUsageTarget
    public var fromDay: String
    public var toDay: String // inclusive, as requested from the provider
    public var days: [CodexDailyUsageDay] = []
    public var fetchedAt: Date?
    public var dataFreshness: String?
    public var estimatedUsdPerCredit: Double?
    public var status: SourceStatus = .missing
    public var message: String?
    public var id: String { target.id }
    public var credits: Double? {
        let readings = days.compactMap(\.credits)
        let total = readings.reduce(0, +)
        return readings.isEmpty || !total.isFinite ? nil : total
    }
    public var estimatedCostUsd: Double? { credits.flatMap { estimatedCost(credits: $0) } }
    public var missingCreditDays: [String] {
        let reported = Set(days.filter { $0.products != nil }.map(\.date))
        return CodexDailyUsage.dateLabels(from: fromDay, to: toDay).filter { !reported.contains($0) }
    }
    public func estimatedCost(credits: Double) -> Double? {
        guard let rate = estimatedUsdPerCredit else { return nil }
        let micros = credits * rate * 1_000_000
        return micros.isFinite && micros >= 0 ? micros.rounded() / 1_000_000 : nil
    }
    public func selected(days count: Int, now: Date = Date()) -> Self {
        let window = Report.window(days: min(90, max(1, count)), calendar: UsageCoverage.utcCalendar, now: now)
        var selected = self
        selected.fromDay = UsageCoverage.dayLabel(window.from)
        selected.toDay = UsageCoverage.dayLabel(window.to.addingTimeInterval(-1))
        selected.days = days.filter { $0.date >= selected.fromDay && $0.date <= selected.toDay }
        return selected
    }
}

/// Read-only analytics using the discovered CLI login. Metrics stay in memory;
/// credentials and service error bodies never enter a report or disk cache.
public actor CodexDailyUsage {
    public static let shared = CodexDailyUsage()
    typealias Reader = @Sendable (CodexUsageTarget, String, String) async -> CodexDailyUsageSnapshot
    private let reader: Reader
    private var cached: [String: CodexDailyUsageSnapshot] = [:]
    private var attempted: [String: Date] = [:]
    private var inFlight: [String: Task<CodexDailyUsageSnapshot, Never>] = [:]

    init(reader: @escaping Reader = { await CodexDailyUsage.read(target: $0, from: $1, to: $2) }) { self.reader = reader }

    public func load(targets: [CodexUsageTarget], force: Bool = false, now: Date = Date()) async -> [CodexDailyUsageSnapshot] {
        let window = Report.window(days: 90, calendar: UsageCoverage.utcCalendar, now: now)
        let from = UsageCoverage.dayLabel(window.from), to = UsageCoverage.dayLabel(window.to.addingTimeInterval(-1))
        return await loadRange(targets: targets, from: from, to: to, force: force, now: now)
    }

    /// A single-day query preserves model names that the provider may group
    /// under "Other" across a longer reporting window.
    public func loadDay(targets: [CodexUsageTarget], date: String, force: Bool = false) async -> [CodexDailyUsageSnapshot] {
        guard Self.isDay(date) else {
            return targets.map {
                var snapshot = CodexDailyUsageSnapshot(target: $0, fromDay: date, toDay: date)
                snapshot.status = .failed; snapshot.message = "Use a valid provider date in YYYY-MM-DD format."
                return snapshot
            }
        }
        return await loadRange(targets: targets, from: date, to: date, force: force, now: Date())
    }

    private func loadRange(targets: [CodexUsageTarget], from: String, to: String, force: Bool, now: Date) async -> [CodexDailyUsageSnapshot] {
        var result: [CodexDailyUsageSnapshot] = []
        for target in targets {
            let key = "\(target.id):\(target.serviceAccountId):\(target.email.lowercased()):\(target.home):\(target.plan):\(from):\(to)"
            if !force, let attempted = attempted[key], now.timeIntervalSince(attempted) < 300, var previous = cached[key] {
                previous.target = target
                result.append(previous)
                continue
            }
            attempted[key] = now
            let reader = self.reader
            let task = inFlight[key] ?? Task { await reader(target, from, to) }
            inFlight[key] = task
            var fresh = await task.value
            inFlight[key] = nil
            if fresh.fetchedAt == nil, fresh.status == .failed, var previous = cached[key], previous.fetchedAt != nil {
                previous.target = target
                previous.status = .partial
                previous.message = "Stale daily analytics. " + (fresh.message ?? "Refresh failed.")
                fresh = previous
            }
            cached[key] = fresh
            result.append(fresh)
        }
        return result
    }

    static func read(target: CodexUsageTarget, from: String, to: String) async -> CodexDailyUsageSnapshot {
        var snapshot = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
        guard ["business", "enterprise", "team", "edu"].contains(target.plan) else {
            snapshot.message = "Dated workspace credits and model I/O require a workspace account."
            return snapshot
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: AnalyticsRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let credential = try credential(target: target)
            let query = ["start_date": from, "end_date": to]
            async let products = fetch(session: session, target: target, credential: credential,
                path: "daily-workspace-user-credit-usage", query: query.merging(["breakdown": "product"]) { _, new in new })
            async let models = optionalFetch(session: session, target: target, credential: credential,
                path: "daily-workspace-user-credit-usage", query: query.merging(["breakdown": "model"]) { _, new in new })
            async let tokens = optionalFetch(session: session, target: target, credential: credential,
                path: "daily-workspace-user-token-usage-breakdown", query: query.merging(["group_by": "day"]) { _, new in new })
            // Ask the provider for this login's conversion; no hardcoded USD
            // rate and no token pricing of credit balances or fast tiers.
            async let estimate = optionalFetch(session: session, target: target, credential: credential,
                path: "credits/estimate", query: [:], body: ["credits": 1])
            snapshot = try await decode(products: products, modelCredits: models, tokens: tokens, estimate: estimate,
                                        target: target, from: from, to: to)
            _ = try Self.credential(target: target) // reject a switched login
        } catch {
            snapshot = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
            snapshot.status = (error as? DailyUsageError) == .identity ? .missing : .failed
            snapshot.message = (error as? DailyUsageError)?.message ?? "Could not read dated workspace analytics. Refresh CLI login and try again."
        }
        return snapshot
    }

    static func credential(target: CodexUsageTarget) throws -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.home).appendingPathComponent("auth.json")),
              let root = JSON.object(data), let token = JSON.object(root["tokens"])?["access_token"] as? String, !token.isEmpty else {
            throw DailyUsageError.identity
        }
        let identity = CodexIdentity.decode(root)
        guard identity.accountId == target.serviceAccountId, identity.email?.lowercased() == target.email.lowercased(),
              identity.planType == target.plan else { throw DailyUsageError.identity }
        return token
    }

    private static func fetch(session: URLSession, target: CodexUsageTarget, credential: String, path: String,
                              query: [String: String], body: [String: Any]? = nil) async throws -> [String: Any] {
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/usage/\(path)")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, timeoutInterval: 12)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(target.serviceAccountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex_cli_rs/0.160.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DailyUsageError.invalid }
        guard response.statusCode == 200 else { throw DailyUsageError.http(response.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_000_000 else { throw DailyUsageError.invalid }
            data.append(byte)
        }
        guard let object = JSON.object(data) else { throw DailyUsageError.invalid }
        return object
    }

    private static func optionalFetch(session: URLSession, target: CodexUsageTarget, credential: String, path: String,
                                     query: [String: String], body: [String: Any]? = nil) async -> [String: Any]? {
        try? await fetch(session: session, target: target, credential: credential, path: path, query: query, body: body)
    }

    static func decode(products: [String: Any], modelCredits: [String: Any]?, tokens: [String: Any]?, estimate: [String: Any]?,
                       target: CodexUsageTarget, from: String, to: String, now: Date = Date()) throws -> CodexDailyUsageSnapshot {
        let productDays = try creditRows(products, breakdown: "product", from: from, to: to)
        let modelDays = modelCredits.flatMap { try? creditRows($0, breakdown: "model", from: from, to: to) }
        let tokenDays = tokens.flatMap { try? tokenRows($0, from: from, to: to) }
        let labels = Set(productDays.keys).union(modelDays?.keys.map { $0 } ?? []).union(tokenDays?.keys.map { $0 } ?? [])
        var snapshot = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
        snapshot.days = labels.sorted().map { CodexDailyUsageDay(date: $0, products: productDays[$0], modelCredits: modelDays?[$0], textModels: tokenDays?[$0]) }
        if let value = estimate?["estimated_usage_usd_micros"], let micros = try? count(value) {
            snapshot.estimatedUsdPerCredit = Double(micros) / 1_000_000
        }
        snapshot.fetchedAt = now
        // Conservatively report the oldest component freshness.
        snapshot.dataFreshness = [products, modelCredits, tokens].compactMap { $0?["data_freshness_ts"] as? String }.min()
        let partial = !snapshot.missingCreditDays.isEmpty || modelDays == nil || tokenDays == nil || snapshot.estimatedUsdPerCredit == nil
            || productDays.keys.contains { modelDays?[$0] == nil || tokenDays?[$0] == nil }
        snapshot.status = partial ? .partial : .ok
        if partial { snapshot.message = "Some daily credit, model, token, or USD readings are unavailable. Reported amounts cover available dates only." }
        return snapshot
    }

    static func creditRows(_ root: [String: Any], breakdown: String, from: String, to: String) throws -> [String: [DailyCreditValue]] {
        guard root["breakdown"] as? String == breakdown, let rows = root["data"] as? [[String: Any]],
              let series = root["series"] as? [[String: Any]] else { throw DailyUsageError.invalid }
        var labels: [String: String] = [:]
        for item in series {
            guard let key = item["key"] as? String, !key.isEmpty, labels[key] == nil,
                  let label = item["label"] as? String else { throw DailyUsageError.invalid }
            labels[key] = label
        }
        var result: [String: [DailyCreditValue]] = [:]
        for row in rows {
            let date = try dateLabel(row["date"], from: from, to: to)
            guard result[date] == nil, let values = row["values"] as? [String: Any] else { throw DailyUsageError.invalid }
            let credits = try values.map { key, value in DailyCreditValue(key: key, label: labels[key] ?? key, credits: try number(value)) }
            guard credits.reduce(0, { $0 + $1.credits }).isFinite else { throw DailyUsageError.invalid }
            result[date] = credits.sorted { $0.key < $1.key }
        }
        return result
    }

    static func tokenRows(_ root: [String: Any], from: String, to: String) throws -> [String: [DailyModelTokens]] {
        guard root["units"] as? String == "credits", root["group_by"] as? String == "day",
              let rows = root["data"] as? [[String: Any]] else { throw DailyUsageError.invalid }
        var result: [String: [DailyModelTokens]] = [:]
        for row in rows {
            let date = try dateLabel(row["date"], from: from, to: to)
            guard result[date] == nil, let models = row["models"] as? [[String: Any]] else { throw DailyUsageError.invalid }
            var ids: Set<String> = []
            result[date] = try models.map { item in
                guard let model = item["model"] as? String, !model.isEmpty, let speed = item["speed"] as? String,
                      ids.insert("\(model):\(speed)").inserted else { throw DailyUsageError.invalid }
                let input = try count(item["uncached_text_input_tokens"]), cache = try count(item["cached_text_input_tokens"])
                let output = try count(item["text_output_tokens"]), total = try count(item["text_total_tokens"])
                let sum = input.addingReportingOverflow(cache)
                let all = sum.partialValue.addingReportingOverflow(output)
                guard !sum.overflow, !all.overflow, all.partialValue == total else { throw DailyUsageError.invalid }
                return DailyModelTokens(model: model, speed: speed, credits: try number(item["credits"]),
                    uncachedInputTokens: input, cachedInputTokens: cache, outputTokens: output, totalTokens: total)
            }.sorted { $0.id < $1.id }
        }
        return result
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              value.doubleValue >= 0 else { throw DailyUsageError.invalid }
        return value.doubleValue
    }
    private static func count(_ value: Any?) throws -> Int {
        let value = try number(value)
        guard value < Double(Int.max), value.rounded(.down) == value else { throw DailyUsageError.invalid }
        return Int(value)
    }
    private static func dateLabel(_ value: Any?, from: String, to: String) throws -> String {
        guard let label = value as? String, label >= from, label <= to, let date = formatter().date(from: label),
              formatter().string(from: date) == label else { throw DailyUsageError.invalid }
        return label
    }
    public static func isDay(_ label: String) -> Bool {
        label.count == 10 && (try? dateLabel(label, from: label, to: label)) != nil
    }
    static func dateLabels(from: String, to: String) -> [String] {
        let formatter = formatter()
        guard var date = formatter.date(from: from), let end = formatter.date(from: to) else { return [] }
        var result: [String] = []
        while date <= end && result.count < 90 {
            result.append(formatter.string(from: date))
            date = date.addingTimeInterval(86_400)
        }
        return result
    }
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = UsageCoverage.utcCalendar
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

private enum DailyUsageError: Error, Equatable {
    case identity, invalid, http(Int)
    var message: String {
        switch self {
        case .identity: return "CLI login differs from the discovered workspace. Refresh account discovery."
        case .invalid: return "Dated workspace analytics returned an unsupported format."
        case .http(let code): return "Dated workspace analytics unavailable (HTTP \(code)). Check workspace access and CLI login."
        }
    }
}

/// Refuse redirects, so a service redirect cannot forward bearer credentials.
private final class AnalyticsRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
