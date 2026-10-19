import Foundation
import PlanMeterCore
import PlanMeterHost
import PlanMeterRemote
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main
enum PlanMeterDaemon {
    @MainActor
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("planmeterd: \(error)\n\nRun planmeterd --help for usage.\n".utf8))
            exit(64)
        }
        switch options.action {
        case .help:
            print(Options.usage)
            return
        case .version:
            print("planmeterd \(daemonVersion)")
            return
        case .run:
            break
        }
        Log.verbose = options.verbose
        // A client that disconnects mid-reply must not kill the daemon.
        signal(SIGPIPE, SIG_IGN)
        do {
            try await Daemon(options: options).run()
        } catch {
            Log.error(error.localizedDescription)
            exit(1)
        }
    }
}

@MainActor
final class Daemon {
    static let tickInterval: UInt64 = 30

    let options: Options

    init(options: Options) {
        self.options = options
    }

    func run() async throws {
        var paths = HostPaths.resolve()
        if let config = options.configDirectory { paths.configDirectory = URL(fileURLWithPath: config, isDirectory: true) }
        if let state = options.stateDirectory { paths.stateDirectory = URL(fileURLWithPath: state, isDirectory: true) }
        try HostPaths.preparePrivateDirectory(paths.configDirectory.path, tighten: false)
        try HostPaths.preparePrivateDirectory(paths.stateDirectory.path, tighten: false)

        let settings = HostSettingsStore(url: paths.settingsFile)
        if let problem = settings.loadError { Log.warning(problem) }
        let serverName = options.serverName ?? HostIdentity.name()

        let engine = HostEngine(serverName: serverName, scanCache: paths.scanCacheFile,
                                loader: .live(pricingCache: paths.pricingCacheFile, offline: options.offline),
                                groupOverrides: settings.settings.groupOverrides)
        engine.onLog = { Log.info($0) }

        let secrets = PrivateFileStore(directory: paths.remoteDirectory)
        let serverKey = RemoteService.loadSoftwareServerKey(store: secrets)
        let service = RemoteService(serverName: serverName, serverKey: serverKey, store: secrets, version: daemonVersion)
        let webDirectory = WebLocator.find(explicit: options.webDirectory)
        service.webDirectory = { webDirectory }
        service.dataProvider = { [engine] request in await engine.reply(for: request) }
        service.onLog = { Log.info("remote: \($0)") }

        #if os(macOS)
        // macOS cannot reach its own tailnet address; loopback is the way in
        // for same-machine clients, as in the Mac app.
        let loopback = true
        #else
        let loopback = options.loopback
        #endif
        let remote = RemoteController(service: service, settings: settings, bindLoopback: loopback)
        remote.forceEnabled = options.remote
        remote.portOverride = options.port

        let control = ControlAPI(engine: engine, settings: settings, remote: remote, version: daemonVersion)
        let socket = options.socketPath.map { (path: $0, isDefault: false) } ?? HostPaths.controlSocket()
        try HostPaths.prepareSocketDirectory(for: socket.path, isDefault: socket.isDefault)
        let controlServer = POSIXHTTPServer(endpoints: [.unix(path: socket.path)], options: .init(peerPolicy: .sameUser)) { request in
            await control.handle(request)
        }
        controlServer.onLog = { Log.warning("control: \($0)") }
        try controlServer.start()

        Log.info("planmeterd \(daemonVersion) as \"\(serverName)\"; control API on \(socket.path)")
        Log.info("state in \(paths.stateDirectory.path), settings in \(paths.settingsFile.path)")
        if options.offline { Log.info("offline: pricing refresh and Codex account-wide readings are off") }
        if webDirectory == nil { Log.warning("web client not found; remote access serves the API only (see --web-dir)") }

        let scan = Task { @MainActor in
            await engine.start()
            Log.info("first scan: \(engine.accounts.count) accounts, \(engine.sources.count) sources")
        }

        await remote.apply()
        logRemote(remote)
        if options.pairingLink { printPairingLink(remote) }

        let tick = Task { @MainActor in
            var lastState = remote.state
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: Daemon.tickInterval * 1_000_000_000) } catch { return }
                await remote.apply()
                if remote.state != lastState {
                    lastState = remote.state
                    self.logRemote(remote)
                }
            }
        }

        let received = await Signals.wait(for: [SIGTERM, SIGINT])
        Log.info("received \(received == SIGTERM ? "SIGTERM" : "SIGINT"); shutting down")
        tick.cancel()
        controlServer.stop()
        remote.stop()
        await engine.stop()
        scan.cancel()
        service.persistDevices()
        Log.info("stopped")
    }

    func logRemote(_ remote: RemoteController) {
        switch remote.state {
        case .off:
            Log.info("remote access off\(remote.message.map { ": \($0)" } ?? " (enable with PUT /v1/remote or --remote)")")
        case .listening:
            Log.info("remote access listening on \(remote.boundAddresses.joined(separator: ", ")) port \(remote.port)\(remote.message.map { "; \($0)" } ?? "")")
        case .unavailable, .error:
            Log.warning("remote access \(remote.state.rawValue): \(remote.message ?? "")")
        }
    }

    /// `--pairing-link`: lets a phone (or a simulator) pair without scanning a
    /// QR code. The link is a secret; it only goes to stdout.
    func printPairingLink(_ remote: RemoteController) {
        guard remote.state == .listening else {
            let hint = remote.isEnabled ? "" : " (remote access is off; add --remote)"
            Log.error("pairing-link: remote listener did not start: \(remote.message ?? remote.state.rawValue)\(hint)")
            return
        }
        do {
            let invite = try remote.newInvite()
            var lines = "pairing-link: \(invite.url.absoluteString)\n"
            if let local = remote.localURL(for: invite) { lines += "pairing-link-local: \(local.absoluteString)\n" }
            if let web = remote.webURL(for: invite) { lines += "pairing-link-web: \(web.absoluteString)\n" }
            FileHandle.standardOutput.write(Data(lines.utf8))
        } catch {
            Log.error("pairing-link: \(error.localizedDescription)")
        }
    }
}

enum HostIdentity {
    /// The short host name, as phones show it.
    static func name() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "planmeterd" }
        let full = String(cString: buffer)
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty || short == "localhost" ? "planmeterd" : short
    }
}

enum WebLocator {
    /// The first directory holding the web client: `--web-dir`,
    /// `$PLANMETER_WEB_DIR`, `<prefix>/share/planmeter/web` next to the
    /// executable, the XDG data directory, system share directories, and
    /// finally the source tree for development builds.
    static func find(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let explicit {
            let url = URL(fileURLWithPath: explicit, isDirectory: true)
            if WebAssetCatalog.isWebDirectory(url) { return url }
            Log.warning("--web-dir \(explicit) has no index.html")
            return nil
        }
        var candidates: [URL] = []
        if let env = environment["PLANMETER_WEB_DIR"], !env.isEmpty { candidates.append(URL(fileURLWithPath: env, isDirectory: true)) }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bin = executable.deletingLastPathComponent()
            candidates.append(bin.deletingLastPathComponent().appendingPathComponent("share/planmeter/web", isDirectory: true))
            candidates.append(bin.appendingPathComponent("web", isDirectory: true))
        }
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? PlanMeterPaths.homeDirectory(environment: environment) + "/.local/share"
        candidates.append(URL(fileURLWithPath: dataHome).appendingPathComponent("planmeter/web", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/usr/local/share/planmeter/web", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/usr/share/planmeter/web", isDirectory: true))
        if let source = WebAssetCatalog.sourceTreeDirectory { candidates.append(source) }
        return candidates.first(where: WebAssetCatalog.isWebDirectory)
    }
}

/// Waits for the first of several signals, then restores their default
/// action so a second one ends the process immediately.
enum Signals {
    private final class Waiter: @unchecked Sendable {
        var sources: [DispatchSourceSignal] = []
        var resumed = false
    }

    @MainActor
    static func wait(for signals: [Int32]) async -> Int32 {
        let waiter = Waiter()
        let received: Int32 = await withCheckedContinuation { continuation in
            for number in signals {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    guard !waiter.resumed else { return }
                    waiter.resumed = true
                    continuation.resume(returning: number)
                }
                source.resume()
                waiter.sources.append(source)
            }
        }
        for source in waiter.sources { source.cancel() }
        for number in signals { signal(number, SIG_DFL) }
        return received
    }
}
