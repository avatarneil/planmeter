import Foundation
import Darwin

/// A login whose subscription windows are read from the provider rather than
/// from transcripts (Codex writes its own windows into each session).
public struct PlanLimitTarget: Hashable, Codable, Sendable, Identifiable {
    public var accountId: String
    public var provider: ProviderKind
    /// Claude: the login's `CLAUDE_CONFIG_DIR`, or nil for the default login.
    public var configDir: String?
    /// Antigravity: the profile's `acp_token.json`.
    public var tokenPath: String?
    /// Expected login email, checked against the CLI's reported account.
    public var email: String?
    /// Antigravity: T3's auth method; only Google sign-in has quotas.
    public var authMethod: String?
    public var id: String { accountId }

    public init(accountId: String, provider: ProviderKind, configDir: String? = nil, tokenPath: String? = nil, email: String? = nil, authMethod: String? = nil) {
        self.accountId = accountId
        self.provider = provider
        self.configDir = configDir
        self.tokenPath = tokenPath
        self.email = email
        self.authMethod = authMethod
    }
}

public struct PlanLimitWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    /// Nil when the provider reports a quota without a fixed cadence.
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var windowStart: Date? {
        guard let resetsAt, let windowMinutes, windowMinutes > 0 else { return nil }
        return resetsAt.addingTimeInterval(-TimeInterval(windowMinutes) * 60)
    }
}

public struct PlanLimitSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var target: PlanLimitTarget
    public var windows: [PlanLimitWindow] = []
    /// The provider's plan name, when it reports one.
    public var plan: String?
    public var fetchedAt: Date?
    public var status: SourceStatus = .missing
    public var message: String?
    public var id: String { target.accountId }

    public init(target: PlanLimitTarget) {
        self.target = target
    }

    /// The window closest to its limit, for compact summaries.
    public var tightest: PlanLimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

/// Fetches at most once per five minutes per login. Failures retain the last
/// successful reading with an explicit stale status, never a fabricated zero.
public actor PlanLimits {
    public static let shared = PlanLimits()
    private var cached: [PlanLimitTarget: PlanLimitSnapshot] = [:]
    private var attempted: [PlanLimitTarget: Date] = [:]
    private var inFlight: [PlanLimitTarget: Task<PlanLimitSnapshot, Never>] = [:]
    private let reader: @Sendable (PlanLimitTarget) async -> PlanLimitSnapshot

    init(reader: @escaping @Sendable (PlanLimitTarget) async -> PlanLimitSnapshot = { await PlanLimits.read(target: $0) }) {
        self.reader = reader
    }

    public func load(targets: [PlanLimitTarget], force: Bool = false) async -> [PlanLimitSnapshot] {
        await withTaskGroup(of: PlanLimitSnapshot.self) { group in
            for target in targets {
                group.addTask { await self.load(target: target, force: force) }
            }
            var result: [PlanLimitSnapshot] = []
            for await snapshot in group { result.append(snapshot) }
            return targets.compactMap { target in result.first { $0.target == target } }
        }
    }

    private func load(target: PlanLimitTarget, force: Bool) async -> PlanLimitSnapshot {
        if !force, let date = attempted[target], Date().timeIntervalSince(date) < 300, let snapshot = cached[target] {
            return snapshot
        }
        attempted[target] = Date()
        let reader = self.reader
        let task = inFlight[target] ?? Task.detached(priority: .utility) { await reader(target) }
        inFlight[target] = task
        let fresh = await task.value
        inFlight[target] = nil
        var snapshot = fresh
        if fresh.fetchedAt == nil, fresh.status == .failed, var previous = cached[target], previous.fetchedAt != nil {
            previous.status = .partial
            previous.message = "Stale reading. " + (fresh.message ?? "Refresh failed.")
            snapshot = previous
        }
        cached[target] = snapshot
        return snapshot
    }

    static func read(target: PlanLimitTarget) async -> PlanLimitSnapshot {
        switch target.provider {
        case .claude: return ClaudePlanLimits.read(target: target)
        case .antigravity: return await AntigravityPlanLimits.read(target: target)
        default:
            var snapshot = PlanLimitSnapshot(target: target)
            snapshot.message = "\(target.provider.displayName) does not report plan limits."
            return snapshot
        }
    }

    /// ISO-8601 with any number of fractional digits (Anthropic sends six).
    static func date(_ value: Any?) -> Date? {
        guard var text = JSON.string(value) else { return nil }
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            text.removeSubrange(dot..<end)
        }
        return ISO8601.parseMs(text).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }
}

// MARK: - Claude

/// Asks the Claude Code CLI for the login's subscription usage. The CLI owns
/// authentication (including the Keychain and token refresh); PlanMeter only
/// sends `initialize` and `get_usage`, never a prompt, so no model turn runs.
public enum ClaudePlanLimits {
    static let windows: [(key: String, label: String, minutes: Int)] = [
        ("five_hour", "5-hour", 300),
        ("seven_day", "Weekly", 10080),
        ("seven_day_opus", "Weekly · Opus", 10080),
        ("seven_day_sonnet", "Weekly · Sonnet", 10080),
    ]

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = NSHomeDirectory()
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" } + [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func read(target: PlanLimitTarget, executableURL: URL? = nil, timeout: TimeInterval = 20) -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot(target: target)
        guard let executableURL = executableURL ?? executable() else {
            snapshot.message = "Claude Code CLI not found. Install it to see plan limits."
            return snapshot
        }
        do {
            let client = try ClaudeControlClient(executableURL: executableURL, configDir: target.configDir, timeout: timeout)
            defer { client.close() }
            let initialized = try client.request(id: "planmeter-init", ["subtype": "initialize"])
            let account = JSON.object(initialized["account"])
            if let expected = target.email, let actual = JSON.string(account?["email"]), expected.lowercased() != actual.lowercased() {
                throw PlanLimitError.identity
            }
            let usage = try client.request(id: "planmeter-usage", ["subtype": "get_usage"])
            snapshot = try decodeClaude(usage, target: target)
        } catch {
            snapshot = PlanLimitSnapshot(target: target)
            snapshot.status = .failed
            // Never display the CLI's error text: it can echo auth details.
            snapshot.message = (error as? PlanLimitError)?.description(provider: .claude)
                ?? "Could not read Claude plan limits. Check the CLI installation and login."
        }
        return snapshot
    }

    /// `get_usage` reports utilization as 0-100.
    static func decodeClaude(_ response: [String: Any], target: PlanLimitTarget, now: Date = Date()) throws -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot(target: target)
        snapshot.plan = JSON.string(response["subscription_type"]).map(planLabel)
        guard JSON.bool(response["rate_limits_available"]) == true else {
            snapshot.status = .ok
            snapshot.fetchedAt = now
            snapshot.message = "This login has no subscription limits (API key or unsupported plan)."
            return snapshot
        }
        guard let limits = JSON.object(response["rate_limits"]) else { throw PlanLimitError.unsupported }
        for window in windows {
            guard let entry = JSON.object(limits[window.key]), let used = JSON.double(entry["utilization"]) else { continue }
            snapshot.windows.append(PlanLimitWindow(id: window.key, label: window.label, usedPercent: clamp(used),
                                                    windowMinutes: window.minutes, resetsAt: PlanLimits.date(entry["resets_at"])))
        }
        let named = Set(snapshot.windows.map { $0.label.lowercased() })
        for entry in (limits["model_scoped"] as? [[String: Any]]) ?? [] {
            guard let name = JSON.string(entry["display_name"]), let used = JSON.double(entry["utilization"]) else { continue }
            let label = "Weekly · \(name)"
            guard !named.contains(label.lowercased()) else { continue }
            snapshot.windows.append(PlanLimitWindow(id: "model:\(name.lowercased())", label: label, usedPercent: clamp(used),
                                                    windowMinutes: 10080, resetsAt: PlanLimits.date(entry["resets_at"])))
        }
        if let extra = JSON.object(limits["extra_usage"]), JSON.bool(extra["is_enabled"]) == true, let used = JSON.double(extra["utilization"]) {
            snapshot.windows.append(PlanLimitWindow(id: "extra_usage", label: "Extra usage", usedPercent: clamp(used)))
        }
        snapshot.status = .ok
        snapshot.fetchedAt = now
        if snapshot.windows.isEmpty { snapshot.message = "No usage windows reported." }
        return snapshot
    }

    static func planLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return type.capitalized
        }
    }
}

enum PlanLimitError: Error {
    case identity, unsupported, timeout, closed, protocolError, signedOut, http

    func description(provider: ProviderKind) -> String {
        let name = provider.displayName
        switch self {
        case .identity: return "\(name) login differs from the discovered account. Refresh account discovery."
        case .unsupported: return "Plan limits unavailable or incompatible with this \(name) version."
        case .timeout: return "\(name) plan limits timed out."
        case .closed: return "\(name) exited before returning plan limits."
        case .protocolError: return "\(name) rejected the plan limit request. Check the CLI version and login."
        case .signedOut: return "Sign in to \(name) with Google to see plan limits."
        case .http: return "Could not read \(name) plan limits. Refresh to retry."
        }
    }
}

private func clamp(_ percent: Double) -> Double { max(0, min(100, percent)) }

/// A short-lived `claude -p` stream-json session for control requests only.
/// Settings, hooks, MCP servers, and session persistence are all disabled.
private final class ClaudeControlClient: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let signal = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)
    let lock = NSLock()
    let workDir: URL
    var buffer = Data()
    var replies: [String: [String: Any]] = [:]
    var failed = false
    let deadline: Date

    init(executableURL: URL, configDir: String?, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        // An empty working directory keeps project settings and CLAUDE.md out.
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("planmeter-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        process.executableURL = executableURL
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--setting-sources", "project,local",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        ]
        var environment = ProcessInfo.processInfo.environment
        // Launched from inside Claude Code, PlanMeter can inherit that session's
        // login; each target names its own.
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir }
        process.environment = environment
        process.currentDirectoryURL = workDir
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock(); self.signal.signal() }
            if data.isEmpty { self.failed = true; handle.readabilityHandler = nil; return }
            self.buffer.append(data)
            if self.buffer.count > 4_000_000 { self.failed = true; handle.readabilityHandler = nil; return }
            while let end = self.buffer.firstIndex(of: 0x0A) {
                let line = Data(self.buffer[..<end])
                self.buffer.removeSubrange(...end)
                if let message = JSON.object(line), JSON.string(message["type"]) == "control_response",
                   let response = JSON.object(message["response"]), let id = JSON.string(response["request_id"]) {
                    self.replies[id] = response
                }
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }
    }

    func request(id: String, _ request: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
        while true {
            lock.lock()
            let reply = replies.removeValue(forKey: id), closed = failed
            lock.unlock()
            if let reply {
                guard JSON.string(reply["subtype"]) == "success" else { throw PlanLimitError.protocolError }
                return JSON.object(reply["response"]) ?? [:]
            }
            if closed { throw PlanLimitError.closed }
            guard signal.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { throw PlanLimitError.timeout }
        }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning, exited.wait(timeout: .now() + 0.5) != .success {
            process.terminate()
            // Bound teardown even if the child ignores SIGTERM.
            if exited.wait(timeout: .now() + 0.3) != .success, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: workDir)
    }
}

// MARK: - Antigravity

/// Reads Antigravity quotas the way T3 Code does: the profile's refresh token
/// is exchanged for a short-lived access token, which reads the quota summary.
/// The token file is never written; the access token is never stored.
public enum AntigravityPlanLimits {
    static let endpoints = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]

    static func read(target: PlanLimitTarget, session: URLSession = .shared) async -> PlanLimitSnapshot {
        var snapshot = PlanLimitSnapshot(target: target)
        if let method = target.authMethod, method != "oauth-personal", method != "oauth-business" {
            snapshot.message = "Plan limits apply only to Google sign-in."
            return snapshot
        }
        guard let tokenPath = target.tokenPath, let data = FileManager.default.contents(atPath: tokenPath),
              let token = JSON.object(data), let clientId = JSON.string(token["client_id"]),
              let clientSecret = JSON.string(token["client_secret"]), let refreshToken = JSON.string(token["refresh_token"]) else {
            snapshot.message = "Plan limits need an Antigravity profile signed in through T3 Code; the standalone CLI keeps its login in the Keychain."
            return snapshot
        }
        let project = JSON.string(token["project_id"])
        do {
            let accessToken = try await refresh(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken, session: session)
            var windows = await fetch("retrieveUserQuotaSummary", accessToken: accessToken, project: project, session: session, parse: summaryWindows)
            if windows.isEmpty {
                windows = await fetch("fetchAvailableModels", accessToken: accessToken, project: project, session: session, parse: modelWindows)
            }
            guard !windows.isEmpty else { throw PlanLimitError.unsupported }
            snapshot.windows = windows
            snapshot.status = .ok
            snapshot.fetchedAt = Date()
        } catch {
            snapshot = PlanLimitSnapshot(target: target)
            snapshot.status = .failed
            snapshot.message = (error as? PlanLimitError)?.description(provider: .antigravity)
                ?? "Could not read Antigravity plan limits. Refresh to retry."
        }
        return snapshot
    }

    private static func refresh(clientId: String, clientSecret: String, refreshToken: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = [("client_id", clientId), ("client_secret", clientSecret), ("refresh_token", refreshToken), ("grant_type", "refresh_token")]
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(form.utf8)
        let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw PlanLimitError.http }
        if http.statusCode == 400 || http.statusCode == 401 { throw PlanLimitError.signedOut }
        guard http.statusCode == 200, let body = JSON.object(data), let token = JSON.string(body["access_token"]) else { throw PlanLimitError.http }
        return token
    }

    /// Both endpoints are asked; for a quota both report, the higher reading wins.
    private static func fetch(_ operation: String, accessToken: String, project: String?, session: URLSession,
                              parse: @escaping @Sendable ([String: Any]) -> [PlanLimitWindow]) async -> [PlanLimitWindow] {
        let body = (try? JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])) ?? Data("{}".utf8)
        let responses = await withTaskGroup(of: [PlanLimitWindow].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var request = URLRequest(url: URL(string: "\(endpoint)/v1internal:\(operation)")!, timeoutInterval: 10)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("antigravity/hub/1.0.0 (aidev_client; os_type=darwin; arch=arm64)", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects.shared),
                          (response as? HTTPURLResponse)?.statusCode == 200, let json = JSON.object(data) else { return [] }
                    return parse(json)
                }
            }
            var all: [[PlanLimitWindow]] = []
            for await windows in group { all.append(windows) }
            return all
        }
        return merge(responses)
    }

    static func merge(_ responses: [[PlanLimitWindow]]) -> [PlanLimitWindow] {
        var byId: [String: PlanLimitWindow] = [:]
        var order: [String] = []
        for window in responses.joined() {
            if let previous = byId[window.id] {
                if window.usedPercent > previous.usedPercent { byId[window.id] = window }
            } else {
                byId[window.id] = window
                order.append(window.id)
            }
        }
        return order.compactMap { byId[$0] }
    }

    private static func window(id: String, label: String, quota: [String: Any], minutes: Int?) -> PlanLimitWindow? {
        guard let remaining = JSON.double(quota["remainingFraction"]) else { return nil }
        return PlanLimitWindow(id: id, label: label, usedPercent: (1 - max(0, min(1, remaining))) * 100,
                               windowMinutes: minutes, resetsAt: PlanLimits.date(quota["resetTime"]))
    }

    static func summaryWindows(_ summary: [String: Any]) -> [PlanLimitWindow] {
        let groups = (summary["groups"] as? [[String: Any]]) ?? []
        let effective = groups.contains { !(($0["buckets"] as? [[String: Any]]) ?? []).isEmpty } ? groups : [["buckets": summary["buckets"] ?? []]]
        var windows: [PlanLimitWindow] = []
        for group in effective {
            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                guard let id = JSON.string(bucket["bucketId"]), JSON.bool(bucket["disabled"]) != true,
                      !windows.contains(where: { $0.id == id }) else { continue }
                let family = id.hasPrefix("gemini-") ? "Gemini"
                    : id.hasPrefix("3p-") ? "Claude & GPT (shared)"
                    : JSON.string(group["displayName"])?.trimmingCharacters(in: .whitespaces) ?? id
                let cadence = JSON.string(bucket["window"])
                let name = cadence == "weekly" ? "Weekly" : cadence == "5h" ? "5-hour"
                    : JSON.string(bucket["displayName"])?.trimmingCharacters(in: .whitespaces) ?? "Quota"
                let minutes = cadence == "weekly" ? 10080 : cadence == "5h" ? 300 : nil
                if let window = window(id: id, label: "\(family) · \(name)", quota: bucket, minutes: minutes) { windows.append(window) }
            }
        }
        return windows
    }

    /// Older accounts expose per-model quotas without a window length; no reset
    /// cadence is invented for them.
    static func modelWindows(_ response: [String: Any]) -> [PlanLimitWindow] {
        var groups: [[PlanLimitWindow]] = []
        for (modelId, value) in (JSON.object(response["models"]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let model = JSON.object(value) else { continue }
            let provider = JSON.string(model["modelProvider"])
            let family = provider == "MODEL_PROVIDER_GOOGLE" || modelId.hasPrefix("gemini-") ? "Gemini"
                : provider == "MODEL_PROVIDER_ANTHROPIC" || modelId.hasPrefix("claude-") ? "Claude"
                : provider == "MODEL_PROVIDER_OPENAI" || modelId.hasPrefix("gpt-") ? "GPT" : nil
            guard let family else { continue }
            var found: [PlanLimitWindow] = []
            if let quota = JSON.object(model["quotaInfo"]),
               let w = window(id: "\(family.lowercased())-quota", label: "\(family) · Quota", quota: quota, minutes: nil) { found.append(w) }
            if let quota = JSON.object(model["weeklyQuotaInfo"]),
               let w = window(id: "\(family.lowercased())-weekly", label: "\(family) · Weekly", quota: quota, minutes: 10080) { found.append(w) }
            groups.append(found)
        }
        return merge(groups)
    }
}

/// Bearer tokens must not follow a redirect to another host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
