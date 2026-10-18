import XCTest
@testable import PlanMeterRemote

final class FineTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_100) // A 15-minute boundary.
    private let personal = RemoteAccount(id: "p", name: "Personal", provider: "claude", providerName: "Claude", group: "personal")
    private let work = RemoteAccount(id: "w", name: "Work", provider: "codex", providerName: "Codex", group: "work")

    private func fiveMinute() -> RemoteTimeline {
        let periods = (0..<6).map { start.addingTimeInterval(TimeInterval($0) * 300) }
        let points = periods.enumerated().flatMap { index, period in
            [RemoteTimelinePoint(period: period, accountId: "p", costUsd: Double(index), tokens: index * 10),
             RemoteTimelinePoint(period: period, accountId: "w", costUsd: 1, tokens: 5, baselineCostUsd: 0.25)]
        }
        return RemoteTimeline(days: 1, resolution: "5m", periods: periods, points: points, accounts: [personal, work])
    }

    func testRebucketingSumsCostTokensAndBaselinesIntoWholePeriods() throws {
        let quarter = try XCTUnwrap(fiveMinute().rebucketed(to: "15m"))
        XCTAssertEqual(quarter.resolution, "15m")
        XCTAssertEqual(quarter.periods, [start, start.addingTimeInterval(900)])
        let first = quarter.points.filter { $0.period == start }
        XCTAssertEqual(first.first { $0.accountId == "p" }?.costUsd, 0 + 1 + 2)
        XCTAssertEqual(first.first { $0.accountId == "w" }?.baselineCostUsd, 0.75)
        XCTAssertEqual(quarter.points.reduce(0) { $0 + $1.tokens }, fiveMinute().points.reduce(0) { $0 + $1.tokens })
        XCTAssertNil(fiveMinute().rebucketed(to: "day")) // Calendar days need the server.
        XCTAssertNil(quarter.rebucketed(to: "5m")) // Never finer than the source.
        XCTAssertTrue(RemoteTimeline.coarsens("minute", to: "5m"))
        XCTAssertFalse(RemoteTimeline.coarsens("hour", to: "15m"))
    }

    func testGroupBarsZeroFillPeriodsAndKeepBaselinesApart() {
        var timeline = fiveMinute()
        timeline.periods.append(start.addingTimeInterval(1800))
        let bars = timeline.groupBars()
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.last?.costs, [:])
        XCTAssertEqual(bars[2].costs["personal"], 2)
        XCTAssertEqual(bars[2].baselines["work"], 0.25)
    }

    func testSubDayReportsFollowDayReportsSoOlderClientsFindTheDayReport() throws {
        func report(days: Int, minutes: Int?) -> RemoteReply {
            RemoteReply(summary: RemoteSummary(days: days, from: start, to: start, groups: [], total: RemoteTotals(costUsd: Double(minutes ?? 0)), todayCostUsd: 0,
                                               generatedAt: start, serverName: "Mac", pricingSource: "test", minutes: minutes),
                        models: [], timeline: RemoteTimeline(days: days, resolution: minutes == nil ? "hour" : "minute", periods: [], points: [], accounts: [], minutes: minutes),
                        limits: RemoteLimits(accounts: [], note: ""))
        }
        let snapshot = CloudSnapshot(id: "mac", name: "Mac", generatedAt: start,
                                     reports: CloudSnapshot.supportedDays.map { report(days: $0, minutes: nil) } + [report(days: 1, minutes: 60)],
                                     timelines: [fiveMinute()])
        XCTAssertEqual(try snapshot.report(days: 1).summary?.minutes, nil)
        XCTAssertEqual(try snapshot.report(days: 1, minutes: 60).timeline?.resolution, "minute")
        XCTAssertEqual(snapshot.reports.first { $0.summary?.days == 1 }?.summary?.minutes, nil) // An older client's lookup.
        XCTAssertEqual(snapshot.fineTimeline(days: 1)?.resolution, "5m")
        XCTAssertNotEqual(snapshot.fineTimeline(days: 1)?.points.first?.accountId, "p") // Account ids are hashed like reports.
        let decoded = try RemoteJSON.decoder.decode(CloudSnapshot.self, from: RemoteJSON.encoder.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        let activity = snapshot.activity()
        XCTAssertNotNil(activity.lastHour)
        XCTAssertNotNil(activity.today)
    }
}
