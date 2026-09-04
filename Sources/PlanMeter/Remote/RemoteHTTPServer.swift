import Foundation
import Network

/// Just enough HTTP/1.1 to serve three JSON endpoints over Network.framework,
/// bound to explicit interface addresses. One request per connection, bounded
/// header and body sizes, hard timeout per connection.
final class RemoteHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        var remoteHost: String
    }

    struct Response: Sendable {
        var status: Int
        var body: Data
        var contentType = "application/json"
        var headers: [String: String] = [:]

        static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return Response(status: status, body: data)
        }

        static func error(_ status: Int, _ message: String) -> Response {
            json(["error": message], status: status)
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static let connectionTimeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "planmeter.remote.http", qos: .userInitiated)
    private var listeners: [NWListener] = []
    private let handler: Handler
    let port: UInt16
    /// One listener per address. macOS cannot connect to its own Tailscale
    /// address, so loopback is bound alongside it for same-machine clients
    /// such as the iOS simulator.
    let bindAddresses: [String]
    var onStateChange: (@Sendable (String, String) -> Void)?

    init(port: UInt16, bindAddresses: [String], handler: @escaping Handler) {
        self.port = port
        self.bindAddresses = bindAddresses
        self.handler = handler
    }

    func start() throws {
        for address in bindAddresses {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = false
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onStateChange?(address, "listening")
                case .failed(let error): self?.onStateChange?(address, "failed: \(error.localizedDescription)")
                case .cancelled: self?.onStateChange?(address, "stopped")
                case .waiting(let error): self?.onStateChange?(address, "waiting: \(error.localizedDescription)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
            listeners.append(listener)
        }
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
    }

    private func serve(_ connection: NWConnection) {
        let remoteHost: String
        if case .hostPort(let host, _) = connection.endpoint {
            remoteHost = Self.describe(host)
        } else {
            remoteHost = "unknown"
        }
        connection.start(queue: queue)
        var buffer = Data()
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: timeout)

        func fail(_ status: Int, _ message: String) {
            timeout.cancel()
            send(Response.error(status, message), on: connection)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }

                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.maxHeaderBytes { fail(431, "headers too large"); return }
                    if isComplete { connection.cancel(); return }
                    receive()
                    return
                }
                guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
                    fail(400, "bad request"); return
                }
                let lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
                guard requestLine.count >= 2 else { fail(400, "bad request"); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                if contentLength > Self.maxBodyBytes { fail(413, "body too large"); return }
                let bodyStart = headerEnd.upperBound
                if buffer.count - bodyStart < contentLength {
                    if isComplete { fail(400, "truncated body"); return }
                    receive()
                    return
                }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                let path = String(requestLine[1].split(separator: "?").first ?? "")
                let request = Request(method: requestLine[0], path: path, headers: headers, body: body, remoteHost: remoteHost)
                timeout.cancel()
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            }
        }
        receive()
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a):
            let s = "\(a)"
            return s.split(separator: "%").first.map(String.init) ?? s
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}

/// Finds the machine's Tailscale addresses. IPv4 in 100.64.0.0/10 is the
/// tailnet CGNAT range; the MagicDNS name comes from the Tailscale CLI when
/// the app is installed.
enum TailscaleInfo {
    static func ipv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isTailnetAddress(ip) { return ip }
        }
        return nil
    }

    /// 100.64.0.0/10 (IPv4) or fd7a:115c:a1e0::/48 (Tailscale IPv6).
    static func isTailnetAddress(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
    }

    static func magicDNSName() -> String? {
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
