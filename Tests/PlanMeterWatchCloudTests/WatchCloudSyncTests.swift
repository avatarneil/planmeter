import XCTest
import PlanMeterRemote
import PlanMeterWatchShared
@testable import PlanMeterWatchCloud

final class WatchCloudSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(id: String = "mac-a") -> CloudSnapshot {
        let account = RemoteAccount(id: "work", name: "Work", provider: "claude", providerName: "Claude", group: "work")
        let totals = RemoteTotals(costUsd: 200, tokens: 6_960_000_000)
        let reports = CloudSnapshot.supportedDays.map { days in
            RemoteReply(
                summary: RemoteSummary(days: days, from: now.addingTimeInterval(-Double(days) * 86400), to: now, groups: [RemoteGroupUsage(group: "work", totals: totals, accounts: [RemoteAccountUsage(account: account, totals: totals)])], total: totals, todayCostUsd: 12, generatedAt: now, serverName: "Mac", pricingSource: "test"),
                models: [],
                timeline: RemoteTimeline(days: days, resolution: "day", periods: [now], points: [RemoteTimelinePoint(period: now, accountId: account.id, costUsd: 12, tokens: 100)], accounts: [account]),
                limits: RemoteLimits(accounts: [], note: "test"))
        }
        return CloudSnapshot(id: id, name: "Mac", generatedAt: now, reports: reports)
    }

    func testCloudConversionKeepsSourceTimestampAndSeparateDailySpend() throws {
        let payload = try WatchCloudSync.payload(from: snapshot())
        XCTAssertEqual(payload.cloudMacID, "mac-a")
        XCTAssertEqual(payload.updatedAt, now)
        XCTAssertEqual(payload.days, 30)
        XCTAssertEqual(payload.workCostUsd, 200)
        XCTAssertEqual(payload.todayCost(groups: ["work"]), 12)
        XCTAssertEqual(payload.workTokens, 6_960_000_000)
        XCTAssertEqual(payload.accounts.first?.group, "work")
    }

    func testSelectionRequiresChoiceForMultipleMacsAndDoesNotSwitchDeletedSource() throws {
        let a = try WatchCloudSync.payload(from: snapshot())
        let b = try WatchCloudSync.payload(from: snapshot(id: "mac-b"))
        XCTAssertThrowsError(try WatchCloudSync.select([a, b], cached: nil))
        XCTAssertEqual(try WatchCloudSync.select([a], cached: nil)?.cloudMacID, "mac-a")
        XCTAssertNil(try WatchCloudSync.select([b], cached: a))
        XCTAssertNil(try WatchCloudSync.select([], cached: a))
        XCTAssertNil(try WatchCloudSync.select([b], cached: nil, selectedMacID: "mac-a"))
    }

    func testCloudRefreshPreservesPreferencesAndNewerCache() throws {
        let a = try WatchCloudSync.payload(from: snapshot())
        var cached = a
        cached.updatedAt = now.addingTimeInterval(60)
        cached.todayCostUsd = 15
        var preferences = ComplicationPreferences()
        preferences.personal = false
        preferences.other = false
        preferences.dailyTarget = 20
        cached.complicationPreferences = preferences
        let chosen = try XCTUnwrap(WatchCloudSync.select([a], cached: cached))
        XCTAssertEqual(chosen.updatedAt, cached.updatedAt)
        XCTAssertEqual(chosen.todayCostUsd, 15)
        XCTAssertEqual(chosen.complicationPreferences, cached.complicationPreferences)
    }

    func testDirectPhonePayloadSurvivesWhenNoMacPublishesToCloud() throws {
        var direct = try WatchCloudSync.payload(from: snapshot())
        direct.cloudMacID = nil
        XCTAssertEqual(try WatchCloudSync.select([], cached: direct), direct)
    }

    func testUnsupportedCloudSchemaIsRejected() {
        var value = snapshot()
        value.version = 2
        XCTAssertThrowsError(try WatchCloudSync.payload(from: value))
    }
}
