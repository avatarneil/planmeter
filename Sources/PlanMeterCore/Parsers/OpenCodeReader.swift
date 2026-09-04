import Foundation
import SQLite3

/// Reads assistant messages out of OpenCode's local SQLite database.
///
/// OpenCode is not covered by T3 Code's Usage page at all. Each assistant
/// message row stores its own token counts and the cost OpenCode computed, so
/// local models show real token volume at $0.
public enum OpenCodeReader {
    public struct Output: Sendable {
        public var records: [UsageRecord]
        public var status: SourceStatus
        public var message: String?
    }

    public static func read(databasePath: String, sinceMs: Int64) -> Output {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return Output(records: [], status: .missing, message: "Database not found.")
        }
        var db: OpaquePointer?
        // Open read-only; the WAL sidecar is handled by SQLite itself.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let db else {
            return Output(records: [], status: .failed, message: "Could not open database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let sql = """
        SELECT id, session_id, time_created, data
        FROM message
        WHERE time_created >= ?
          AND data LIKE '%"role":"assistant"%'
        ORDER BY time_created
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            return Output(records: [], status: .failed, message: msg)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sinceMs)

        var records: [UsageRecord] = []
        var malformed = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let created = sqlite3_column_int64(stmt, 2)
            guard let raw = sqlite3_column_text(stmt, 3) else { malformed += 1; continue }
            let data = Data(bytes: raw, count: Int(strlen(raw)))
            guard let obj = JSON.object(data), JSON.string(obj["role"]) == "assistant" else { continue }
            guard let tokens = JSON.object(obj["tokens"]) else { continue }
            let cache = JSON.object(tokens["cache"]) ?? [:]
            let output = JSON.positiveInt(tokens["output"])
            let totals = TokenTotals(
                uncachedInput: JSON.positiveInt(tokens["input"]),
                cachedInput: JSON.positiveInt(cache["read"]),
                cacheCreation: JSON.positiveInt(cache["write"]),
                output: output,
                // OpenCode reports reasoning outside `output`; fold it in so
                // the total matches what the provider billed.
                reasoning: 0
            )
            var withReasoning = totals
            let reasoning = JSON.positiveInt(tokens["reasoning"])
            withReasoning.output += reasoning
            withReasoning.reasoning = reasoning
            if withReasoning.isEmpty { continue }

            let providerID = JSON.string(obj["providerID"]) ?? "opencode"
            let modelID = JSON.string(obj["modelID"]) ?? "unknown"
            let time = JSON.object(obj["time"])
            let completed = JSON.double(time?["completed"]).map { Int64($0) }
            let timestampMs = completed ?? JSON.double(time?["created"]).map { Int64($0) } ?? created
            let cost = JSON.double(obj["cost"])

            records.append(UsageRecord(
                provider: .opencode,
                timestampMs: timestampMs,
                model: "\(providerID)/\(modelID)",
                sessionId: sessionId,
                totals: withReasoning,
                // OpenCode's own cost figure is authoritative, including $0
                // for local models; a missing field falls back to pricing.
                reportedCostUsd: cost,
                dedupeKey: id.isEmpty ? nil : id
            ))
        }
        let status: SourceStatus = malformed > 0 ? .partial : .ok
        return Output(records: records, status: status, message: malformed > 0 ? "\(malformed) rows unreadable." : nil)
    }
}
