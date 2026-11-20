import Foundation
#if os(macOS)
import CommonCrypto
import Security
#endif

/// Cursor 3.x encrypts `cursorAuth/accessToken` in `state.vscdb` with Electron's
/// `safeStorage` and saves it as `cursor-safe-storage:v1:<base64>`. On macOS the
/// blob is Chromium's OSCrypt format: `v10`, then AES-128-CBC with a key derived
/// by PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds) from the password Cursor
/// keeps in the login Keychain as "Cursor Safe Storage", and an IV of 16 spaces.
///
/// The token is decrypted in memory for each request, exactly like a plaintext
/// one, and is never copied or written. Only the derived key is kept, for the life
/// of the process. macOS asks for Keychain access once per app if you choose
/// Always Allow; PlanMeter explains why before it does.
public enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:"
    static let v1Prefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"
    static let keychainAccount = "Cursor"

    /// How this process may get the Keychain key when macOS would have to ask.
    public enum KeychainAccess: Sendable {
        /// Explain on standard error, then let macOS ask (the CLI).
        case prompt
        /// Never ask in the background; record that access is needed so the
        /// app can explain why first and then call `requestAccess()`.
        case askFirst
        /// Never ask (the MCP server: an agent's request must not stall on a dialog).
        case never
    }

    /// Why PlanMeter wants the key, shown before macOS asks.
    public static let accessExplanation = """
        Cursor now encrypts the login it saves on this Mac and keeps the key in your login Keychain as \
        "Cursor Safe Storage". PlanMeter needs that key to decrypt the login and read your Cursor usage \
        and plan limits from cursor.com.

        The login is decrypted only in memory and sent only to cursor.com. PlanMeter never saves, copies, \
        or changes it, and reads nothing else from your Keychain.
        """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var access: KeychainAccess = .prompt
    nonisolated(unsafe) private static var approvalNeeded = false
    nonisolated(unsafe) private static var notice: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var cachedKey: Data?
    nonisolated(unsafe) private static var cachedFailure: CursorError?

    public static var keychainAccess: KeychainAccess {
        get { lock.lock(); defer { lock.unlock() }; return access }
        set { lock.lock(); defer { lock.unlock() }; access = newValue }
    }

    /// Runs just before macOS shows its Keychain dialog in `.prompt` mode.
    public static var promptNotice: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return notice }
        set { lock.lock(); defer { lock.unlock() }; notice = newValue }
    }

    /// In `.askFirst` mode: a login needed the key and macOS would have asked.
    public static var needsApproval: Bool {
        lock.lock(); defer { lock.unlock() }
        return approvalNeeded
    }

    /// Asks macOS for the key now, after the host has explained why. Blocks
    /// while the dialog is open, so call it off the main thread. Returns the
    /// reason on failure.
    public static func requestAccess() -> String? {
        #if os(macOS)
        lock.lock()
        defer { lock.unlock() }
        if cachedKey != nil { return nil }
        do {
            try store(password: try keychainPassword(interactive: true))
            return nil
        } catch {
            return ((error as? CursorError) ?? .keychainDenied).message
        }
        #else
        return CursorError.encrypted.message
        #endif
    }

    static func isEncrypted(_ value: String) -> Bool { value.hasPrefix(prefix) }

    /// Decrypts a saved `cursor-safe-storage:` value with the Keychain key.
    static func decrypt(_ value: String) throws -> String {
        #if os(macOS)
        let ciphertext = try ciphertext(value)
        return try decrypt(ciphertext: ciphertext, key: try key())
        #else
        throw CursorError.encrypted
        #endif
    }

    #if os(macOS)
    /// Checks the saved value's shape before anything asks the Keychain.
    static func ciphertext(_ value: String) throws -> Data {
        guard value.hasPrefix(v1Prefix) else { throw CursorError.encrypted }
        guard value.utf8.count <= 16_384,
              let blob = Data(base64Encoded: String(value.dropFirst(v1Prefix.count))) else { throw CursorError.unreadable }
        // Chromium marks the scheme with a version tag; `v10` is the Keychain one.
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { throw CursorError.encrypted }
        let ciphertext = Data(blob.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { throw CursorError.unreadable }
        return ciphertext
    }

    static func decrypt(_ value: String, key: Data) throws -> String {
        try decrypt(ciphertext: try ciphertext(value), key: key)
    }

    private static func decrypt(ciphertext: Data, key: Data) throws -> String {
        guard let plain = try crypt(CCOperation(kCCDecrypt), ciphertext, key: key),
              let text = String(data: plain, encoding: .utf8) else {
            // A wrong key fails the padding check or yields bytes that aren't text.
            throw CursorError.unreadable
        }
        return text
    }

    /// The `v1` value Cursor would save for `token`; used by tests.
    static func encrypt(_ token: String, key: Data) throws -> String {
        guard let sealed = try crypt(CCOperation(kCCEncrypt), Data(token.utf8), key: key) else { throw CursorError.unreadable }
        return v1Prefix + (Data("v10".utf8) + sealed).base64EncodedString()
    }

    static func deriveKey(password: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) throws -> Data? {
        guard key.count == kCCKeySizeAES128 else { throw CursorError.unreadable }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, outBytes.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    /// The derived key, reading the Keychain the first time. It is read
    /// silently first: macOS asks only when this app has no access yet, and
    /// only `.prompt` lets it ask from here.
    private static func key() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        if let cachedFailure { throw cachedFailure }
        do {
            let password: Data
            do {
                password = try keychainPassword(interactive: false)
            } catch CursorError.keychainUnavailable {
                switch access {
                case .never: throw CursorError.keychainUnavailable
                case .askFirst:
                    approvalNeeded = true
                    throw CursorError.keychainNeedsApproval
                case .prompt:
                    notice?()
                    password = try keychainPassword(interactive: true)
                }
            }
            return try store(password: password)
        } catch let error as CursorError {
            // One answer per CLI run; the app asks again from its button.
            if access == .prompt, error == .keychainDenied { cachedFailure = error }
            throw error
        }
    }

    @discardableResult
    private static func store(password: Data) throws -> Data {
        guard let key = deriveKey(password: password) else { throw CursorError.unreadable }
        cachedKey = key
        approvalNeeded = false
        return key
    }

    private static func keychainPassword(interactive: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Cursor's item is in the file-based login keychain, whose "allow
        // access" dialog only this process-wide switch can suppress.
        let legacy = LegacyKeychain.self as LegacyKeychainInteraction.Type
        legacy.setUserInteractionAllowed(interactive)
        defer { legacy.setUserInteractionAllowed(true) }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { throw CursorError.unreadable }
            return data
        case errSecItemNotFound: throw CursorError.keychainMissing
        // With the dialog suppressed, an app that hasn't been allowed yet gets
        // errSecAuthFailed at once rather than errSecInteractionNotAllowed.
        case errSecInteractionNotAllowed, errSecAuthFailed where !interactive: throw CursorError.keychainUnavailable
        default: throw CursorError.keychainDenied
        }
    }
    #endif
}

#if os(macOS)
// Through a protocol so the deprecated call doesn't warn on every build.
private protocol LegacyKeychainInteraction { static func setUserInteractionAllowed(_ allowed: Bool) }
private enum LegacyKeychain: LegacyKeychainInteraction {
    @available(macOS, deprecated: 10.10)
    static func setUserInteractionAllowed(_ allowed: Bool) { SecKeychainSetUserInteractionAllowed(allowed) }
}
#endif
