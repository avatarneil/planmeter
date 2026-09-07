import Foundation

/// Drives `tailscale serve` so the web client is reachable at
/// `https://<machine>.<tailnet>.ts.net/` with a real certificate, tailnet-only.
enum TailscaleServe {
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]
    static let httpsPort = 443

    static var executablePath: String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Result: Sendable {
        var ok: Bool
        var standardOutput: String = ""
        var standardError: String = ""

        var output: String {
            [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static var isAvailable: Bool { executablePath != nil }

    static func run(_ arguments: [String]) -> Result {
        guard let executablePath else { return Result(ok: false, standardError: "Tailscale CLI not found.") }
        return run(arguments, executableURL: URL(fileURLWithPath: executablePath))
    }

    static func run(_ arguments: [String], executableURL: URL) -> Result {
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
    static func enable(localPort: UInt16) -> Result {
        run(["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(localPort)"])
    }

    static func disable() -> Result {
        run(["serve", "--https=\(httpsPort)", "off"])
    }

    /// True when the current serve config points 443 at our loopback port.
    static func isActive(localPort: UInt16) -> Bool {
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

    struct CertificateStatus: Sendable {
        var domain: String?
        var message: String?
    }

    static func certificateStatus() -> CertificateStatus {
        certificateStatus(from: run(["status", "--json"]))
    }

    static func certificateStatus(from result: Result) -> CertificateStatus {
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
        return CertificateStatus(message: "Tailscale reports no HTTPS certificate domain for this Mac. Check MagicDNS and HTTPS in the Tailscale admin console.")
    }
}
