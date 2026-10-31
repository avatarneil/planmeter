import Foundation
import SQLite3

/// Reads Antigravity conversation SQLite databases (`<session-id>.db`).
///
/// Ported from T3 Code's `antigravityUsageReader.ts`: decodes protobuf blobs
/// in `gen_metadata`, `steps`, and `trajectory_metadata_blob`, and merges
/// candidate records that share request/response identifiers across tables.
public enum AntigravityReader {
    enum DecodeError: Error {
        case invalidProtobuf
        case invalidDatabase
    }

    enum ProtoValue: Sendable {
        case varint(UInt64)
        case bytes(Data)
    }

    typealias ProtoFields = [Int: [ProtoValue]]

    static let maxSafeInteger: UInt64 = 9_007_199_254_740_991

    public static let modelIds: [Int: String] = [
        246: "gemini-2.5-pro",
        312: "gemini-2.5-flash",
        313: "gemini-2.5-flash-thinking",
        329: "gemini-2.5-flash-thinking",
        330: "gemini-2.5-flash-lite",
        281: "claude-sonnet-4",
        282: "claude-sonnet-4",
        290: "claude-opus-4",
        291: "claude-opus-4",
        333: "claude-sonnet-4-5",
        334: "claude-sonnet-4-5",
        340: "claude-haiku-4-5",
        341: "claude-haiku-4-5",
        1026: "claude-opus-4-6",
        1035: "claude-sonnet-4-6",
        1016: "gemini-3.1-pro",
        1036: "gemini-3.1-pro",
        1037: "gemini-3.1-pro",
        1018: "gemini-3-flash-preview",
        1084: "gemini-3-flash-preview",
        1047: "gemini-3-flash-preview",
    ]

    struct MetadataEntry: Sendable {
        var model: String
        var timestampMs: Int64?
        var usages: [ProtoFields]
    }

    struct Candidate: Sendable {
        var record: UsageRecord
        var keys: [String]
        var timestampQuality: Int
    }

    struct Group {
        var record: UsageRecord
        var timestampQuality: Int
        var parent: Int
        var size: Int
        var owner: Int
    }

    /// Parses one conversation `.db` file and returns its merged usage records,
    /// or `nil` when the file is unreadable or not an Antigravity conversation DB.
    public static func parseDatabase(path: String, fallbackTimestampMs: Int64) -> [UsageRecord]? {
        let sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard let candidates = try? readDatabase(path: path, sessionId: sessionId, fallbackTimestampMs: fallbackTimestampMs) else {
            return nil
        }
        return mergeCandidates(candidates)
    }

    static func readDatabase(path: String, sessionId: String, fallbackTimestampMs: Int64) throws -> [Candidate] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw DecodeError.invalidDatabase
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        let tables = try readTableNames(db: db)
        guard tables.contains("gen_metadata") || tables.contains("steps") else {
            throw DecodeError.invalidDatabase
        }

        let generations: [(idx: Int, entry: MetadataEntry)] = tables.contains("gen_metadata")
            ? try readMetadataRows(db: db, query: "SELECT idx, data FROM gen_metadata ORDER BY rowid", step: false)
            : []

        var trajectoryTimestamp: Int64?
        if tables.contains("trajectory_metadata_blob") {
            trajectoryTimestamp = try readTrajectoryTimestamp(db: db)
        }

        let steps: [(idx: Int, entry: MetadataEntry)] = tables.contains("steps")
            ? try readMetadataRows(db: db, query: "SELECT idx, metadata AS data FROM steps ORDER BY rowid", step: true)
            : []

        return try usageCandidates(
            sessionId: sessionId,
            generations: generations,
            steps: steps,
            trajectoryTimestamp: trajectoryTimestamp,
            fallbackTimestamp: fallbackTimestampMs
        )
    }

    private static func readTableNames(db: OpaquePointer) throws -> Set<String> {
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DecodeError.invalidDatabase
        }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    names.insert(String(cString: cStr))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DecodeError.invalidDatabase
            }
        }
        return names
    }

    private static func readMetadataRows(db: OpaquePointer, query: String, step: Bool) throws -> [(idx: Int, entry: MetadataEntry)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DecodeError.invalidDatabase
        }
        defer { sqlite3_finalize(stmt) }
        var entries: [(idx: Int, entry: MetadataEntry)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if step, sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                    continue
                }
                guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER else {
                    throw DecodeError.invalidDatabase
                }
                let idx = Int(sqlite3_column_int64(stmt, 0))
                guard sqlite3_column_type(stmt, 1) == SQLITE_BLOB else {
                    throw DecodeError.invalidDatabase
                }
                let byteCount = Int(sqlite3_column_bytes(stmt, 1))
                let blob: Data
                if byteCount > 0, let raw = sqlite3_column_blob(stmt, 1) {
                    blob = Data(bytes: raw, count: byteCount)
                } else {
                    blob = Data()
                }
                let parsed = try parseMetadata(blob, step: step)
                entries.append((idx: idx, entry: parsed))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DecodeError.invalidDatabase
            }
        }
        entries.sort { $0.idx < $1.idx }
        return entries
    }

    private static func readTrajectoryTimestamp(db: OpaquePointer) throws -> Int64? {
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM trajectory_metadata_blob"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DecodeError.invalidDatabase
        }
        defer { sqlite3_finalize(stmt) }
        var resolved: Int64?
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                guard sqlite3_column_type(stmt, 0) == SQLITE_BLOB else {
                    throw DecodeError.invalidDatabase
                }
                let byteCount = Int(sqlite3_column_bytes(stmt, 0))
                let blob: Data
                if byteCount > 0, let raw = sqlite3_column_blob(stmt, 0) {
                    blob = Data(bytes: raw, count: byteCount)
                } else {
                    blob = Data()
                }
                let fields = try parseFields(blob)
                let nestedFields = try nested(fields, 2)
                if resolved == nil {
                    resolved = timestampMs(nestedFields)
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DecodeError.invalidDatabase
            }
        }
        return resolved
    }

    static func parseMetadata(_ bytes: Data, step: Bool) throws -> MetadataEntry {
        let root = try parseFields(bytes)
        if !step, bytesAt(root, 1) == nil {
            throw DecodeError.invalidProtobuf
        }
        let data = try step ? root : nested(root, 1)
        let modelFields = try step ? nested(data, 24) : data
        var usages: [ProtoFields] = []
        if let usageBytes = bytesAt(data, step ? 9 : 4) {
            usages.append(try parseFields(usageBytes))
        }
        for retryValue in data[step ? 28 : 17] ?? [] {
            guard case .bytes(let retryBytes) = retryValue else {
                throw DecodeError.invalidProtobuf
            }
            let retryFields = try parseFields(retryBytes)
            if let retryUsage = bytesAt(retryFields, 2) {
                usages.append(try parseFields(retryUsage))
            }
        }
        let firstText = try textAt(modelFields, step ? 12 : 19)
        let secondText = try firstText.isEmpty ? textAt(modelFields, step ? 8 : 21) : firstText
        let modelId = numberAt(modelFields, step ? 1 : 3)
        let ts: Int64?
        if step {
            let ts8 = try timestampMs(nested(data, 8))
            let ts1 = try timestampMs(nested(data, 1))
            ts = ts8 ?? ts1
        } else {
            ts = try timestampMs(nested(nested(data, 9), 4))
        }
        return MetadataEntry(
            model: modelName(name: secondText, id: modelId),
            timestampMs: ts,
            usages: usages
        )
    }

    static func usageCandidates(
        sessionId: String,
        generations: [(idx: Int, entry: MetadataEntry)],
        steps: [(idx: Int, entry: MetadataEntry)],
        trajectoryTimestamp: Int64?,
        fallbackTimestamp: Int64
    ) throws -> [Candidate] {
        var candidates: [Candidate] = []
        var generationModels: [Int: String] = [:]
        for (idx, entry) in generations {
            generationModels[idx] = entry.model
        }
        let defaultModel = generations.compactMap { nonEmpty($0.entry.model) }.first
            ?? steps.compactMap { nonEmpty($0.entry.model) }.first

        for (source, entries) in [("step", steps), ("generation", generations)] {
            var lastKnownModel: String? = defaultModel
            for (index, item) in entries.enumerated() {
                let idx = item.idx
                let entry = item.entry
                if let entryModel = nonEmpty(entry.model) {
                    lastKnownModel = entryModel
                } else if source == "step", let genModel = nonEmpty(generationModels[idx]) {
                    lastKnownModel = genModel
                }
                for (usageIndex, usage) in entry.usages.enumerated() {
                    let outputTokens = max(numberAt(usage, 3), numberAt(usage, 9) + numberAt(usage, 10))
                    let totals = TokenTotals(
                        uncachedInput: numberAt(usage, 2),
                        cachedInput: numberAt(usage, 5),
                        cacheCreation: numberAt(usage, 4),
                        output: outputTokens,
                        reasoning: min(outputTokens, numberAt(usage, 9))
                    )
                    if totals.isEmpty { continue }

                    var keys: [String] = []
                    for key in [11, 12, 7] {
                        let id = try textAt(usage, key)
                        if !id.isEmpty {
                            keys.append("antigravity:\(key):\(id)")
                        }
                    }

                    let usageModelId = numberAt(usage, 1)
                    let resolvedModel = nonEmpty(modelIds[usageModelId])
                        ?? nonEmpty(entry.model)
                        ?? (source == "step" ? nonEmpty(generationModels[idx]) : nil)
                        ?? nonEmpty(modelName(name: "", id: usageModelId))
                        ?? lastKnownModel
                        ?? "antigravity-unknown"
                    lastKnownModel = resolvedModel

                    let timestampMs = entry.timestampMs ?? trajectoryTimestamp ?? fallbackTimestamp
                    let dedupeKey = keys.first ?? "antigravity:\(sessionId):\(source):\(index):\(usageIndex)"
                    let record = UsageRecord(
                        provider: .antigravity,
                        timestampMs: timestampMs,
                        model: resolvedModel,
                        sessionId: sessionId,
                        totals: totals,
                        reportedCostUsd: nil,
                        dedupeKey: dedupeKey
                    )
                    let quality = entry.timestampMs != nil ? 2 : (trajectoryTimestamp != nil ? 1 : 0)
                    candidates.append(Candidate(record: record, keys: keys, timestampQuality: quality))
                }
            }
        }
        return candidates
    }

    static func mergeCandidates(_ candidates: [Candidate]) -> [UsageRecord] {
        var groups: [Group] = []
        groups.reserveCapacity(candidates.count)
        var identities: [String: Int] = [:]

        func find(_ start: Int) -> Int {
            var root = start
            while groups[root].parent != root {
                root = groups[root].parent
            }
            var index = start
            while index != root {
                let parent = groups[index].parent
                groups[index].parent = root
                index = parent
            }
            return root
        }

        func merge(_ left: Int, _ right: Int) {
            var a = find(left)
            var b = find(right)
            if a == b { return }
            if groups[a].size < groups[b].size {
                swap(&a, &b)
            }
            let target = groups[a]
            let source = groups[b]
            let first = target.owner < source.owner ? target : source
            let other = target.owner < source.owner ? source : target
            let bestTime: Group
            if source.timestampQuality > target.timestampQuality
                || (source.timestampQuality == target.timestampQuality && source.record.timestampMs < target.record.timestampMs) {
                bestTime = source
            } else {
                bestTime = target
            }
            let x = target.record.totals
            let y = source.record.totals
            var mergedRecord = first.record
            if mergedRecord.model == "antigravity-unknown" {
                mergedRecord.model = other.record.model
            }
            mergedRecord.timestampMs = bestTime.record.timestampMs
            mergedRecord.totals = TokenTotals(
                uncachedInput: max(x.uncachedInput, y.uncachedInput),
                cachedInput: max(x.cachedInput, y.cachedInput),
                cacheCreation: max(x.cacheCreation, y.cacheCreation),
                output: max(x.output, y.output),
                reasoning: max(x.reasoning, y.reasoning)
            )
            groups[a].record = mergedRecord
            groups[a].timestampQuality = bestTime.timestampQuality
            groups[a].owner = first.owner
            groups[a].size = target.size + source.size
            groups[b].parent = a
        }

        for candidate in candidates {
            let index = groups.count
            groups.append(Group(
                record: candidate.record,
                timestampQuality: candidate.timestampQuality,
                parent: index,
                size: 1,
                owner: index
            ))
            for key in candidate.keys {
                if let existing = identities[key] {
                    merge(index, existing)
                }
                identities[key] = index
            }
        }

        var out: [UsageRecord] = []
        for (index, group) in groups.enumerated() where group.parent == index {
            out.append(group.record)
        }
        return out
    }

    static func modelName(name: String, id: Int) -> String {
        if !name.isEmpty {
            var normalized = name.lowercased()
            if let parenRange = normalized.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
                normalized.removeSubrange(parenRange)
            }
            normalized = normalized.replacingOccurrences(of: " ", with: "-")
            if normalized.hasPrefix("claude-") {
                normalized = normalized.replacingOccurrences(
                    of: #"^claude-(4(?:\.\d+)?)-(sonnet|opus|haiku)"#,
                    with: "claude-$2-$1",
                    options: .regularExpression
                ).replacingOccurrences(of: ".", with: "-")
            }
            return normalized
        }
        return modelIds[id] ?? (id > 0 ? "antigravity-model-\(id)" : "")
    }

    // MARK: - Protobuf wire helpers

    static func parseFields(_ bytes: Data) throws -> ProtoFields {
        var offset = bytes.startIndex
        let end = bytes.endIndex
        var result: ProtoFields = [:]

        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 70 {
                guard offset < end else { throw DecodeError.invalidProtobuf }
                let byte = bytes[offset]
                offset += 1
                if shift == 63, byte > 1 {
                    throw DecodeError.invalidProtobuf
                }
                value |= UInt64(byte & 0x7F) << shift
                if byte < 128 {
                    return value
                }
                shift += 7
            }
            throw DecodeError.invalidProtobuf
        }

        while offset < end {
            let tag = try readVarint()
            guard tag <= maxSafeInteger else { throw DecodeError.invalidProtobuf }
            let number = Int(tag / 8)
            let wire = Int(tag % 8)
            guard number > 0 else { throw DecodeError.invalidProtobuf }

            switch wire {
            case 0:
                let v = try readVarint()
                result[number, default: []].append(.varint(v))
            case 1:
                guard end - offset >= 8 else { throw DecodeError.invalidProtobuf }
                offset += 8
            case 5:
                guard end - offset >= 4 else { throw DecodeError.invalidProtobuf }
                offset += 4
            case 2:
                let rawLength = try readVarint()
                guard rawLength <= maxSafeInteger, rawLength <= UInt64(end - offset) else {
                    throw DecodeError.invalidProtobuf
                }
                let length = Int(rawLength)
                let slice = Data(bytes[offset..<(offset + length)])
                offset += length
                result[number, default: []].append(.bytes(slice))
            default:
                throw DecodeError.invalidProtobuf
            }
        }
        return result
    }

    static func numberAt(_ fields: ProtoFields, _ key: Int) -> Int {
        guard case .varint(let v) = fields[key]?.first, v <= maxSafeInteger, let n = Int(exactly: v) else {
            return 0
        }
        return n
    }

    static func bytesAt(_ fields: ProtoFields, _ key: Int) -> Data? {
        guard case .bytes(let data) = fields[key]?.first else { return nil }
        return data
    }

    static func nested(_ fields: ProtoFields, _ key: Int) throws -> ProtoFields {
        guard let data = bytesAt(fields, key) else { return [:] }
        return try parseFields(data)
    }

    static func textAt(_ fields: ProtoFields, _ key: Int) throws -> String {
        guard let data = bytesAt(fields, key) else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DecodeError.invalidProtobuf
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func timestampMs(_ fields: ProtoFields) -> Int64? {
        let seconds = numberAt(fields, 1)
        guard seconds > 0 else { return nil }
        let nanos = numberAt(fields, 2)
        return Int64(seconds) * 1000 + Int64(nanos / 1_000_000)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
