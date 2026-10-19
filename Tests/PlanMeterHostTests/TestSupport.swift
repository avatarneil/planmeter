import Foundation
import XCTest
import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeterHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A fresh directory under the system temp directory, removed by the caller.
/// Kept short: Unix socket paths are limited to about 100 bytes.
func makeTemporaryDirectory(_ name: String = "pm") throws -> URL {
    let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let url = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Raw HTTP over a socket, so tests control every byte sent.
enum RawHTTP {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var raw: Data

        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        var errorMessage: String? { (json as? [String: Any])?["error"] as? String }
    }

    enum Target {
        case tcp(String, UInt16)
        case unix(String)
    }

    static func connect(_ target: Target) -> Int32? {
        switch target {
        case .tcp(let host, let port):
            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            let fd = socket(AF_INET, Socket.stream, 0)
            guard fd >= 0 else { return nil }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            if !ok { posixClose(fd); return nil }
            return fd
        case .unix(let path):
            guard var addr = try? Socket.unixAddress(path) else { return nil }
            let fd = socket(AF_UNIX, Socket.stream, 0)
            guard fd >= 0 else { return nil }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } == 0
            if !ok { posixClose(fd); return nil }
            return fd
        }
    }

    /// Sends `bytes`, optionally half-closes, then reads until the server
    /// closes the connection (or `timeout` passes).
    static func exchange(_ target: Target, _ bytes: Data, halfClose: Bool = false, timeout: TimeInterval = 10) -> Reply? {
        guard let fd = connect(target) else { return nil }
        defer { posixClose(fd) }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if !bytes.isEmpty { Socket.writeAll(fd, bytes, until: Date().addingTimeInterval(timeout)) }
        if halfClose { shutdown(fd, Int32(SHUT_WR)) }
        return readReply(fd, timeout: timeout)
    }

    static func readReply(_ fd: Int32, timeout: TimeInterval) -> Reply? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Socket.wait(fd, for: Int16(POLLIN), until: deadline) {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Reply? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Reply(status: status, headers: headers, body: data.subdata(in: end.upperBound..<data.endIndex), raw: data)
    }

    static func request(_ method: String, _ path: String, body: Data = Data(), headers: [String: String] = [:]) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

@inline(__always) func posixConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, addr, length)
    #elseif canImport(Glibc)
    return Glibc.connect(fd, addr, length)
    #else
    return Musl.connect(fd, addr, length)
    #endif
}

@inline(__always) func posixBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, addr, length)
    #elseif canImport(Glibc)
    return Glibc.bind(fd, addr, length)
    #else
    return Musl.bind(fd, addr, length)
    #endif
}

/// Deterministic keys for fixtures and tests.
enum TestKeys {
    static func bytes(_ start: UInt8) -> Data { Data((0..<32).map { start &+ UInt8($0) }) }
    static var server: SoftwareAgreementKey { try! SoftwareAgreementKey(rawRepresentation: bytes(1)) }
    static var phone: SoftwareSigningKey { try! SoftwareSigningKey(rawRepresentation: bytes(41)) }
}

/// An in-memory `SecretStore`.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ key: String, _ data: Data) throws { lock.lock(); values[key] = data; lock.unlock() }
    func delete(_ key: String) throws { lock.lock(); values[key] = nil; lock.unlock() }
}

/// A listener that binds nothing, for control API tests.
final class FakeListener: RemoteListener {
    let boundAddresses: [String]
    private(set) var stopped = false
    init(addresses: [String]) { boundAddresses = addresses }
    func stop() { stopped = true }
}

extension RemoteController.Environment {
    /// A connected tailnet with no `tailscale serve` changes.
    static func fake(addresses: [String] = ["100.64.0.7"], dnsName: String? = "devbox.tail1234.ts.net",
                     certificateDomain: String? = "devbox.tail1234.ts.net") -> Self {
        Self(
            tailnetAddresses: { addresses },
            magicDNSName: { dnsName },
            tailscaleAvailable: { true },
            certificateStatus: { .init(domain: certificateDomain, message: certificateDomain == nil ? "Tailscale is not connected (Stopped). Connect Tailscale and try again." : nil) },
            serveIsActive: { _ in false },
            serveEnable: { _ in .init(ok: false, standardError: "serve is disabled in tests") },
            serveDisable: { .init(ok: true) }
        )
    }
}

extension HostEngine.Loader {
    /// Serves fixed scan output; no network, no disk.
    static func fixed(discovery: Discovery, scan: ScanOutput, rates: RateTable) -> Self {
        Self(
            discover: { discovery },
            scan: { _, _, _ in scan },
            threadCatalog: { _ in [:] },
            accountUsage: { _, _ in [] },
            dailyUsage: { _, _ in [] },
            cloudUsage: { _, _ in [] },
            loadCachedRates: { rates },
            fetchRates: { throw HostEngine.HostEngineError.offline }
        )
    }
}

/// A complete control API over deterministic state: fixed clock, keys,
/// tokens, devices, and usage. Used by routing tests and the fixtures.
@MainActor
struct ControlHarness {
    static let now = ISO8601DateFormatter().date(from: "2026-10-19T12:30:00Z")!
    static let workId = "codex:plan:business"
    static let personalId = "claude:home:/home/dev/.claude/projects"

    let directory: URL
    let engine: HostEngine
    let settings: HostSettingsStore
    let service: RemoteService
    let remote: RemoteController
    let api: ControlAPI

    static func make(remoteEnabled: Bool = true) async throws -> ControlHarness {
        let directory = try makeTemporaryDirectory("pmctl")
        var work = Account(id: workId, provider: .codex, displayName: "Codex Work", email: "dev@example.com", planLabel: "Business", suggestedGroup: .work, sourceDescription: "~/.codex")
        work.accentColorHex = "#0891b2"
        let personal = Account(id: personalId, provider: .claude, displayName: "Claude Personal", email: "dev@example.net", planLabel: "Max", suggestedGroup: .personal, sourceDescription: "~/.claude")
        let discovery = Discovery(accounts: [work, personal])
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Usage only in the last half hour: "today" in every whole-hour time
        // zone, so the fixtures do not depend on the machine's zone.
        var cells: [CellKey: Cell] = [:]
        cells[CellKey(startMs: nowMs - 25 * 60_000, accountId: workId, model: "gpt-5-codex")] =
            Cell(totals: TokenTotals(uncachedInput: 1200, cachedInput: 8000, output: 400), reportedCostUsd: 1.25, records: 3, sessionIds: ["w1"])
        cells[CellKey(startMs: nowMs - 10 * 60_000, accountId: personalId, model: "claude-sonnet-4-5")] =
            Cell(totals: TokenTotals(uncachedInput: 600, cachedInput: 2000, output: 200), reportedCostUsd: 0.5, records: 2, sessionIds: ["p1"])
        let limits = ["business": RateLimitSnapshot(planType: "business", timestampMs: nowMs - 60_000,
            primary: RateLimitWindow(usedPercent: 42, windowMinutes: 300, resetsAt: Int64(now.timeIntervalSince1970) + 7200),
            secondary: RateLimitWindow(usedPercent: 12.5, windowMinutes: 10080, resetsAt: Int64(now.timeIntervalSince1970) + 3 * 86400),
            hasCredits: false, unlimitedCredits: nil, creditsBalance: nil)]
        let sources = [
            SourceReport(provider: .codex, path: "/home/dev/.codex/sessions", status: .ok, scannedFiles: 12, reusedFiles: 40, skippedFiles: 0),
            SourceReport(provider: .claude, path: "/home/dev/.claude/projects", status: .ok, scannedFiles: 3, reusedFiles: 9, skippedFiles: 0),
        ]
        let scan = ScanOutput(cells: cells, rateLimits: limits, sources: sources, scannedAt: now)
        let rates = RateTable(rates: [:], source: "LiteLLM", fetchedAt: now)

        let settings = HostSettingsStore(url: directory.appendingPathComponent("config/settings.json"))
        try settings.update { s in
            s.groupOverrides = [personalId: .work]
            s.spendGroups = [.personal, .work]
            s.spendThresholds = ["today": SpendThreshold(limit: 25, warningPercent: 80)]
        }
        try settings.updateRemote { $0.enabled = remoteEnabled }

        let engine = HostEngine(serverName: "devbox", scanCache: directory.appendingPathComponent("state/scan-cache.json"),
                                loader: .fixed(discovery: discovery, scan: scan, rates: rates), groupOverrides: settings.settings.groupOverrides)
        engine.clock = { now }
        engine.rates = rates
        await engine.refresh()

        let store = PrivateFileStore(directory: directory.appendingPathComponent("state/remote"))
        let phone = TestKeys.phone
        try store.writeCodable([PairedDevice(id: DeviceId.derive(fromPublicKey: phone.publicKeyRaw), name: "Pixel 9", platform: "android",
                                             publicKey: phone.publicKeyRaw, pairedAt: now.addingTimeInterval(-86400),
                                             lastSeenAt: now.addingTimeInterval(-120), requestCount: 42)], RemoteService.devicesFile)
        let service = RemoteService(serverName: "devbox", serverKey: TestKeys.server, store: store, version: "0.3.6")
        service.clock = { now }
        service.makeToken = { "fixture-token-0123456789abcdefghijklmnopqrstu" }
        service.makeWebCode = { "12345678" }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "HH:mm:ss"
        service.logTimestamp = { utc.string(from: $0) }
        service.dataProvider = { [engine] in await engine.reply(for: $0) }

        let remote = RemoteController(service: service, settings: settings, environment: .fake(),
                                      listenerFactory: { _, addresses, _ in FakeListener(addresses: addresses) }, bindLoopback: false)
        await remote.apply()
        let api = ControlAPI(engine: engine, settings: settings, remote: remote, version: "0.3.6")
        return ControlHarness(directory: directory, engine: engine, settings: settings, service: service, remote: remote, api: api)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func call(_ method: String, _ path: String, json: String? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, path: path, body: json.map { Data($0.utf8) } ?? Data(), remoteHost: "unix"))
    }
}

extension HTTPResponse {
    var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    var errorMessage: String? { object?["error"] as? String }
    func decoded<T: Decodable>(_ type: T.Type) throws -> T { try RemoteJSON.decoder.decode(type, from: body) }
}

/// `protocol/fixtures`, shared with ProtocolFixtureTests: the same
/// PLANMETER_REGENERATE_FIXTURES switch, pretty sorted JSON on disk, and a
/// semantic comparison that works on macOS and Linux alike.
enum ProtocolFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures", isDirectory: true)
    static var regenerating: Bool { ProcessInfo.processInfo.environment["PLANMETER_REGENERATE_FIXTURES"] == "1" }

    /// Writes `document` when regenerating; otherwise returns a description
    /// of how it differs from the committed file, or nil when it matches.
    static func check(_ path: String, _ document: Any) throws -> String? {
        let url = root.appendingPathComponent(path)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        if regenerating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        }
        guard let committed = FileManager.default.contents(atPath: url.path) else { return "\(path): missing" }
        // Key order, whitespace, and number formatting vary by platform;
        // compare after one round trip through the same serializer.
        func canonical(_ data: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
        }
        return try canonical(committed) == canonical(data) ? nil : "\(path) differs from the implementation:\n\(String(decoding: data, as: UTF8.self))"
    }

    /// The fixture files directly in `directory`.
    static func files(in directory: String) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path).filter { !$0.hasPrefix(".") })
    }

    static let hint = "If the change is intended, run `PLANMETER_REGENERATE_FIXTURES=1 swift test --filter PlanMeterHostTests` on a Mac and review the diff."

    /// A JSON value for a request or response body: parsed JSON when it is
    /// JSON, otherwise the text.
    static func body(_ data: Data) -> Any {
        if data.isEmpty { return NSNull() }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return object }
        return String(decoding: data, as: UTF8.self)
    }
}
