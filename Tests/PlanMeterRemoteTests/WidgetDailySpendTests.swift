import Foundation
import XCTest
import PlanMeterRemote

final class WidgetDailySpendTests: XCTestCase {
    func testCalendarDayExcludesYesterdayAndCombinesWorkAccounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
        let accounts = [("w1", "work"), ("w2", "work"), ("p", "personal")].map {
            RemoteAccount(id: $0.0, name: $0.0, provider: "codex", providerName: "Codex", group: $0.1)
        }
        let timeline = RemoteTimeline(days: 1, resolution: "hour", periods: [], points: [
            .init(period: today.addingTimeInterval(-3600), accountId: "w1", costUsd: 99, tokens: 0),
            .init(period: today, accountId: "w1", costUsd: 5, tokens: 0),
            .init(period: today.addingTimeInterval(3600), accountId: "w2", costUsd: 7, tokens: 0),
            .init(period: today, accountId: "p", costUsd: 3, tokens: 0),
        ], accounts: accounts)
        XCTAssertEqual(timeline.costByGroup(on: today, calendar: calendar), ["work": 12, "personal": 3])
        XCTAssertEqual(timeline.costByGroup(on: today.addingTimeInterval(86400), calendar: calendar), [:])
    }
}
