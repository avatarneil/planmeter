import Foundation
import PlanMeterCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where `planmeterd` keeps its files.
///
/// Linux follows XDG through `PlanMeterPaths`: settings in
/// `$XDG_CONFIG_HOME/planmeter` (default `~/.config/planmeter`); scan cache,
/// pricing cache, paired devices, and the server key in
/// `$XDG_STATE_HOME/planmeter` (default `~/.local/state/planmeter`), the same
/// state directory the CLI and MCP server use.
/// On macOS the daemon is a development tool and uses its own folder,
/// `~/Library/Application Support/PlanMeter/planmeterd`, so it never shares
/// state with the Mac app.
public struct HostPaths: Sendable, Equatable {
    public var configDirectory: URL
    public var stateDirectory: URL

    public init(configDirectory: URL, stateDirectory: URL) {
        self.configDirectory = configDirectory
        self.stateDirectory = stateDirectory
    }

    public var settingsFile: URL { configDirectory.appendingPathComponent("settings.json") }
    public var remoteDirectory: URL { stateDirectory.appendingPathComponent("remote", isDirectory: true) }
    public var scanCacheFile: URL { stateDirectory.appendingPathComponent("scan-cache.json") }
    public var pricingCacheFile: URL { stateDirectory.appendingPathComponent("model-rates.json") }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> HostPaths {
        #if os(macOS)
        let base = URL(fileURLWithPath: PlanMeterPaths.homeDirectory(environment: environment))
            .appendingPathComponent("Library/Application Support/PlanMeter/planmeterd", isDirectory: true)
        return HostPaths(configDirectory: base, stateDirectory: base)
        #else
        return HostPaths(configDirectory: PlanMeterPaths.configDirectory(environment: environment),
                         stateDirectory: PlanMeterPaths.stateDirectory(environment: environment))
        #endif
    }

    /// The control socket, first match wins: `$PLANMETER_CONTROL_SOCKET`,
    /// `$XDG_RUNTIME_DIR/planmeter/control.sock`, `/tmp/planmeter-$UID/control.sock`.
    /// `isDefault` is false for an explicitly configured path.
    public static func controlSocket(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     uid: UInt32 = UInt32(getuid())) -> (path: String, isDefault: Bool) {
        if let explicit = environment["PLANMETER_CONTROL_SOCKET"], !explicit.isEmpty {
            return (explicit, false)
        }
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            return (URL(fileURLWithPath: runtime).appendingPathComponent("planmeter/control.sock").path, true)
        }
        return ("/tmp/planmeter-\(uid)/control.sock", true)
    }

    public enum DirectoryError: Error, LocalizedError, Equatable {
        case notADirectory(String)
        case symbolicLink(String)
        case foreignOwner(String)
        case notPrivate(String)
        case create(String, String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "\(p) exists and is not a directory"
            case .symbolicLink(let p): return "\(p) is a symbolic link; refusing to use it"
            case .foreignOwner(let p): return "\(p) belongs to another user; refusing to use it"
            case .notPrivate(let p): return "\(p) is accessible to other users and could not be made private"
            case .create(let p, let reason): return "Could not create \(p): \(reason)"
            }
        }
    }

    /// Creates a private (0700) directory, or checks an existing one belongs
    /// to this user.
    ///
    /// With `tighten` (the control socket and the secret store) the result
    /// must be a real directory, not a symbolic link, owned by this user and
    /// closed to everyone else; an existing one is reset to 0700. The
    /// directory is made with `mkdir` and then inspected, never inspected
    /// first, so another user cannot slip one in between (say in /tmp).
    /// Without it (settings and state, where dotfile managers symlink
    /// freely) an existing directory only has to be ours.
    public static func preparePrivateDirectory(_ path: String, tighten: Bool) throws {
        if mkdir(path, 0o700) != 0 {
            var code = errno
            if code == ENOENT {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                do {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } catch {
                    throw DirectoryError.create(path, error.localizedDescription)
                }
                code = mkdir(path, 0o700) == 0 ? 0 : errno
            }
            guard code == 0 || code == EEXIST else { throw DirectoryError.create(path, String(cString: strerror(code))) }
        }
        var st = stat()
        guard (tighten ? lstat(path, &st) : stat(path, &st)) == 0 else { throw DirectoryError.create(path, "vanished after creation") }
        if tighten && isType(st.st_mode, S_IFLNK) { throw DirectoryError.symbolicLink(path) }
        guard isType(st.st_mode, S_IFDIR) else { throw DirectoryError.notADirectory(path) }
        guard st.st_uid == geteuid() else { throw DirectoryError.foreignOwner(path) }
        guard tighten, (UInt32(st.st_mode) & 0o077) != 0 else { return }
        // Ours and not a link, so nobody else can swap it out from under the
        // chmod; check the result anyway.
        guard chmod(path, 0o700) == 0, lstat(path, &st) == 0, isType(st.st_mode, S_IFDIR),
              st.st_uid == geteuid(), (UInt32(st.st_mode) & 0o077) == 0 else {
            throw DirectoryError.notPrivate(path)
        }
    }

    private static func isType<T: BinaryInteger>(_ mode: mode_t, _ type: T) -> Bool {
        (UInt32(mode) & UInt32(S_IFMT)) == UInt32(type)
    }

    /// Readies the directory holding the control socket. Default locations
    /// are ours alone: created 0700, or tightened to 0700, and refused when
    /// another user owns them (someone could otherwise plant a socket for the
    /// desktop app to talk to). An explicit path may live in a shared sticky
    /// directory such as /tmp, where only we can replace our own socket.
    public static func prepareSocketDirectory(for socketPath: String, isDefault: Bool) throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        var st = stat()
        if !isDefault, stat(parent, &st) == 0, st.st_uid != geteuid() {
            let sticky = (UInt32(st.st_mode) & UInt32(S_ISVTX)) != 0
            guard st.st_uid == 0, sticky else { throw DirectoryError.foreignOwner(parent) }
            return
        }
        try preparePrivateDirectory(parent, tighten: isDefault)
    }
}
