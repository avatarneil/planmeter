import Foundation

/// Prefer a dated workspace reading over overlapping local estimates for the
/// same unambiguous account/day. Never add lifetime or generic account tokens.
public enum UsageProjection {
    public struct Result {
        public var buckets: [Bucket]
        public var workspaceAccountIds: Set<String>
    }

    public static func available(_ snapshots: [CodexDailyUsageSnapshot], accounts: [Account]) -> Bool {
        snapshots.contains { snapshot in
            snapshot.fetchedAt != nil && snapshot.target.localAccountId.map { id in accounts.contains { $0.id == id } } == true
                && snapshot.days.contains { $0.credits != nil && $0.textModels != nil && snapshot.estimatedUsdPerCredit != nil }
        }
    }

    public static func buckets(local: [Bucket], snapshots: [CodexDailyUsageSnapshot], accounts: [Account],
                               from: Date, to: Date, calendar: Calendar = .current) -> Result {
        struct Key: Hashable { var account: String; var day: Date }
        let known = Set(accounts.map(\.id))
        let owners = Dictionary(grouping: snapshots.compactMap { $0.target.localAccountId }, by: { $0 })
        var replacements: [Key: [Bucket]] = [:]
        var ids: Set<String> = []
        for snapshot in snapshots where snapshot.fetchedAt != nil {
            guard let account = snapshot.target.localAccountId, known.contains(account), owners[account]?.count == 1 else { continue }
            for day in snapshot.days {
                guard CodexDailyUsage.isDay(day.date), let period = date(day.date, calendar: calendar), period >= from, period < to,
                      let credits = day.credits, let cost = snapshot.estimatedCost(credits: credits), let models = day.textModels else { continue }
                var rows: [String: Bucket] = [:]
                func empty(_ model: String) -> Bucket {
                    Bucket(periodStart: period, accountId: account, model: model, totals: .zero, costUsd: 0,
                           cacheSavingsUsd: 0, costSource: .workspaceCredits, records: 0, sessions: 0)
                }
                let textCredits = models.reduce(0) { $0 + $1.credits }
                let useTextCredits = textCredits.isFinite && textCredits <= credits + 0.000001
                for model in models where model.totalTokens > 0 || model.credits > 0 {
                    var row = rows[model.model] ?? empty(model.model)
                    row.totals.add(TokenTotals(uncachedInput: model.uncachedInputTokens, cachedInput: model.cachedInputTokens, output: model.outputTokens))
                    if useTextCredits { row.costUsd += snapshot.estimatedCost(credits: model.credits) ?? 0 }
                    rows[model.model] = row
                }
                if useTextCredits {
                    // Metered text credits keep task/review costs with their
                    // tokens even when billing-model groups use other names.
                    var remaining = max(0, credits - textCredits)
                    let active = Set(rows.keys)
                    let other = (day.modelCredits ?? []).filter { !active.contains($0.key) && $0.credits > 0 }
                    if other.reduce(0, { $0 + $1.credits }) <= remaining + 0.000001 {
                        for group in other {
                            var row = empty(group.key)
                            row.costUsd = snapshot.estimatedCost(credits: group.credits) ?? 0
                            rows[group.key] = row
                            remaining -= group.credits
                        }
                    }
                    if remaining > 0.000001 {
                        var row = empty("Additional workspace credits")
                        row.costUsd = snapshot.estimatedCost(credits: remaining) ?? 0
                        rows[row.model] = row
                    }
                } else if let groups = day.modelCredits,
                   abs(groups.reduce(0) { $0 + $1.credits } - credits) < 0.000001 {
                    for group in groups where group.credits > 0 {
                        var row = rows[group.key] ?? empty(group.key)
                        row.costUsd += snapshot.estimatedCost(credits: group.credits) ?? 0
                        rows[group.key] = row
                    }
                } else {
                    var row = empty("Workspace credits (model unavailable)")
                    row.costUsd = cost
                    rows[row.model] = row
                }
                if rows.isEmpty { rows["Workspace usage"] = empty("Workspace usage") }
                // Preserve the exact daily USD total despite per-model rounding.
                let key = rows.values.sorted { $0.costUsd == $1.costUsd ? $0.model < $1.model : $0.costUsd > $1.costUsd }[0].model
                rows[key]!.costUsd += cost - rows.values.reduce(0) { $0 + $1.costUsd }
                let overlap = local.filter { $0.accountId == account && calendar.startOfDay(for: $0.periodStart) == period }
                rows[key]!.sessions = overlap.reduce(0) { $0 + $1.sessions }
                rows[key]!.records = overlap.reduce(0) { $0 + $1.records }
                rows[key]!.cacheSavingsUsd = overlap.reduce(0) { $0 + $1.cacheSavingsUsd }
                replacements[Key(account: account, day: period)] = Array(rows.values)
                ids.insert(account)
            }
        }
        let retained = local.filter { replacements[Key(account: $0.accountId, day: calendar.startOfDay(for: $0.periodStart))] == nil }
        let combined = retained + replacements.values.flatMap { $0 }
        return Result(buckets: combined.sorted {
            if $0.periodStart != $1.periodStart { return $0.periodStart < $1.periodStart }
            if $0.accountId != $1.accountId { return $0.accountId < $1.accountId }
            return $0.model < $1.model
        }, workspaceAccountIds: ids)
    }

    /// Provider date labels are displayed as calendar dates, not as fabricated
    /// midnight activity timestamps. All provider projections use day bars.
    private static func date(_ label: String, calendar: Calendar) -> Date? {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
