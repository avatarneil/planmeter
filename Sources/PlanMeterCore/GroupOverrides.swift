import Foundation

/// Personal/Work assignments the user made in the app, shared with the CLI and
/// MCP server through the app's preferences domain.
public enum GroupOverrides {
    public static let suiteName = "com.neilgoldader.planmeter"
    static let key = "planGroupOverrides"

    /// The app's own defaults when running inside the bundle, otherwise the
    /// app's domain opened by name (reading another process's plist is fine).
    public static func defaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    public static func load() -> [String: PlanGroup] {
        guard let raw = defaults().dictionary(forKey: key) as? [String: String] else { return [:] }
        return raw.compactMapValues(PlanGroup.init(rawValue:))
    }

    public static func save(_ overrides: [String: PlanGroup]) {
        let d = defaults()
        d.set(overrides.mapValues(\.rawValue), forKey: key)
        d.synchronize()
    }

    public static func group(for account: Account, overrides: [String: PlanGroup]) -> PlanGroup {
        overrides[account.id] ?? account.suggestedGroup
    }
}
