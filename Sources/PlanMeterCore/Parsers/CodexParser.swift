import Foundation

/// Rolling state for one Codex rollout file. Ported from T3 Code's
/// `CodexScanState`, plus the plan type carried from `rate_limits`.
public struct CodexScanState: Sendable {
    public var model = ""
    public var sessionId = ""
    public var lastUsageSignature: String?
    public var sawSessionMeta = false
    public var suppressingForkCopies = false
    public var forkCopyAnchorMs: Int64 = 0
    public var lastPlanType: String?
    /// Most recent subscription-window reading seen in this file.
    public var latestRateLimits: RateLimitSnapshot?

    public init() {}
}

public enum CodexParser {
    static let gate = Data("\"token_count\"".utf8)
    static let turnContextGate = Data("\"turn_context\"".utf8)
    static let sessionMetaGate = Data("\"session_meta\"".utf8)

    /// One second separates a fork's re-stamped parent history from the
    /// child's own first turn. Same threshold as T3 Code and ccusage.
    static let forkCopyMaxGapMs: Int64 = 1000

    public static func parse(line: Data, state: inout CodexScanState) -> UsageRecord? {
        let carriesUsage = line.range(of: gate) != nil
        if !carriesUsage && line.range(of: turnContextGate) == nil && line.range(of: sessionMetaGate) == nil {
            return nil
        }
        guard let record = JSON.object(line), let payload = JSON.object(record["payload"]) else { return nil }
        let recordType = JSON.string(record["type"])

        if recordType == "session_meta" {
            if state.sawSessionMeta { return nil }
            state.sawSessionMeta = true
            if let id = JSON.string(payload["id"]) ?? JSON.string(payload["session_id"]) { state.sessionId = id }
            if let metaMs = JSON.timestampMs(record["timestamp"]), isForked(payload) {
                state.suppressingForkCopies = true
                state.forkCopyAnchorMs = metaMs
            }
            return nil
        }

        if recordType == "turn_context" {
            if let model = JSON.string(payload["model"]) { state.model = model }
            return nil
        }

        guard JSON.string(payload["type"]) == "token_count" else { return nil }
        let timestampMs = JSON.timestampMs(record["timestamp"])

        if let limits = JSON.object(payload["rate_limits"]) {
            if let plan = JSON.string(limits["plan_type"]) { state.lastPlanType = plan }
            if let timestampMs, let snapshot = rateLimitSnapshot(limits, timestampMs: timestampMs, fallbackPlan: state.lastPlanType) {
                state.latestRateLimits = snapshot
            }
        }

        guard let info = JSON.object(payload["info"]), let last = JSON.object(info["last_token_usage"]) else { return nil }
        guard let timestampMs else { return nil }
        guard !state.model.isEmpty else { return nil }

        let signature = usageSignature(last)
        if signature == state.lastUsageSignature { return nil }
        state.lastUsageSignature = signature

        if state.suppressingForkCopies {
            if timestampMs - state.forkCopyAnchorMs < forkCopyMaxGapMs {
                state.forkCopyAnchorMs = timestampMs
                return nil
            }
            state.suppressingForkCopies = false
        }

        let inputTokens = JSON.positiveInt(last["input_tokens"])
        let cached = JSON.positiveInt(last["cached_input_tokens"])
        let cacheWrite = JSON.positiveInt(last["cache_write_input_tokens"])
        let output = JSON.positiveInt(last["output_tokens"])
        let totals = TokenTotals(
            uncachedInput: max(0, inputTokens - cached - cacheWrite),
            cachedInput: cached,
            cacheCreation: cacheWrite,
            output: output,
            reasoning: min(output, JSON.positiveInt(last["reasoning_output_tokens"]))
        )
        if totals.isEmpty { return nil }

        return UsageRecord(
            provider: .codex,
            timestampMs: timestampMs,
            model: state.model,
            sessionId: state.sessionId,
            totals: totals,
            reportedCostUsd: nil,
            dedupeKey: nil,
            planType: state.lastPlanType
        )
    }

    static func isForked(_ payload: [String: Any]) -> Bool {
        if JSON.string(payload["forked_from_id"]) != nil { return true }
        guard let source = JSON.object(payload["source"]),
              let subagent = JSON.object(source["subagent"]),
              let spawn = JSON.object(subagent["thread_spawn"]) else { return false }
        return JSON.string(spawn["parent_thread_id"]) != nil
    }

    /// Order-independent fingerprint of the usage payload for duplicate
    /// suppression. JSON key order is not stable through `JSONSerialization`.
    static func usageSignature(_ last: [String: Any]) -> String {
        last.keys.sorted().map { "\($0)=\(JSON.positiveInt(last[$0]))" }.joined(separator: ",")
    }

    static func rateLimitSnapshot(_ limits: [String: Any], timestampMs: Int64, fallbackPlan: String?) -> RateLimitSnapshot? {
        guard let plan = JSON.string(limits["plan_type"]) ?? fallbackPlan else { return nil }
        let credits = JSON.object(limits["credits"])
        return RateLimitSnapshot(
            planType: plan,
            timestampMs: timestampMs,
            primary: window(limits["primary"]),
            secondary: window(limits["secondary"]),
            hasCredits: JSON.bool(credits?["has_credits"]),
            unlimitedCredits: JSON.bool(credits?["unlimited"]),
            creditsBalance: JSON.string(credits?["balance"])
        )
    }

    static func window(_ value: Any?) -> RateLimitWindow? {
        guard let w = JSON.object(value), let used = JSON.double(w["used_percent"]) else { return nil }
        let minutes = JSON.positiveInt(w["window_minutes"])
        let resets = JSON.double(w["resets_at"]).map { Int64($0) } ?? 0
        guard minutes > 0, resets > 0 else { return nil }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resets)
    }
}
