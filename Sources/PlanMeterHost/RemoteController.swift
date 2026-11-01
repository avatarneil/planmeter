import Foundation
import PlanMeterRemote

/// Something that serves the remote API until stopped.
public protocol RemoteListener: AnyObject {
    /// The addresses actually bound.
    var boundAddresses: [String] { get }
    func stop()
}

/// The daemon's remote-access lifecycle: which addresses to listen on, the
/// listener itself, Tailscale HTTPS, and pairing links. The Mac app's
/// `RemoteState` plays the same role with Network.framework and SwiftUI.
///
/// It binds the machine's tailnet addresses (IPv4 and IPv6) as Tailscale
/// reports them, never the wildcard, with one listener per address. Loopback
/// is added when Tailscale Serve needs it for HTTPS, when asked to
/// (`--loopback`, for local testing), and always on macOS, which cannot
/// connect to its own tailnet address.
@MainActor
public final class RemoteController {
    /// Tailscale probes and `tailscale serve`, injectable for tests.
    public struct Environment: Sendable {
        /// Tailnet addresses and MagicDNS name, read together.
        public var tailnet: @Sendable () -> TailscaleInfo.Node
        public var tailscaleAvailable: @Sendable () -> Bool
        public var certificateStatus: @Sendable () -> TailscaleServe.CertificateStatus
        public var serveIsActive: @Sendable (UInt16) -> Bool
        public var serveEnable: @Sendable (UInt16) -> TailscaleServe.Result
        public var serveDisable: @Sendable () -> TailscaleServe.Result

        public init(tailnet: @escaping @Sendable () -> TailscaleInfo.Node,
                    tailscaleAvailable: @escaping @Sendable () -> Bool, certificateStatus: @escaping @Sendable () -> TailscaleServe.CertificateStatus,
                    serveIsActive: @escaping @Sendable (UInt16) -> Bool, serveEnable: @escaping @Sendable (UInt16) -> TailscaleServe.Result,
                    serveDisable: @escaping @Sendable () -> TailscaleServe.Result) {
            self.tailnet = tailnet
            self.tailscaleAvailable = tailscaleAvailable
            self.certificateStatus = certificateStatus
            self.serveIsActive = serveIsActive
            self.serveEnable = serveEnable
            self.serveDisable = serveDisable
        }

        public static let live = Environment(
            tailnet: { TailscaleInfo.node() },
            tailscaleAvailable: { TailscaleServe.isAvailable },
            certificateStatus: { TailscaleServe.certificateStatus() },
            serveIsActive: { TailscaleServe.isActive(localPort: $0) },
            serveEnable: { TailscaleServe.enable(localPort: $0) },
            serveDisable: { TailscaleServe.disable() }
        )
    }

    public typealias ListenerFactory = @MainActor (_ port: UInt16, _ addresses: [String], _ handler: @escaping HTTPHandler) throws -> RemoteListener

    public enum State: String, Sendable {
        case off, listening, unavailable, error
    }

    public enum ControllerError: Error, LocalizedError {
        case notListening
        case invalidPort
        case bindFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notListening: return "remote access is not listening"
            case .invalidPort: return "port must be between 1025 and 65535"
            case .bindFailed(let reason): return reason
            }
        }
    }

    public let service: RemoteService
    public let settings: HostSettingsStore
    public var environment: Environment
    public var listenerFactory: ListenerFactory
    /// `--remote` (true) or `--no-remote` (false) for this run.
    public var forceEnabled: Bool?
    /// `--port` for this run; cleared when a client sets the port.
    public var portOverride: UInt16?
    public var bindLoopback: Bool

    public private(set) var state: State = .off
    public private(set) var message: String?
    public private(set) var boundAddresses: [String] = []
    public private(set) var boundPort: UInt16?
    public private(set) var tailnetAddresses: [String] = []
    public private(set) var dnsName: String?
    public private(set) var tailscaleAvailable = false
    public private(set) var httpsActive = false
    public private(set) var httpsDomain: String?
    public private(set) var httpsMessage: String?
    /// One listener per bound address. Each tick starts the missing ones and
    /// stops the unwanted ones, so an address that failed to bind is retried
    /// without disturbing the others (or cancelling the invite).
    private var listeners: [String: RemoteListener] = [:]
    /// Bumped by `stop()`. An `apply()` or HTTPS refresh that was waiting on
    /// Tailscale across a stop finds a newer generation when it resumes and
    /// changes nothing, so a tick in flight cannot undo shutdown.
    private var generation = 0

    public init(service: RemoteService, settings: HostSettingsStore, environment: Environment = .live,
                listenerFactory: ListenerFactory? = nil, bindLoopback: Bool) {
        self.service = service
        self.settings = settings
        self.environment = environment
        self.listenerFactory = listenerFactory ?? RemoteController.posixListener
        self.bindLoopback = bindLoopback
    }

    public var isEnabled: Bool { forceEnabled ?? settings.remote.enabled }
    public var port: UInt16 { portOverride ?? settings.remote.port }
    public var httpsEnabled: Bool { settings.remote.httpsEnabled }
    public var loopbackBound: Bool { boundAddresses.contains("127.0.0.1") }

    /// One POSIX listener per address; addresses that fail to bind are
    /// reported and skipped, as long as one succeeds.
    public static func posixListener(port: UInt16, addresses: [String], handler: @escaping HTTPHandler) throws -> RemoteListener {
        var servers: [POSIXHTTPServer] = []
        var failures: [String] = []
        for address in addresses {
            let server = POSIXHTTPServer(endpoints: [.tcp(host: address, port: port)], handler: handler)
            do {
                try server.start()
                servers.append(server)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard !servers.isEmpty else {
            throw ControllerError.bindFailed(failures.joined(separator: "; "))
        }
        return POSIXListenerGroup(servers: servers, addresses: addresses.enumerated().compactMap { index, address in
            servers.contains { $0.endpoints.first == .tcp(host: address, port: port) } ? address : nil
        }, failures: failures)
    }

    // MARK: Lifecycle

    /// Brings the listeners in line with settings and the network: binds new
    /// addresses, retries ones that failed, drops ones that went away, and
    /// starts over when the port changed. Safe to call repeatedly; the daemon
    /// calls it every 30 seconds so a Tailscale connection made after boot is
    /// picked up.
    public func apply() async {
        let environment = self.environment
        let generation = self.generation
        let probe = await Task.detached(priority: .utility) { () -> (TailscaleInfo.Node, Bool) in
            (environment.tailnet(), environment.tailscaleAvailable())
        }.value
        guard generation == self.generation, !Task.isCancelled else { return }
        tailnetAddresses = probe.0.addresses
        dnsName = probe.0.dnsName
        tailscaleAvailable = probe.1

        guard isEnabled else {
            if !listeners.isEmpty { service.log("remote access off") }
            stopListener()
            state = .off
            message = forceEnabled == false ? "Disabled for this run (--no-remote)." : nil
            return
        }
        var addresses = tailnetAddresses
        if bindLoopback || httpsEnabled { addresses.append("127.0.0.1") }
        if let boundPort, boundPort != port { stopListener() }
        let unwanted = listeners.keys.filter { !addresses.contains($0) }
        if !unwanted.isEmpty {
            for address in unwanted { listeners.removeValue(forKey: address)?.stop() }
            // The invite may name an address that is gone.
            service.cancelInvite()
        }
        guard !addresses.isEmpty else {
            stopListener()
            state = .unavailable
            message = "Tailscale is not connected. Remote access only listens on the tailnet."
            return
        }
        let service = self.service
        let previous = boundAddresses
        var failures: [String] = []
        for address in addresses where listeners[address] == nil {
            do {
                let listener = try listenerFactory(port, [address], { request in await service.handle(request) })
                if listener.boundAddresses.contains(address) {
                    listeners[address] = listener
                } else {
                    listener.stop()
                    failures.append("could not bind \(address)")
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        boundAddresses = addresses.filter { listeners[$0] != nil }
        boundPort = listeners.isEmpty ? nil : port
        let previousMessage = message
        if listeners.isEmpty {
            state = .error
            message = "Could not start: \(failures.joined(separator: "; "))"
            if message != previousMessage { service.log(message!) }
        } else {
            state = .listening
            if tailnetAddresses.isEmpty {
                message = "Tailscale is not connected; listening on loopback only."
            } else if !failures.isEmpty {
                message = "Some addresses could not be bound: \(failures.joined(separator: "; "))"
            } else {
                message = nil
            }
            if boundAddresses != previous {
                service.log("listening on \(boundAddresses.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ", ")) port \(port)")
            }
            if let message, message != previousMessage, !failures.isEmpty { service.log(message) }
        }
        await refreshHTTPS(ensure: httpsEnabled)
    }

    public func stop() {
        generation += 1
        stopListener()
        state = .off
        httpsActive = false
    }

    private func stopListener() {
        for listener in listeners.values { listener.stop() }
        listeners.removeAll()
        boundAddresses = []
        boundPort = nil
        service.cancelInvite()
    }

    // MARK: Settings

    public func update(enabled: Bool?, httpsEnabled: Bool?, port: Int?) async throws {
        var validatedPort: UInt16?
        if let port {
            guard let valid = RemoteSettings.validPort(port) else { throw ControllerError.invalidPort }
            validatedPort = valid
        }
        let wasHTTPS = self.httpsEnabled
        try settings.updateRemote { remote in
            if let enabled { remote.enabled = enabled }
            if let httpsEnabled { remote.httpsEnabled = httpsEnabled }
            if let validatedPort { remote.port = validatedPort }
        }
        if enabled != nil { forceEnabled = forceEnabled == false ? false : nil }
        if validatedPort != nil { portOverride = nil }
        if wasHTTPS && httpsEnabled == false {
            let environment = self.environment
            let result = await Task.detached(priority: .utility) { environment.serveDisable() }.value
            httpsActive = false
            httpsMessage = result.ok ? nil : result.output
            service.log("tailscale serve off")
        }
        await apply()
    }

    // MARK: Tailscale HTTPS

    public var httpsURL: URL? {
        guard httpsActive, let domain = httpsDomain else { return nil }
        return URL(string: "https://\(domain)/")
    }

    /// Reads the current serve state; when `ensure` is set, re-applies our
    /// mapping (idempotent) so it survives Tailscale restarts.
    public func refreshHTTPS(ensure: Bool) async {
        guard isEnabled, !listeners.isEmpty else {
            httpsActive = false
            return
        }
        let port = self.port
        let environment = self.environment
        let generation = self.generation
        let (domain, active, message) = await Task.detached(priority: .utility) { () -> (String?, Bool, String?) in
            guard environment.tailscaleAvailable() else { return (nil, false, "Tailscale CLI not found. Install the tailscale package.") }
            let certificate = environment.certificateStatus()
            guard let domain = certificate.domain else { return (nil, false, certificate.message) }
            var active = environment.serveIsActive(port)
            var message: String?
            if ensure && !active {
                let result = environment.serveEnable(port)
                active = result.ok && environment.serveIsActive(port)
                if !active { message = result.output.isEmpty ? "tailscale serve failed" : result.output }
            }
            return (domain, active, message)
        }.value
        guard generation == self.generation else { return }
        let changed = active != httpsActive || message != httpsMessage
        httpsDomain = domain
        httpsActive = active
        httpsMessage = message
        if changed, let message, ensure { service.log("tailscale serve: \(message)") }
    }

    // MARK: Pairing

    /// A fresh invite for the MagicDNS name (or tailnet address, or loopback
    /// when that is all there is).
    @discardableResult
    public func newInvite() throws -> PairingInvite {
        guard state == .listening, let port = boundPort else { throw ControllerError.notListening }
        let tailnet = boundAddresses.first { TailscaleInfo.isTailnetAddress($0) && !$0.contains(":") }
            ?? boundAddresses.first { TailscaleInfo.isTailnetAddress($0) }
        guard let host = (tailnet != nil ? dnsName : nil) ?? tailnet ?? (loopbackBound ? "127.0.0.1" : nil) else {
            throw ControllerError.notListening
        }
        return service.newInvite(host: host, port: port)
    }

    /// The invite for a client on this machine: same token, loopback host.
    public func localURL(for invite: PairingInvite) -> URL? {
        guard loopbackBound else { return nil }
        var local = invite
        local.serverHost = "127.0.0.1"
        return local.url
    }

    /// Browser pairing link: the HTTPS origin when Tailscale Serve is on,
    /// otherwise loopback (browsers treat it as a secure context too).
    public func webURL(for invite: PairingInvite) -> URL? {
        if let https = httpsURL { return service.webPairingURL(for: invite, origin: https.absoluteString) }
        guard loopbackBound, let port = boundPort else { return nil }
        return service.webPairingURL(for: invite, origin: "http://127.0.0.1:\(port)/")
    }

    // MARK: Status

    public func status() -> RemoteStatus {
        let invite = service.activeInvite.map { invite in
            RemoteStatus.Invite(url: invite.url.absoluteString, localUrl: localURL(for: invite)?.absoluteString,
                                webUrl: webURL(for: invite)?.absoluteString, webCode: service.webPairingCode, expiresAt: invite.expiresAt)
        }
        return RemoteStatus(
            enabled: isEnabled,
            port: Int(port),
            status: state.rawValue,
            message: message,
            bindAddresses: boundAddresses,
            tailscale: .init(available: tailscaleAvailable, address: tailnetAddresses.first { !$0.contains(":") } ?? tailnetAddresses.first, dnsName: dnsName),
            https: .init(enabled: httpsEnabled, active: httpsActive, url: httpsURL?.absoluteString, certificateStatus: httpsMessage),
            devices: service.devices,
            invite: invite,
            log: service.events
        )
    }
}

/// Independent listeners, one per address.
final class POSIXListenerGroup: RemoteListener {
    let servers: [POSIXHTTPServer]
    let boundAddresses: [String]
    let failures: [String]

    init(servers: [POSIXHTTPServer], addresses: [String], failures: [String]) {
        self.servers = servers
        self.boundAddresses = addresses
        self.failures = failures
    }

    func stop() {
        for server in servers { server.stop() }
    }
}
