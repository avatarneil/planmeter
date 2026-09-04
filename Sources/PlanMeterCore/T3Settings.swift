import Foundation

/// A provider instance as configured in T3 Code's `settings.json`.
public struct T3ProviderInstance: Hashable, Sendable {
    public var id: String
    public var driver: String
    public var displayName: String?
    public var accentColorHex: String?
    public var enabled: Bool
    public var homePath: String?
    public var shadowHomePath: String?

    public init(id: String, driver: String, displayName: String? = nil, accentColorHex: String? = nil, enabled: Bool = true, homePath: String? = nil, shadowHomePath: String? = nil) {
        self.id = id
        self.driver = driver
        self.displayName = displayName
        self.accentColorHex = accentColorHex
        self.enabled = enabled
        self.homePath = homePath
        self.shadowHomePath = shadowHomePath
    }

    /// The default slot for a driver has the driver kind as its id.
    public var isDefaultForDriver: Bool { id == driver }
}

public struct T3Settings: Sendable {
    public var instances: [T3ProviderInstance]
    public var settingsPath: URL

    public static let builtInDrivers = ["codex", "claudeAgent", "cursor", "grok", "opencode", "antigravity"]

    public static func defaultHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["T3CODE_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: PathUtil.expand(env))
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
    }

    public static func defaultSettingsURL() -> URL {
        defaultHome().appendingPathComponent("userdata/settings.json")
    }

    /// Reads `settings.json`, merging legacy `providers` entries into
    /// synthesized default instances the way the T3 server does.
    public static func load(from url: URL = defaultSettingsURL()) -> T3Settings? {
        guard let data = try? Data(contentsOf: url), let root = JSON.object(data) else { return nil }
        var instances: [T3ProviderInstance] = []

        if let raw = JSON.object(root["providerInstances"]) {
            for (id, value) in raw {
                guard let entry = JSON.object(value), let driver = JSON.string(entry["driver"]) else { continue }
                let config = JSON.object(entry["config"]) ?? [:]
                instances.append(T3ProviderInstance(
                    id: id,
                    driver: driver,
                    displayName: JSON.string(entry["displayName"]),
                    accentColorHex: JSON.string(entry["accentColor"]),
                    enabled: JSON.bool(entry["enabled"]) ?? true,
                    homePath: JSON.string(config["homePath"]),
                    shadowHomePath: JSON.string(config["shadowHomePath"])
                ))
            }
        }

        let legacy = JSON.object(root["providers"]) ?? [:]
        for driver in builtInDrivers where !instances.contains(where: { $0.id == driver }) {
            guard let entry = JSON.object(legacy[driver]) else { continue }
            instances.append(T3ProviderInstance(
                id: driver,
                driver: driver,
                enabled: JSON.bool(entry["enabled"]) ?? true,
                homePath: JSON.string(entry["homePath"]),
                shadowHomePath: JSON.string(entry["shadowHomePath"])
            ))
        }

        // Preserve T3's presentation order: settings key order is lost through
        // the dictionary, so fall back to driver order, default slot first.
        instances.sort { a, b in
            let ai = builtInDrivers.firstIndex(of: a.driver) ?? builtInDrivers.count
            let bi = builtInDrivers.firstIndex(of: b.driver) ?? builtInDrivers.count
            if ai != bi { return ai < bi }
            if a.isDefaultForDriver != b.isDefaultForDriver { return a.isDefaultForDriver }
            return a.id < b.id
        }
        return T3Settings(instances: instances, settingsPath: url)
    }
}

public enum PathUtil {
    public static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + trimmed.dropFirst(1)
        }
        return (trimmed as NSString).standardizingPath
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
