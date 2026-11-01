import Foundation
import PlanMeterCore
import PlanMeterRemote

/// What the report builder reads from a host: the Mac's `AppModel` or the
/// daemon's `HostEngine`. Both answer from the same `PlanMeterCore` state, so
/// the same inputs produce byte-identical replies on every host.
@MainActor
public protocol RemoteReportSource: AnyObject {
    /// Configured accounts plus placeholders for unclaimed attribution keys.
    var accounts: [Account] { get }
    func account(for id: String) -> Account
    func group(for account: Account) -> PlanGroup
    /// Priced buckets for `[from, to)`, with workspace credits replacing
    /// overlapping local estimates (see `UsageProjection`).
    func projectedUsage(from: Date, to: Date, resolution: Resolution) -> UsageProjection.Result
    /// Spend since local midnight, independent of any selected range.
    var todayTotal: Aggregate { get }
    var lastScan: Date? { get }
    var rates: RateTable { get }
    var rateLimits: [String: RateLimitSnapshot] { get }
    /// Claude Code and Antigravity windows read from the provider, by account id.
    var planLimits: [String: PlanLimitSnapshot] { get }
    var sources: [SourceReport] { get }
    /// The name remote clients show for this host.
    var reportServerName: String { get }
}

/// Labels for Codex rate-limit windows, shared by the Mac UI and remote replies.
public enum RateLimitLabel {
    public static func windowName(minutes: Int) -> String {
        switch minutes {
        case 10080: return "Weekly"
        case 300: return "5-hour"
        case 60: return "Hourly"
        case 1440: return "Daily"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }
}

/// Report windows shared by the Mac's range picker and remote replies.
public enum ReportWindow {
    /// The current hour plus the preceding 23, which remote clients label
    /// "24h" and the Mac shows as Last 24 Hours.
    public static func rollingDay(now: Date) -> (from: Date, to: Date) {
        let hour = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
        return (hour.addingTimeInterval(-23 * 3600), hour.addingTimeInterval(3600))
    }
}

private struct AccountModelKey: Hashable { var account: String; var model: String }
private struct PeriodAccountKey: Hashable { var period: Date; var account: String }

/// Turns a host's current state into the typed replies the phone reads.
@MainActor
public enum RemoteReportBuilder {
    public static let maxDays = 365

    public static func reply<Model: RemoteReportSource>(for request: RemoteRequest, model: Model, now: Date = Date()) -> RemoteReply {
        let days = min(max(request.days ?? 30, 1), maxDays)
        let minutes = request.minutes.map { min(max($0, 5), 1440) }
        switch request.method {
        case .summary: return RemoteReply(summary: summary(model: model, days: days, minutes: minutes, now: now))
        case .models: return RemoteReply(models: models(model: model, days: days, minutes: minutes, filter: request.account, now: now))
        case .timeline:
            let resolution = request.resolution.flatMap(Resolution.init(rawValue:)) ?? .day
            return RemoteReply(timeline: timeline(model: model, days: days, minutes: minutes, resolution: resolution, now: now))
        case .limits: return RemoteReply(limits: limits(model: model))
        case .accounts: return RemoteReply(accounts: accounts(model: model))
        }
    }

    public static func totals(_ a: Aggregate) -> RemoteTotals {
        RemoteTotals(costUsd: a.costUsd, tokens: a.totals.total, inputTokens: a.totals.input, cachedInputTokens: a.totals.cachedInput, outputTokens: a.totals.output, sessions: a.sessions, cacheSavingsUsd: a.cacheSavingsUsd)
    }

    public static func account<Model: RemoteReportSource>(_ a: Account, model: Model) -> RemoteAccount {
        RemoteAccount(id: a.id, name: a.displayName, provider: a.provider.rawValue, providerName: a.provider.displayName, group: model.group(for: a).rawValue, email: a.email, plan: a.planLabel, accentColorHex: a.accentColorHex)
    }

    /// Remote clients label one day as "24h": the Mac's current hour plus the
    /// preceding 23. Sub-day windows end at the next five-minute boundary.
    public static func window(days: Int, minutes: Int?, now: Date) -> (from: Date, to: Date, coarsest: Resolution) {
        if let minutes {
            let w = Report.window(minutes: minutes, now: now)
            return (w.from, w.to, .hour)
        }
        if days == 1 {
            let w = ReportWindow.rollingDay(now: now)
            return (w.from, w.to, .hour)
        }
        let w = Report.window(days: days, now: now)
        return (w.from, w.to, .day)
    }

    /// The requested resolution, coarsened to fit the window's alignment and at
    /// most ~1,500 periods.
    public static func resolution(_ requested: Resolution, from: Date, to: Date, coarsest: Resolution) -> Resolution {
        let order = Resolution.allCases
        var index = min(order.firstIndex(of: requested) ?? order.count - 1, order.firstIndex(of: coarsest) ?? order.count - 1)
        while index < order.count - 1, let step = order[index].stepMs,
              (to.timeIntervalSince(from) * 1000) / Double(step) > 1500, order[index + 1] != .day || coarsest == .day {
            index += 1
        }
        return order[index]
    }

    public static func buckets<Model: RemoteReportSource>(model: Model, days: Int, minutes: Int? = nil, resolution: Resolution? = nil, now: Date = Date()) -> (buckets: [Bucket], from: Date, to: Date, resolution: Resolution) {
        let w = window(days: days, minutes: minutes, now: now)
        let resolution = self.resolution(resolution ?? (minutes != nil ? .fiveMinutes : w.coarsest), from: w.from, to: w.to, coarsest: w.coarsest)
        return (model.projectedUsage(from: w.from, to: w.to, resolution: resolution).buckets, w.from, w.to, resolution)
    }

    public static func summary<Model: RemoteReportSource>(model: Model, days: Int, minutes: Int? = nil, now: Date = Date()) -> RemoteSummary {
        let (buckets, from, to, _) = buckets(model: model, days: days, minutes: minutes, now: now)
        let byAccount = Aggregation.byAccount(buckets)
        var groups: [RemoteGroupUsage] = []
        for group in PlanGroup.allCases {
            let members = model.accounts.filter { model.group(for: $0) == group }
            if members.isEmpty { continue }
            var agg = Aggregate()
            var rows: [RemoteAccountUsage] = []
            for m in members {
                let a = byAccount[m.id] ?? Aggregate()
                for b in buckets where b.accountId == m.id { agg.add(b) }
                rows.append(RemoteAccountUsage(account: account(m, model: model), totals: totals(a)))
            }
            rows.sort { $0.totals.costUsd > $1.totals.costUsd || ($0.totals.costUsd == $1.totals.costUsd && $0.totals.tokens > $1.totals.tokens) }
            if group == .other && agg.totals.total == 0 && agg.costUsd == 0 { continue }
            groups.append(RemoteGroupUsage(group: group.rawValue, totals: totals(agg), accounts: rows))
        }
        return RemoteSummary(
            days: days,
            from: from,
            to: to,
            groups: groups,
            total: totals(Aggregation.total(buckets)),
            todayCostUsd: model.todayTotal.costUsd,
            generatedAt: model.lastScan ?? Date(),
            serverName: model.reportServerName,
            pricingSource: model.rates.source,
            minutes: minutes
        )
    }

    public static func models<Model: RemoteReportSource>(model: Model, days: Int, minutes: Int? = nil, filter: String?, now: Date = Date()) -> [RemoteModelRow] {
        let (buckets, _, _, _) = buckets(model: model, days: days, minutes: minutes, now: now)
        var agg: [AccountModelKey: Aggregate] = [:]
        var unpriced: Set<AccountModelKey> = []
        for b in buckets {
            let k = AccountModelKey(account: b.accountId, model: b.model)
            var a = agg[k] ?? Aggregate()
            a.add(b)
            agg[k] = a
            if b.costSource == .unpriced { unpriced.insert(k) }
        }
        let f = filter?.lowercased()
        var rows: [RemoteModelRow] = []
        for (k, a) in agg {
            let acct = model.account(for: k.account)
            if let f, !(acct.id.lowercased().contains(f) || acct.displayName.lowercased().contains(f) || acct.provider.rawValue == f) { continue }
            rows.append(RemoteModelRow(accountId: acct.id, accountName: acct.displayName, group: model.group(for: acct).rawValue, provider: acct.provider.rawValue, model: k.model, totals: totals(a), priced: !unpriced.contains(k)))
        }
        rows.sort { $0.totals.costUsd > $1.totals.costUsd || ($0.totals.costUsd == $1.totals.costUsd && $0.totals.tokens > $1.totals.tokens) }
        return rows
    }

    public static func timeline<Model: RemoteReportSource>(model: Model, days: Int, minutes: Int? = nil, resolution: Resolution, now: Date = Date()) -> RemoteTimeline {
        let (buckets, from, to, resolution) = buckets(model: model, days: days, minutes: minutes, resolution: resolution, now: now)
        var agg: [PeriodAccountKey: (cost: Double, tokens: Int, baseline: Double)] = [:]
        for b in buckets {
            let k = PeriodAccountKey(period: b.periodStart, account: b.accountId)
            let cur = agg[k] ?? (0, 0, 0)
            agg[k] = (cur.cost + b.costUsd, cur.tokens + b.totals.total, cur.baseline + (b.costSource == .workspaceBaseline ? b.costUsd : 0))
        }
        var points: [RemoteTimelinePoint] = []
        points.reserveCapacity(agg.count)
        for (key, value) in agg {
            points.append(RemoteTimelinePoint(period: key.period, accountId: key.account, costUsd: value.cost, tokens: value.tokens,
                                              baselineCostUsd: value.baseline > 0 ? value.baseline : nil))
        }
        points.sort { (a: RemoteTimelinePoint, b: RemoteTimelinePoint) -> Bool in
            if a.period != b.period { return a.period < b.period }
            return a.accountId < b.accountId
        }
        var ids = Set<String>()
        for p in points { ids.insert(p.accountId) }
        return RemoteTimeline(
            days: days,
            resolution: resolution.rawValue,
            periods: Aggregation.periods(from: from, to: to, resolution: resolution),
            points: points,
            accounts: model.accounts.filter { ids.contains($0.id) }.map { account($0, model: model) },
            minutes: minutes
        )
    }

    public static func limits<Model: RemoteReportSource>(model: Model) -> RemoteLimits {
        var rows: [RemoteAccountLimits] = []
        for a in model.accounts where a.provider == .codex {
            let plan = a.id.replacingOccurrences(of: "codex:plan:", with: "")
            var windows: [RemoteLimitWindow] = []
            var note: String?
            var asOf: Date?
            if let s = model.rateLimits[plan] {
                asOf = Date(timeIntervalSince1970: TimeInterval(s.timestampMs) / 1000)
                if let p = s.primary { windows.append(RemoteLimitWindow(label: RateLimitLabel.windowName(minutes: p.windowMinutes), usedPercent: p.usedPercent, windowMinutes: p.windowMinutes, resetsAt: p.resetDate)) }
                if let sec = s.secondary { windows.append(RemoteLimitWindow(label: RateLimitLabel.windowName(minutes: sec.windowMinutes), usedPercent: sec.usedPercent, windowMinutes: sec.windowMinutes, resetsAt: sec.resetDate)) }
                if windows.isEmpty {
                    note = s.unlimitedCredits == true ? "Unlimited credits" : s.hasCredits == true ? "Billed against credits; no usage windows." : "No usage windows reported."
                }
            } else {
                note = "No limit readings in scanned sessions yet."
            }
            rows.append(RemoteAccountLimits(account: account(a, model: model), windows: windows, note: note, asOf: asOf))
        }
        for a in model.accounts {
            guard let snapshot = model.planLimits[a.id] else { continue }
            // Older clients require a reset time, so untimed quotas stay out of
            // replies. Phones, the web client, and the Linux app all read these,
            // so the note names no host.
            let windows = snapshot.windows.compactMap { w in
                w.resetsAt.map { RemoteLimitWindow(label: w.label, usedPercent: w.usedPercent, windowMinutes: w.windowMinutes ?? 0, resetsAt: $0) }
            }
            var note = snapshot.message
            if windows.count < snapshot.windows.count {
                note = [note, "Quotas without a reset time aren't shown here."].compactMap { $0 }.joined(separator: " ")
            }
            rows.append(RemoteAccountLimits(account: account(a, model: model), windows: windows, note: note, asOf: snapshot.fetchedAt))
        }
        return RemoteLimits(accounts: rows, note: "Codex windows come from the last session each account ran; Claude Code and Antigravity windows are read from the provider.")
    }

    public static func accounts<Model: RemoteReportSource>(model: Model) -> RemoteAccounts {
        RemoteAccounts(
            accounts: model.accounts.map { account($0, model: model) },
            sources: model.sources.map { RemoteSource(provider: $0.provider.rawValue, path: $0.path, status: $0.status.rawValue) },
            scannedAt: model.lastScan
        )
    }
}
