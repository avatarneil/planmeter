import XCTest
@testable import PlanMeterRemote

final class CloudAccountGuardTests: XCTestCase {
    func testOnlyADifferentAccountIsTreatedAsAChange() throws {
        let suite = "CloudAccountGuardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let guardian = CloudAccountGuard(defaults: defaults, key: "account")
        XCTAssertEqual(guardian.verify("_abc"), .adopted)
        // Repeated account notifications for the same user keep uploading.
        XCTAssertEqual(guardian.verify("_abc"), .unchanged)
        XCTAssertEqual(guardian.verify("_abc"), .unchanged)
        XCTAssertEqual(guardian.verify("_other"), .changed)
        XCTAssertNotEqual(defaults.string(forKey: "account"), "_abc") // Only a digest is stored.
        guardian.reset()
        XCTAssertEqual(guardian.verify("_other"), .adopted)
        XCTAssertEqual(guardian.verify("_abc"), .changed)
    }
}
