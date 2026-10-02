import XCTest
@testable import PlanMeterCore

final class CodexDailyUsageTests: XCTestCase {
    let target = CodexUsageTarget(id: "workspace:member", name: "Workspace", home: "/tmp/unused", email: "member@example.com",
                                 plan: "business", serviceAccountId: "workspace", localAccountId: "codex:plan:business")
    let now = AccountUsageTests().now

    func credits(_ breakdown: String = "product", date: String = "2026-10-01", values: [String: Any]? = nil) -> [String: Any] {
        let values = values ?? (breakdown == "product" ? ["work": 20, "codex": 2, "chatgpt": 0.5] : ["test": 22, "voice": 0.5])
        return ["breakdown": breakdown, "series": values.keys.sorted().map { ["key": $0, "label": $0.capitalized] },
                "data_freshness_ts": "2026-10-02T02:00:00Z", "data": [["date": date, "values": values]]]
    }
    func tokens() -> [String: Any] {
        ["units": "credits", "group_by": "day", "data_freshness_ts": "2026-10-02T01:00:00Z", "data": [["date": "2026-10-01", "models": [
            ["model": "test", "speed": "standard", "credits": 20, "uncached_text_input_tokens": 20,
             "cached_text_input_tokens": 80, "text_output_tokens": 10, "text_total_tokens": 110],
            ["model": "test", "speed": "fast", "credits": 2, "uncached_text_input_tokens": 10,
             "cached_text_input_tokens": 30, "text_output_tokens": 10, "text_total_tokens": 50]]]]]
    }
    func snapshot() throws -> CodexDailyUsageSnapshot {
        try CodexDailyUsage.decode(products: credits(), modelCredits: credits("model"), tokens: tokens(),
                                  estimate: ["estimated_usage_usd_micros": 75_000], target: target,
                                  from: "2026-10-01", to: "2026-10-01", now: now)
    }

    func testDatedModelIOAndFastTierUseProviderCreditsWithoutDoubleCounting() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.credits, 22.5)
        XCTAssertEqual(snapshot.estimatedCostUsd, 1.6875)
        XCTAssertEqual(snapshot.dataFreshness, "2026-10-02T01:00:00Z")
        XCTAssertEqual(snapshot.days[0].modelCredits?.first { $0.key == "voice" }?.credits, 0.5)
        let standard = try XCTUnwrap(snapshot.days[0].textModels?.first { $0.speed == "standard" })
        XCTAssertEqual(standard.totalTokens, 110)
        XCTAssertEqual(standard.uncachedInputTokens, 20)
        XCTAssertEqual(standard.cachedInputTokens, 80)
        XCTAssertEqual(standard.outputTokens, 10)
        XCTAssertEqual(snapshot.days[0].textModels?.count, 2)
        // Text-model credits exclude voice; they are not added to product credits.
        XCTAssertEqual(snapshot.days[0].textModels?.reduce(0) { $0 + $1.credits }, 22)
    }

    func testJSONReportsExposeDailyUSDAndIOWithoutChangingLocalSpend() throws {
        var context = ReportContext(discovery: Discovery(), accounts: [], rates: RateTable(), scan: ScanOutput(), overrides: [:])
        let before = Report.summary(context, days: 2)["total"] as! [String: Any]
        var snapshot = try snapshot()
        let today = UsageCoverage.dayLabel(Date())
        snapshot.fromDay = today; snapshot.toDay = today; snapshot.days[0].date = today
        context.dailyUsage = [snapshot]
        let summary = Report.summary(context, days: 2)
        let after = summary["total"] as! [String: Any]
        XCTAssertEqual(after["costUsd"] as? Double, before["costUsd"] as? Double)
        XCTAssertEqual(after["tokens"] as? Int, before["tokens"] as? Int)
        let coverage = summary["accountWide"] as! [String: Any]
        let daily = coverage["dailyUsage"] as! [[String: Any]]
        XCTAssertEqual(daily[0]["credits"] as? Double, 22.5)
        XCTAssertEqual(daily[0]["estimatedCostUsd"] as? Double, 1.6875)
        let days = daily[0]["days"] as! [[String: Any]]
        XCTAssertEqual(days[0]["estimatedCostUsd"] as? Double, 1.6875)
        let models = days[0]["textModels"] as! [[String: Any]]
        XCTAssertEqual(models.first { $0["speed"] as? String == "standard" }?["uncachedInputTokens"] as? Int, 20)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(summary))
    }

    func testMissingDatesAndConversionStayUnavailableWhileExplicitZeroIsZero() throws {
        let snapshot = try CodexDailyUsage.decode(products: credits(values: ["codex": 0]), modelCredits: nil, tokens: nil,
            estimate: nil, target: target, from: "2026-10-01", to: "2026-10-02", now: now)
        XCTAssertEqual(snapshot.credits, 0)
        XCTAssertNil(snapshot.estimatedCostUsd)
        XCTAssertEqual(snapshot.missingCreditDays, ["2026-10-02"])
        XCTAssertEqual(snapshot.status, .partial)
        let today = snapshot.selected(days: 1, now: now)
        XCTAssertEqual(today.fromDay, "2026-10-02")
        XCTAssertNil(today.credits)
        XCTAssertNil(today.estimatedCostUsd)
        XCTAssertEqual(today.missingCreditDays, ["2026-10-02"])
        XCTAssertEqual(snapshot.selected(days: 2, now: now).credits, 0)
    }

    func testPercentFeedAndMalformedOptionalComponentsCannotHideGoodCredits() throws {
        var percentages = tokens()
        percentages["units"] = "percent"
        let snapshot = try CodexDailyUsage.decode(products: credits(), modelCredits: credits("wrong"), tokens: percentages,
            estimate: ["estimated_usage_usd_micros": true], target: target, from: "2026-10-01", to: "2026-10-01")
        XCTAssertEqual(snapshot.credits, 22.5)
        XCTAssertNil(snapshot.days[0].textModels)
        XCTAssertNil(snapshot.days[0].modelCredits)
        XCTAssertNil(snapshot.estimatedCostUsd)
        XCTAssertEqual(snapshot.status, .partial)
    }

    func testInvalidCreditsDatesDuplicatesAndTokenTotalsAreRejected() throws {
        for value: Any in [true, -1, "100", Double.infinity] {
            XCTAssertThrowsError(try CodexDailyUsage.creditRows(credits(values: ["test": value]), breakdown: "product", from: "2026-10-01", to: "2026-10-02"))
        }
        for date in ["2026-02-31", "2026-09-30", "2026-10-1"] {
            XCTAssertThrowsError(try CodexDailyUsage.creditRows(credits(date: date), breakdown: "product", from: "2026-10-01", to: "2026-10-02"))
        }
        var duplicate = credits()
        duplicate["data"] = [duplicate["data"] as! [[String: Any]], duplicate["data"] as! [[String: Any]]].flatMap { $0 }
        XCTAssertThrowsError(try CodexDailyUsage.creditRows(duplicate, breakdown: "product", from: "2026-10-01", to: "2026-10-02"))
        for bad: Any in [true, -1, 1.5, Double(Int.max)] {
            var invalid = tokens()
            var rows = invalid["data"] as! [[String: Any]]
            var models = rows[0]["models"] as! [[String: Any]]
            models[0]["text_output_tokens"] = bad
            rows[0]["models"] = models; invalid["data"] = rows
            XCTAssertThrowsError(try CodexDailyUsage.tokenRows(invalid, from: "2026-10-01", to: "2026-10-02"))
        }
        var invalid = tokens()
        var rows = invalid["data"] as! [[String: Any]]
        var models = rows[0]["models"] as! [[String: Any]]
        models[0]["text_total_tokens"] = 111
        rows[0]["models"] = models; invalid["data"] = rows
        XCTAssertThrowsError(try CodexDailyUsage.tokenRows(invalid, from: "2026-10-01", to: "2026-10-02"))
    }

    func testCoalescingCacheForcedRefreshAndStaleReadings() async throws {
        actor Reads {
            var count = 0
            func read(_ target: CodexUsageTarget, from: String, to: String) async -> CodexDailyUsageSnapshot {
                count += 1
                let attempt = count
                try? await Task.sleep(for: .milliseconds(20))
                var value = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
                if attempt == 1 { value.fetchedAt = Date(); value.status = .ok }
                else { value.status = .failed; value.message = "Refresh failed." }
                return value
            }
        }
        let reads = Reads()
        let loader = CodexDailyUsage { await reads.read($0, from: $1, to: $2) }
        async let first = loader.load(targets: [target], now: now)
        async let second = loader.load(targets: [target], now: now)
        let values = await [first, second]
        XCTAssertNotNil(values[0][0].fetchedAt)
        XCTAssertNotNil(values[1][0].fetchedAt)
        let count = await reads.count
        XCTAssertEqual(count, 1)
        _ = await loader.load(targets: [target], now: now.addingTimeInterval(299))
        let stale = await loader.load(targets: [target], force: true, now: now.addingTimeInterval(299))[0]
        XCTAssertNotNil(stale.fetchedAt)
        XCTAssertEqual(stale.status, .partial)
        XCTAssertTrue(stale.message?.hasPrefix("Stale daily analytics.") == true)
        var other = target
        other.home = "/tmp/other-login"
        let isolated = await loader.load(targets: [other], now: now)[0]
        XCTAssertNil(isolated.fetchedAt)
    }

    func testIdentityFailureDropsCachedMetricsInsteadOfReturningStaleOtherUser() async {
        actor Reads {
            var count = 0
            func read(_ target: CodexUsageTarget, from: String, to: String) -> CodexDailyUsageSnapshot {
                count += 1
                var value = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
                if count == 1 { value.fetchedAt = Date(); value.status = .ok }
                else { value.status = .missing }
                return value
            }
        }
        let reads = Reads()
        let loader = CodexDailyUsage { await reads.read($0, from: $1, to: $2) }
        _ = await loader.load(targets: [target], now: now)
        let next = await loader.load(targets: [target], force: true, now: now)[0]
        XCTAssertNil(next.fetchedAt)
    }

    func testCredentialRequiresExactDiscoveredLoginAndIsNeverEncoded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var target = target; target.home = dir.path
        let payload: [String: Any] = ["email": target.email, "https://api.openai.com/auth": ["chatgpt_account_id": target.serviceAccountId, "chatgpt_plan_type": target.plan]]
        let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let secret = "e30.\(encoded).private-test-credential"
        try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": secret, "access_token": secret]]).write(to: dir.appendingPathComponent("auth.json"))
        XCTAssertEqual(try CodexDailyUsage.credential(target: target), secret)
        let data = try JSONEncoder().encode(CodexDailyUsageSnapshot(target: target, fromDay: "2026-10-01", toDay: "2026-10-01"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        target.serviceAccountId = "other-workspace"
        XCTAssertThrowsError(try CodexDailyUsage.credential(target: target))
    }
}
