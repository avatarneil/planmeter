import Foundation
import Network
import PlanMeterHost

/// Just enough HTTP/1.1 to serve three JSON endpoints over Network.framework,
/// bound to explicit interface addresses. One request per connection, bounded
/// header and body sizes, hard timeout per connection. Framing and limits are
/// shared with the portable listener in PlanMeterHost.
final class RemoteHTTPServer: @unchecked Sendable {
    typealias Request = HTTPRequest
    typealias Response = HTTPResponse
    typealias Handler = HTTPHandler

    static let maxHeaderBytes = HTTPLimits.maxHeaderBytes
    static let maxBodyBytes = HTTPLimits.maxBodyBytes
    static let connectionTimeout = HTTPLimits.connectionTimeout

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

                switch HTTPRequestParser.parse(buffer, isComplete: isComplete, remoteHost: remoteHost) {
                case .incomplete:
                    receive()
                case .close:
                    connection.cancel()
                case .failure(let status, let message):
                    fail(status, message)
                case .request(let request):
                    timeout.cancel()
                    Task {
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                }
            }
        }
        receive()
    }

    private func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
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
