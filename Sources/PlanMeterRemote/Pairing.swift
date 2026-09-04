import CryptoKit
import Foundation

/// What the QR code carries: where the server is, its public key (so the phone
/// pins it), and a single-use token that expires in minutes.
public struct PairingInvite: Codable, Equatable, Sendable {
    public static let scheme = "planmeter"
    public static let host = "pair"

    public var serverHost: String
    public var port: Int
    public var serverName: String
    public var serverPublicKey: Data
    public var token: String
    public var expiresAt: Date

    public init(serverHost: String, port: Int, serverName: String, serverPublicKey: Data, token: String, expiresAt: Date) {
        self.serverHost = serverHost
        self.port = port
        self.serverName = serverName
        self.serverPublicKey = serverPublicKey
        self.token = token
        self.expiresAt = expiresAt
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = Self.host
        c.queryItems = [
            URLQueryItem(name: "h", value: serverHost),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "n", value: serverName),
            URLQueryItem(name: "k", value: serverPublicKey.base64URLEncodedString()),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "e", value: String(Int64(expiresAt.timeIntervalSince1970))),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var map: [String: String] = [:]
        for item in items { map[item.name] = item.value }
        guard let h = map["h"], !h.isEmpty,
              let p = map["p"], let port = Int(p), (1...65535).contains(port),
              let k = map["k"], let key = Data(base64URLEncoded: k), key.count == 65,
              let t = map["t"], !t.isEmpty,
              let e = map["e"], let exp = Int64(e) else { return nil }
        serverHost = h
        self.port = port
        serverName = map["n"] ?? h
        serverPublicKey = key
        token = t
        expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
    }

    public var isExpired: Bool { Date() > expiresAt }

    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64URLEncodedString()
    }
}

public struct PairRequest: Codable, Equatable, Sendable {
    public var token: String
    public var deviceName: String
    public var devicePublicKey: Data
    public var platform: String

    public init(token: String, deviceName: String, devicePublicKey: Data, platform: String) {
        self.token = token
        self.deviceName = deviceName
        self.devicePublicKey = devicePublicKey
        self.platform = platform
    }
}

public struct PairResponse: Codable, Equatable, Sendable {
    public var deviceId: String
    public var serverName: String
    public var serverVersion: String

    public init(deviceId: String, serverName: String, serverVersion: String) {
        self.deviceId = deviceId
        self.serverName = serverName
        self.serverVersion = serverVersion
    }
}

/// What the phone keeps after pairing.
public struct PairedServer: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var serverName: String
    public var serverPublicKey: Data
    public var deviceId: String
    public var pairedAt: Date

    public init(host: String, port: Int, serverName: String, serverPublicKey: Data, deviceId: String, pairedAt: Date) {
        self.host = host
        self.port = port
        self.serverName = serverName
        self.serverPublicKey = serverPublicKey
        self.deviceId = deviceId
        self.pairedAt = pairedAt
    }

    public var baseURL: URL {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)")!
    }
}

/// What the Mac keeps per paired phone.
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var publicKey: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var requestCount: Int

    public init(id: String, name: String, platform: String, publicKey: Data, pairedAt: Date, lastSeenAt: Date? = nil, requestCount: Int = 0) {
        self.id = id
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.requestCount = requestCount
    }
}

public enum DeviceId {
    /// Stable id derived from the device's public key.
    public static func derive(fromPublicKey key: Data) -> String {
        Data(SHA256.hash(data: key)).base64URLEncodedString().prefix(22).description
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
