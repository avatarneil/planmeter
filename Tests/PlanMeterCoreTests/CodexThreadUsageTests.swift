import XCTest
@testable import PlanMeterCore

final class CodexThreadUsageTests: XCTestCase {
    let dot = "6abee66a-0f8c-8191-bd03-3fa7172510f7"
    let task = "6abfc44a-09e0-8191-8bd0-42930721f0c0"

    func fixture() -> [String: Any] {
        ["threadUsage": ["threadId": dot, "estimatedUsageCreditsMicros": 0, "estimatedUsageUsdMicros": 0,
            "groups": [["model": "test", "reasoningEffort": "medium", "speed": "standard",
                "estimatedUsageCreditsMicros": 0, "netNewInputTokens": 20, "cachedInputTokens": 80,
                "inputTokens": 100, "outputTokens": 10, "totalTokens": 110]]]]
    }

    func testZeroBillingStillHasPricedTokenBreakdownWithoutDoubleCountingCachedInput() throws {
        let ref = CodexThreadReference(id: dot, origin: "cloud")
        let usage = try XCTUnwrap(CodexThreadUsage.decode(fixture(), reference: ref))
        let rates = RateTable(rates: ["test": ModelRate(input: 0.1, output: 0.2, cacheRead: 0.01, cacheCreation: 0.1)])
        XCTAssertEqual(usage.scope, "lifetime")
        XCTAssertEqual(usage.serviceCostUsd, 0)
        XCTAssertEqual(usage.estimatedUsageCreditsMicros, 0)
        XCTAssertEqual(usage.totalTokens, 110)
        XCTAssertEqual(try XCTUnwrap(usage.tokenRateCost(rates: rates)), 4.8, accuracy: 0.00001)
        XCTAssertNil(usage.tokenRateCost(rates: RateTable()))
    }

    func testMissingFieldsAndUnavailableServiceReadingStayUnavailable() throws {
        let ref = CodexThreadReference(id: dot, origin: "cloud")
        XCTAssertNil(try CodexThreadUsage.decode(["threadUsage": NSNull()], reference: ref))
        let value: [String: Any] = ["threadUsage": ["threadId": dot, "estimatedUsageCreditsMicros": 3_500_000,
            "estimatedUsageUsdMicros": NSNull(), "groups": [["model": "test", "estimatedUsageCreditsMicros": 3_500_000,
                "inputTokens": 100, "cachedInputTokens": 80, "outputTokens": NSNull()]]]]
        let usage = try XCTUnwrap(CodexThreadUsage.decode(value, reference: ref))
        XCTAssertNil(usage.serviceCostUsd)
        XCTAssertNil(usage.totalTokens)
        XCTAssertNil(usage.tokenRateCost(rates: RateTable(rates: ["test": ModelRate(input: 1, output: 1, cacheRead: 1, cacheCreation: 1)])))
    }

    func testMalformedBreakdownAndWrongThreadAreRejected() throws {
        let ref = CodexThreadReference(id: task, origin: "cloud")
        XCTAssertThrowsError(try CodexThreadUsage.decode(fixture(), reference: ref))
        for bad: Any in [true, -1, 1.5, Double.infinity, "100"] {
            let value: [String: Any] = ["threadUsage": ["threadId": task, "estimatedUsageCreditsMicros": 0,
                "groups": [["estimatedUsageCreditsMicros": 0, "outputTokens": bad]]]]
            XCTAssertThrowsError(try CodexThreadUsage.decode(value, reference: ref))
        }
        let invalidCache: [String: Any] = ["threadUsage": ["threadId": task, "estimatedUsageCreditsMicros": 0,
            "groups": [["estimatedUsageCreditsMicros": 0, "inputTokens": 10, "cachedInputTokens": 11]]]]
        XCTAssertThrowsError(try CodexThreadUsage.decode(invalidCache, reference: ref))
    }

    func testCloudCacheAndSpawnedTasksAreDeduplicatedAndIsolatedByAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var target = CodexUsageTarget(id: "owner", name: "Owner", home: dir.path, email: "test@example.com", plan: "business", serviceAccountId: "owner")
        let data: [String: Any] = ["electron-persisted-atom-state": [
            "cloud-aeon-sidebar-cache-v1": ["accountId": "owner", "userId": "owner-user", "threads": [
                ["id": dot, "name": "Dot", "updatedAt": 200, "threadSource": "aeon"],
                ["id": task, "name": "Task", "updatedAt": 100, "threadSource": "aeon_child"],
                ["id": "bad-id", "name": "Ignore"]]],
            "aeon-subtasks-by-account-v1": ["owner": ["[\"durable\",\"\(dot)\"]": [task, task]]]]]
        try JSONSerialization.data(withJSONObject: data).write(to: dir.appendingPathComponent(".codex-global-state.json"))
        let refs = CodexThreadUsage.references(target: target)
        XCTAssertEqual(Set(refs.map(\.id)), Set([dot, task]))
        XCTAssertEqual(refs.first { $0.id == task }?.parentThreadId, dot)
        XCTAssertEqual(refs.first { $0.id == dot }?.title, "Dot")
        XCTAssertEqual(CodexThreadUsage.references(target: target, limit: 1).count, 1)
        target.serviceAccountId = "different"
        XCTAssertTrue(CodexThreadUsage.references(target: target).isEmpty)
        target.serviceAccountId = "owner"
        let claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_user_id": "different-user"]]
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "e30.\(encoded).signature"]])
            .write(to: dir.appendingPathComponent("auth.json"))
        XCTAssertTrue(CodexThreadUsage.references(target: target).isEmpty)
    }

    func testLifetimeServiceUsageNeverChangesDailyReconciliationOrSpend() throws {
        let old = AccountUsageTests()
        var snapshot = old.snapshot()
        snapshot.serviceThreads = [try XCTUnwrap(CodexThreadUsage.decode(fixture(), reference: CodexThreadReference(id: dot, origin: "cloud")))]
        let row = UsageCoverage.reconcile([snapshot], entries: [old.entry()], rates: RateTable(), days: 1, now: old.now)[0]
        XCTAssertEqual(row.accountTokens, 250)
        XCTAssertEqual(row.knownThreadTokens, 100)
        XCTAssertEqual(row.knownThreadCostUsd, 2)
        XCTAssertEqual(row.differenceTokens, 150)
        XCTAssertEqual(row.knownThreads, 1)
    }
}
