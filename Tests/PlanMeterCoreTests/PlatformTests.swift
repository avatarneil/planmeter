import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PlanMeterCore

final class PlatformTests: XCTestCase {
    func testXDGDirectoriesFollowTheSpec() {
        let home = "/home/ada"
        XCTAssertEqual(PlanMeterPaths.xdgDirectory("XDG_STATE_HOME", fallback: ".local/state", environment: [:], home: home).path,
                       "/home/ada/.local/state/planmeter")
        XCTAssertEqual(PlanMeterPaths.xdgDirectory("XDG_STATE_HOME", fallback: ".local/state", environment: ["XDG_STATE_HOME": "/srv/state"], home: home).path,
                       "/srv/state/planmeter")
        // Empty and relative values are invalid and fall back to the default.
        for value in ["", "relative/state"] {
            XCTAssertEqual(PlanMeterPaths.xdgDirectory("XDG_STATE_HOME", fallback: ".local/state", environment: ["XDG_STATE_HOME": value], home: home).path,
                           "/home/ada/.local/state/planmeter")
        }
        XCTAssertEqual(PlanMeterPaths.xdgDirectory("XDG_CONFIG_HOME", fallback: ".config", environment: ["XDG_STATE_HOME": "/srv/state"], home: home).path,
                       "/home/ada/.config/planmeter")
    }

    func testStateDirectoryIsWhereCachesLive() {
        let state = PlanMeterPaths.stateDirectory()
        XCTAssertEqual(AppPaths.supportDirectory(), state)
        XCTAssertEqual(PricingLoader.appCachePath(), state.appendingPathComponent("model-rates.json").path)
        #if canImport(Darwin)
        // Unchanged from earlier releases.
        XCTAssertTrue(state.path.hasSuffix("/Library/Application Support/PlanMeter"), state.path)
        XCTAssertEqual(PlanMeterPaths.configDirectory(), state)
        #else
        XCTAssertEqual(state.lastPathComponent, "planmeter")
        XCTAssertEqual(PlanMeterPaths.stateDirectory(environment: ["XDG_STATE_HOME": "/srv/state"]).path, "/srv/state/planmeter")
        XCTAssertEqual(PlanMeterPaths.configDirectory(environment: ["XDG_CONFIG_HOME": "/srv/config"]).path, "/srv/config/planmeter")
        XCTAssertEqual(PlanMeterPaths.cacheDirectory(environment: ["XDG_CACHE_HOME": "/srv/cache"]).path, "/srv/cache/planmeter")
        // $HOME wins over the password database, as for Node and Rust tools.
        XCTAssertEqual(PlanMeterPaths.homeDirectory(environment: ["HOME": "/home/ada"]), "/home/ada")
        XCTAssertEqual(PlanMeterPaths.homeDirectory(environment: ["HOME": "relative"]), NSHomeDirectory())
        XCTAssertEqual(PlanMeterPaths.stateDirectory(environment: ["HOME": "/home/ada"]).path, "/home/ada/.local/state/planmeter")
        #endif
    }

    func testAppleCodexLocationsAreUnchanged() {
        XCTAssertEqual(CodexAccountUsage.appleExecutableCandidates(environment: ["PATH": "/a:/b"], home: "/Users/ada"), [
            "/a/codex", "/b/codex",
            "/Users/ada/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        ])
    }

    func testLinuxCodexLocationsCoverPathPackageManagersAndNewestNvm() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        for version in ["v9.11.2", "v22.3.0", "v20.18.1"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"), withIntermediateDirectories: true)
        }
        let environment = ["PATH": "/usr/local/bin:/opt/bin", "PNPM_HOME": "/opt/pnpm", "BUN_INSTALL": "relative", "VOLTA_HOME": ""]
        let candidates = CodexAccountUsage.linuxExecutableCandidates(environment: environment, home: home.path)
        XCTAssertEqual(Array(candidates.prefix(3)), ["/usr/local/bin/codex", "/opt/bin/codex", "/opt/pnpm/codex"])
        XCTAssertEqual(candidates.filter { $0 == "/usr/local/bin/codex" }.count, 1)
        for expected in [home.path + "/.local/bin/codex", home.path + "/.npm-global/bin/codex", home.path + "/.bun/bin/codex",
                         home.path + "/.volta/bin/codex", "/usr/bin/codex"] {
            XCTAssertTrue(candidates.contains(expected), expected)
        }
        XCTAssertFalse(candidates.contains { $0.hasPrefix("relative") || $0 == "/bin/codex" })
        let nvm = candidates.filter { $0.contains("/.nvm/") }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
        XCTAssertEqual(nvm, ["v22.3.0", "v20.18.1", "v9.11.2"])
    }

    func testJSONBooleansAreNotCounts() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"t":true,"f":false,"one":1,"zero":0}"#.utf8)) as? [String: Any])
        XCTAssertTrue(JSON.isBoolean(try XCTUnwrap(object["t"] as? NSNumber)))
        XCTAssertTrue(JSON.isBoolean(try XCTUnwrap(object["f"] as? NSNumber)))
        XCTAssertFalse(JSON.isBoolean(try XCTUnwrap(object["one"] as? NSNumber)))
        XCTAssertFalse(JSON.isBoolean(try XCTUnwrap(object["zero"] as? NSNumber)))
    }

    func testLibcurlWithoutWebSocketsIsReportedAsUnavailable() {
        let unsupported = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL,
                                  userInfo: [NSLocalizedDescriptionKey: "WebSockets not supported by libcurl"])
        #if canImport(Darwin)
        XCTAssertFalse(CodexCloudUsage.isWebSocketUnsupported(unsupported))
        #else
        XCTAssertTrue(CodexCloudUsage.isWebSocketUnsupported(unsupported))
        #endif
        XCTAssertFalse(CodexCloudUsage.isWebSocketUnsupported(URLError(.timedOut)))
        XCTAssertFalse(CodexCloudUsage.isWebSocketUnsupported(CocoaError(.fileNoSuchFile)))
    }
}
