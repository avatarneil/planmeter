import Foundation

/// Prefer a dated workspace reading over overlapping local estimates for the
/// same unambiguous account. Never add lifetime or generic account tokens.
///
/// Provider dates are UTC days, reported through a freshness time that lags
/// real usage. A reading replaces local usage only in the hours it covers,
/// `[UTC day start, freshness)`, and is shared among the local calendar days
/// those hours fall on in proportion to the local usage it replaces. Later
/// hours keep their local estimates until the provider reports them.
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

    /// For `.day`, `from` must be a local midnight. Finer resolutions place each
    /// share in the bucket where it occurred: text usage follows the local usage
    /// it replaces minute by minute; credits with no timing form an even baseline.
    public static func buckets(cells: [CellKey: Cell], rates: RateTable, snapshots: [CodexDailyUsageSnapshot], accounts: [Account],
                               from: Date, to: Date, resolution: Resolution, calendar: Calendar = .current) -> Result {
        let known = Set(accounts.map(\.id))
        let owners = Dictionary(grouping: snapshots.compactMap { $0.target.localAccountId }, by: { $0 })
        let eligible = snapshots.filter { snapshot in
            guard snapshot.fetchedAt != nil, let account = snapshot.target.localAccountId else { return false }
            return known.contains(account) && owners[account]?.count == 1
        }
        struct DayKey: Hashable { var account: String; var startMs: Int64 }
        let dayMs: Int64 = 86_400_000
        let workspaceAccounts = Set(eligible.compactMap(\.target.localAccountId))
        var cellsByDay: [DayKey: [CellKey]] = [:]
        for key in cells.keys where workspaceAccounts.contains(key.accountId) {
            cellsByDay[DayKey(account: key.accountId, startMs: key.startMs / dayMs * dayMs), default: []].append(key)
        }
        func price(_ key: CellKey) -> Double {
            guard let cell = cells[key] else { return 0 }
            return cell.reportedCostUsd + (rates.price(model: key.model, totals: cell.unpricedTotals) ?? 0)
        }
        // Slices are split at the window's edges, so a partial first or last bucket
        // gets only the share of the reading inside the window, like local cells.
        let fromMs = milliseconds(from), toMs = milliseconds(to)

        var replaced: Set<CellKey> = []
        var projected: [Bucket] = []
        var ids: Set<String> = []
        for snapshot in eligible {
            guard let account = snapshot.target.localAccountId else { continue }
            // Credits bound what a day's reading covers. Without a freshness time,
            // a reading can only cover usage until it was fetched.
            let freshness = (snapshot.creditsFreshness ?? snapshot.dataFreshness).flatMap(ISO8601.parseMs)
                ?? snapshot.fetchedAt.map(milliseconds)
            for day in snapshot.days {
                guard let start = utcStartMs(day.date), let credits = day.credits,
                      let cost = snapshot.estimatedCost(credits: credits), let models = day.textModels else { continue }
                let end = min(start + dayMs, freshness ?? start + dayMs)
                guard end > start, fromMs < end, start < toMs else { continue }
                let slices = self.slices(start: start, end: end, resolution: resolution, calendar: calendar, cuts: [fromMs, toMs])
                guard slices.contains(where: { $0.from >= fromMs && $0.from < toMs }) else { continue }
                let covered = (cellsByDay[DayKey(account: account, startMs: start)] ?? []).filter { $0.startMs < end }
                var local = Array(repeating: [CellKey](), count: slices.count)
                for key in covered { local[slice(containing: key.startMs, in: slices)].append(key) }
                // Text usage follows the local usage it replaces, by cost when every
                // model is priced; credits without text tokens (Chat, voice, image),
                // or a reading with no local trace, spread evenly over the reported time.
                let duration = slices.map { Double($0.to - $0.from) }
                let priced = covered.allSatisfy { key in
                    cells[key].map { $0.unpricedTotals.isEmpty || rates.price(model: key.model, totals: $0.unpricedTotals) != nil } ?? true
                }
                var activity = local.map { keys in keys.reduce(0) { $0 + (priced ? price($1) : Double(cells[$1]?.totals.total ?? 0)) } }
                let traced = activity.reduce(0, +) > 0
                if !traced { activity = duration }
                let textCuts = cuts(activity), timeCuts = cuts(duration)
                replaced.formUnion(covered)
                ids.insert(account)
                let rows = workspaceRows(day: day, snapshot: snapshot, account: account, credits: credits, cost: cost, models: models)
                for (index, slice) in slices.enumerated() where slice.from >= fromMs && slice.from < toMs {
                    var sliceRows: [Bucket] = rows.compactMap { row in
                        let followsUsage = row.totals.total > 0 || row.model == unattributed
                        let (lower, upper) = followsUsage ? textCuts[index] : timeCuts[index]
                        // Zero-credit days add nothing to draw.
                        guard upper > lower, row.costUsd != 0 || row.totals.total > 0 else { return nil }
                        var row = row
                        row.periodStart = slice.period
                        row.costUsd *= upper - lower
                        row.totals = row.totals.share(from: lower, to: upper)
                        if !(followsUsage && traced) { row.costSource = .workspaceBaseline }
                        return row
                    }
                    // Sessions and cache savings describe the local usage replaced here,
                    // even when no share of the reading lands in this period.
                    guard !local[index].isEmpty else { projected += sliceRows; continue }
                    if !sliceRows.contains(where: { $0.costSource == .workspaceCredits }) {
                        sliceRows.append(Bucket(periodStart: slice.period, accountId: account, model: "Workspace usage", totals: .zero,
                                                costUsd: 0, cacheSavingsUsd: 0, costSource: .workspaceCredits, records: 0, sessions: 0))
                    }
                    let top = sliceRows.indices.filter { sliceRows[$0].costSource == .workspaceCredits }.max {
                        sliceRows[$0].costUsd == sliceRows[$1].costUsd ? sliceRows[$0].model > sliceRows[$1].model : sliceRows[$0].costUsd < sliceRows[$1].costUsd
                    }!
                    sliceRows[top].sessionIds = Set(local[index].flatMap { cells[$0]?.sessionIds ?? [] })
                    sliceRows[top].sessions = sliceRows[top].sessionIds.count
                    sliceRows[top].records = local[index].reduce(0) { $0 + (cells[$1]?.records ?? 0) }
                    sliceRows[top].cacheSavingsUsd = local[index].reduce(0) { $0 + rates.cacheSavings(model: $1.model, totals: cells[$1]?.totals ?? .zero) }
                    projected += sliceRows
                }
            }
        }
        let remaining = replaced.isEmpty ? cells : cells.filter { !replaced.contains($0.key) }
        let local = Aggregation.buckets(cells: remaining, rates: rates, from: from, to: to, resolution: resolution, calendar: calendar)
        return Result(buckets: (local + projected).sorted {
            if $0.periodStart != $1.periodStart { return $0.periodStart < $1.periodStart }
            if $0.accountId != $1.accountId { return $0.accountId < $1.accountId }
            if $0.model != $1.model { return $0.model < $1.model }
            return $0.costSource.rawValue < $1.costSource.rawValue
        }, workspaceAccountIds: ids)
    }

    /// `[start, end)` split into the resolution's periods (local days, or UTC-aligned
    /// steps) and at any `cuts`, so no slice straddles a window edge.
    static func slices(start: Int64, end: Int64, resolution: Resolution, calendar: Calendar, cuts: [Int64] = []) -> [(period: Date, from: Int64, to: Int64)] {
        var slices: [(period: Date, from: Int64, to: Int64)]
        if let step = resolution.stepMs {
            slices = []
            var cursor = start
            while cursor < end {
                let period = milliseconds(resolution.periodStart(forMs: cursor, calendar: calendar))
                let stop = min(end, period + step)
                slices.append((Date(timeIntervalSince1970: TimeInterval(period) / 1000), cursor, stop))
                cursor = stop
            }
        } else {
            slices = localPieces(start: start, end: end, calendar: calendar).map { ($0.day, $0.from, $0.to) }
        }
        for cut in cuts where cut > start && cut < end {
            guard let index = slices.firstIndex(where: { $0.from < cut && cut < $0.to }) else { continue }
            let slice = slices[index]
            slices.replaceSubrange(index...index, with: [(slice.period, slice.from, cut), (slice.period, cut, slice.to)])
        }
        return slices
    }

    /// Index of the slice containing `ms`; slices are contiguous and sorted.
    private static func slice(containing ms: Int64, in slices: [(period: Date, from: Int64, to: Int64)]) -> Int {
        var low = 0, high = slices.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if slices[middle].from <= ms { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// The whole day's cost when the provider gave no model breakdown; it follows local usage.
    private static let unattributed = "Workspace credits (model unavailable)"

    /// One day's reading as model rows whose costs sum exactly to `cost`.
    private static func workspaceRows(day: CodexDailyUsageDay, snapshot: CodexDailyUsageSnapshot, account: String,
                                      credits: Double, cost: Double, models: [DailyModelTokens]) -> [Bucket] {
        var rows: [String: Bucket] = [:]
        func empty(_ model: String) -> Bucket {
            Bucket(periodStart: .distantPast, accountId: account, model: model, totals: .zero, costUsd: 0,
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
            var row = empty(unattributed)
            row.costUsd = cost
            rows[row.model] = row
        }
        if rows.isEmpty { rows["Workspace usage"] = empty("Workspace usage") }
        // Preserve the exact daily USD total despite per-model rounding.
        let key = rows.values.sorted { $0.costUsd == $1.costUsd ? $0.model < $1.model : $0.costUsd > $1.costUsd }[0].model
        rows[key]!.costUsd += cost - rows.values.reduce(0) { $0 + $1.costUsd }
        return rows.values.sorted { $0.model < $1.model }
    }

    /// `[start, end)` split at local midnights, keyed by local day.
    static func localPieces(start: Int64, end: Int64, calendar: Calendar) -> [(day: Date, from: Int64, to: Int64)] {
        var pieces: [(day: Date, from: Int64, to: Int64)] = []
        var cursor = start
        while cursor < end {
            let date = Date(timeIntervalSince1970: TimeInterval(cursor) / 1000)
            // A day interval, not start + 1 day, stays exact across daylight-saving changes at midnight.
            guard let day = calendar.dateInterval(of: .day, for: date) else { break }
            let next = Int64((day.end.timeIntervalSince1970 * 1000).rounded())
            let stop = min(end, max(next, cursor + 1))
            pieces.append((day.start, cursor, stop))
            cursor = stop
        }
        return pieces
    }

    /// Cumulative `[lower, upper)` fractions for each weight; the last ends at exactly 1.
    private static func cuts(_ weights: [Double]) -> [(Double, Double)] {
        let total = weights.reduce(0, +)
        let last = weights.lastIndex { $0 > 0 }
        var lower = 0.0
        return weights.enumerated().map { index, weight in
            let upper = index == last ? 1 : lower + (total > 0 ? weight / total : 0)
            defer { lower = upper }
            return (lower, upper)
        }
    }

    private static func utcStartMs(_ label: String) -> Int64? {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard CodexDailyUsage.isDay(label), parts.count == 3,
              let date = UsageCoverage.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension TokenTotals {
    /// The `[from, to)` fraction of these totals. Adjacent shares of the same
    /// totals sum exactly to the original counts.
    func share(from: Double, to: Double) -> TokenTotals {
        func part(_ value: Int) -> Int { Int((Double(value) * to).rounded()) - Int((Double(value) * from).rounded()) }
        return TokenTotals(uncachedInput: part(uncachedInput), cachedInput: part(cachedInput), cacheCreation: part(cacheCreation),
                           output: part(output), reasoning: part(reasoning))
    }
}
