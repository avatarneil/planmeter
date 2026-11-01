import XCTest
@testable import PlanMeterCore

final class PlanLimitsTests: XCTestCase {
    let claude = PlanLimitTarget(accountId: "claude:home:/tmp/projects", provider: .claude, email: "me@example.com")

    /// Trimmed from a real `get_usage` reply (Claude Code 2.1.314).
    let usage: [String: Any] = [
        "subscription_type": "max",
        "rate_limits_available": true,
        "rate_limits": [
            "five_hour": ["utilization": 6, "resets_at": "2026-11-01T07:19:59.851432+00:00"],
            "seven_day": ["utilization": 3, "resets_at": "2026-11-04T16:59:59.851453+00:00"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": ["utilization": 120, "resets_at": NSNull()],
            "extra_usage": ["is_enabled": false, "utilization": NSNull()],
            "model_scoped": [
                ["display_name": "Fable", "utilization": 0, "resets_at": "2026-11-04T17:00:00+00:00"],
                ["display_name": "Sonnet", "utilization": 9, "resets_at": "2026-11-04T17:00:00+00:00"],
            ],
        ] as [String: Any],
    ]

    func testDecodesClaudeWindowsWithMicrosecondResets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try ClaudePlanLimits.decodeClaude(usage, target: claude, now: now)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour", "Weekly", "Weekly · Sonnet", "Weekly · Fable"])
        let five = snapshot.windows[0]
        XCTAssertEqual(five.usedPercent, 6)
        XCTAssertEqual(five.windowMinutes, 300)
        XCTAssertEqual(five.resetsAt?.timeIntervalSince1970 ?? 0, 1_793_517_599, accuracy: 1)
        XCTAssertEqual(five.windowStart, five.resetsAt?.addingTimeInterval(-300 * 60))
        // Clamped, and an unknown reset stays unknown rather than becoming now.
        XCTAssertEqual(snapshot.windows[2].usedPercent, 100)
        XCTAssertNil(snapshot.windows[2].resetsAt)
        XCTAssertEqual(snapshot.tightest?.label, "Weekly · Sonnet")
    }

    func testClaudeLoginWithoutSubscriptionLimitsIsNotAFailure() throws {
        let snapshot = try ClaudePlanLimits.decodeClaude(["rate_limits_available": false], target: claude)
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.message)
        XCTAssertThrowsError(try ClaudePlanLimits.decodeClaude(["rate_limits_available": true], target: claude))
    }

    func testIncludesEnabledExtraUsageWithoutInventingAReset() throws {
        var response = usage
        var limits = response["rate_limits"] as! [String: Any]
        limits["extra_usage"] = ["is_enabled": true, "utilization": 42.5]
        response["rate_limits"] = limits
        let extra = try ClaudePlanLimits.decodeClaude(response, target: claude).windows.last
        XCTAssertEqual(extra?.label, "Extra usage")
        XCTAssertEqual(extra?.usedPercent, 42.5)
        XCTAssertNil(extra?.resetsAt)
        XCTAssertNil(extra?.windowStart)
    }

    func testReadsClaudeLimitsThroughControlRequestsOnly() throws {
        let (script, log) = try fakeClaude(email: "ME@example.com")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let target = PlanLimitTarget(accountId: claude.accountId, provider: .claude, configDir: "/tmp/claude-work", email: claude.email)
        let snapshot = ClaudePlanLimits.read(target: target, executableURL: script, timeout: 10)
        XCTAssertEqual(snapshot.status, .ok, snapshot.message ?? "")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 6)
        let recorded = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(recorded.contains("CLAUDE_CONFIG_DIR=/tmp/claude-work"))
        XCTAssertTrue(recorded.contains("--no-session-persistence"))
        XCTAssertTrue(recorded.contains("\"subtype\":\"get_usage\""))
        XCTAssertFalse(recorded.contains("\"type\":\"user\""), "No prompt may be sent.")
    }

    func testRejectsClaudeLimitsForADifferentLogin() throws {
        let (script, _) = try fakeClaude(email: "someone-else@example.com")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let snapshot = ClaudePlanLimits.read(target: claude, executableURL: script, timeout: 10)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.message?.contains("differs") == true)
    }

    func testAntigravitySummaryBucketsAreLabelledByFamilyAndCadence() {
        let summary: [String: Any] = ["groups": [
            ["displayName": "Gemini models", "buckets": [
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.75, "resetTime": "2026-11-01T05:00:00Z"],
                ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 1.4],
            ]],
            ["displayName": "Partner models", "buckets": [
                ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.1, "resetTime": "2026-11-04T00:00:00.123456Z"],
                ["bucketId": "3p-off", "window": "weekly", "remainingFraction": 0, "disabled": true],
                ["bucketId": "flex", "displayName": "Flex credits", "remainingFraction": 0.5],
                ["bucketId": "no-reading", "window": "weekly"],
            ]],
        ]]
        let windows = AntigravityPlanLimits.summaryWindows(summary)
        XCTAssertEqual(windows.map(\.label), ["Gemini · 5-hour", "Gemini · Weekly", "Claude & GPT (shared) · Weekly", "Partner models · Flex credits"])
        XCTAssertEqual(windows.map(\.usedPercent), [25, 0, 90, 50])
        XCTAssertEqual(windows.map(\.windowMinutes), [300, 10080, 10080, nil])
        XCTAssertNotNil(windows[2].resetsAt)
        XCTAssertNil(windows[3].resetsAt)
        // Ungrouped buckets are read when no group carries any.
        XCTAssertEqual(AntigravityPlanLimits.summaryWindows(["buckets": [["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5]]]).count, 1)
    }

    func testAntigravityModelQuotasKeepTheTightestPerFamily() {
        let response: [String: Any] = ["models": [
            "gemini-3-pro": ["modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": ["remainingFraction": 0.8]],
            "gemini-3-flash": ["quotaInfo": ["remainingFraction": 0.2, "resetTime": "2026-11-01T00:00:00Z"]],
            "claude-sonnet-4-6": ["modelProvider": "MODEL_PROVIDER_ANTHROPIC", "weeklyQuotaInfo": ["remainingFraction": 0.6]],
            "mystery": ["quotaInfo": ["remainingFraction": 0]],
        ]]
        let windows = AntigravityPlanLimits.modelWindows(response)
        XCTAssertEqual(Set(windows.map(\.label)), ["Gemini · Quota", "Claude · Weekly"])
        let gemini = windows.first { $0.id == "gemini-quota" }
        XCTAssertEqual(gemini?.usedPercent ?? 0, 80, accuracy: 0.0001)
        XCTAssertNil(gemini?.windowMinutes)
        XCTAssertEqual(windows.first { $0.id == "claude-weekly" }?.windowMinutes, 10080)
    }

    func testAntigravityWithoutAProfileTokenExplainsInsteadOfFailing() async {
        let target = PlanLimitTarget(accountId: "antigravity:home:/x", provider: .antigravity, tokenPath: "/nonexistent/acp_token.json")
        let snapshot = await AntigravityPlanLimits.read(target: target)
        XCTAssertEqual(snapshot.status, .missing)
        XCTAssertNotNil(snapshot.message)
        let apiKey = PlanLimitTarget(accountId: "antigravity:home:/x", provider: .antigravity, tokenPath: "/nonexistent", authMethod: "gemini-api-key")
        let unsupported = await AntigravityPlanLimits.read(target: apiKey)
        XCTAssertTrue(unsupported.message?.contains("Google sign-in") == true)
    }

    func testFailedRefreshKeepsTheLastReadingMarkedStale() async {
        final class Reads: @unchecked Sendable {
            var count = 0
            let lock = NSLock()
            func read(_ target: PlanLimitTarget) -> PlanLimitSnapshot {
                lock.lock(); defer { lock.unlock() }
                count += 1
                var snapshot = PlanLimitSnapshot(target: target)
                if count == 1 {
                    snapshot.windows = [PlanLimitWindow(id: "five_hour", label: "5-hour", usedPercent: 40, windowMinutes: 300)]
                    snapshot.status = .ok
                    snapshot.fetchedAt = Date()
                } else {
                    snapshot.status = .failed
                    snapshot.message = "Timed out."
                }
                return snapshot
            }
        }
        let reads = Reads()
        let limits = PlanLimits(reader: { reads.read($0) })
        let first = await limits.load(targets: [claude])
        _ = await limits.load(targets: [claude])
        XCTAssertEqual(reads.count, 1, "Readings are reused for five minutes.")
        let stale = await limits.load(targets: [claude], force: true)
        XCTAssertEqual(stale[0].windows, first[0].windows)
        XCTAssertEqual(stale[0].status, .partial)
        XCTAssertTrue(stale[0].message?.hasPrefix("Stale reading.") == true)
    }

    func testDiscoveryTargetsClaudeConfigDirsAndAntigravityProfiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claudeHome = dir.appendingPathComponent("claude-work")
        let acp = dir.appendingPathComponent("agy/antigravity-acp")
        try FileManager.default.createDirectory(at: claudeHome.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: acp.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"work@example.com"}}"#.write(to: claudeHome.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let settings = T3Settings(instances: [
            T3ProviderInstance(id: "claudeAgent", driver: "claudeAgent"),
            T3ProviderInstance(id: "claude-work", driver: "claudeAgent", homePath: claudeHome.path),
            T3ProviderInstance(id: "antigravity", driver: "antigravity", homePath: acp.path, authMethod: "oauth-personal"),
        ], settingsPath: dir.appendingPathComponent("settings.json"))
        let targets = AccountDiscovery.discover(settings: settings, environment: [:]).planLimitTargets
        let claudeTargets = targets.filter { $0.provider == .claude }
        XCTAssertEqual(claudeTargets.map(\.configDir), [nil, claudeHome.path])
        XCTAssertEqual(claudeTargets.last?.email, "work@example.com")
        XCTAssertEqual(claudeTargets.last?.accountId, Account.claudeId(transcriptDir: claudeHome.appendingPathComponent("projects").path))
        let antigravity = targets.first { $0.provider == .antigravity }
        XCTAssertEqual(antigravity?.tokenPath, acp.appendingPathComponent("acp_token.json").path)
        XCTAssertEqual(antigravity?.authMethod, "oauth-personal")
    }

    /// A stand-in `claude` that answers control requests and logs its inputs.
    private func fakeClaude(email: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("log")
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        echo "args: $*" >> '\(log.path)'
        echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >> '\(log.path)'
        while IFS= read -r line; do
          echo "$line" >> '\(log.path)'
          case "$line" in
            *planmeter-init*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"planmeter-init","response":{"account":{"email":"\(email)"}}}}' ;;
            *planmeter-usage*) echo '{"type":"system","subtype":"noise"}'; echo '{"type":"control_response","response":{"subtype":"success","request_id":"planmeter-usage","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":6,"resets_at":"2026-11-01T07:19:59.851432+00:00"}}}}}' ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }
}
