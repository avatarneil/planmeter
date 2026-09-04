import Foundation

public enum Resolution: String, Sendable {
    case hour
    case day
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

    public init(periodStart: Date, accountId: String, model: String, totals: TokenTotals, costUsd: Double, cacheSavingsUsd: Double, costSource: CostSource, records: Int, sessions: Int) {
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
    public var sessions = 0
    public var unpricedTokens = 0

    public init() {}

    public mutating func add(_ bucket: Bucket) {
        totals.add(bucket.totals)
        costUsd += bucket.costUsd
        cacheSavingsUsd += bucket.cacheSavingsUsd
        records += bucket.records
        sessions += bucket.sessions
        if bucket.costSource == .unpriced { unpricedTokens += bucket.totals.total }
    }
}

public enum Aggregation {
    /// Prices and re-buckets hourly cells into the requested window.
    ///
    /// Cells are UTC hours; `day` resolution snaps each to the local start of
    /// day so the chart reads in the user's own calendar.
    public static func buckets(cells: [CellKey: Cell], rates: RateTable, from: Date, to: Date, resolution: Resolution, calendar: Calendar = .current) -> [Bucket] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        struct Key: Hashable { var period: Date; var account: String; var model: String }
        struct Acc { var cell = Cell(); var reportedRecords = 0 }
        var merged: [Key: Cell] = [:]

        for (key, cell) in cells {
            guard key.hourStartMs >= fromMs, key.hourStartMs < toMs else { continue }
            let hour = Date(timeIntervalSince1970: TimeInterval(key.hourStartMs) / 1000)
            let period = resolution == .hour ? hour : calendar.startOfDay(for: hour)
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
                sessions: cell.sessionIds.count
            ))
        }
        out.sort { a, b in
            if a.periodStart != b.periodStart { return a.periodStart < b.periodStart }
            if a.accountId != b.accountId { return a.accountId < b.accountId }
            return a.model < b.model
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
        var cursor = resolution == .hour ? from : calendar.startOfDay(for: from)
        let component: Calendar.Component = resolution == .hour ? .hour : .day
        while cursor < to {
            out.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}
