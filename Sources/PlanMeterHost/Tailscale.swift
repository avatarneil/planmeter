import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Drives `tailscale serve` so the web client is reachable at
/// `https://<machine>.<tailnet>.ts.net/` with a real certificate, tailnet-only.
public enum TailscaleServe {
    #if os(macOS)
    public static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]
    #else
    /// `PATH` first, then the locations distribution packages and the static
    /// tarball install to.
    public static var cliCandidates: [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var candidates = path.split(separator: ":").filter { !$0.isEmpty }.map { "\($0)/tailscale" }
        for fallback in ["/usr/bin/tailscale", "/usr/sbin/tailscale", "/usr/local/bin/tailscale"] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }
    #endif
    public static let httpsPort = 443

    /// The installed CLI, whether or not it can be run right now.
    public static var executablePath: String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    #if os(macOS)
    /// The Tailscale app's own binary doubles as its CLI and guesses which
    /// one it is meant to be. Run from an app with piped output while the
    /// Tailscale app was not running, it came up as the app itself and never
    /// exited: PlanMeter launched at login hung waiting for `status --json`.
    /// This variable makes it a CLI regardless. Other CLIs ignore it.
    static let forceCLIEnvironment = ["TAILSCALE_BE_CLI": "true"]
    #endif

    public struct Result: Sendable {
        public var ok: Bool
        public var standardOutput: String = ""
        public var standardError: String = ""

        public init(ok: Bool, standardOutput: String = "", standardError: String = "") {
            self.ok = ok
            self.standardOutput = standardOutput
            self.standardError = standardError
        }

        public var output: String {
            [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    public static var isAvailable: Bool { executablePath != nil }

    /// How long a read-only command such as `status --json` may take. It
    /// normally answers in well under a second; this is a backstop against a
    /// CLI that never returns (see `forceCLIEnvironment` on macOS).
    public static let defaultTimeout: TimeInterval = 10
    /// `serve` may wait for Serve to be enabled in the admin console, so it
    /// gets longer before being stopped.
    public static let serveTimeout: TimeInterval = 30

    public static func run(_ arguments: [String], timeout: TimeInterval = defaultTimeout) -> Result {
        guard let executablePath else { return Result(ok: false, standardError: "Tailscale CLI not found.") }
        return run(arguments, executableURL: URL(fileURLWithPath: executablePath), timeout: timeout)
    }

    /// Runs the CLI and returns its output. Never blocks much past `timeout`:
    /// a child that is still running then is terminated (killed if it ignores
    /// SIGTERM) and the result fails with whatever it had printed.
    public static func run(_ arguments: [String], executableURL: URL, timeout: TimeInterval = defaultTimeout) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        #if os(macOS)
        process.environment = ProcessInfo.processInfo.environment.merging(forceCLIEnvironment) { $1 }
        #endif
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return Result(ok: false, standardError: error.localizedDescription) }
        let deadline = DispatchTime.now() + timeout
        // Drain both streams as data arrives so neither pipe can block the
        // child. Diagnostics stay separate from the JSON on stdout.
        let capture = PipeCapture([out.fileHandleForReading, err.fileHandleForReading])
        // Once the child has exited, its output is at most moments behind,
        // even right at the deadline.
        let finished = exited.wait(timeout: deadline) == .success
            && capture.waitForEnd(until: max(deadline, .now() + 0.5))
        if !finished {
            if process.isRunning {
                process.terminate()
                // Bound teardown even if the child ignores SIGTERM.
                if exited.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 0.5)
                }
            }
            // Let the readers collect what the child wrote before it stopped.
            _ = capture.waitForEnd(until: .now() + 0.2)
        }
        let streams = capture.data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard finished else {
            let note = "The Tailscale CLI did not finish within \(Int(timeout)) seconds."
            return Result(ok: false, standardOutput: streams[0], standardError: [streams[1], note].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return Result(ok: process.terminationStatus == 0, standardOutput: streams[0], standardError: streams[1])
    }

    /// Proxies HTTPS 443 on the tailnet to the loopback listener. Persists in
    /// tailscaled until turned off, so it survives app restarts.
    public static func enable(localPort: UInt16) -> Result {
        run(["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(localPort)"], timeout: serveTimeout)
    }

    public static func disable() -> Result {
        run(["serve", "--https=\(httpsPort)", "off"], timeout: serveTimeout)
    }

    /// True when the current serve config points 443 at our loopback port.
    public static func isActive(localPort: UInt16) -> Bool {
        let result = run(["serve", "status", "--json"])
        guard result.ok, let data = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // Shape: {"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7787"}}}}}
        guard let web = root["Web"] as? [String: Any] else { return false }
        for (_, site) in web {
            guard let siteDict = site as? [String: Any], let handlers = siteDict["Handlers"] as? [String: Any] else { continue }
            for (_, handler) in handlers {
                if let h = handler as? [String: Any], let proxy = h["Proxy"] as? String, proxy.contains("127.0.0.1:\(localPort)") {
                    return true
                }
            }
        }
        return false
    }

    public struct CertificateStatus: Sendable {
        public var domain: String?
        public var message: String?

        public init(domain: String? = nil, message: String? = nil) {
            self.domain = domain
            self.message = message
        }
    }

    public static func certificateStatus() -> CertificateStatus {
        certificateStatus(from: run(["status", "--json"]))
    }

    #if os(macOS)
    static let machineNoun = "this Mac"
    #else
    static let machineNoun = "this machine"
    #endif

    public static func certificateStatus(from result: Result) -> CertificateStatus {
        guard result.ok else {
            let detail = result.output.isEmpty ? "The command failed without an error message." : result.output
            return CertificateStatus(message: "Could not read Tailscale status: \(detail)")
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CertificateStatus(message: "Could not read Tailscale status: invalid JSON response.")
        }
        guard let state = root["BackendState"] as? String else {
            return CertificateStatus(message: "Could not read Tailscale status: missing connection state.")
        }
        guard state == "Running" else {
            return CertificateStatus(message: "Tailscale is not connected (\(state)). Connect Tailscale and try again.")
        }
        if let domains = root["CertDomains"] as? [String],
           let domain = domains.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return CertificateStatus(domain: domain)
        }
        return CertificateStatus(message: "Tailscale reports no HTTPS certificate domain for \(machineNoun). Check MagicDNS and HTTPS in the Tailscale admin console.")
    }
}

/// Finds the machine's Tailscale addresses. IPv4 in 100.64.0.0/10 is the
/// tailnet CGNAT range, but other networks use it too (carrier-grade NAT,
/// cloud VPCs, container networks), so an address only counts when Tailscale
/// reports it or it sits on Tailscale's own interface. The MagicDNS name
/// comes from the Tailscale CLI when it is installed.
public enum TailscaleInfo {
    /// What `tailscale status --json` says about this machine.
    public struct Node: Sendable, Equatable {
        /// Tailnet addresses, IPv4 first; at most one per family.
        public var addresses: [String]
        public var dnsName: String?

        public init(addresses: [String], dnsName: String? = nil) {
            self.addresses = addresses
            self.dnsName = dnsName
        }
    }

    /// Addresses and MagicDNS name from one CLI call. The addresses are the
    /// ones Tailscale reports for this node; when the CLI is missing or does
    /// not answer, the interface scan (`ipv4()`, `ipv6()`) stands in.
    public static func node() -> Node {
        let result = TailscaleServe.isAvailable ? TailscaleServe.run(["status", "--json"]) : nil
        if let result, let reported = node(fromStatus: result) { return reported }
        return Node(addresses: [ipv4(), ipv6()].compactMap { $0 })
    }

    /// Parses `tailscale status --json`. Nil when the output is unusable;
    /// no addresses when Tailscale is not running.
    static func node(fromStatus result: TailscaleServe.Result) -> Node? {
        guard let root = statusObject(result), let state = root["BackendState"] as? String else { return nil }
        guard state == "Running" else { return Node(addresses: [], dnsName: dnsName(in: root)) }
        let reported = ((root["Self"] as? [String: Any])?["TailscaleIPs"] as? [String]) ?? (root["TailscaleIPs"] as? [String]) ?? []
        let tailnet = reported.filter(isTailnetAddress)
        return Node(addresses: [tailnet.first { !$0.contains(":") }, tailnet.first { $0.contains(":") }].compactMap { $0 },
                    dnsName: dnsName(in: root))
    }

    private static func statusObject(_ result: TailscaleServe.Result) -> [String: Any]? {
        guard let data = result.standardOutput.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func dnsName(in root: [String: Any]) -> String? {
        guard let dns = (root["Self"] as? [String: Any])?["DNSName"] as? String, !dns.isEmpty else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }

    /// The tailnet IPv4 address on Tailscale's interface.
    public static func ipv4() -> String? {
        interfaceAddresses(family: AF_INET).first { isTailscaleInterface($0.interface) && isTailnetAddress($0.address) }?.address
    }

    /// The tailnet IPv6 address (fd7a:115c:a1e0::/48) on Tailscale's interface.
    public static func ipv6() -> String? {
        interfaceAddresses(family: AF_INET6).first { isTailscaleInterface($0.interface) && isTailnetAddress($0.address) }?.address
    }

    /// `tailscale0` on Linux (the default `--tun` name) and `utun*` on macOS,
    /// where both the standalone and App Store clients use a utun device.
    static func isTailscaleInterface(_ name: String) -> Bool {
        name.hasPrefix("tailscale") || name.hasPrefix("utun")
    }

    /// Numeric addresses of every interface in one address family.
    static func interfaceAddresses(family: Int32) -> [(interface: String, address: String)] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        var out: [(interface: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == family else { continue }
            // Linux has no sa_len; the family fixes the length.
            let length = family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            // Drop an IPv6 zone suffix such as "%utun4".
            out.append((String(cString: ifa.pointee.ifa_name), ip.split(separator: "%").first.map(String.init) ?? ip))
        }
        return out
    }

    /// 100.64.0.0/10 (IPv4) or fd7a:115c:a1e0::/48 (Tailscale IPv6).
    public static func isTailnetAddress(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }

    public static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
    }

    /// The MagicDNS name in `status --json` output. `.some(nil)` when
    /// Tailscale answered without one; nil when the output is unusable.
    public static func magicDNSName(fromStatus result: TailscaleServe.Result) -> String?? {
        guard let root = statusObject(result), root["BackendState"] is String else { return nil }
        return .some(dnsName(in: root))
    }
}

/// Reads a child's output streams on background threads. Blocking reads
/// rather than readability handlers: on Linux a handler can miss end of file.
/// A reader stays blocked only while something still holds the pipe open,
/// such as a descendant of a child that was stopped.
private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Data]
    private let readers = DispatchGroup()

    init(_ handles: [FileHandle]) {
        buffers = Array(repeating: Data(), count: handles.count)
        for (index, handle) in handles.enumerated() {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                while case let data = handle.availableData, !data.isEmpty {
                    lock.lock()
                    buffers[index].append(data)
                    lock.unlock()
                }
                readers.leave()
            }
        }
    }

    /// True once every stream reached end of file before `deadline`.
    func waitForEnd(until deadline: DispatchTime) -> Bool {
        readers.wait(timeout: deadline) == .success
    }

    var data: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }
}
