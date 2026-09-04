import Foundation

/// Parses Claude Code `~/.claude/projects/**/*.jsonl` transcripts.
///
/// Ported from T3 Code's `parseClaudeLine`: one record per assistant content
/// block, each repeating the parent message's full `usage`, so callers must
/// drop repeats by `dedupeKey` and keep the first.
public enum ClaudeParser {
    static let gate = Data("\"usage\"".utf8)

    public static func parse(line: Data) -> UsageRecord? {
        guard line.range(of: gate) != nil, let record = JSON.object(line) else { return nil }
        guard JSON.string(record["type"]) == "assistant" else { return nil }
        guard let message = JSON.object(record["message"]), let usage = JSON.object(message["usage"]) else { return nil }
        guard let timestampMs = JSON.timestampMs(record["timestamp"]) else { return nil }
        guard let model = JSON.string(message["model"]) else { return nil }

        let messageId = JSON.string(message["id"])
        let requestId = JSON.string(record["requestId"])
        let dedupeKey: String? = (messageId == nil && requestId == nil) ? nil : "\(messageId ?? ""):\(requestId ?? "")"

        let totals = TokenTotals(
            uncachedInput: JSON.positiveInt(usage["input_tokens"]),
            cachedInput: JSON.positiveInt(usage["cache_read_input_tokens"]),
            cacheCreation: JSON.positiveInt(usage["cache_creation_input_tokens"]),
            output: JSON.positiveInt(usage["output_tokens"]),
            reasoning: 0
        )
        let cost = JSON.double(record["costUSD"])
        // Locally synthesized messages (`<synthetic>`) carry an all-zero usage
        // block; counting them would invent sessions with no tokens.
        if totals.isEmpty && (cost ?? 0) == 0 { return nil }

        return UsageRecord(
            provider: .claude,
            timestampMs: timestampMs,
            model: model,
            sessionId: JSON.string(record["sessionId"]) ?? "",
            totals: totals,
            reportedCostUsd: cost,
            dedupeKey: dedupeKey
        )
    }
}
