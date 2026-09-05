import XCTest
@testable import PlanMeterCore

final class SpendThresholdTests: XCTestCase {
    func testWarningAndLimitBoundaries() {
        let threshold = SpendThreshold(limit: 100, warningPercent: 75)
        XCTAssertEqual(threshold.status(spend: 0), .comfortable)
        XCTAssertEqual(threshold.status(spend: 74.99), .comfortable)
        XCTAssertEqual(threshold.status(spend: 75), .approaching)
        XCTAssertEqual(threshold.status(spend: 99.99), .approaching)
        XCTAssertEqual(threshold.status(spend: 100), .reached)
        XCTAssertEqual(threshold.status(spend: 125), .reached)
        XCTAssertEqual(threshold.fraction(spend: 125), 1.25)
    }

    func testInvalidLimitsAndWarningLevels() {
        for limit in [0, -1, 0.001, .infinity, .nan, 1_000_000_001] {
            XCTAssertFalse(SpendThreshold(limit: limit).isValid)
        }
        for warning in [0, 100, -1, .infinity, .nan] {
            XCTAssertFalse(SpendThreshold(limit: 100, warningPercent: warning).isValid)
        }
        XCTAssertTrue(SpendThreshold(limit: 0.01).isValid)
        XCTAssertEqual(SpendThreshold(limit: 0).fraction(spend: 10), 0)
    }

    func testPersistencePerPeriodAndRemoval() throws {
        let name = "SpendThresholdTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(SpendThreshold.load(from: defaults).isEmpty)
        let values = ["today": SpendThreshold(limit: 50), "month": SpendThreshold(limit: 500, warningPercent: 90)]
        SpendThreshold.save(values, to: defaults)
        XCTAssertEqual(SpendThreshold.load(from: defaults), values)
        SpendThreshold.save(["month": values["month"]!, "day": SpendThreshold(limit: -1)], to: defaults)
        XCTAssertEqual(SpendThreshold.load(from: defaults), ["month": values["month"]!])
        defaults.set(Data("invalid".utf8), forKey: "menuBarSpendThresholds")
        XCTAssertTrue(SpendThreshold.load(from: defaults).isEmpty)
    }
}
