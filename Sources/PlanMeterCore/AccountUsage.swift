import Foundation

/// A service login, separate from the plan-type attribution used by transcripts.
public struct CodexUsageTarget: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var home: String
    public var email: String
    public var plan: String
    public var serviceAccountId: String
    public var localAccountId: String?
}

public struct AccountUsageDay: Codable, Hashable, Sendable {
    public var startDate: String
    public var tokens: Int
}

public struct AccountUsageSnapshot: Codable, Sendable, Identifiable {
    public var id: String { target.id }
    public var target: CodexUsageTarget
    public var days: [AccountUsageDay] = []
    public var lifetimeTokens: Int?
    public var fetchedAt: Date?
    public var status: SourceStatus = .missing
    public var message: String?
}

/// Retain the actual per-session cells; assigning a multi-session cell's entire
/// cost to each session would multiply spend.
public struct ThreadCellEntry: Codable, Sendable {
    public var sessionId: String
    public var key: CellKey
    public var cell: Cell
    public var sourcePath: String
}

public struct ThreadSpend: Codable, Sendable, Identifiable {
    public var title: String?
    public var chatId: String?
    public var chatURL: String?
    public var id: String { "\(accountId):\(sessionId)" }
    public var accountId: String
    public var provider: ProviderKind
    public var sessionId: String
    public var tokens: Int
    public var costUsd: Double
    public var unpricedTokens: Int
    public var models: [String]
    public var sourcePaths: [String]
    public var firstActivity: Date
    public var lastActivity: Date
}

public struct ThreadLink: Codable, Sendable {
    public var title: String
    public var chatId: String?
}

public struct UsageReconciliation: Codable, Sendable {
    public var snapshot: AccountUsageSnapshot
    public var fromDay: String
    public var toDay: String
    public var accountTokens: Int?
    public var knownThreadTokens: Int?
    public var knownThreadCostUsd: Double?
    /// Signed: negative differences remain visible as reporting discrepancies.
    public var differenceTokens: Int?
    public var knownThreads: Int?
    public var missingDays: [String]
    public var threadIds: [String]?
}

public enum UsageCoverage {
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func dayLabel(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func threads(_ entries: [ThreadCellEntry], rates: RateTable, from: Date, to: Date) -> [ThreadSpend] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        var rows: [String: ThreadSpend] = [:]
        for entry in entries where entry.key.hourStartMs >= fromMs && entry.key.hourStartMs < toMs {
            let id = "\(entry.key.accountId):\(entry.sessionId)"
            let date = Date(timeIntervalSince1970: Double(entry.key.hourStartMs) / 1000)
            var row = rows[id] ?? ThreadSpend(accountId: entry.key.accountId, provider: Account.placeholder(id: entry.key.accountId).provider,
                sessionId: entry.sessionId, tokens: 0, costUsd: 0, unpricedTokens: 0, models: [], sourcePaths: [], firstActivity: date, lastActivity: date)
            if row.provider == .codex, UUID(uuidString: row.sessionId) != nil { row.chatURL = "codex://threads/\(row.sessionId)" }
            row.tokens += entry.cell.totals.total
            let priced = rates.price(model: entry.key.model, totals: entry.cell.unpricedTotals)
            row.costUsd += entry.cell.reportedCostUsd + (priced ?? 0)
            if priced == nil { row.unpricedTokens += entry.cell.unpricedTotals.total }
            if !row.models.contains(entry.key.model) { row.models.append(entry.key.model); row.models.sort() }
            if !row.sourcePaths.contains(entry.sourcePath) { row.sourcePaths.append(entry.sourcePath); row.sourcePaths.sort() }
            row.firstActivity = min(row.firstActivity, date)
            row.lastActivity = max(row.lastActivity, date)
            rows[id] = row
        }
        return rows.values.sorted { $0.costUsd == $1.costUsd ? $0.id < $1.id : $0.costUsd > $1.costUsd }
    }

    /// Service day labels are compared to UTC transcript days, independent of
    /// the local/rolling chart range. Missing buckets do not mean zero usage.
    public static func reconcile(_ snapshots: [AccountUsageSnapshot], entries: [ThreadCellEntry], rates: RateTable, days: Int, now: Date = Date()) -> [UsageReconciliation] {
        let w = Report.window(days: days, calendar: utcCalendar, now: now)
        let from = dayLabel(w.from), to = dayLabel(w.to)
        let threads = self.threads(entries, rates: rates, from: w.from, to: w.to)
        return snapshots.map { snapshot in
            let selected = snapshot.days.filter { $0.startDate >= from && $0.startDate < to }
            let reported = Set(selected.map(\.startDate))
            let missing = Aggregation.periods(from: w.from, to: w.to, resolution: .day, calendar: utcCalendar)
                .map(dayLabel).filter { !reported.contains($0) }
            let total = snapshot.fetchedAt != nil && !selected.isEmpty ? selected.reduce(0) { $0 + $1.tokens } : nil
            let known = snapshot.target.localAccountId.map { id in threads.filter { $0.accountId == id } }
            let tokens = known.map { $0.reduce(0) { $0 + $1.tokens } }
            return UsageReconciliation(snapshot: snapshot, fromDay: from, toDay: to, accountTokens: total,
                knownThreadTokens: tokens, knownThreadCostUsd: known.map { $0.reduce(0) { $0 + $1.costUsd } },
                differenceTokens: missing.isEmpty && snapshot.status == .ok ? total.flatMap { total in tokens.map { total - $0 } } : nil,
                knownThreads: known?.count, missingDays: missing, threadIds: known?.map(\.sessionId).sorted())
        }
    }
}
