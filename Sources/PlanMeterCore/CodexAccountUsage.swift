import Foundation
import Darwin

/// Fetches at most once per five minutes per login. Failures retain the last
/// successful reading with an explicit stale status, never a fabricated zero.
public actor CodexAccountUsage {
    public static let shared = CodexAccountUsage()
    private var cached: [String: AccountUsageSnapshot] = [:]
    private var attempted: [String: Date] = [:]
    private var inFlight: [String: Task<AccountUsageSnapshot, Never>] = [:]
    private let reader: @Sendable (CodexUsageTarget) -> AccountUsageSnapshot

    init(reader: @escaping @Sendable (CodexUsageTarget) -> AccountUsageSnapshot = { CodexAccountUsage.read(target: $0) }) {
        self.reader = reader
    }

    public func load(targets: [CodexUsageTarget], force: Bool = false) async -> [AccountUsageSnapshot] {
        var result: [AccountUsageSnapshot] = []
        for target in targets {
            let key = "\(target.id):\(target.home):\(target.plan)"
            if !force, let date = attempted[key], Date().timeIntervalSince(date) < 300, var snapshot = cached[key] {
                snapshot.target = target
                result.append(snapshot)
                continue
            }
            attempted[key] = Date()
            let reader = self.reader
            let task = inFlight[key] ?? Task.detached(priority: .utility) { reader(target) }
            inFlight[key] = task
            let fresh = await task.value
            inFlight[key] = nil
            var snapshot = fresh
            if fresh.fetchedAt == nil, var previous = cached[key], previous.fetchedAt != nil {
                previous.target = target
                previous.status = .partial
                previous.message = "Stale reading. " + (fresh.message ?? "Refresh failed.")
                snapshot = previous
            }
            cached[key] = snapshot
            result.append(snapshot)
        }
        return result
    }

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" } + [
            NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func read(target: CodexUsageTarget, executableURL: URL? = nil, timeout: TimeInterval = 15,
                     threadReferences: [CodexThreadReference]? = nil) -> AccountUsageSnapshot {
        var snapshot = AccountUsageSnapshot(target: target)
        guard let executableURL = executableURL ?? executable() else {
            snapshot.message = "Codex CLI not found. Install a version supporting account/usage/read."
            return snapshot
        }
        do {
            let rpc = try CodexUsageRPC(executableURL: executableURL, home: target.home, timeout: timeout)
            defer { rpc.close() }
            _ = try rpc.request(id: 1, method: "initialize", params: [
                "clientInfo": ["name": "planmeter", "version": "0.3.3"], "capabilities": ["experimentalApi": true],
            ])
            try rpc.send(["method": "initialized", "params": [:]])
            let login = try rpc.request(id: 2, method: "account/read", params: ["refreshToken": false])
            guard let account = JSON.object(login["account"]), JSON.string(account["type"]) == "chatgpt",
                  JSON.string(account["email"])?.lowercased() == target.email.lowercased(),
                  JSON.string(account["planType"]) == target.plan else { throw UsageError.identity }
            if let routing = JSON.object(login["workspaceRouting"]), let id = JSON.string(routing["chatgptAccountId"]), id != target.serviceAccountId {
                throw UsageError.identity
            }
            let result = try rpc.request(id: 3, method: "account/usage/read", params: [:])
            snapshot = try decode(result, target: target)
            let references = threadReferences ?? CodexThreadUsage.references(target: target)
            // Pipeline a small batch of independent service reads so a cloud
            // inventory fits inside the same bounded refresh deadline.
            for start in stride(from: 0, to: references.count, by: 8) {
                guard Date() < rpc.deadline else { break }
                var pending: [(Int, CodexThreadReference)] = []
                for index in start..<min(start + 8, references.count) {
                    let reference = references[index]
                    snapshot.threadUsageAttempted += 1
                    do {
                        try rpc.send(["id": index + 4, "method": "account/usage/read", "params": ["threadId": reference.id]])
                        pending.append((index + 4, reference))
                    } catch { snapshot.threadUsageUnavailable += 1 }
                }
                for (id, reference) in pending {
                    do {
                        let result = try rpc.response(id: id)
                        if let usage = try CodexThreadUsage.decode(result, reference: reference) {
                            snapshot.serviceThreads.append(usage)
                        } else { snapshot.threadUsageUnavailable += 1 }
                    } catch { snapshot.threadUsageUnavailable += 1 }
                }
            }
            if !references.isEmpty {
                snapshot.threadUsageMessage = "Lifetime usage for \(snapshot.serviceThreads.count) of \(references.count) known desktop/cloud threads. The cached inventory may be incomplete; these readings cannot be assigned to individual days."
            }
            // Re-check the local login in case a switch occurred during the fetch.
            let identity = CodexIdentity.read(homePath: target.home)
            guard identity.accountId == target.serviceAccountId, identity.email?.lowercased() == target.email.lowercased(), identity.planType == target.plan else { throw UsageError.identity }
        } catch {
            snapshot = AccountUsageSnapshot(target: target)
            snapshot.status = .failed
            // Never display the server's error body: it can contain auth data.
            snapshot.message = (error as? UsageError)?.description ?? "Could not read Codex account usage. Check CLI installation and login."
        }
        return snapshot
    }

    static func decode(_ result: [String: Any], target: CodexUsageTarget, now: Date = Date()) throws -> AccountUsageSnapshot {
        guard let rows = result["dailyUsageBuckets"] as? [[String: Any]], JSON.object(result["summary"]) != nil else { throw UsageError.unsupported }
        var days: [AccountUsageDay] = []
        var seen: Set<String> = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = UsageCoverage.utcCalendar
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for row in rows {
            guard let label = row["startDate"] as? String, let date = formatter.date(from: label), formatter.string(from: date) == label,
                  let number = row["tokens"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.down) == number.doubleValue, seen.insert(label).inserted else { throw UsageError.unsupported }
            days.append(AccountUsageDay(startDate: label, tokens: number.intValue))
        }
        var total = 0
        for day in days {
            let addition = total.addingReportingOverflow(day.tokens)
            guard !addition.overflow else { throw UsageError.unsupported }
            total = addition.partialValue
        }
        var snapshot = AccountUsageSnapshot(target: target)
        snapshot.days = days.sorted { $0.startDate < $1.startDate }
        snapshot.lifetimeTokens = JSON.object(result["summary"])?["lifetimeTokens"] as? Int
        snapshot.fetchedAt = now
        snapshot.status = .ok
        if days.isEmpty { snapshot.message = "No daily usage buckets reported." }
        return snapshot
    }
}

enum UsageError: Error {
    case identity, unsupported, timeout, closed, protocolError
    var description: String {
        switch self {
        case .identity: return "Codex login changed or differs from the discovered account. Refresh account discovery."
        case .unsupported: return "Daily account usage unavailable or incompatible with this Codex CLI."
        case .timeout: return "Codex account usage timed out."
        case .closed: return "Codex app-server exited before returning account usage."
        case .protocolError: return "Codex rejected the account usage request. Check CLI version and login."
        }
    }
}

/// A short-lived stdio client. Only initialization and read methods are sent;
/// it never starts a model turn, changes login, or consumes reset credits.
private final class CodexUsageRPC: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let signal = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var buffer = Data()
    var replies: [Int: [String: Any]] = [:]
    var failed = false
    let deadline: Date

    init(executableURL: URL, home: String, timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home)
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
                if let message = JSON.object(line), let id = message["id"] as? Int {
                    self.replies[id] = message
                }
            }
        }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params])
        return try response(id: id)
    }

    func response(id: Int) throws -> [String: Any] {
        while true {
            lock.lock()
            let reply = replies.removeValue(forKey: id), closed = failed
            lock.unlock()
            if let reply {
                guard reply["error"] == nil, let result = JSON.object(reply["result"]) else { throw UsageError.protocolError }
                return result
            }
            if closed { throw UsageError.closed }
            guard signal.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { throw UsageError.timeout }
        }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning, exited.wait(timeout: .now() + 0.3) != .success {
            process.terminate()
            // Bound teardown even if the child ignores SIGTERM.
            if exited.wait(timeout: .now() + 0.2) != .success, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
