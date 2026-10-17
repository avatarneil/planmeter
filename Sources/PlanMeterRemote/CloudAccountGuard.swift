import CryptoKit
import Foundation

/// Remembers which iCloud account receives this Mac's uploads. CloudKit posts
/// account-change notifications for token refreshes and wake from sleep too, so
/// only a different account identifier should stop uploading.
public struct CloudAccountGuard {
    public enum Verdict: Equatable { case adopted, unchanged, changed }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "cloudSync.accountDigest") {
        self.defaults = defaults
        self.key = key
    }

    /// The first identifier seen after `reset()` is adopted; later ones must match.
    public func verify(_ identifier: String) -> Verdict {
        // Store a digest; the opaque record name never needs to be read back.
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let saved = defaults.string(forKey: key) else {
            defaults.set(digest, forKey: key)
            return .adopted
        }
        return saved == digest ? .unchanged : .changed
    }

    public func reset() { defaults.removeObject(forKey: key) }
}
