import CryptoKit
import Foundation
import Observation
import PlanMeterCore
import PlanMeterRemote

/// Owns the remote-access server: identity key, paired devices, the current
/// pairing invite, and request handling. All mutable state is main-actor.
@Observable
@MainActor
final class RemoteState {
    static let defaultPort: UInt16 = 7787
    static let inviteLifetime: TimeInterval = 5 * 60
    static let maxPairFailures = 5
    static let webPairingPath = "/v1/web-pairing-invite"

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
    var devices: [PairedDevice] = []
    var invite: PairingInvite?
    /// A short-lived, separately generated claim code for a web app that is
    /// already open and therefore cannot receive the QR URL from iOS Camera.
    var webPairingCode: String?
    var events: [String] = []
    var requestCount = 0
    var pairFailures = 0

    /// Tailscale Serve fronting the loopback listener with HTTPS on 443 so the
    /// web client gets a secure context and a real certificate.
    var httpsEnabled: Bool = UserDefaults.standard.bool(forKey: "remoteHTTPSEnabled")
    var httpsActive = false
    var httpsDomain: String?
    var httpsMessage: String?
    var isTogglingHTTPS = false

    /// Supplied by the app model: answers RPCs with fresh data.
    var dataProvider: (@MainActor (RemoteRequest) async -> RemoteReply)?

    let serverName: String
    let serverKey: ServerAgreementKey
    let serverKeyIsEnclave: Bool
    private let store: FileSecretStore
    private let replay = ReplayCache()
    private var server: RemoteHTTPServer?

    init() {
        serverName = Host.current().localizedName ?? "Mac"
        store = FileSecretStore(directory: AppPaths.supportDirectory().appendingPathComponent("remote", isDirectory: true))
        if let blob = try? store.readCodable(KeyBlob.self, "server-key.json"), let key = try? AgreementKeys.load(blob) {
            serverKey = key
            if case .enclave = blob { serverKeyIsEnclave = true } else { serverKeyIsEnclave = false }
        } else {
            let made = AgreementKeys.make()
            serverKey = made.key
            if case .enclave = made.blob { serverKeyIsEnclave = true } else { serverKeyIsEnclave = false }
            try? store.writeCodable(made.blob, "server-key.json")
        }
        devices = (try? store.readCodable([PairedDevice].self, "devices.json")) ?? []
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
            return await self.handle(request)
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
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "k", value: invite.serverPublicKey.base64URLEncodedString()),
            URLQueryItem(name: "t", value: invite.token),
            URLQueryItem(name: "e", value: String(Int64(invite.expiresAt.timeIntervalSince1970))),
            URLQueryItem(name: "n", value: invite.serverName),
        ]
        guard let query = fragment.percentEncodedQuery else { return nil }
        return URL(string: origin + "#" + query)
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        invite = nil
        webPairingCode = nil
        status = "Off"
    }

    func restart() {
        if isEnabled { start() }
    }

    // MARK: Pairing

    func newInvite() {
        guard let host = magicDNSName ?? bindAddress else { return }
        invite = PairingInvite(
            serverHost: host,
            port: Int(port),
            serverName: serverName,
            serverPublicKey: serverKey.publicKeyRaw,
            token: PairingInvite.makeToken(),
            expiresAt: Date().addingTimeInterval(Self.inviteLifetime)
        )
        webPairingCode = String(format: "%08d", Int.random(in: 0...99_999_999))
        pairFailures = 0
        log("pairing code issued, expires in \(Int(Self.inviteLifetime / 60)) min")
    }

    func cancelInvite() {
        invite = nil
        webPairingCode = nil
    }

    func revoke(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        persistDevices()
        log("revoked \(device.name)")
    }

    private func persistDevices() {
        try? store.writeCodable(devices, "devices.json")
    }

    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        events.insert("\(stamp)  \(line)", at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }

    // MARK: Request handling

    /// The peer to judge and log. Tailscale Serve proxies from loopback and
    /// adds X-Forwarded-For with the tailnet peer; anything else on loopback
    /// is a process on this Mac.
    private func peer(of request: RemoteHTTPServer.Request) -> String {
        if TailscaleInfo.isLoopback(request.remoteHost),
           let forwarded = request.headers["x-forwarded-for"]?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
           !forwarded.isEmpty {
            return forwarded
        }
        return request.remoteHost
    }

    private func handle(_ request: RemoteHTTPServer.Request) async -> RemoteHTTPServer.Response {
        // Defense in depth: bound to the tailnet address already, but refuse
        // anything that did not arrive from a tailnet peer (or this Mac).
        let peer = peer(of: request)
        guard TailscaleInfo.isTailnetAddress(peer) || TailscaleInfo.isLoopback(peer) else {
            log("rejected non-tailnet peer \(peer)")
            return .error(403, "tailnet peers only")
        }
        var patched = request
        patched.remoteHost = peer
        switch (request.method, request.path) {
        case ("GET", RemoteClient.infoPath):
            return .json(ServerInfo(version: Self.appVersion, serverName: serverName))
        case ("POST", RemoteClient.pairPath):
            return await handlePair(patched)
        case ("POST", Self.webPairingPath):
            return handleWebPairingInvite(patched)
        case ("POST", RemoteClient.rpcPath):
            return await handleRPC(patched)
        case (_, RemoteClient.infoPath), (_, RemoteClient.pairPath), (_, RemoteClient.rpcPath), (_, Self.webPairingPath):
            return .error(405, "method not allowed")
        case ("GET", let path) where WebAssets.files[path] != nil:
            guard let asset = WebAssets.load(path: path) else { return .error(404, "web client not bundled") }
            return RemoteHTTPServer.Response(status: 200, body: asset.data, contentType: asset.contentType, headers: WebAssets.securityHeaders)
        default:
            return .error(404, "not found")
        }
    }

    private func decodeSealed(_ request: RemoteHTTPServer.Request) -> SecureChannel.SealedRequest? {
        guard let sealed = try? RemoteJSON.decoder.decode(SecureChannel.SealedRequest.self, from: request.body) else { return nil }
        do { try SecureChannel.checkTimestamp(sealed) } catch { return nil }
        return sealed
    }

    /// Exchanges the numeric code displayed on the Mac for the same secret
    /// material carried in the web QR fragment. The endpoint is tailnet-only,
    /// HTTPS is required by the web client, attempts share the invite's strict
    /// failure budget, and the invite is still consumed only by `handlePair`.
    private func handleWebPairingInvite(_ request: RemoteHTTPServer.Request) -> RemoteHTTPServer.Response {
        guard let invite, !invite.isExpired, let webPairingCode else {
            self.webPairingCode = nil
            return .error(403, "no active pairing code")
        }
        guard let claim = try? RemoteJSON.decoder.decode(WebPairingClaim.self, from: request.body) else {
            return pairFailure("invalid web pairing claim from \(request.remoteHost)")
        }
        let code = claim.code.filter { $0 >= "0" && $0 <= "9" }
        guard code.count == 8,
              Data(code.utf8).constantTimeEquals(Data(webPairingCode.utf8)) else {
            return pairFailure("wrong web pairing code from \(request.remoteHost)")
        }
        log("web pairing code claimed from \(request.remoteHost)")
        return .json(WebPairingOffer(
            serverName: invite.serverName,
            serverPublicKey: invite.serverPublicKey.base64EncodedString(),
            token: invite.token,
            expiresAt: Int64(invite.expiresAt.timeIntervalSince1970)
        ))
    }

    private func handlePair(_ request: RemoteHTTPServer.Request) async -> RemoteHTTPServer.Response {
        guard let sealed = decodeSealed(request), sealed.deviceId == "pairing" else {
            return .error(400, "bad pairing request")
        }
        guard let invite, !invite.isExpired else {
            log("pairing attempt from \(request.remoteHost) with no active code")
            return .error(403, "no active pairing code")
        }
        guard replay.record(deviceId: "pairing", nonce: sealed.nonce) else { return .error(409, "replay") }
        let opened: SecureChannel.Opened
        let pair: PairRequest
        do {
            opened = try SecureChannel.open(sealed, serverKey: serverKey, method: "POST", path: RemoteClient.pairPath)
            pair = try RemoteJSON.decoder.decode(PairRequest.self, from: opened.plaintext)
        } catch {
            return pairFailure("undecryptable pairing request from \(request.remoteHost)")
        }
        guard pair.devicePublicKey.count == 65,
              SecureChannel.verifySignature(sealed, devicePublicKeyRaw: pair.devicePublicKey, method: "POST", path: RemoteClient.pairPath) else {
            return pairFailure("pairing signature failed from \(request.remoteHost)")
        }
        guard Data(pair.token.utf8).constantTimeEquals(Data(invite.token.utf8)) else {
            return pairFailure("wrong pairing token from \(request.remoteHost)")
        }

        let id = DeviceId.derive(fromPublicKey: pair.devicePublicKey)
        let name = String(pair.deviceName.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(id: id, name: name.isEmpty ? "Device" : name, platform: String(pair.platform.prefix(32)), publicKey: pair.devicePublicKey, pairedAt: Date())
        devices.removeAll { $0.id == id }
        devices.append(device)
        persistDevices()
        self.invite = nil
        webPairingCode = nil
        pairFailures = 0
        log("paired \(device.name) (\(device.platform)) from \(request.remoteHost)")

        let response = PairResponse(deviceId: id, serverName: serverName, serverVersion: Self.appVersion)
        return seal(response, key: opened.responseKey, cipher: opened.cipher)
    }

    private func pairFailure(_ message: String) -> RemoteHTTPServer.Response {
        pairFailures += 1
        log(message)
        if pairFailures >= Self.maxPairFailures {
            invite = nil
            webPairingCode = nil
            log("pairing code cancelled after repeated failures")
        }
        return .error(403, "pairing rejected")
    }

    private func handleRPC(_ request: RemoteHTTPServer.Request) async -> RemoteHTTPServer.Response {
        guard let sealed = decodeSealed(request) else { return .error(400, "bad request") }
        guard let index = devices.firstIndex(where: { $0.id == sealed.deviceId }) else {
            log("request from unpaired device \(sealed.deviceId.prefix(8)) at \(request.remoteHost)")
            return .error(401, "unknown device")
        }
        let device = devices[index]
        guard SecureChannel.verifySignature(sealed, devicePublicKeyRaw: device.publicKey, method: "POST", path: RemoteClient.rpcPath) else {
            log("bad signature from \(device.name)")
            return .error(401, "signature failed")
        }
        guard replay.record(deviceId: device.id, nonce: sealed.nonce) else {
            log("replayed request from \(device.name)")
            return .error(409, "replay")
        }
        let opened: SecureChannel.Opened
        let rpc: RemoteRequest
        do {
            opened = try SecureChannel.open(sealed, serverKey: serverKey, method: "POST", path: RemoteClient.rpcPath)
            rpc = try RemoteJSON.decoder.decode(RemoteRequest.self, from: opened.plaintext)
        } catch {
            return .error(400, "undecryptable request")
        }
        devices[index].lastSeenAt = Date()
        devices[index].requestCount += 1
        requestCount += 1
        if requestCount % 20 == 1 { persistDevices() }

        let reply = await dataProvider?(rpc) ?? RemoteReply(error: "server not ready")
        return seal(reply, key: opened.responseKey, cipher: opened.cipher)
    }

    private func seal<T: Encodable>(_ value: T, key: SymmetricKey, cipher: SecureChannel.Cipher) -> RemoteHTTPServer.Response {
        do {
            let plaintext = try RemoteJSON.encoder.encode(value)
            let sealed = try SecureChannel.sealResponse(plaintext: plaintext, key: key, cipher: cipher)
            return RemoteHTTPServer.Response(status: 200, body: try RemoteJSON.encoder.encode(sealed))
        } catch {
            return .error(500, "could not seal response")
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

private struct WebPairingClaim: Decodable {
    let code: String
}

private struct WebPairingOffer: Encodable {
    let serverName: String
    let serverPublicKey: String
    let token: String
    let expiresAt: Int64
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}
