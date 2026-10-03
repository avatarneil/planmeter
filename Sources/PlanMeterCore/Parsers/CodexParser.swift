import Foundation

/// Rolling state for one Codex rollout file. Ported from T3 Code's
/// `CodexScanState`, plus the plan type carried from `rate_limits`.
public struct CodexScanState: Sendable {
    public var model = ""
    public var turnId: String?
    public var sessionId = ""
    public var lastUsageSignature: String?
    public var sawSessionMeta = false
    public var suppressingForkCopies = false
    public var forkCopyAnchorMs: Int64 = 0
    public var forkCreatedMs: Int64?
    public var lastPlanType: String?
    var turnModels: [String: String] = [:]
    var turnPlans: [String: String] = [:]
    var modernTurns: Set<String> = []
    var seenResponseIds: Set<String> = []
    var pendingModernMirror = false
    var pendingModernTurnId: String?
    /// Most recent subscription-window reading seen in this file.
    public var latestRateLimits: RateLimitSnapshot?

    public init() {}
}

public enum CodexParser {
    static let gate = Data("\"token_count\"".utf8)
    static let modernGate = Data("\"token_usage_record\"".utf8)
    static let turnContextGate = Data("\"turn_context\"".utf8)
    static let sessionMetaGate = Data("\"session_meta\"".utf8)

    /// One second separates a fork's re-stamped parent history from the
    /// child's own first turn. Same threshold as T3 Code and ccusage.
    static let forkCopyMaxGapMs: Int64 = 1000

    /// The modern response precedes its legacy rate-limit/plan event, and
    /// retained compaction records can precede their matching turn context.
    /// Recover this metadata without deriving an account from the file path.
    static func preparedState(data: Data) -> CodexScanState {
        var state = CodexScanState()
        var sessionId: String?
        var turnId: String?
        data.forEachLine { line in
            guard line.range(of: gate) != nil || line.range(of: modernGate) != nil || line.range(of: turnContextGate) != nil
                    || line.range(of: sessionMetaGate) != nil,
                  let record = JSON.object(line), let payload = JSON.object(record["payload"]) else { return }
            switch JSON.string(record["type"]) {
            case "session_meta":
                if sessionId == nil { sessionId = JSON.string(payload["id"]) ?? JSON.string(payload["session_id"]) }
            case "turn_context":
                turnId = JSON.string(payload["turn_id"])
                if let turnId, let model = JSON.string(payload["model"]), state.turnModels[turnId] == nil {
                    state.turnModels[turnId] = model
                }
            case "token_usage_record":
                if JSON.string(payload["thread_id"]) == sessionId { turnId = JSON.string(payload["turn_id"]) }
            case "event_msg":
                guard JSON.string(payload["type"]) == "token_count",
                      let limits = JSON.object(payload["rate_limits"]), let plan = JSON.string(limits["plan_type"]) else { return }
                if state.lastPlanType == nil { state.lastPlanType = plan }
                if let turnId, state.turnPlans[turnId] == nil { state.turnPlans[turnId] = plan }
            default: break
            }
        }
        return state
    }

    public static func parse(line: Data, state: inout CodexScanState) -> UsageRecord? {
        let carriesUsage = line.range(of: gate) != nil
        if !carriesUsage && line.range(of: modernGate) == nil && line.range(of: turnContextGate) == nil && line.range(of: sessionMetaGate) == nil {
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
                state.forkCreatedMs = metaMs
            }
            return nil
        }

        if recordType == "turn_context" {
            let nextTurnId = JSON.string(payload["turn_id"])
            let nextModel = JSON.string(payload["model"])
            if nextTurnId != state.turnId || nextTurnId == nil || (nextModel != nil && nextModel != state.model) {
                state.lastUsageSignature = nil
            }
            if let nextModel { state.model = nextModel }
            state.turnId = nextTurnId
            if state.turnId != state.pendingModernTurnId { state.pendingModernMirror = false }
            return nil
        }

        if recordType == "token_usage_record" {
            guard let threadId = JSON.string(payload["thread_id"]), let turnId = JSON.string(payload["turn_id"]),
                  let responseId = JSON.string(payload["response_id"]) else { return nil }
            guard !state.sessionId.isEmpty else { return nil }
            if threadId != state.sessionId {
                // Copied parent responses and their mirrors are inherited
                // history, even if the child has already emitted a response.
                state.pendingModernMirror = true
                state.pendingModernTurnId = turnId
                return nil
            }
            guard let usage = JSON.object(payload["usage"]), let totals = tokenTotals(usage, requireTotal: true),
                  let timestampMs = JSON.timestampMs(record["timestamp"]) else { return nil }
            // The writer immediately follows a valid modern response with a
            // legacy mirror; it may be an estimated compaction payload.
            state.pendingModernMirror = true
            state.pendingModernTurnId = turnId
            state.modernTurns.insert(turnId)
            state.suppressingForkCopies = false
            let key = "\(threadId):\(responseId)"
            guard state.seenResponseIds.insert(key).inserted, !totals.isEmpty else { return nil }
            let model = state.turnId == turnId && !state.model.isEmpty ? state.model
                : state.turnModels[turnId] ?? "Codex model unavailable"
            let plan = state.turnPlans[turnId] ?? state.lastPlanType
            if let plan { state.lastPlanType = plan }
            return UsageRecord(provider: .codex, timestampMs: timestampMs, model: model, sessionId: threadId,
                               totals: totals, dedupeKey: key, planType: plan)
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
        let mirror = state.pendingModernMirror
        state.pendingModernMirror = false
        if mirror || state.turnId.map({ state.modernTurns.contains($0) }) == true { return nil }
        guard let timestampMs else { return nil }
        guard !state.model.isEmpty else { return nil }
        guard let totals = tokenTotals(last, requireTotal: false) else { return nil }

        if state.suppressingForkCopies {
            // Current forks preserve their parent's original timestamps. Keep
            // those earlier rows out even when they span many historical turns.
            if let created = state.forkCreatedMs, timestampMs < created { return nil }
            if timestampMs - state.forkCopyAnchorMs < forkCopyMaxGapMs {
                state.forkCopyAnchorMs = timestampMs
                return nil
            }
            state.suppressingForkCopies = false
        }

        let signature = usageSignature(last)
        if signature == state.lastUsageSignature { return nil }
        state.lastUsageSignature = signature

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
        last.keys.sorted().map { "\($0)=\(count(last[$0]) ?? 0)" }.joined(separator: ",")
    }

    /// Counters are finite, nonnegative integers. Validate both the inclusive
    /// input count and its cache subsets before doing any Int arithmetic.
    static func tokenTotals(_ usage: [String: Any], requireTotal: Bool) -> TokenTotals? {
        guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]),
              let cached = count(usage["cached_input_tokens"] ?? 0), let write = count(usage["cache_write_input_tokens"] ?? 0),
              let reasoning = count(usage["reasoning_output_tokens"] ?? 0) else { return nil }
        let cacheSum = cached.addingReportingOverflow(write), total = input.addingReportingOverflow(output)
        guard !cacheSum.overflow, cacheSum.partialValue <= input, !total.overflow, reasoning <= output else { return nil }
        if requireTotal || usage["total_tokens"] != nil {
            guard count(usage["total_tokens"]) == total.partialValue else { return nil }
        }
        return TokenTotals(uncachedInput: input - cacheSum.partialValue, cachedInput: cached, cacheCreation: write,
                           output: output, reasoning: reasoning)
    }

    static func count(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number >= 0, number.rounded(.down) == number, number < Double(Int.max),
              value.int64Value >= 0 else { return nil }
        return Int(exactly: value.int64Value)
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
        guard let minutes = count(w["window_minutes"]), let resets = count(w["resets_at"]), minutes > 0, resets > 0 else { return nil }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: Int64(resets))
    }
}
