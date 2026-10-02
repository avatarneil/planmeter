import Foundation

/// Cloud estimates are dated per turn. Prefer a local rollout for an exact
/// thread ID, since an aggregate turn cannot be split around local responses.
public enum CodexCloudProjection {
    public static func merging(_ snapshots: [CodexCloudUsageSnapshot], into local: ScanOutput) -> ScanOutput {
        var result = local
        let localThreads = Set(local.threads.filter { $0.key.accountId.hasPrefix("codex:") }.map(\.sessionId))
        let owners = Dictionary(grouping: snapshots.compactMap { $0.target.localAccountId }, by: { $0 })
        var seenTurns: Set<String> = []
        var seenResponses: Set<String> = []
        for snapshot in snapshots {
            var folded = 0
            var skipped = 0
            if snapshot.fetchedAt != nil, let account = snapshot.target.localAccountId, owners[account]?.count == 1 {
                for turn in snapshot.turns {
                    guard !localThreads.contains(turn.reference.id) else { continue }
                    let totals = turn.totals ?? .zero
                    let charged = turn.serviceCostUsd.map { $0.isFinite && $0 > 0 } == true
                    guard !totals.isEmpty || charged else { continue }
                    let model = turn.model.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex model unavailable"
                    let id = "\(snapshot.target.serviceAccountId):\(turn.reference.id):\(turn.turnId)"
                    let responseKeys = turn.responseIds.map { "\(snapshot.target.serviceAccountId):\($0)" }
                    guard seenTurns.insert(id).inserted else { continue }
                    guard responseKeys.allSatisfy({ !seenResponses.contains($0) }) else { skipped += 1; continue }
                    let date = turn.completedAt ?? turn.startedAt
                    let timestamp = date.timeIntervalSince1970 * 1000
                    guard timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max) else { skipped += 1; continue }
                    let key = CellKey(hourStartMs: CellKey.hourStart(forMs: Int64(timestamp)), accountId: account, model: model)
                    var cell = result.cells[key] ?? Cell()
                    guard canAdd(totals, to: cell.totals), canAdd(totals, to: cell.unpricedTotals) else { skipped += 1; continue }
                    let record = UsageRecord(provider: .codex, timestampMs: Int64(timestamp), model: model,
                        sessionId: turn.reference.id, totals: totals, reportedCostUsd: turn.serviceCostUsd,
                        dedupeKey: id, planType: snapshot.target.plan)
                    cell.add(record)
                    result.cells[key] = cell
                    var threadCell = Cell()
                    threadCell.add(record)
                    result.threads.append(ThreadCellEntry(sessionId: turn.reference.id, key: key, cell: threadCell,
                        sourcePath: "codex://threads/\(turn.reference.id)"))
                    seenResponses.formUnion(responseKeys)
                    folded += 1
                }
            }
            var message = snapshot.message
            if snapshot.target.localAccountId == nil {
                message = "Cloud account attribution is ambiguous; its readings remain separate from chart totals."
            } else if skipped > 0 {
                message = (message.map { $0 + " " } ?? "") + "\(skipped) overlapping or invalid turn readings were excluded."
            }
            result.sources.append(SourceReport(provider: .codex, path: "Codex cloud usage · \(snapshot.target.name)",
                status: skipped > 0 ? .partial : snapshot.status, scannedFiles: folded, reusedFiles: 0,
                skippedFiles: snapshot.threadsUnavailable + skipped, message: message))
        }
        return result
    }

    public static func catalog(_ snapshots: [CodexCloudUsageSnapshot], local: [String: ThreadLink]) -> [String: ThreadLink] {
        var result = local
        for snapshot in snapshots {
            for turn in snapshot.turns {
                let key = "codex:\(turn.reference.id)"
                if result[key] == nil, let title = turn.reference.title, !title.isEmpty {
                    result[key] = ThreadLink(title: title, chatId: nil)
                }
            }
        }
        return result
    }

    private static func canAdd(_ value: TokenTotals, to existing: TokenTotals) -> Bool {
        let parts = [value.uncachedInput, value.cachedInput, value.cacheCreation, value.output]
        let previous = [existing.uncachedInput, existing.cachedInput, existing.cacheCreation, existing.output]
        var total = 0
        for (part, old) in zip(parts, previous) {
            guard part >= 0, old >= 0 else { return false }
            let sum = part.addingReportingOverflow(old)
            guard !sum.overflow else { return false }
            let all = total.addingReportingOverflow(sum.partialValue)
            guard !all.overflow else { return false }
            total = all.partialValue
        }
        return !value.reasoning.addingReportingOverflow(existing.reasoning).overflow
    }
}
