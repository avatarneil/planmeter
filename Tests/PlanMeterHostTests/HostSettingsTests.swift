import XCTest
import PlanMeterCore
@testable import PlanMeterHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@MainActor
final class HostSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config/settings.json")
        let store = HostSettingsStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.settings, HostSettings())
        XCTAssertEqual(store.settings.spendGroups, [.personal, .work, .other])
        XCTAssertEqual(store.remote, RemoteSettings(enabled: false, port: 7787, httpsEnabled: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is written until something changes")

        try store.update { s in
            s.groupOverrides = ["claude:home:/x": .work]
            s.spendGroups = [.work, .personal, .work]
            s.spendThresholds = ["month": SpendThreshold(limit: 300, warningPercent: 90)]
        }
        try store.updateRemote { r in r.enabled = true; r.port = 9000; r.httpsEnabled = true }
        XCTAssertEqual(store.settings.spendGroups, [.personal, .work])

        let reloaded = HostSettingsStore(url: url)
        XCTAssertEqual(reloaded.settings, store.settings)
        XCTAssertEqual(reloaded.remote, RemoteSettings(enabled: true, port: 9000, httpsEnabled: true))

        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["spendGroups"] as? [String], ["personal", "work"])
        XCTAssertEqual((json["remote"] as? [String: Any])?["port"] as? Int, 9000)
    }

    func testLenientDecoding() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("""
        {"groupOverrides": {"a": "work", "b": "family"}, "spendGroups": ["nope"],
         "spendThresholds": {"today": {"limit": 5, "warningPercent": 50}, "decade": {"limit": 5, "warningPercent": 50}, "week": {"limit": -1, "warningPercent": 50}},
         "remote": {"enabled": true, "port": 80}}
        """.utf8).write(to: url)
        let store = HostSettingsStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.settings.groupOverrides, ["a": .work])
        XCTAssertEqual(store.settings.spendGroups, PlanGroup.allCases)
        XCTAssertEqual(store.settings.spendThresholds, ["today": SpendThreshold(limit: 5, warningPercent: 50)])
        XCTAssertEqual(store.remote, RemoteSettings(enabled: true, port: 7787, httpsEnabled: false))
    }

    func testCorruptFileFallsBackToDefaults() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("{not json".utf8).write(to: url)
        let store = HostSettingsStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.settings, HostSettings())
        try store.updateRemote { $0.enabled = true }
        XCTAssertNil(store.loadError)
        XCTAssertTrue(HostSettingsStore(url: url).remote.enabled)
    }

    func testRangeIdsMatchTheMacRanges() async {
        XCTAssertEqual(HostSettings.rangeIds, ["lastHour", "today", "day", "week", "month", "quarter"])
    }

    // MARK: Paths

    func testControlSocketPrecedence() async {
        XCTAssertEqual(HostPaths.controlSocket(environment: ["PLANMETER_CONTROL_SOCKET": "/x/y.sock", "XDG_RUNTIME_DIR": "/run/user/1000"], uid: 1000).path, "/x/y.sock")
        XCTAssertFalse(HostPaths.controlSocket(environment: ["PLANMETER_CONTROL_SOCKET": "/x/y.sock"], uid: 1000).isDefault)
        let runtime = HostPaths.controlSocket(environment: ["XDG_RUNTIME_DIR": "/run/user/1000"], uid: 1000)
        XCTAssertEqual(runtime.path, "/run/user/1000/planmeter/control.sock")
        XCTAssertTrue(runtime.isDefault)
        XCTAssertEqual(HostPaths.controlSocket(environment: ["XDG_RUNTIME_DIR": "relative"], uid: 1000).path, "/tmp/planmeter-1000/control.sock")
        XCTAssertEqual(HostPaths.controlSocket(environment: [:], uid: 501).path, "/tmp/planmeter-501/control.sock")
    }

    func testStateAndConfigDirectories() async {
        let paths = HostPaths.resolve(environment: ["HOME": "/home/dev", "XDG_CONFIG_HOME": "/cfg", "XDG_STATE_HOME": "/st"])
        #if os(macOS)
        XCTAssertTrue(paths.configDirectory.path.hasSuffix("/Library/Application Support/PlanMeter/planmeterd"), paths.configDirectory.path)
        XCTAssertEqual(paths.stateDirectory, paths.configDirectory)
        XCTAssertNotEqual(paths.stateDirectory, PlanMeterPaths.stateDirectory(), "never the Mac app's folder")
        #else
        XCTAssertEqual(paths.configDirectory.path, "/cfg/planmeter")
        XCTAssertEqual(paths.stateDirectory.path, "/st/planmeter")
        let fallback = HostPaths.resolve(environment: ["HOME": "/home/dev", "XDG_STATE_HOME": "relative"])
        XCTAssertEqual(fallback.configDirectory.path, "/home/dev/.config/planmeter")
        XCTAssertEqual(fallback.stateDirectory.path, "/home/dev/.local/state/planmeter")
        #endif
        XCTAssertEqual(paths.remoteDirectory.lastPathComponent, "remote")
        XCTAssertEqual(paths.scanCacheFile.lastPathComponent, "scan-cache.json")
    }

    func testSocketDirectoryIsCreatedPrivateAndTightened() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("planmeter/control.sock").path
        try HostPaths.prepareSocketDirectory(for: socket, isDefault: true)
        func mode(_ path: String) -> UInt32 { var st = stat(); stat(path, &st); return UInt32(st.st_mode) & 0o777 }
        XCTAssertEqual(mode(dir.appendingPathComponent("planmeter").path), 0o700)
        chmod(dir.appendingPathComponent("planmeter").path, 0o755)
        try HostPaths.prepareSocketDirectory(for: socket, isDefault: true)
        XCTAssertEqual(mode(dir.appendingPathComponent("planmeter").path), 0o700)
        // An explicit path in a directory we own is left as it is.
        chmod(dir.path, 0o755)
        try HostPaths.prepareSocketDirectory(for: dir.appendingPathComponent("x.sock").path, isDefault: false)
        XCTAssertEqual(mode(dir.path), 0o755)
        // A shared sticky directory such as /tmp is fine for explicit paths.
        try HostPaths.prepareSocketDirectory(for: "/tmp/planmeter-test-\(UUID().uuidString).sock", isDefault: false)
        // A file where the directory should be is refused.
        let file = dir.appendingPathComponent("file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try HostPaths.prepareSocketDirectory(for: file.appendingPathComponent("c.sock").path, isDefault: true))
    }
}
