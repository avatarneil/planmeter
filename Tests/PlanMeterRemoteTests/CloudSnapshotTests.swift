import XCTest
@testable import PlanMeterRemote

final class CloudSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot() -> CloudSnapshot {
        let account = RemoteAccount(id: "claude:/Users/private/.claude", name: "Personal", provider: "claude", providerName: "Claude", group: "personal", email: "private@example.com")
        let totals = RemoteTotals(costUsd: 125.50, tokens: 6_960_000_000)
        let reports = CloudSnapshot.supportedDays.map { days in
            RemoteReply(
                summary: RemoteSummary(days: days, from: now.addingTimeInterval(-Double(days) * 86400), to: now, groups: [RemoteGroupUsage(group: "personal", totals: totals, accounts: [RemoteAccountUsage(account: account, totals: totals)])], total: totals, todayCostUsd: 8, generatedAt: now, serverName: "Mac", pricingSource: "test"),
                models: [RemoteModelRow(accountId: account.id, accountName: account.name, group: account.group, provider: account.provider, model: "test-model", totals: totals, priced: true)],
                timeline: RemoteTimeline(days: days, resolution: days == 1 ? "hour" : "day", periods: [now], points: [RemoteTimelinePoint(period: now, accountId: account.id, costUsd: 125.50, tokens: totals.tokens)], accounts: [account]),
                limits: RemoteLimits(accounts: [RemoteAccountLimits(account: account, windows: [])], note: "test"),
                accounts: RemoteAccounts(accounts: [account], sources: [RemoteSource(provider: "claude", path: "/Users/private/.claude", status: "ok")], scannedAt: now),
                error: "private debug detail"
            )
        }
        return CloudSnapshot(id: "mac-a", name: "Mac", generatedAt: now, reports: reports)
    }

    func testSnapshotRedactsPathsAndEmailsWithoutBreakingAccountJoins() throws {
        let value = snapshot()
        let encoded = try RemoteJSON.encoder.encode(value)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/private"))
        XCTAssertFalse(json.contains("private@example.com"))
        XCTAssertFalse(json.contains("private debug detail"))
        for days in CloudSnapshot.supportedDays {
            let report = try value.report(days: days)
            let id = try XCTUnwrap(report.summary?.groups.first?.accounts.first?.account.id)
            XCTAssertEqual(id.count, 64)
            XCTAssertEqual(report.timeline?.accounts.first?.id, id)
            XCTAssertEqual(report.timeline?.points.first?.accountId, id)
            XCTAssertEqual(report.models?.first?.accountId, id)
            XCTAssertEqual(report.limits?.accounts.first?.account.id, id)
            XCTAssertNil(report.accounts)
            XCTAssertEqual(report.summary?.total.tokens, 6_960_000_000)
        }
    }

    func testRoundTripPreservesRangesAndOriginalTimestamp() throws {
        let value = snapshot()
        let decoded = try RemoteJSON.decoder.decode(CloudSnapshot.self, from: RemoteJSON.encoder.encode(value))
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.generatedAt, now)
        for days in CloudSnapshot.supportedDays {
            let report = try decoded.report(days: days)
            XCTAssertEqual(report.summary?.days, days)
            XCTAssertEqual(report.timeline?.resolution, days == 1 ? "hour" : "day")
            XCTAssertEqual(report.summary?.generatedAt, now)
        }
    }

    #if os(macOS)
    func testUnprovisionedMacReturnsActionableErrorInsteadOfInitializingCloudKit() async {
        do {
            _ = try await CloudSnapshotStore().fetch()
            XCTFail("The test runner should not have PlanMeter’s iCloud entitlement")
        } catch CloudSyncError.unavailable {
            // Expected: do not let CloudKit terminate an ad-hoc SwiftPM process.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    #endif

    func testRejectsUnsupportedOrIncompleteSnapshots() throws {
        var value = snapshot()
        value.version = 2
        XCTAssertThrowsError(try value.report(days: 30))
        value.version = 1
        XCTAssertThrowsError(try value.report(days: 365))
        value.reports[0].timeline = nil
        XCTAssertThrowsError(try value.report(days: 1))
    }
}
