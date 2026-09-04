import CryptoKit
import Foundation

public enum RemoteClientError: Error, LocalizedError {
    case http(Int, String)
    case transport(String)
    case malformedReply
    case inviteExpired
    case channel(SecureChannel.ChannelError)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): return message.isEmpty ? "Server returned HTTP \(code)." : message
        case .transport(let s): return s
        case .malformedReply: return "Unreadable reply from server."
        case .inviteExpired: return "This pairing code has expired. Make a new one on the Mac."
        case .channel(let e): return e.errorDescription
        }
    }
}

/// Talks to a PlanMeter Mac over the encrypted channel.
public final class RemoteClient: Sendable {
    public let server: PairedServer
    let signer: DeviceSigningKey
    let session: URLSession

    public init(server: PairedServer, signer: DeviceSigningKey, session: URLSession = RemoteClient.makeSession()) {
        self.server = server
        self.signer = signer
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    public static let rpcPath = "/v1/rpc"
    public static let pairPath = "/v1/pair"
    public static let infoPath = "/v1/info"

    public func call(_ request: RemoteRequest) async throws -> RemoteReply {
        let body = try RemoteJSON.encoder.encode(request)
        let data = try await Self.exchange(baseURL: server.baseURL, path: Self.rpcPath, plaintext: body, serverPublicKey: server.serverPublicKey, deviceId: server.deviceId, signer: signer, session: session)
        let reply = try Self.decode(RemoteReply.self, data)
        if let error = reply.error { throw RemoteClientError.http(200, error) }
        return reply
    }

    /// Completes pairing. The request is encrypted to the invite's server key
    /// and signed by the brand-new device key, so the token and the key never
    /// travel in the clear even inside the tailnet.
    public static func pair(invite: PairingInvite, deviceName: String, platform: String, signer: DeviceSigningKey, session: URLSession = makeSession()) async throws -> PairedServer {
        if invite.isExpired { throw RemoteClientError.inviteExpired }
        let request = PairRequest(token: invite.token, deviceName: deviceName, devicePublicKey: signer.publicKeyRaw, platform: platform)
        let body = try RemoteJSON.encoder.encode(request)
        let stub = PairedServer(host: invite.serverHost, port: invite.port, serverName: invite.serverName, serverPublicKey: invite.serverPublicKey, deviceId: "pairing", pairedAt: Date())
        let data = try await exchange(baseURL: stub.baseURL, path: pairPath, plaintext: body, serverPublicKey: invite.serverPublicKey, deviceId: "pairing", signer: signer, session: session)
        let response = try decode(PairResponse.self, data)
        return PairedServer(host: invite.serverHost, port: invite.port, serverName: response.serverName, serverPublicKey: invite.serverPublicKey, deviceId: response.deviceId, pairedAt: Date())
    }

    public static func info(host: String, port: Int, session: URLSession = makeSession()) async throws -> ServerInfo {
        let stub = PairedServer(host: host, port: port, serverName: "", serverPublicKey: Data(), deviceId: "", pairedAt: Date())
        var req = URLRequest(url: stub.baseURL.appendingPathComponent(infoPath))
        req.httpMethod = "GET"
        let (data, response) = try await perform(req, session: session)
        guard response.statusCode == 200 else { throw RemoteClientError.http(response.statusCode, "") }
        return try decode(ServerInfo.self, data)
    }

    // MARK: Internals

    static func exchange(baseURL: URL, path: String, plaintext: Data, serverPublicKey: Data, deviceId: String, signer: DeviceSigningKey, session: URLSession) async throws -> Data {
        let sealed: (request: SecureChannel.SealedRequest, responseKey: SymmetricKey)
        do {
            sealed = try SecureChannel.seal(plaintext: plaintext, serverPublicKeyRaw: serverPublicKey, deviceId: deviceId, signer: signer, method: "POST", path: path)
        } catch let e as SecureChannel.ChannelError {
            throw RemoteClientError.channel(e)
        }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("PlanMeterMobile/\(SecureChannel.protocolVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try RemoteJSON.encoder.encode(sealed.request)
        let (data, response) = try await perform(req, session: session)
        guard response.statusCode == 200 else {
            let message = (try? RemoteJSON.decoder.decode([String: String].self, from: data))?["error"] ?? ""
            throw RemoteClientError.http(response.statusCode, message)
        }
        let envelope = try decode(SecureChannel.SealedResponse.self, data)
        do {
            return try SecureChannel.openResponse(envelope, key: sealed.responseKey)
        } catch let e as SecureChannel.ChannelError {
            throw RemoteClientError.channel(e)
        }
    }

    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteClientError.malformedReply }
            return (data, http)
        } catch let e as RemoteClientError {
            throw e
        } catch {
            throw RemoteClientError.transport(error.localizedDescription)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try RemoteJSON.decoder.decode(type, from: data) } catch { throw RemoteClientError.malformedReply }
    }
}
