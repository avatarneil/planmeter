import Foundation
import Observation
import PlanMeterCore
import PlanMeterHost
import PlanMeterRemote

/// Owns the Mac's remote-access server: settings, the Network.framework
/// listener, Tailscale HTTPS, and the observable state the Remote sheet shows.
/// Pairing and request handling are delegated to the portable `RemoteService`,
/// whose state is mirrored here for SwiftUI. All mutable state is main-actor.
@Observable
@MainActor
final class RemoteState {
    static let defaultPort: UInt16 = RemoteService.defaultPort
    static let inviteLifetime: TimeInterval = RemoteService.inviteLifetime
    static let maxPairFailures = RemoteService.maxPairFailures
    static let webPairingPath = RemoteService.webPairingPath

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "remoteEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "remoteEnabled")
            if isEnabled { start() } else { stop() }
        }
    }
    var port: UInt16 = UInt16(UserDefaults.standard.integer(forKey: "remotePort")).nonZero ?? RemoteState.defaultPort
    var status: String = "Off"
    var isListening = false
    var bindAddress: String?
    var magicDNSName: String?
    // Mirrored from `service` after every change.
    private(set) var devices: [PairedDevice] = []
    private(set) var invite: PairingInvite?
    /// A short-lived, separately generated claim code for a web app that is
    /// already open and therefore cannot receive the QR URL from iOS Camera.
    private(set) var webPairingCode: String?
    private(set) var events: [String] = []
    private(set) var requestCount = 0
    private(set) var pairFailures = 0

    /// Tailscale Serve fronting the loopback listener with HTTPS on 443 so the
    /// web client gets a secure context and a real certificate.
    var httpsEnabled: Bool = UserDefaults.standard.bool(forKey: "remoteHTTPSEnabled")
    var httpsActive = false
    var httpsDomain: String?
    var httpsMessage: String?
    var isTogglingHTTPS = false

    /// Supplied by the app model: answers RPCs with fresh data.
    var dataProvider: (@MainActor (RemoteRequest) async -> RemoteReply)? {
        get { service.dataProvider }
        set { service.dataProvider = newValue }
    }

    let serverName: String
    let serverKey: ServerAgreementKey
    let serverKeyIsEnclave: Bool
    @ObservationIgnored let service: RemoteService
    @ObservationIgnored private var server: RemoteHTTPServer?

    init() {
        serverName = Host.current().localizedName ?? "Mac"
        let store = FileSecretStore(directory: AppPaths.supportDirectory().appendingPathComponent("remote", isDirectory: true))
        let loaded = RemoteService.loadServerKey(store: store, load: AgreementKeys.load, make: AgreementKeys.make)
        serverKey = loaded.key
        if case .enclave = loaded.blob { serverKeyIsEnclave = true } else { serverKeyIsEnclave = false }
        service = RemoteService(serverName: serverName, serverKey: serverKey, store: store, version: Self.appVersion)
        service.webDirectory = { WebAssets.directory }
        service.onChange = { [weak self] in self?.syncFromService() }
        syncFromService()
    }

    private func syncFromService() {
        if devices != service.devices { devices = service.devices }
        if invite != service.invite { invite = service.invite }
        if webPairingCode != service.webPairingCode { webPairingCode = service.webPairingCode }
        if events != service.events { events = service.events }
        if requestCount != service.requestCount { requestCount = service.requestCount }
        if pairFailures != service.pairFailures { pairFailures = service.pairFailures }
    }

    // MARK: Lifecycle

    func start() {
        stop()
        bindAddress = TailscaleInfo.ipv4()
        magicDNSName = TailscaleInfo.magicDNSName()
        guard let bindAddress else {
            status = "Tailscale is not connected. Remote access only listens on the tailnet."
            isListening = false
            return
        }
        // Loopback is bound too: macOS cannot connect to its own tailnet
        // address, and same-machine clients (the iOS simulator, tests) need a
        // way in. Loopback only ever reaches processes already on this Mac.
        let server = RemoteHTTPServer(port: port, bindAddresses: [bindAddress, "127.0.0.1"]) { [weak self] request in
            guard let self else { return .error(503, "server stopping") }
            return await self.service.handle(request)
        }
        server.onStateChange = { [weak self] address, state in
            Task { @MainActor in
                guard let self else { return }
                if address == bindAddress {
                    switch state {
                    case "listening":
                        self.isListening = true
                        self.status = "Listening on \(bindAddress):\(self.port)"
                    case "stopped":
                        self.isListening = false
                    default:
                        self.isListening = false
                        self.status = state
                    }
                }
                self.log("\(address): \(state)")
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
        Task { await refreshHTTPSStatus(ensure: httpsEnabled) }
    }

    // MARK: Tailscale HTTPS

    var httpsURL: URL? {
        guard httpsActive, let domain = httpsDomain else { return nil }
        return URL(string: "https://\(domain)/")
    }

    /// Reads the current serve state; when `ensure` is set, re-applies our
    /// mapping (idempotent) so it survives Tailscale restarts.
    func refreshHTTPSStatus(ensure: Bool) async {
        let port = self.port
        let (domain, active, message) = await Task.detached(priority: .utility) { () -> (String?, Bool, String?) in
            guard TailscaleServe.isAvailable else { return (nil, false, "Tailscale CLI not found. Install the macOS app or Homebrew package.") }
            let certificate = TailscaleServe.certificateStatus()
            guard let domain = certificate.domain else { return (nil, false, certificate.message) }
            var active = TailscaleServe.isActive(localPort: port)
            var message: String?
            if ensure && !active {
                let result = TailscaleServe.enable(localPort: port)
                active = result.ok && TailscaleServe.isActive(localPort: port)
                if !active { message = result.output.isEmpty ? "tailscale serve failed" : result.output }
            }
            return (domain, active, message)
        }.value
        httpsDomain = domain
        httpsActive = active
        httpsMessage = message
        if let message { log("tailscale serve: \(message)") }
    }

    func setHTTPS(enabled: Bool) async {
        isTogglingHTTPS = true
        defer { isTogglingHTTPS = false }
        httpsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "remoteHTTPSEnabled")
        if enabled {
            await refreshHTTPSStatus(ensure: true)
            if httpsActive { log("tailscale serve on: https://\(httpsDomain ?? "?")/") }
        } else {
            let result = await Task.detached(priority: .utility) { TailscaleServe.disable() }.value
            httpsActive = false
            httpsMessage = result.ok ? nil : result.output
            log("tailscale serve off")
        }
    }

    /// Browser pairing link: same token as the app invite, carried in the URL
    /// fragment so it never reaches server logs. Uses the HTTPS origin when
    /// Tailscale Serve is on; otherwise loopback, which browsers also treat as
    /// a secure context (for simulators and tests on this Mac).
    func webPairingURL(for invite: PairingInvite) -> URL? {
        let origin: String
        if let https = httpsURL {
            origin = https.absoluteString
        } else {
            origin = "http://127.0.0.1:\(port)/"
        }
        return service.webPairingURL(for: invite, origin: origin)
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        service.cancelInvite()
        status = "Off"
    }

    func restart() {
        if isEnabled { start() }
    }

    // MARK: Pairing

    func newInvite() {
        guard let host = magicDNSName ?? bindAddress else { return }
        service.newInvite(host: host, port: port)
    }

    func cancelInvite() {
        service.cancelInvite()
    }

    func revoke(_ device: PairedDevice) {
        service.revoke(id: device.id)
    }

    func log(_ line: String) {
        service.log(line)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}
