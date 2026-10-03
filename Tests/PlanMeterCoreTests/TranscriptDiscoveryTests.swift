import XCTest
@testable import PlanMeterCore

final class TranscriptDiscoveryTests: XCTestCase {
    func testSeparateLoginHomesSharingTranscriptSymlinksProduceOnePhysicalSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let work = directory.appendingPathComponent("work")
        let personal = directory.appendingPathComponent("personal")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        for name in ["sessions", "archived_sessions"] {
            let actual = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: personal.appendingPathComponent(name), withDestinationURL: actual)
        }
        let settings = T3Settings(instances: [
            T3ProviderInstance(id: "work", driver: "codex", homePath: work.path),
            T3ProviderInstance(id: "personal", driver: "codex", homePath: personal.path),
        ], settingsPath: directory.appendingPathComponent("settings.json"))
        let discovery = AccountDiscovery.discover(settings: settings, environment: [:])
        let roots = discovery.sources.filter { $0.provider == .codex }.map(\.rootDir)
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(Set(roots), Set(["sessions", "archived_sessions"].map {
            work.appendingPathComponent($0).resolvingSymlinksInPath().path
        }))
    }
}
