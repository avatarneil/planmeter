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
        var output: String
    }

    static var isAvailable: Bool { executablePath != nil }

    static func run(_ arguments: [String]) -> Result {
        guard let executablePath else { return Result(ok: false, output: "Tailscale CLI not found.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch { return Result(ok: false, output: error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(ok: process.terminationStatus == 0, output: text)
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
        guard result.ok, let data = result.output.data(using: .utf8),
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

    /// Whether the tailnet issues certificates for this machine.
    static func certDomain() -> String? {
        let result = run(["status", "--json"])
        guard result.ok, let data = result.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domains = root["CertDomains"] as? [String], let first = domains.first else { return nil }
        return first
    }
}
