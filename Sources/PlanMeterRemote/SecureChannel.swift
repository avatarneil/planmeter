import CryptoKit
import Foundation

/// End-to-end encryption and proof-of-possession for one request/response,
/// layered on top of whatever transport carries it (Tailscale WireGuard here).
///
/// Request: the client makes a fresh ephemeral P-256 key, agrees a shared
/// secret with the server's static public key, derives request and response
/// keys with HKDF (salted by a random nonce, labelled by direction), seals the
/// body with an AEAD using the request header as additional data, then signs
/// header + hash of ciphertext with its device key. The server verifies the
/// signature against the paired key, checks the clock window and nonce,
/// decrypts, and answers under the response key. Each request has its own
/// ephemeral key, so recorded traffic cannot be decrypted later even if a
/// static key leaks.
///
/// The AEAD is negotiated per request: native clients use ChaCha20-Poly1305,
/// browsers use AES-256-GCM because WebCrypto has no ChaCha. Both use a
/// 12-byte nonce and the `nonce || ciphertext || tag` combined layout.
public enum SecureChannel {
    public static let protocolVersion = 1
    static let label = "planmeter-remote-v1"
    public static let maxClockSkew: TimeInterval = 120
    public static let nonceLength = 12

    public enum Cipher: String, Codable, Equatable, Sendable {
        case chacha20poly1305 = "chacha20poly1305"
        case aes256gcm = "aes-256-gcm"
    }

    public struct SealedRequest: Codable, Equatable, Sendable {
        public var v: Int
        public var deviceId: String
        public var ephemeralPublicKey: Data
        public var nonce: Data
        public var timestamp: Int64
        public var ciphertext: Data
        public var signature: Data
        public var cipher: Cipher?

        public var effectiveCipher: Cipher { cipher ?? .chacha20poly1305 }
    }

    public struct SealedResponse: Codable, Equatable, Sendable {
        public var nonce: Data
        public var ciphertext: Data
        public var cipher: Cipher?

        public var effectiveCipher: Cipher { cipher ?? .chacha20poly1305 }
    }

    public enum ChannelError: Error, LocalizedError, Equatable {
        case unsupportedVersion
        case timeWindow
        case badSignature
        case replay
        case decryptFailed
        case malformed
        case unknownDevice

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "Unsupported protocol version."
            case .timeWindow: return "Request timestamp outside the allowed window."
            case .badSignature: return "Device signature did not verify."
            case .replay: return "Nonce already seen."
            case .decryptFailed: return "Could not decrypt payload."
            case .malformed: return "Malformed envelope."
            case .unknownDevice: return "Device is not paired."
            }
        }
    }

    public struct Opened: Sendable {
        public var plaintext: Data
        public var responseKey: SymmetricKey
        public var cipher: Cipher
    }

    // MARK: Key derivation

    struct DerivedKeys {
        var request: SymmetricKey
        var response: SymmetricKey
    }

    static func derive(_ secret: SharedSecret, nonce: Data, deviceId: String) -> DerivedKeys {
        func key(_ direction: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: nonce,
                sharedInfo: Data("\(label)|\(deviceId)|\(direction)".utf8),
                outputByteCount: 32
            )
        }
        return DerivedKeys(request: key("request"), response: key("response"))
    }

    /// Bytes bound into both the AEAD (as additional data) and the signature.
    /// Mirrored byte-for-byte by the web client.
    static func header(deviceId: String, ephemeral: Data, nonce: Data, timestamp: Int64, method: String, path: String, cipher: Cipher) -> Data {
        Data("\(label)\n\(method.uppercased())\n\(path)\n\(deviceId)\n\(timestamp)\n\(nonce.base64EncodedString())\n\(ephemeral.base64EncodedString())\n\(cipher.rawValue)\n".utf8)
    }

    static func signingInput(header: Data, ciphertext: Data) -> Data {
        header + Data(SHA256.hash(data: ciphertext))
    }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    // MARK: AEAD

    static func aeadSeal(_ plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data, cipher: Cipher) throws -> Data {
        switch cipher {
        case .chacha20poly1305:
            return try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad).combined
        case .aes256gcm:
            guard let combined = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad).combined else {
                throw ChannelError.malformed
            }
            return combined
        }
    }

    static func aeadOpen(_ combined: Data, key: SymmetricKey, aad: Data, cipher: Cipher) throws -> Data {
        do {
            switch cipher {
            case .chacha20poly1305:
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: key, authenticating: aad)
            case .aes256gcm:
                return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
            }
        } catch {
            throw ChannelError.decryptFailed
        }
    }

    // MARK: Client side

    public static func seal(plaintext: Data, serverPublicKeyRaw: Data, deviceId: String, signer: DeviceSigningKey, method: String, path: String, cipher: Cipher = .chacha20poly1305, now: Date = Date()) throws -> (request: SealedRequest, responseKey: SymmetricKey) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let serverKey = try P256.KeyAgreement.PublicKey(x963Representation: serverPublicKeyRaw)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: serverKey)
        let nonce = randomNonce()
        let timestamp = Int64(now.timeIntervalSince1970)
        let ephemeralRaw = ephemeral.publicKey.x963Representation
        let keys = derive(secret, nonce: nonce, deviceId: deviceId)
        let hdr = header(deviceId: deviceId, ephemeral: ephemeralRaw, nonce: nonce, timestamp: timestamp, method: method, path: path, cipher: cipher)
        let ciphertext = try aeadSeal(plaintext, key: keys.request, nonce: nonce, aad: hdr, cipher: cipher)
        let signature = try signer.sign(signingInput(header: hdr, ciphertext: ciphertext))
        return (SealedRequest(v: protocolVersion, deviceId: deviceId, ephemeralPublicKey: ephemeralRaw, nonce: nonce, timestamp: timestamp, ciphertext: ciphertext, signature: signature, cipher: cipher), keys.response)
    }

    public static func openResponse(_ response: SealedResponse, key: SymmetricKey) throws -> Data {
        guard response.nonce.count == nonceLength else { throw ChannelError.malformed }
        return try aeadOpen(response.ciphertext, key: key, aad: response.nonce, cipher: response.effectiveCipher)
    }

    // MARK: Server side

    /// Verifies the proof-of-possession signature. `publicKeyRaw` is the paired
    /// device key, or for pairing the key carried inside the decrypted body.
    public static func verifySignature(_ request: SealedRequest, devicePublicKeyRaw: Data, method: String, path: String) -> Bool {
        let hdr = header(deviceId: request.deviceId, ephemeral: request.ephemeralPublicKey, nonce: request.nonce, timestamp: request.timestamp, method: method, path: path, cipher: request.effectiveCipher)
        return SigningKeys.verify(signature: request.signature, for: signingInput(header: hdr, ciphertext: request.ciphertext), publicKeyRaw: devicePublicKeyRaw)
    }

    public static func checkTimestamp(_ request: SealedRequest, now: Date = Date()) throws {
        guard request.v == protocolVersion else { throw ChannelError.unsupportedVersion }
        guard request.nonce.count == nonceLength, request.ephemeralPublicKey.count == 65 else { throw ChannelError.malformed }
        let skew = abs(Double(request.timestamp) - now.timeIntervalSince1970)
        guard skew <= maxClockSkew else { throw ChannelError.timeWindow }
    }

    /// Decrypts without verifying the signature; callers verify first (paired
    /// device) or afterwards against a key found in the plaintext (pairing).
    public static func open(_ request: SealedRequest, serverKey: ServerAgreementKey, method: String, path: String) throws -> Opened {
        let secret = try serverKey.sharedSecret(withPublicKeyRaw: request.ephemeralPublicKey)
        let keys = derive(secret, nonce: request.nonce, deviceId: request.deviceId)
        let cipher = request.effectiveCipher
        let hdr = header(deviceId: request.deviceId, ephemeral: request.ephemeralPublicKey, nonce: request.nonce, timestamp: request.timestamp, method: method, path: path, cipher: cipher)
        let plaintext = try aeadOpen(request.ciphertext, key: keys.request, aad: hdr, cipher: cipher)
        return Opened(plaintext: plaintext, responseKey: keys.response, cipher: cipher)
    }

    public static func sealResponse(plaintext: Data, key: SymmetricKey, cipher: Cipher = .chacha20poly1305) throws -> SealedResponse {
        let nonce = randomNonce()
        let combined = try aeadSeal(plaintext, key: key, nonce: nonce, aad: nonce, cipher: cipher)
        return SealedResponse(nonce: nonce, ciphertext: combined, cipher: cipher)
    }
}

/// Remembers (device, nonce) pairs for the clock window so a captured request
/// cannot be replayed. Thread-safe; prunes on insert.
public final class ReplayCache: @unchecked Sendable {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = SecureChannel.maxClockSkew * 2 + 5) { self.ttl = ttl }

    /// Returns false when the nonce was already recorded.
    public func record(deviceId: String, nonce: Data, now: Date = Date()) -> Bool {
        let key = "\(deviceId):\(nonce.base64EncodedString())"
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value) < ttl }
        if seen[key] != nil { return false }
        seen[key] = now
        return true
    }
}

public extension Data {
    /// Constant-time equality for secrets such as pairing tokens.
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self, other) { diff |= a ^ b }
        return diff == 0
    }
}
