import Foundation

public enum Resolution: String, CaseIterable, Sendable {
    case minute
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case hour
    case day

    /// Fixed bucket length in milliseconds; nil for local calendar days.
    public var stepMs: Int64? {
        switch self {
        case .minute: return 60_000
        case .fiveMinutes: return 300_000
        case .fifteenMinutes: return 900_000
        case .hour: return 3_600_000
        case .day: return nil
        }
    }

    public var label: String {
        switch self {
        case .minute: return "1 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .hour: return "1 hour"
        case .day: return "1 day"
        }
    }

    /// The bucket containing `ms`. Fixed steps align to UTC, which matches local
    /// boundaries in every time zone offset that is a multiple of the step.
    public func periodStart(forMs ms: Int64, calendar: Calendar = .current) -> Date {
        guard let step = stepMs else {
            return calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
        let floored = ms >= 0 ? ms / step * step : (ms - step + 1) / step * step
        return Date(timeIntervalSince1970: TimeInterval(floored) / 1000)
    }
}

/// One (period, account, model) row of priced usage.
public struct Bucket: Identifiable, Hashable, Sendable {
    public var id: String { "\(periodStart.timeIntervalSince1970):\(accountId):\(model)" }
    public var periodStart: Date
    public var accountId: String
    public var model: String
    public var totals: TokenTotals
    public var costUsd: Double
    public var cacheSavingsUsd: Double
    public var costSource: CostSource
    public var records: Int
    public var sessions: Int
    /// The sessions behind `sessions`, so totals across buckets count each once.
    public var sessionIds: Set<String> = []

    public init(periodStart: Date, accountId: String, model: String, totals: TokenTotals, costUsd: Double, cacheSavingsUsd: Double, costSource: CostSource, records: Int, sessions: Int, sessionIds: Set<String> = []) {
        self.sessionIds = sessionIds
        self.periodStart = periodStart
        self.accountId = accountId
        self.model = model
        self.totals = totals
        self.costUsd = costUsd
        self.cacheSavingsUsd = cacheSavingsUsd
        self.costSource = costSource
        self.records = records
        self.sessions = sessions
    }
}

public struct Aggregate: Hashable, Sendable {
    public var totals = TokenTotals.zero
    public var costUsd = 0.0
    public var cacheSavingsUsd = 0.0
    public var records = 0
    public var unpricedTokens = 0
    /// Distinct sessions: a session spanning many minute buckets counts once.
    public var sessionIds: Set<String> = []
    private var unidentifiedSessions = 0
    public var sessions: Int { sessionIds.count + unidentifiedSessions }

    public init() {}

    public mutating func add(_ bucket: Bucket) {
        totals.add(bucket.totals)
        costUsd += bucket.costUsd
        cacheSavingsUsd += bucket.cacheSavingsUsd
        records += bucket.records
        if bucket.sessionIds.isEmpty { unidentifiedSessions += bucket.sessions } else { sessionIds.formUnion(bucket.sessionIds) }
        if bucket.costSource == .unpriced { unpricedTokens += bucket.totals.total }
    }
}

public enum Aggregation {
    /// Prices and re-buckets per-minute cells into the requested window.
    ///
    /// Cells are UTC minutes; `day` resolution snaps each to the local start of
    /// day so the chart reads in the user's own calendar.
    public static func buckets(cells: [CellKey: Cell], rates: RateTable, from: Date, to: Date, resolution: Resolution, calendar: Calendar = .current) -> [Bucket] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        struct Key: Hashable { var period: Date; var account: String; var model: String }
        struct Acc { var cell = Cell(); var reportedRecords = 0 }
        var merged: [Key: Cell] = [:]

        for (key, cell) in cells {
            guard key.startMs >= fromMs, key.startMs < toMs else { continue }
            let period = resolution.periodStart(forMs: key.startMs, calendar: calendar)
            let k = Key(period: period, account: key.accountId, model: key.model)
            if var existing = merged[k] {
                existing.merge(cell)
                merged[k] = existing
            } else {
                merged[k] = cell
            }
        }

        var out: [Bucket] = []
        out.reserveCapacity(merged.count)
        for (k, cell) in merged {
            let priced = rates.price(model: k.model, totals: cell.unpricedTotals)
            let costUsd = cell.reportedCostUsd + (priced ?? 0)
            let hasReported = cell.reportedCostUsd > 0 || cell.unpricedTotals.isEmpty
            let source: CostSource
            if cell.unpricedTotals.isEmpty {
                source = .providerReported
            } else if priced == nil {
                source = hasReported && cell.reportedCostUsd > 0 ? .mixed : .unpriced
            } else {
                source = cell.reportedCostUsd > 0 ? .mixed : .modelPriced
            }
            out.append(Bucket(
                periodStart: k.period,
                accountId: k.account,
                model: k.model,
                totals: cell.totals,
                costUsd: costUsd,
                cacheSavingsUsd: rates.cacheSavings(model: k.model, totals: cell.totals),
                costSource: source,
                records: cell.records,
                sessions: cell.sessionIds.count,
                sessionIds: cell.sessionIds
            ))
        }
        out.sort { a, b in
            if a.periodStart != b.periodStart { return a.periodStart < b.periodStart }
            if a.accountId != b.accountId { return a.accountId < b.accountId }
            return a.model < b.model
        }
        return out
    }

    /// Merges cells into coarser fixed-step cells, e.g. minutes into hours.
    public static func rollup(_ cells: [CellKey: Cell], stepMs: Int64) -> [CellKey: Cell] {
        var out: [CellKey: Cell] = [:]
        out.reserveCapacity(cells.count / 4)
        for (key, cell) in cells {
            var coarse = key
            coarse.startMs = key.startMs / stepMs * stepMs
            if var existing = out[coarse] {
                existing.merge(cell)
                out[coarse] = existing
            } else {
                out[coarse] = cell
            }
        }
        return out
    }

    public static func total(_ buckets: [Bucket]) -> Aggregate {
        var agg = Aggregate()
        for b in buckets { agg.add(b) }
        return agg
    }

    public static func byAccount(_ buckets: [Bucket]) -> [String: Aggregate] {
        var out: [String: Aggregate] = [:]
        for b in buckets {
            var agg = out[b.accountId] ?? Aggregate()
            agg.add(b)
            out[b.accountId] = agg
        }
        return out
    }

    public static func byModel(_ buckets: [Bucket]) -> [String: Aggregate] {
        var out: [String: Aggregate] = [:]
        for b in buckets {
            var agg = out[b.model] ?? Aggregate()
            agg.add(b)
            out[b.model] = agg
        }
        return out
    }

    /// Period starts covering `[from, to)` so charts show empty periods too.
    public static func periods(from: Date, to: Date, resolution: Resolution, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        if let step = resolution.stepMs {
            var cursor = Int64(resolution.periodStart(forMs: Int64((from.timeIntervalSince1970 * 1000).rounded()), calendar: calendar).timeIntervalSince1970 * 1000)
            let end = Int64((to.timeIntervalSince1970 * 1000).rounded())
            while cursor < end {
                out.append(Date(timeIntervalSince1970: TimeInterval(cursor) / 1000))
                cursor += step
            }
            return out
        }
        var cursor = calendar.startOfDay(for: from)
        while cursor < to {
            out.append(cursor)
            guard let next = calendar.dateInterval(of: .day, for: cursor)?.end, next > cursor else { break }
            cursor = next
        }
        return out
    }
}
