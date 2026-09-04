import CryptoKit
import Foundation
import Security

/// The phone's long-lived identity: a P-256 signing key. Lives in the Secure
/// Enclave when the hardware has one, so the private half never exists in
/// memory the app can read.
public protocol DeviceSigningKey: Sendable {
    /// X9.63 uncompressed public point (65 bytes).
    var publicKeyRaw: Data { get }
    func sign(_ message: Data) throws -> Data
}

/// The Mac's long-lived identity: a P-256 key-agreement key. Requests are
/// encrypted to it; only the holder can derive the response key.
public protocol ServerAgreementKey: Sendable {
    var publicKeyRaw: Data { get }
    func sharedSecret(withPublicKeyRaw raw: Data) throws -> SharedSecret
}

public enum KeyError: Error, LocalizedError {
    case enclaveUnavailable
    case malformedKey
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .enclaveUnavailable: return "Secure Enclave is not available on this device."
        case .malformedKey: return "Stored key material is malformed."
        case .storage(let s): return s
        }
    }
}

/// Serialized private key. `enclave` blobs are wrapped by the Secure Enclave
/// and are useless on any other device.
public enum KeyBlob: Codable, Equatable, Sendable {
    case software(Data)
    case enclave(Data)
}

// MARK: - Signing

public struct SoftwareSigningKey: DeviceSigningKey {
    let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws {
        do { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) } catch { throw KeyError.malformedKey }
    }

    public var publicKeyRaw: Data { key.publicKey.x963Representation }
    public var blob: KeyBlob { .software(key.rawRepresentation) }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

public struct EnclaveSigningKey: DeviceSigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    public init() throws {
        guard SecureEnclave.isAvailable else { throw KeyError.enclaveUnavailable }
        key = try SecureEnclave.P256.Signing.PrivateKey()
    }
    public init(dataRepresentation: Data) throws {
        guard SecureEnclave.isAvailable else { throw KeyError.enclaveUnavailable }
        do { key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation) } catch { throw KeyError.malformedKey }
    }

    public var publicKeyRaw: Data { key.publicKey.x963Representation }
    public var blob: KeyBlob { .enclave(key.dataRepresentation) }
    public func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

public enum SigningKeys {
    /// Prefers the Secure Enclave; falls back to a software key (simulators,
    /// Intel Macs without a T2).
    public static func make() -> (key: DeviceSigningKey, blob: KeyBlob) {
        if let enclave = try? EnclaveSigningKey() { return (enclave, enclave.blob) }
        let soft = SoftwareSigningKey()
        return (soft, soft.blob)
    }

    public static func load(_ blob: KeyBlob) throws -> DeviceSigningKey {
        switch blob {
        case .software(let raw): return try SoftwareSigningKey(rawRepresentation: raw)
        case .enclave(let data): return try EnclaveSigningKey(dataRepresentation: data)
        }
    }

    public static func verify(signature: Data, for message: Data, publicKeyRaw: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyRaw),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }
}

// MARK: - Key agreement

public struct SoftwareAgreementKey: ServerAgreementKey {
    let key: P256.KeyAgreement.PrivateKey

    public init() { key = P256.KeyAgreement.PrivateKey() }
    public init(rawRepresentation: Data) throws {
        do { key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation) } catch { throw KeyError.malformedKey }
    }

    public var publicKeyRaw: Data { key.publicKey.x963Representation }
    public var blob: KeyBlob { .software(key.rawRepresentation) }
    public func sharedSecret(withPublicKeyRaw raw: Data) throws -> SharedSecret {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        return try key.sharedSecretFromKeyAgreement(with: peer)
    }
}

public struct EnclaveAgreementKey: ServerAgreementKey {
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey

    public init() throws {
        guard SecureEnclave.isAvailable else { throw KeyError.enclaveUnavailable }
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
    }
    public init(dataRepresentation: Data) throws {
        guard SecureEnclave.isAvailable else { throw KeyError.enclaveUnavailable }
        do { key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: dataRepresentation) } catch { throw KeyError.malformedKey }
    }

    public var publicKeyRaw: Data { key.publicKey.x963Representation }
    public var blob: KeyBlob { .enclave(key.dataRepresentation) }
    public func sharedSecret(withPublicKeyRaw raw: Data) throws -> SharedSecret {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        return try key.sharedSecretFromKeyAgreement(with: peer)
    }
}

public enum AgreementKeys {
    public static func make() -> (key: ServerAgreementKey, blob: KeyBlob) {
        if let enclave = try? EnclaveAgreementKey() { return (enclave, enclave.blob) }
        let soft = SoftwareAgreementKey()
        return (soft, soft.blob)
    }

    public static func load(_ blob: KeyBlob) throws -> ServerAgreementKey {
        switch blob {
        case .software(let raw): return try SoftwareAgreementKey(rawRepresentation: raw)
        case .enclave(let data): return try EnclaveAgreementKey(dataRepresentation: data)
        }
    }
}

// MARK: - Secret storage

/// Where a key blob or paired-server record lives. The Mac uses a 0600 file in
/// Application Support (ad-hoc signatures make keychain ACL prompts noisy);
/// iOS uses the keychain, this-device-only.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ data: Data) throws
    func delete(_ key: String) throws
}

public struct FileSecretStore: SecretStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    func url(_ key: String) -> URL { directory.appendingPathComponent(key) }

    public func read(_ key: String) throws -> Data? {
        let u = url(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ key: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url(key), options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
    }

    public func delete(_ key: String) throws {
        let u = url(key)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyError.storage("keychain read failed (\(status))") }
        return out as? Data
    }

    public func write(_ key: String, _ data: Data) throws {
        try delete(key)
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.storage("keychain write failed (\(status))") }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError.storage("keychain delete failed (\(status))") }
    }
}

public extension SecretStore {
    func readCodable<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let data = try read(key) else { return nil }
        return try RemoteJSON.decoder.decode(type, from: data)
    }

    func writeCodable<T: Encodable>(_ value: T, _ key: String) throws {
        try write(key, try RemoteJSON.encoder.encode(value))
    }
}
