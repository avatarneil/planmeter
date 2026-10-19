import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit cache locations, for hosts that keep their own state directory
/// (`planmeterd`) instead of the app's Application Support folder.
extension PricingLoader {
    /// The freshest of T3 Code's pricing cache and the cache at `appCachePath`.
    public static func loadCached(appCachePath: String) -> RateTable? {
        loadCached(t3Path: t3CachePath(), appPath: appCachePath)
    }

    /// Fetches LiteLLM pricing and, once validated, writes it to `cacheURL`.
    public static func fetch(cacheURL: URL) async throws -> RateTable {
        try await fetch(session: .shared, cacheURL: cacheURL)
    }
}
