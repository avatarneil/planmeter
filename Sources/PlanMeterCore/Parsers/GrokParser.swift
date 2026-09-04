import Foundation

/// Parses Grok Build `sessions/<id>/updates.jsonl`. Ported from T3 Code's
/// `parseGrokLine`; usage lands on `turn_completed` updates and is split per
/// model when `usage.modelUsage` is present.
public enum GrokParser {
    static let gate = Data("\"turn_completed\"".utf8)
    /// Grok reports cost in integer ticks where 1 USD = 10^10 ticks.
    public static let ticksPerDollar: Double = 10_000_000_000

    struct Totals {
        var input = 0, output = 0, cachedRead = 0, cacheCreation = 0, reasoning = 0
        var costTicks: Double?

        init?(_ value: Any?) {
            guard let r = JSON.object(value) else { return nil }
            input = JSON.positiveInt(r["inputTokens"])
            output = JSON.positiveInt(r["outputTokens"])
            cachedRead = JSON.positiveInt(r["cachedReadTokens"])
            cacheCreation = JSON.positiveInt(r["cacheCreationTokens"])
            reasoning = JSON.positiveInt(r["reasoningTokens"])
            costTicks = JSON.double(r["costUsdTicks"])
        }

        var usage: TokenTotals {
            TokenTotals(
                uncachedInput: max(0, input - cachedRead - cacheCreation),
                cachedInput: cachedRead,
                cacheCreation: cacheCreation,
                output: output,
                reasoning: min(output, reasoning)
            )
        }

        var costUsd: Double? {
            guard let ticks = costTicks, ticks >= 0 else { return nil }
            return ticks / GrokParser.ticksPerDollar
        }
    }

    public static func parse(line: Data) -> [UsageRecord] {
        guard line.range(of: gate) != nil, let record = JSON.object(line) else { return [] }
        guard let params = JSON.object(record["params"]), let update = JSON.object(params["update"]) else { return [] }
        guard JSON.string(update["sessionUpdate"]) == "turn_completed", let usage = JSON.object(update["usage"]) else { return [] }

        let sessionId = JSON.string(params["sessionId"]) ?? ""
        let promptId = JSON.string(update["prompt_id"])

        var timestampMs: Int64?
        if let meta = JSON.object(params["_meta"]), let agentMs = JSON.double(meta["agentTimestampMs"]) {
            timestampMs = Int64(agentMs)
        }
        if timestampMs == nil, let ts = JSON.double(record["timestamp"]) {
            timestampMs = Int64(ts > 1e12 ? ts : ts * 1000)
        }
        guard let timestampMs else { return [] }
        guard let topLevel = Totals(usage) else { return [] }

        var models: [(String, Totals)] = []
        if let modelUsage = JSON.object(usage["modelUsage"]) {
            for (model, raw) in modelUsage where !model.isEmpty {
                if let t = Totals(raw) { models.append((model, t)) }
            }
            models.sort { $0.0 < $1.0 }
        }

        if models.isEmpty {
            let totals = topLevel.usage
            if totals.isEmpty { return [] }
            return [UsageRecord(
                provider: .grok,
                timestampMs: timestampMs,
                model: "grok",
                sessionId: sessionId,
                totals: totals,
                reportedCostUsd: topLevel.costUsd,
                dedupeKey: promptId.map { "\(sessionId):\($0):grok" }
            )]
        }

        // Models with their own ticks keep them; the remaining aggregate cost
        // is pro-rated by token share across the models that lack ticks.
        var tickedCost = 0.0
        var untickedTokens = 0
        for (_, t) in models {
            let tokens = t.usage.total
            if tokens == 0 { continue }
            if let c = t.costUsd { tickedCost += c } else { untickedTokens += tokens }
        }
        let remaining: Double? = topLevel.costUsd.map { max(0, $0 - tickedCost) }

        var out: [UsageRecord] = []
        for (model, t) in models {
            let totals = t.usage
            if totals.isEmpty { continue }
            var cost = t.costUsd
            if cost == nil, let remaining, untickedTokens > 0 {
                cost = remaining * (Double(totals.total) / Double(untickedTokens))
            }
            out.append(UsageRecord(
                provider: .grok,
                timestampMs: timestampMs,
                model: model,
                sessionId: sessionId,
                totals: totals,
                reportedCostUsd: cost,
                dedupeKey: promptId.map { "\(sessionId):\($0):\(model)" }
            ))
        }
        return out
    }
}
