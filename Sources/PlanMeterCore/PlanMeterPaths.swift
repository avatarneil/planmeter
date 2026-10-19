import Foundation

/// Where PlanMeter keeps its own files. Provider homes (`~/.codex`, `~/.claude`,
/// T3 Code's settings) are discovered separately and never written.
///
/// On Apple platforms every kind resolves to `~/Library/Application Support/PlanMeter`,
/// where the app has always kept its files (`cacheDirectory` uses `~/Library/Caches`).
/// Elsewhere the XDG base directory spec applies:
///
/// | Kind   | Linux                                    | Holds                                              |
/// | ------ | ---------------------------------------- | -------------------------------------------------- |
/// | state  | `$XDG_STATE_HOME/planmeter` (`~/.local/state`) | scan cache, pricing cache, server key, paired devices |
/// | config | `$XDG_CONFIG_HOME/planmeter` (`~/.config`)     | host configuration                                 |
/// | cache  | `$XDG_CACHE_HOME/planmeter` (`~/.cache`)       | disposable downloads                               |
public enum PlanMeterPaths {
    /// The user's home directory. On Linux this honors `$HOME`, as do the agents
    /// whose files PlanMeter reads (Node's `os.homedir()`, Rust's `home_dir()`);
    /// Foundation there reads the password database instead. Apple platforms
    /// keep `NSHomeDirectory()`.
    public static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if canImport(Darwin)
        return NSHomeDirectory()
        #else
        if let home = environment["HOME"], home.hasPrefix("/") { return home }
        return NSHomeDirectory()
        #endif
    }

    /// Durable state: the scan cache, pricing cache, and remote-access keys.
    public static func stateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if canImport(Darwin)
        return appleSupportDirectory()
        #else
        return xdgDirectory("XDG_STATE_HOME", fallback: ".local/state", environment: environment, home: homeDirectory(environment: environment))
        #endif
    }

    /// Configuration a person might edit or back up.
    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if canImport(Darwin)
        return appleSupportDirectory()
        #else
        return xdgDirectory("XDG_CONFIG_HOME", fallback: ".config", environment: environment, home: homeDirectory(environment: environment))
        #endif
    }

    /// Files that may be deleted at any time and rebuilt.
    public static func cacheDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if canImport(Darwin)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("PlanMeter", isDirectory: true)
        #else
        return xdgDirectory("XDG_CACHE_HOME", fallback: ".cache", environment: environment, home: homeDirectory(environment: environment))
        #endif
    }

    /// `$VARIABLE/planmeter`, or `<home>/<fallback>/planmeter` when the variable
    /// is unset, empty, or relative (the spec says relative values are invalid).
    static func xdgDirectory(_ variable: String, fallback: String, environment: [String: String], home: String) -> URL {
        let base: String
        if let value = environment[variable], value.hasPrefix("/") {
            base = value
        } else {
            base = (home as NSString).appendingPathComponent(fallback)
        }
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("planmeter", isDirectory: true)
    }

    #if canImport(Darwin)
    private static func appleSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlanMeter", isDirectory: true)
    }
    #endif
}

/// The app's original name for `PlanMeterPaths.stateDirectory()`.
public enum AppPaths {
    public static func supportDirectory() -> URL {
        PlanMeterPaths.stateDirectory()
    }
}
