import XCTest
@testable import PlanMeterCore

final class CodexCloudUsageTests: XCTestCase {
    let threadId = "00000000-0000-4000-8000-000000000001"
    let turnId = "00000000-0000-4000-8000-000000000002"
    let secondId = "00000000-0000-4000-8000-000000000003"
    var reference: CodexThreadReference { CodexThreadReference(id: threadId, origin: "cloud", kind: "aeon_child") }
    var target: CodexUsageTarget {
        CodexUsageTarget(id: "workspace:user", name: "Work", home: "/tmp/unused", email: "member@example.com",
            plan: "business", serviceAccountId: "workspace", localAccountId: "codex:plan:business")
    }
    var now: Date { Date(timeIntervalSince1970: 1_790_976_000) }
    var turn: CodexCloudTurnUsage { CodexCloudTurnUsage(reference: reference, turnId: turnId,
        startedAt: now.addingTimeInterval(-300), completedAt: now.addingTimeInterval(-200)) }
    func estimated(_ id: String? = nil) -> [String: Any] {
        ["turn_id": id ?? turnId, "model": "gpt-6-astra", "estimated_usage_credits_micros": 195_316_500,
         "estimated_usage_usd_micros": 7_812_660, "net_new_input_tokens": 74_317,
         "cached_input_tokens": 6_381_440, "input_tokens": 6_455_757, "output_tokens": 13_761,
         "total_tokens": 6_469_518, "settled_response_ids": ["resp_one", "resp_two"]]
    }
    func response(_ rows: [[String: Any]]) -> [String: Any] { ["threads": [["thread_id": threadId, "turns": rows]]] }

    func testCloudBillableTurnsKeepExactProviderCostAndCachedInputSubset() throws {
        var second = turn; second.turnId = secondId
        var row = estimated(secondId)
        row["estimated_usage_credits_micros"] = 204_517_750; row["estimated_usage_usd_micros"] = 8_180_710
        row["net_new_input_tokens"] = 169_040; row["cached_input_tokens"] = 4_962_432
        row["input_tokens"] = 5_131_472; row["output_tokens"] = 31_899; row["total_tokens"] = 5_163_371
        row["settled_response_ids"] = ["resp_three"]
        let turns = try CodexCloudUsage.applyEstimates(response([estimated(), row]), turns: [turn, second])
        XCTAssertEqual(turns.compactMap(\.serviceCostUsd).reduce(0, +), 15.993370, accuracy: 0.000001)
        XCTAssertEqual(turns.compactMap(\.credits).reduce(0, +), 399.834250, accuracy: 0.000001)
        XCTAssertEqual(turns.compactMap(\.totals).reduce(TokenTotals.zero, +).total, 11_632_889)
        XCTAssertEqual(turns[0].totals?.uncachedInput, 74_317)
        XCTAssertEqual(turns[0].totals?.cachedInput, 6_381_440)
        XCTAssertEqual(turns[0].model, "gpt-6-astra")
        XCTAssertEqual(turns[0].responseIds, ["resp_one", "resp_two"])
        XCTAssertEqual(turns[0].completedAt, turn.completedAt)
    }

    func testHistoryUsesUnixSecondsAndExactThreadIdentity() throws {
        let page: [String: Any] = ["data": [["id": turnId, "startedAt": now.timeIntervalSince1970 - 300,
            "completedAt": now.timeIntervalSince1970 - 200, "itemsView": "notLoaded", "items": []]], "nextCursor": NSNull()]
        let value = try XCTUnwrap(CodexCloudUsage.decodeTurns(page, reference: reference, now: now).first)
        XCTAssertEqual(value.startedAt, turn.startedAt); XCTAssertEqual(value.completedAt, turn.completedAt)
        XCTAssertEqual(value.reference.id, threadId); XCTAssertNil(value.totals); XCTAssertNil(value.serviceCostUsd)
        var invalid = page; invalid["data"] = [["id": turnId, "startedAt": true]]
        XCTAssertThrowsError(try CodexCloudUsage.decodeTurns(invalid, reference: reference, now: now))
        invalid["data"] = [["id": turnId, "startedAt": now.timeIntervalSince1970 + 1_000]]
        XCTAssertThrowsError(try CodexCloudUsage.decodeTurns(invalid, reference: reference, now: now))
        invalid["data"] = (page["data"] as! [[String: Any]]) + (page["data"] as! [[String: Any]])
        XCTAssertThrowsError(try CodexCloudUsage.decodeTurns(invalid, reference: reference, now: now))
    }

    func testUnavailableSettlementRemainsUnknownAndExplicitZeroSurvives() throws {
        var row = estimated(); row["estimated_usage_usd_micros"] = 0; row["estimated_usage_credits_micros"] = 0
        let zero = try CodexCloudUsage.applyEstimates(response([row]), turns: [turn])[0]
        XCTAssertEqual(zero.serviceCostUsd, 0); XCTAssertEqual(zero.credits, 0); XCTAssertNotNil(zero.totals)
        row["settled_response_ids"] = NSNull()
        let pending = try CodexCloudUsage.applyEstimates(response([row]), turns: [turn])[0]
        XCTAssertEqual(pending.serviceCostUsd, 0); XCTAssertEqual(pending.credits, 0); XCTAssertNotNil(pending.totals)
        XCTAssertTrue(pending.responseIds.isEmpty)
        let missing = try CodexCloudUsage.applyEstimates(["threads": []], turns: [turn])[0]
        XCTAssertNil(missing.model); XCTAssertNil(missing.totals); XCTAssertNil(missing.serviceCostUsd)
        let housekeeping = try CodexCloudUsage.applyEstimates(response([["turn_id": turnId, "model": NSNull(),
            "estimated_usage_usd_micros": NSNull(), "settled_response_ids": NSNull()]]), turns: [turn])[0]
        XCTAssertNil(housekeeping.totals); XCTAssertNil(housekeeping.serviceCostUsd)
    }

    func testForeignDuplicateAndInconsistentBillingRowsAreRejected() throws {
        var row = estimated(); row["turn_id"] = secondId
        XCTAssertThrowsError(try CodexCloudUsage.applyEstimates(response([row]), turns: [turn]))
        XCTAssertThrowsError(try CodexCloudUsage.applyEstimates(response([estimated(), estimated()]), turns: [turn]))
        XCTAssertThrowsError(try CodexCloudUsage.applyEstimates(response([estimated()]), turns: [turn, turn]))
        for (key, value) in [("input_tokens", true as Any), ("cached_input_tokens", 8_000_000 as Any),
            ("total_tokens", 1 as Any), ("net_new_input_tokens", 1 as Any), ("estimated_usage_usd_micros", -1 as Any),
            ("settled_response_ids", ["resp_one", "resp_one"] as Any)] {
            var row = estimated(); row[key] = value
            XCTAssertThrowsError(try CodexCloudUsage.applyEstimates(response([row]), turns: [turn]), key)
        }
        XCTAssertThrowsError(try CodexCloudUsage.applyEstimates(["threads": [["thread_id": secondId,
            "turns": [estimated()]]]], turns: [turn]))
    }

    func testCloudSnapshotEncodingRetainsNilAmountsAndNoCredentials() throws {
        var snapshot = CodexCloudUsageSnapshot(target: target); snapshot.turns = [turn]; snapshot.status = .partial
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(CodexCloudUsageSnapshot.self, from: data)
        XCTAssertEqual(restored.turns.first?.id, turn.id); XCTAssertNil(restored.turns.first?.totals)
        XCTAssertNil(restored.turns.first?.serviceCostUsd)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("access_token")); XCTAssertFalse(text.contains("openai-bearer"))
    }

    func testCacheCoalescesAndRetainsStaleUntilIdentityChanges() async throws {
        let state = CloudReadState(target: target, turn: turn)
        let reader = CodexCloudUsage(reader: { _ in await state.read() })
        async let first = reader.load(targets: [target])
        async let second = reader.load(targets: [target])
        let pair = await (first, second)
        XCTAssertEqual(pair.0.first?.turns.count, 1); XCTAssertEqual(pair.1.first?.turns.count, 1)
        let firstCalls = await state.calls; XCTAssertEqual(firstCalls, 1)
        _ = await reader.load(targets: [target]); let cachedCalls = await state.calls; XCTAssertEqual(cachedCalls, 1)
        await state.set(.failed)
        let staleRows = await reader.load(targets: [target], force: true)
        let stale = try XCTUnwrap(staleRows.first)
        XCTAssertEqual(stale.status, .partial); XCTAssertEqual(stale.turns.count, 1)
        XCTAssertTrue(stale.message?.contains("Stale") == true)
        await state.set(.missing)
        let changedRows = await reader.load(targets: [target], force: true)
        let changed = try XCTUnwrap(changedRows.first)
        XCTAssertNil(changed.fetchedAt); XCTAssertTrue(changed.turns.isEmpty)
    }

    func testPersonalQuotaWindowsKeepTheirOwnUnitsAndUnknownValues() throws {
        let response: [String: Any] = ["threads": [["thread_id": threadId, "five_hour_limit_percent": "0.123456",
            "weekly_limit_percent": 1.25, "balance_usage_credits": "0E-10", "data_status": "partial", "usage_source": "unknown"]]]
        let quota = try XCTUnwrap(CodexCloudUsage.decodeQuotas(response, references: [reference]).first)
        XCTAssertEqual(quota.fiveHourLimitPercent, 0.123456); XCTAssertEqual(quota.weeklyLimitPercent, 1.25)
        XCTAssertEqual(quota.balanceUsageCredits, "0E-10"); XCTAssertEqual(quota.dataStatus, "partial")
        XCTAssertEqual(quota.usageSource, "unknown")
        XCTAssertThrowsError(try CodexCloudUsage.decodeQuotas(response, references: []))
        XCTAssertThrowsError(try CodexCloudUsage.decodeQuotas(["threads": [["thread_id": threadId,
            "weekly_limit_percent": true]]], references: [reference]))
        let missing = try XCTUnwrap(CodexCloudUsage.decodeQuotas(["threads": [["thread_id": threadId,
            "weekly_limit_percent": NSNull()]]], references: [reference]).first)
        XCTAssertNil(missing.weeklyLimitPercent); XCTAssertNil(missing.balanceUsageCredits)
        let adjustment = try XCTUnwrap(CodexCloudUsage.decodeQuotas(["threads": [["thread_id": threadId,
            "balance_usage_credits": "-1.25"]]], references: [reference]).first)
        XCTAssertEqual(adjustment.balanceUsageCredits, "-1.25")
    }

    func testMissingOrChangedLocalCredentialDropsCloudSnapshot() async {
        let snapshot = await CodexCloudUsage.read(target: target, timeout: 1)
        XCTAssertEqual(snapshot.status, .missing); XCTAssertNil(snapshot.fetchedAt); XCTAssertTrue(snapshot.turns.isEmpty)
    }

    func testNullableHistoryDatesDoNotEraseOtherDatedTurns() throws {
        let rows: [[String: Any]] = [["id": turnId, "startedAt": NSNull(), "completedAt": now.timeIntervalSince1970 - 100],
            ["id": secondId, "startedAt": NSNull(), "completedAt": NSNull()]]
        let turns = try CodexCloudUsage.decodeTurns(["data": rows], reference: reference, now: now)
        XCTAssertEqual(turns.count, 1)
        XCTAssertFalse(turns[0].startedAtIsKnown)
        XCTAssertEqual(turns[0].completedAt, now.addingTimeInterval(-100))
        XCTAssertEqual(turns[0].startedAt, turns[0].completedAt)
    }

    func testFreshInventoryRetainsExactAeonAttachmentButRefreshesRecency() {
        var cached = reference; cached.parentThreadId = secondId; cached.title = "Known task"; cached.updatedAt = 100
        var fresh = reference; fresh.kind = nil; fresh.updatedAt = 200
        let merged = CodexCloudUsage.mergeReference(fresh, cached: cached)
        XCTAssertEqual(merged.updatedAt, 200); XCTAssertEqual(merged.parentThreadId, secondId)
        XCTAssertEqual(merged.title, "Known task"); XCTAssertEqual(merged.kind, "aeon_child")
        fresh.parentThreadId = turnId; fresh.title = "Current title"
        let changed = CodexCloudUsage.mergeReference(fresh, cached: cached)
        XCTAssertEqual(changed.parentThreadId, turnId); XCTAssertEqual(changed.title, "Current title")
    }
}

private actor CloudReadState {
    let target: CodexUsageTarget
    let turn: CodexCloudTurnUsage
    var calls = 0
    var status: SourceStatus = .ok
    init(target: CodexUsageTarget, turn: CodexCloudTurnUsage) { self.target = target; self.turn = turn }
    func set(_ value: SourceStatus) { status = value }
    func read() async -> CodexCloudUsageSnapshot {
        calls += 1
        try? await Task.sleep(nanoseconds: 25_000_000)
        var value = CodexCloudUsageSnapshot(target: target); value.status = status
        if status == .ok { value.fetchedAt = Date(); value.turns = [turn] }
        return value
    }
}
