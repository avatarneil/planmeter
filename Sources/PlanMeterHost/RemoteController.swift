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
/// The listener binds the machine's tailnet addresses (IPv4 and IPv6), never
/// the wildcard. Loopback is added when Tailscale Serve needs it for HTTPS,
/// when asked to (`--loopback`, for local testing), and always on macOS,
/// which cannot connect to its own tailnet address.
@MainActor
public final class RemoteController {
    /// Tailscale probes and `tailscale serve`, injectable for tests.
    public struct Environment: Sendable {
        public var tailnetAddresses: @Sendable () -> [String]
        public var magicDNSName: @Sendable () -> String?
        public var tailscaleAvailable: @Sendable () -> Bool
        public var certificateStatus: @Sendable () -> TailscaleServe.CertificateStatus
        public var serveIsActive: @Sendable (UInt16) -> Bool
        public var serveEnable: @Sendable (UInt16) -> TailscaleServe.Result
        public var serveDisable: @Sendable () -> TailscaleServe.Result

        public init(tailnetAddresses: @escaping @Sendable () -> [String], magicDNSName: @escaping @Sendable () -> String?,
                    tailscaleAvailable: @escaping @Sendable () -> Bool, certificateStatus: @escaping @Sendable () -> TailscaleServe.CertificateStatus,
                    serveIsActive: @escaping @Sendable (UInt16) -> Bool, serveEnable: @escaping @Sendable (UInt16) -> TailscaleServe.Result,
                    serveDisable: @escaping @Sendable () -> TailscaleServe.Result) {
            self.tailnetAddresses = tailnetAddresses
            self.magicDNSName = magicDNSName
            self.tailscaleAvailable = tailscaleAvailable
            self.certificateStatus = certificateStatus
            self.serveIsActive = serveIsActive
            self.serveEnable = serveEnable
            self.serveDisable = serveDisable
        }

        public static let live = Environment(
            tailnetAddresses: { [TailscaleInfo.ipv4(), TailscaleInfo.ipv6()].compactMap { $0 } },
            magicDNSName: { TailscaleInfo.magicDNSName() },
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
    private var listener: RemoteListener?
    /// What the current listener was asked to bind. Compared on each tick
    /// instead of `boundAddresses`, so an address that keeps failing to bind
    /// does not restart the listener (and cancel the invite) every 30 seconds.
    private var requestedAddresses: [String] = []

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

    /// Brings the listener in line with settings and the network: starts,
    /// stops, or rebinds when the tailnet addresses or port changed. Safe to
    /// call repeatedly; the daemon calls it every 30 seconds so a Tailscale
    /// connection made after boot is picked up.
    public func apply() async {
        let environment = self.environment
        let probe = await Task.detached(priority: .utility) { () -> ([String], String?, Bool) in
            (environment.tailnetAddresses(), environment.magicDNSName(), environment.tailscaleAvailable())
        }.value
        tailnetAddresses = probe.0
        dnsName = probe.1
        tailscaleAvailable = probe.2

        guard isEnabled else {
            if listener != nil { service.log("remote access off") }
            stopListener()
            state = .off
            message = forceEnabled == false ? "Disabled for this run (--no-remote)." : nil
            return
        }
        var addresses = tailnetAddresses
        if bindLoopback || httpsEnabled { addresses.append("127.0.0.1") }
        if listener != nil, Set(addresses) == Set(requestedAddresses), boundPort == port {
            await refreshHTTPS(ensure: httpsEnabled)
            return
        }
        stopListener()
        guard !addresses.isEmpty else {
            state = .unavailable
            message = "Tailscale is not connected. Remote access only listens on the tailnet."
            return
        }
        let service = self.service
        do {
            let listener = try listenerFactory(port, addresses, { request in await service.handle(request) })
            self.listener = listener
            requestedAddresses = addresses
            boundAddresses = listener.boundAddresses
            boundPort = port
            state = .listening
            if tailnetAddresses.isEmpty {
                message = "Tailscale is not connected; listening on loopback only."
            } else if let group = listener as? POSIXListenerGroup, !group.failures.isEmpty {
                message = "Some addresses could not be bound: \(group.failures.joined(separator: "; "))"
            } else {
                message = nil
            }
            service.log("listening on \(boundAddresses.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ", ")) port \(port)")
        } catch {
            state = .error
            message = "Could not start: \(error.localizedDescription)"
            service.log(message!)
        }
        await refreshHTTPS(ensure: httpsEnabled)
    }

    public func stop() {
        stopListener()
        state = .off
    }

    private func stopListener() {
        listener?.stop()
        listener = nil
        requestedAddresses = []
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
        guard isEnabled, listener != nil else {
            httpsActive = false
            return
        }
        let port = self.port
        let environment = self.environment
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
