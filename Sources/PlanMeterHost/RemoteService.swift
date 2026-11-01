import Foundation
import PlanMeterRemote

/// The remote-access protocol for one host: paired devices, the pairing
/// invite and web pairing code, and handling of `/v1/info`, `/v1/pair`,
/// `/v1/rpc`, the web pairing endpoint, and the web client's static files.
///
/// Shared by the Mac app (wrapped by its observable `RemoteState`) and
/// `planmeterd`. The transport is someone else's job: any listener that
/// produces an `HTTPRequest` can call `handle(_:)`.
///
/// Security properties, all enforced here:
/// - Only tailnet peers (100.64.0.0/10, fd7a:115c:a1e0::/48) or loopback are
///   served; `X-Forwarded-For` is honoured only from loopback (Tailscale Serve).
/// - Pairing tokens and web codes are compared in constant time, are single
///   use, and expire after five minutes.
/// - Five failed pairing attempts cancel the invite and its web code.
/// - Every request is signed and its nonce recorded for the clock window, so
///   captured requests cannot be replayed.
@MainActor
public final class RemoteService {
    nonisolated public static let defaultPort: UInt16 = 7787
    nonisolated public static let inviteLifetime: TimeInterval = 5 * 60
    nonisolated public static let maxPairFailures = 5
    nonisolated public static let webPairingPath = "/v1/web-pairing-invite"
    nonisolated public static let serverKeyFile = "server-key.json"
    nonisolated public static let devicesFile = "devices.json"
    nonisolated static let maxEvents = 50

    public let serverName: String
    public let serverKey: ServerAgreementKey
    /// Reported in `/v1/info` and pairing responses.
    public let version: String
    public private(set) var devices: [PairedDevice]
    public private(set) var invite: PairingInvite?
    /// A short-lived, separately generated claim code for a web app that is
    /// already open and therefore cannot receive the QR URL from a camera.
    public private(set) var webPairingCode: String?
    /// Newest first, at most 50.
    public internal(set) var events: [String] = []
    public private(set) var requestCount = 0
    public private(set) var pairFailures = 0

    /// Answers RPCs with fresh data.
    public var dataProvider: (@MainActor (RemoteRequest) async -> RemoteReply)?
    /// Where the web client lives, if this host serves it.
    public var webDirectory: @MainActor () -> URL? = { nil }
    /// Called after any state change, for hosts that mirror state into UI.
    public var onChange: (@MainActor () -> Void)?
    /// Every activity line, for hosts that also log elsewhere.
    public var onLog: (@MainActor (String) -> Void)?

    /// Test seams; production uses the clock and system randomness.
    public var clock: @MainActor () -> Date = { Date() }
    public var makeToken: @MainActor () -> String = { PairingInvite.makeToken() }
    public var makeWebCode: @MainActor () -> String = { String(format: "%08d", Int.random(in: 0...99_999_999)) }
    public var logTimestamp: @MainActor (Date) -> String = { $0.formatted(date: .omitted, time: .standard) }

    private let store: SecretStore
    private let replay = ReplayCache()

    public init(serverName: String, serverKey: ServerAgreementKey, store: SecretStore, version: String) {
        self.serverName = serverName
        self.serverKey = serverKey
        self.store = store
        self.version = version
        devices = (try? store.readCodable([PairedDevice].self, Self.devicesFile)) ?? []
    }

    /// Loads the server's key-agreement key, or makes and saves one.
    nonisolated public static func loadServerKey(store: SecretStore, load: (KeyBlob) throws -> ServerAgreementKey,
                                     make: () -> (key: ServerAgreementKey, blob: KeyBlob)) -> (key: ServerAgreementKey, blob: KeyBlob) {
        if let blob = try? store.readCodable(KeyBlob.self, serverKeyFile), let key = try? load(blob) {
            return (key, blob)
        }
        let made = make()
        try? store.writeCodable(made.blob, serverKeyFile)
        return made
    }

    /// A software P-256 key in a 0600 file: hosts without a Secure Enclave.
    nonisolated public static func loadSoftwareServerKey(store: SecretStore) -> ServerAgreementKey {
        loadServerKey(store: store, load: { blob in
            guard case .software(let raw) = blob else { throw KeyError.malformedKey }
            return try SoftwareAgreementKey(rawRepresentation: raw)
        }, make: {
            let key = SoftwareAgreementKey()
            return (key, key.blob)
        }).key
    }

    // MARK: Pairing

    @discardableResult
    public func newInvite(host: String, port: UInt16) -> PairingInvite {
        let invite = PairingInvite(
            serverHost: host,
            port: Int(port),
            serverName: serverName,
            serverPublicKey: serverKey.publicKeyRaw,
            token: makeToken(),
            expiresAt: clock().addingTimeInterval(Self.inviteLifetime)
        )
        self.invite = invite
        webPairingCode = makeWebCode()
        pairFailures = 0
        log("pairing code issued, expires in \(Int(Self.inviteLifetime / 60)) min")
        return invite
    }

    /// The invite, if it has not expired.
    public var activeInvite: PairingInvite? {
        guard let invite, !isExpired(invite) else { return nil }
        return invite
    }

    public func cancelInvite() {
        invite = nil
        webPairingCode = nil
        changed()
    }

    @discardableResult
    public func revoke(id: String) -> PairedDevice? {
        guard let device = devices.first(where: { $0.id == id }) else { return nil }
        devices.removeAll { $0.id == id }
        persistDevices()
        log("revoked \(device.name)")
        return device
    }

    /// Writes paired devices (request counts and last-seen times are
    /// otherwise saved every 20 requests).
    public func persistDevices() {
        try? store.writeCodable(devices, Self.devicesFile)
    }

    public func log(_ line: String) {
        let stamp = logTimestamp(clock())
        events.insert("\(stamp)  \(line)", at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        onLog?(line)
        changed()
    }

    /// Browser pairing link: same token as the app invite, carried in the URL
    /// fragment so it never reaches server logs. `origin` ends with "/".
    public func webPairingURL(for invite: PairingInvite, origin: String) -> URL? {
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

    private func isExpired(_ invite: PairingInvite) -> Bool { clock() > invite.expiresAt }

    private func changed() { onChange?() }

    // MARK: Request handling

    /// The peer to judge and log. Tailscale Serve proxies from loopback and
    /// adds X-Forwarded-For with the tailnet peer; anything else on loopback
    /// is a process on this machine.
    private func peer(of request: HTTPRequest) -> String {
        if TailscaleInfo.isLoopback(request.remoteHost),
           let forwarded = request.headers["x-forwarded-for"]?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
           !forwarded.isEmpty {
            return forwarded
        }
        return request.remoteHost
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Defense in depth: bound to the tailnet address already, but refuse
        // anything that did not arrive from a tailnet peer (or this machine).
        let peer = peer(of: request)
        guard TailscaleInfo.isTailnetAddress(peer) || TailscaleInfo.isLoopback(peer) else {
            log("rejected non-tailnet peer \(peer)")
            return .error(403, "tailnet peers only")
        }
        var patched = request
        patched.remoteHost = peer
        switch (request.method, request.path) {
        case ("GET", RemoteClient.infoPath):
            return .json(ServerInfo(version: version, serverName: serverName))
        case ("POST", RemoteClient.pairPath):
            return await handlePair(patched)
        case ("POST", Self.webPairingPath):
            return handleWebPairingInvite(patched)
        case ("POST", RemoteClient.rpcPath):
            return await handleRPC(patched)
        case (_, RemoteClient.infoPath), (_, RemoteClient.pairPath), (_, RemoteClient.rpcPath), (_, Self.webPairingPath):
            return .error(405, "method not allowed")
        case ("GET", let path) where WebAssetCatalog.files[path] != nil:
            guard let asset = WebAssetCatalog.load(path: path, from: webDirectory()) else { return .error(404, "web client not bundled") }
            return HTTPResponse(status: 200, body: asset.data, contentType: asset.contentType, headers: WebAssetCatalog.securityHeaders)
        default:
            return .error(404, "not found")
        }
    }

    private func decodeSealed(_ request: HTTPRequest) -> SecureChannel.SealedRequest? {
        guard let sealed = try? RemoteJSON.decoder.decode(SecureChannel.SealedRequest.self, from: request.body) else { return nil }
        do { try SecureChannel.checkTimestamp(sealed, now: clock()) } catch { return nil }
        return sealed
    }

    /// Exchanges the numeric code displayed on the host for the same secret
    /// material carried in the web QR fragment. The endpoint is tailnet-only,
    /// HTTPS is required by the web client, attempts share the invite's strict
    /// failure budget, and the invite is still consumed only by `handlePair`.
    private func handleWebPairingInvite(_ request: HTTPRequest) -> HTTPResponse {
        guard let invite, !isExpired(invite), let webPairingCode else {
            self.webPairingCode = nil
            changed()
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

    private func handlePair(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sealed = decodeSealed(request), sealed.deviceId == "pairing" else {
            return .error(400, "bad pairing request")
        }
        guard let invite, !isExpired(invite) else {
            log("pairing attempt from \(request.remoteHost) with no active code")
            return .error(403, "no active pairing code")
        }
        guard replay.record(deviceId: "pairing", nonce: sealed.nonce, now: clock()) else { return .error(409, "replay") }
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
        let device = PairedDevice(id: id, name: name.isEmpty ? "Device" : name, platform: String(pair.platform.prefix(32)), publicKey: pair.devicePublicKey, pairedAt: clock())
        devices.removeAll { $0.id == id }
        devices.append(device)
        persistDevices()
        self.invite = nil
        webPairingCode = nil
        pairFailures = 0
        log("paired \(device.name) (\(device.platform)) from \(request.remoteHost)")

        let response = PairResponse(deviceId: id, serverName: serverName, serverVersion: version)
        return seal(response, opened: opened)
    }

    private func pairFailure(_ message: String) -> HTTPResponse {
        pairFailures += 1
        log(message)
        if pairFailures >= Self.maxPairFailures {
            invite = nil
            webPairingCode = nil
            log("pairing code cancelled after repeated failures")
        }
        return .error(403, "pairing rejected")
    }

    private func handleRPC(_ request: HTTPRequest) async -> HTTPResponse {
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
        guard replay.record(deviceId: device.id, nonce: sealed.nonce, now: clock()) else {
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
        devices[index].lastSeenAt = clock()
        devices[index].requestCount += 1
        requestCount += 1
        if requestCount % 20 == 1 { persistDevices() }
        changed()

        let reply = await dataProvider?(rpc) ?? RemoteReply(error: "server not ready")
        return seal(reply, opened: opened)
    }

    private func seal<T: Encodable>(_ value: T, opened: SecureChannel.Opened) -> HTTPResponse {
        do {
            let plaintext = try RemoteJSON.encoder.encode(value)
            let sealed = try SecureChannel.sealResponse(plaintext: plaintext, key: opened.responseKey, cipher: opened.cipher)
            return HTTPResponse(status: 200, body: try RemoteJSON.encoder.encode(sealed))
        } catch {
            return .error(500, "could not seal response")
        }
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
