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

    // Sanitized shape of the live workspace groups response. Two reasoning
    // efforts deliberately share a model and speed, as real provider rows do.
    func productTokens() -> [String: [String: Any]] {
        func group(model: String, speed: String, reasoning: String, surface: String, credits: Double,
                   input: Int, cached: Int, output: Int) -> [String: Any] {
            ["dimensions": ["model": model, "speed": speed, "reasoning_effort": reasoning, "surface": surface],
             "is_other": false, "credits": credits, "on_demand_credits": credits,
             "uncached_text_input_tokens": input, "cached_text_input_tokens": cached,
             "text_output_tokens": output, "text_total_tokens": input + cached + output, "total_tokens": input + cached + output]
        }
        func feed(_ groups: [[String: Any]]) -> [String: Any] {
            ["units": "credits", "group_by": "day", "breakdown_by": ["model", "reasoning_effort", "speed", "surface"],
             "data_freshness_ts": "2026-10-02T00:30:00Z", "data": [["date": "2026-10-01", "groups": groups]]]
        }
        return ["work": feed([
            group(model: "test", speed: "standard", reasoning: "low", surface: "work", credits: 12, input: 12, cached: 40, output: 6),
            group(model: "test", speed: "standard", reasoning: "high", surface: "work", credits: 8, input: 8, cached: 40, output: 4)]),
                "codex": feed([group(model: "test", speed: "fast", reasoning: "low", surface: "unknown", credits: 2, input: 10, cached: 30, output: 10)])]
    }

    func mutateGroups(_ feed: [String: Any], _ mutate: (inout [[String: Any]]) -> Void) -> [String: Any] {
        var feed = feed
        var data = feed["data"] as! [[String: Any]]
        var groups = data[0]["groups"] as! [[String: Any]]
        mutate(&groups)
        data[0]["groups"] = groups
        feed["data"] = data
        return feed
    }

    func detailedSnapshot(_ productTokens: [String: [String: Any]]) throws -> CodexDailyUsageSnapshot {
        try CodexDailyUsage.decode(products: credits(), modelCredits: credits("model"), tokens: tokens(),
                                  estimate: ["estimated_usage_usd_micros": 75_000], target: target,
                                  from: "2026-10-01", to: "2026-10-01", productTokens: productTokens, now: now)
    }

    func testProductReasoningSurfaceGroupsReconcileWithoutAddingSpendOrTokens() throws {
        let snapshot = try detailedSnapshot(productTokens())
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.credits, 22.5)
        XCTAssertEqual(snapshot.estimatedCostUsd, 1.6875)
        XCTAssertEqual(snapshot.dataFreshness, "2026-10-02T00:30:00Z")
        let models = try XCTUnwrap(snapshot.days.first?.textModels)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(Set(models.map(\.id)).count, 3)
        XCTAssertEqual(models.reduce(0) { $0 + $1.totalTokens }, 160)
        XCTAssertEqual(models.reduce(0) { $0 + $1.credits }, 22)
        XCTAssertEqual(Set(models.filter { $0.product == "work" }.compactMap(\.reasoningEffort)), ["low", "high"])
        let codex = try XCTUnwrap(models.first { $0.product == "codex" })
        XCTAssertEqual(codex.surface, "unknown") // Mode identifies the product, even when surface is unknown.
        XCTAssertEqual(codex.totalTokens, 50)
        let data = try JSONEncoder().encode(models)
        let roundTrip = try JSONDecoder().decode([DailyModelTokens].self, from: data)
        XCTAssertEqual(roundTrip.map(\.id), models.map(\.id))
    }

    func testGroupedIdentityIncludesEveryDimensionAndRejectsDuplicateRows() throws {
        let work = try XCTUnwrap(productTokens()["work"])
        XCTAssertEqual(try CodexDailyUsage.groupedTokenRows(work, product: "work", from: "2026-10-01", to: "2026-10-01")["2026-10-01"]?.count, 2)
        let duplicate = mutateGroups(work) { $0.append($0[0]) }
        XCTAssertThrowsError(try CodexDailyUsage.groupedTokenRows(duplicate, product: "work", from: "2026-10-01", to: "2026-10-01"))
        let rows = try XCTUnwrap(CodexDailyUsage.groupedTokenRows(work, product: "work", from: "2026-10-01", to: "2026-10-01")["2026-10-01"])
        var otherSurface = rows[0]; otherSurface.surface = "codex"
        var otherProduct = rows[0]; otherProduct.product = "codex"
        XCTAssertNotEqual(rows[0].id, otherSurface.id)
        XCTAssertNotEqual(rows[0].id, otherProduct.id)
    }

    func testProviderOtherRetainsUnknownAttributionAndMarksDetailPartial() throws {
        var feeds = productTokens()
        feeds["codex"] = mutateGroups(try XCTUnwrap(feeds["codex"])) {
            $0[0]["dimensions"] = [String: String](); $0[0]["is_other"] = true
        }
        // Other can retain already unknown baseline attribution. If the
        // baseline knows the model, that knowledge must survive the group cap.
        let fallback = try detailedSnapshot(feeds)
        XCTAssertEqual(fallback.days[0].textModels?.count, 2)
        XCTAssertNil(fallback.days[0].textModels?.first { $0.model == "other" })
        XCTAssertEqual(fallback.status, .partial)
        var baseline = tokens()
        var data = baseline["data"] as! [[String: Any]]
        var models = data[0]["models"] as! [[String: Any]]
        models[1]["model"] = "other"; models[1]["speed"] = "unknown"
        data[0]["models"] = models; baseline["data"] = data
        let snapshot = try CodexDailyUsage.decode(products: credits(), modelCredits: credits("model"), tokens: baseline,
            estimate: ["estimated_usage_usd_micros": 75_000], target: target, from: "2026-10-01", to: "2026-10-01",
            productTokens: feeds, now: now)
        let other = try XCTUnwrap(snapshot.days[0].textModels?.first { $0.model == "other" })
        XCTAssertEqual(other.product, "codex")
        XCTAssertEqual(other.speed, "unknown")
        XCTAssertNil(other.reasoningEffort)
        XCTAssertNil(other.surface)
        XCTAssertEqual(other.totalTokens, 50)
        XCTAssertEqual(other.credits, 2)
        XCTAssertEqual(snapshot.estimatedCostUsd, 1.6875)
        XCTAssertEqual(snapshot.status, .partial)
    }

    func testMissingMalformedOrInconsistentProductDetailsFallBackToBaseline() throws {
        var missing = productTokens(); missing.removeValue(forKey: "work")
        var invalid = productTokens()
        invalid["work"] = mutateGroups(try XCTUnwrap(invalid["work"])) { $0[0]["is_other"] = 1 }
        var wrongCredits = productTokens()
        wrongCredits["work"] = mutateGroups(try XCTUnwrap(wrongCredits["work"])) { $0[0]["credits"] = 11 }
        var wrongIO = productTokens()
        wrongIO["work"] = mutateGroups(try XCTUnwrap(wrongIO["work"])) {
            $0[0]["uncached_text_input_tokens"] = 11; $0[0]["cached_text_input_tokens"] = 41
        }
        var wrongModel = productTokens()
        wrongModel["work"] = mutateGroups(try XCTUnwrap(wrongModel["work"])) {
            var dimensions = $0[0]["dimensions"] as! [String: String]
            dimensions["model"] = "different-model"; $0[0]["dimensions"] = dimensions
        }
        for feed in [missing, invalid, wrongCredits, wrongIO, wrongModel] {
            let snapshot = try detailedSnapshot(feed)
            XCTAssertEqual(snapshot.status, .partial)
            XCTAssertTrue(snapshot.message?.contains("detail is unavailable") == true)
            XCTAssertEqual(snapshot.days[0].textModels?.count, 2)
            XCTAssertTrue(snapshot.days[0].textModels?.allSatisfy { $0.product == nil } == true)
            XCTAssertEqual(snapshot.days[0].textModels?.reduce(0) { $0 + $1.totalTokens }, 160)
            XCTAssertEqual(snapshot.estimatedCostUsd, 1.6875)
        }
        let unavailableUSD = try CodexDailyUsage.decode(products: credits(), modelCredits: credits("model"), tokens: tokens(),
            estimate: nil, target: target, from: "2026-10-01", to: "2026-10-01", productTokens: missing)
        XCTAssertTrue(unavailableUSD.message?.contains("USD readings are unavailable") == true)
        XCTAssertTrue(unavailableUSD.message?.contains("detail is unavailable") == true)
    }

    func testRepeatedQueryDimensionsAndLegacyCodableRemainCompatible() throws {
        let items = CodexDailyUsage.productQueryItems("codex")
        XCTAssertEqual(items.filter { $0.name == "breakdown_by" }.compactMap(\.value), ["model", "reasoning_effort", "speed", "surface"])
        XCTAssertEqual(items.first { $0.name == "modes" }?.value, "codex")
        let original = try XCTUnwrap(try snapshot().days[0].textModels?.first)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DailyModelTokens.self, from: data)
        XCTAssertNil(decoded.product)
        XCTAssertNil(decoded.reasoningEffort)
        XCTAssertNil(decoded.surface)
        // Old memberwise calls still compile without the optional dimensions.
        let legacy = DailyModelTokens(model: "test", speed: "standard", credits: 1, uncachedInputTokens: 1,
                                      cachedInputTokens: 2, outputTokens: 3, totalTokens: 6)
        XCTAssertNil(legacy.product)
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

    func testFocusedDayHasItsOwnCacheAndInvalidDatesNeverReachTheReader() async {
        actor Reads {
            var ranges: [String] = []
            func read(_ target: CodexUsageTarget, from: String, to: String) -> CodexDailyUsageSnapshot {
                ranges.append("\(from):\(to)")
                var result = CodexDailyUsageSnapshot(target: target, fromDay: from, toDay: to)
                result.fetchedAt = Date(); result.status = .ok
                return result
            }
        }
        let reads = Reads()
        let loader = CodexDailyUsage { await reads.read($0, from: $1, to: $2) }
        _ = await loader.load(targets: [target], now: now)
        let focused = await loader.loadDay(targets: [target], date: "2026-10-01")[0]
        XCTAssertEqual(focused.fromDay, "2026-10-01")
        XCTAssertEqual(focused.toDay, "2026-10-01")
        _ = await loader.loadDay(targets: [target], date: "2026-10-01")
        let invalid = await loader.loadDay(targets: [target], date: "2026-02-31")[0]
        XCTAssertEqual(invalid.status, .failed)
        let ranges = await reads.ranges
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.last, "2026-10-01:2026-10-01")
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
