import XCTest
@testable import PlanMeterDesktopShared

final class DesktopSnapshotTests: XCTestCase {
    func testRoundTripAndAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(DesktopWidgetStore.load(from: directory))
        let first = DesktopSnapshot.preview
        try DesktopWidgetStore.save(first, to: directory)
        XCTAssertEqual(DesktopWidgetStore.load(from: directory), first)
        var second = first
        second.cost = 81
        second.limit = nil
        try DesktopWidgetStore.save(second, to: directory)
        XCTAssertEqual(DesktopWidgetStore.load(from: directory), second)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(DesktopWidgetStore.filename))
        XCTAssertNil(DesktopWidgetStore.load(from: directory))
    }

    func testRejectsUnsupportedVersionsAndInvalidNumbers() throws {
        var snapshot = DesktopSnapshot.preview
        snapshot.version = 2
        XCTAssertNil(DesktopSnapshot.decode(try JSONEncoder().encode(snapshot)))
        snapshot.version = 1
        snapshot.limit = 0
        XCTAssertFalse(snapshot.isValid)
        snapshot.limit = 100
        snapshot.cost = -1
        XCTAssertFalse(snapshot.isValid)
        snapshot.cost = .infinity
        XCTAssertFalse(snapshot.isValid)
        snapshot.cost = 50
        snapshot.warningPercent = 100
        XCTAssertFalse(snapshot.isValid)
    }

    func testStalenessUsesScanTimeAndLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let justBeforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23, minute: 59))!
        var snapshot = DesktopSnapshot.preview
        snapshot.scannedAt = justBeforeMidnight
        snapshot.generatedAt = justBeforeMidnight
        XCTAssertFalse(snapshot.isStale(at: justBeforeMidnight, calendar: calendar))
        XCTAssertTrue(snapshot.isStale(at: justBeforeMidnight.addingTimeInterval(61), calendar: calendar))
        snapshot.rangeID = "week"
        XCTAssertFalse(snapshot.isStale(at: justBeforeMidnight.addingTimeInterval(61), calendar: calendar))
        snapshot.generatedAt = justBeforeMidnight.addingTimeInterval(899)
        XCTAssertTrue(snapshot.isStale(at: justBeforeMidnight.addingTimeInterval(900), calendar: calendar))
    }

    func testOlderSnapshotWithoutDetailsStillLoads() throws {
        let data = try JSONEncoder().encode(DesktopSnapshot.preview)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "detail")
        let decoded = try XCTUnwrap(DesktopSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertNil(decoded.detail)
        XCTAssertEqual(decoded.cost, DesktopSnapshot.preview.cost)
    }

    func testDetailValidationAndRoundTrip() throws {
        var snapshot = DesktopSnapshot.preview
        XCTAssertEqual(DesktopSnapshot.decode(try JSONEncoder().encode(snapshot)), snapshot)
        snapshot.detail?.trend[0].cost = -1
        XCTAssertFalse(snapshot.isValid)
        snapshot = .preview
        snapshot.detail?.cachedInputShare = 1.5
        XCTAssertFalse(snapshot.isValid)
    }

    func testLimitFractionPreservesOverage() {
        var snapshot = DesktopSnapshot.preview
        snapshot.cost = 125
        snapshot.limit = 100
        XCTAssertEqual(snapshot.fraction, 1.25)
        snapshot.limit = nil
        XCTAssertNil(snapshot.fraction)
    }
}
