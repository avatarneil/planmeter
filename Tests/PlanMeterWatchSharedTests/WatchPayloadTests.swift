import Foundation
import XCTest
import PlanMeterWatchShared

final class WatchPayloadTests: XCTestCase {
    private func payload(updatedAt: Date, days: Int = 30) -> WatchPayload {
        WatchPayload(updatedAt: updatedAt, days: days, serverName: "Mac",
                     personalCostUsd: 1, workCostUsd: 2, otherCostUsd: 0,
                     personalTokens: 0, workTokens: 0, todayCostUsd: 1, accounts: [], limits: [])
    }

    func testFilteredDailySpendAndLegacyCache() throws {
        var p = payload(updatedAt: Date())
        XCTAssertNil(p.todayCost(groups: ["work"]))
        XCTAssertEqual(p.todayCost(groups: ["personal", "work", "other"]), 1)
        XCTAssertEqual(p.todayCost(groups: []), 0)
        p.todayCostByGroup = ["work": 12, "personal": 3]
        XCTAssertEqual(p.todayCost(groups: ["work"]), 12)
        XCTAssertEqual(p.todayCost(groups: ["personal", "work"]), 15)
        XCTAssertEqual(p.todayCost(groups: ["other"]), 0)
        let decoded = try XCTUnwrap(WatchPayload.decode(try XCTUnwrap(p.encoded())))
        XCTAssertEqual(decoded.todayCost(groups: ["work"]), 12)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(p.encoded())) as? [String: Any])
        json.removeValue(forKey: "todayCostByGroup")
        let legacy = try XCTUnwrap(WatchPayload.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(legacy.todayCost(groups: ["work"]))
    }

    func testWidgetExpiresAtFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let p = payload(updatedAt: now)
        XCTAssertFalse(p.isStale(at: now.addingTimeInterval(899)))
        XCTAssertTrue(p.isStale(at: now.addingTimeInterval(900)))
        XCTAssertEqual(p.nextWidgetRefresh(after: now.addingTimeInterval(300)), now.addingTimeInterval(900))
        XCTAssertGreaterThan(p.nextWidgetRefresh(after: now.addingTimeInterval(1000)), now.addingTimeInterval(1000))
    }

    func testTodayExpiresAtMidnightBeforeAgeThreshold() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26)))
        let p = payload(updatedAt: midnight.addingTimeInterval(-60))
        XCTAssertFalse(p.isStale(at: midnight.addingTimeInterval(-1), calendar: calendar))
        XCTAssertTrue(p.isStale(at: midnight, calendar: calendar))
        XCTAssertEqual(p.nextWidgetRefresh(after: midnight.addingTimeInterval(-30), calendar: calendar), midnight)
    }

    func testRangeLabelsDistinguishRollingDayFromToday() {
        XCTAssertEqual(payload(updatedAt: Date(), days: 1).rangeLabel, "24h")
        XCTAssertEqual(payload(updatedAt: Date(), days: 7).rangeLabel, "7d")
        XCTAssertEqual(payload(updatedAt: Date(), days: 30).rangeLabel, "30d")
    }

    func testLargeTokenCountsSurvivePhoneToWatchTransport() throws {
        let payload = WatchPayload(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), days: 30, serverName: "Mac",
            personalCostUsd: 1, workCostUsd: 2, otherCostUsd: 0,
            personalTokens: 3_480_000_000, workTokens: 6_960_000_000, todayCostUsd: 1,
            accounts: [.init(name: "Work", group: "work", provider: "codex", costUsd: 2, tokens: 6_960_000_000)],
            limits: []
        )
        let data = try XCTUnwrap(payload.encoded())
        XCTAssertEqual(WatchPayload.decode(data), payload)
        XCTAssertEqual(MemoryLayout.size(ofValue: payload.workTokens), 8)
        XCTAssertEqual(MemoryLayout.size(ofValue: payload.accounts[0].tokens), 8)
        XCTAssertEqual(WatchPayload.tokens(payload.workTokens), "7.0B")
    }
}
