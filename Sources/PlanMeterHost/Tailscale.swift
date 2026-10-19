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

    public static var executablePath: String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

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

    public static func run(_ arguments: [String]) -> Result {
        guard let executablePath else { return Result(ok: false, standardError: "Tailscale CLI not found.") }
        return run(arguments, executableURL: URL(fileURLWithPath: executablePath))
    }

    public static func run(_ arguments: [String], executableURL: URL) -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return Result(ok: false, standardError: error.localizedDescription) }
        // Drain both streams concurrently so neither pipe can block the child.
        // Diagnostics must stay separate from the JSON on stdout.
        final class ErrorBuffer: @unchecked Sendable { var data = Data() }
        let errors = ErrorBuffer()
        let reader = DispatchWorkItem { errors.data = err.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(execute: reader)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reader.wait()
        return Result(
            ok: process.terminationStatus == 0,
            standardOutput: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Proxies HTTPS 443 on the tailnet to the loopback listener. Persists in
    /// tailscaled until turned off, so it survives app restarts.
    public static func enable(localPort: UInt16) -> Result {
        run(["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(localPort)"])
    }

    public static func disable() -> Result {
        run(["serve", "--https=\(httpsPort)", "off"])
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
/// tailnet CGNAT range; the MagicDNS name comes from the Tailscale CLI when
/// it is installed.
public enum TailscaleInfo {
    /// The first tailnet IPv4 address on any interface.
    public static func ipv4() -> String? {
        interfaceAddresses(family: AF_INET).first(where: isTailnetAddress)
    }

    /// The first tailnet IPv6 address (fd7a:115c:a1e0::/48) on any interface.
    public static func ipv6() -> String? {
        interfaceAddresses(family: AF_INET6).first(where: isTailnetAddress)
    }

    /// Numeric addresses of every interface in one address family.
    static func interfaceAddresses(family: Int32) -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        var out: [String] = []
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
            out.append(ip.split(separator: "%").first.map(String.init) ?? ip)
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

    public static func magicDNSName() -> String? {
        guard let cli = TailscaleServe.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = root["Self"] as? [String: Any],
              let dns = selfNode["DNSName"] as? String, !dns.isEmpty else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }
}
