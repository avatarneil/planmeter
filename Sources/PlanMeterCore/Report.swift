import Foundation

/// Everything needed to answer a usage question: discovered accounts, scanned
/// cells, pricing, and the user's group assignments. Shared by the CLI and the
/// MCP server so both report exactly what the app shows.
public struct ReportContext: Sendable {
    public var discovery: Discovery
    public var accounts: [Account]
    public var rates: RateTable
    public var scan: ScanOutput
    public var overrides: [String: PlanGroup]

    public func group(for account: Account) -> PlanGroup {
        GroupOverrides.group(for: account, overrides: overrides)
    }

    public func account(for id: String) -> Account {
        accounts.first { $0.id == id } ?? Account.placeholder(id: id)
    }
}

public enum Report {
    public static func load(days: Int, cache: ScanCache? = nil) async -> ReportContext {
        let settings = T3Settings.load()
        let discovery = AccountDiscovery.discover(settings: settings)
        let rates = PricingLoader.loadCached() ?? RateTable()
        let scanCache = cache ?? ScanCache()
        if cache == nil { await scanCache.load() }
        let sinceMs = Int64((Date().timeIntervalSince1970 - TimeInterval(days + 1) * 86_400) * 1000)
        let scan = await Scanner.scan(sources: discovery.sources, openCodeDatabase: discovery.openCodeDatabase, sinceMs: sinceMs, cache: scanCache)

        var accounts = discovery.accounts
        let known = Set(accounts.map(\.id))
        for id in Set(scan.cells.keys.map(\.accountId)).subtracting(known).sorted() {
            accounts.append(Account.placeholder(id: id))
        }
        return ReportContext(discovery: discovery, accounts: accounts, rates: rates, scan: scan, overrides: GroupOverrides.load())
    }

    /// `[from, to)` covering the last `days` local calendar days including today.
    public static func window(days: Int, calendar: Calendar = .current, now: Date = Date()) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let from = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        return (from, to)
    }

    public static func buckets(_ ctx: ReportContext, days: Int, resolution: Resolution = .day) -> [Bucket] {
        let w = window(days: days)
        return Aggregation.buckets(cells: ctx.scan.cells, rates: ctx.rates, from: w.from, to: w.to, resolution: resolution)
    }

    // MARK: JSON-friendly reports

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func round(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    static func aggregateJSON(_ a: Aggregate) -> [String: Any] {
        [
            "costUsd": round(a.costUsd),
            "tokens": a.totals.total,
            "inputTokens": a.totals.input,
            "uncachedInputTokens": a.totals.uncachedInput,
            "cachedInputTokens": a.totals.cachedInput,
            "cacheCreationTokens": a.totals.cacheCreation,
            "outputTokens": a.totals.output,
            "reasoningTokens": a.totals.reasoning,
            "sessions": a.sessions,
            "cacheSavingsUsd": round(a.cacheSavingsUsd),
            "unpricedTokens": a.unpricedTokens,
        ]
    }

    static func accountJSON(_ a: Account, group: PlanGroup) -> [String: Any] {
        var out: [String: Any] = [
            "id": a.id,
            "name": a.displayName,
            "provider": a.provider.rawValue,
            "providerName": a.provider.displayName,
            "group": group.rawValue,
        ]
        if let e = a.email { out["email"] = e }
        if let p = a.planLabel { out["plan"] = p }
        if let o = a.organization { out["organization"] = o }
        return out
    }

    public static func summary(_ ctx: ReportContext, days: Int) -> [String: Any] {
        let w = window(days: days)
        let buckets = self.buckets(ctx, days: days)
        let byAccount = Aggregation.byAccount(buckets)
        var groups: [[String: Any]] = []
        for group in PlanGroup.allCases {
            let members = ctx.accounts.filter { ctx.group(for: $0) == group }
            if members.isEmpty { continue }
            var agg = Aggregate()
            var rows: [[String: Any]] = []
            for m in members {
                let a = byAccount[m.id] ?? Aggregate()
                for b in buckets where b.accountId == m.id { agg.add(b) }
                var row = accountJSON(m, group: group)
                row.merge(aggregateJSON(a)) { _, new in new }
                rows.append(row)
            }
            rows.sort { ($0["costUsd"] as? Double ?? 0) > ($1["costUsd"] as? Double ?? 0) }
            var g: [String: Any] = ["group": group.rawValue, "accounts": rows]
            g.merge(aggregateJSON(agg)) { _, new in new }
            groups.append(g)
        }
        let total = Aggregation.total(buckets)
        var out: [String: Any] = [
            "days": days,
            "from": iso(w.from),
            "to": iso(w.to),
            "timeZone": TimeZone.current.identifier,
            "groups": groups,
            "pricing": ["source": ctx.rates.source, "knownModels": ctx.rates.knownModels],
            "note": "Costs are API-equivalent token prices from LiteLLM rates, not subscription charges.",
        ]
        out["total"] = aggregateJSON(total)
        return out
    }

    public static func models(_ ctx: ReportContext, days: Int, accountFilter: String?) -> [String: Any] {
        let buckets = self.buckets(ctx, days: days)
        struct Key: Hashable { var account: String; var model: String }
        var agg: [Key: Aggregate] = [:]
        var unpriced: Set<Key> = []
        for b in buckets {
            let k = Key(account: b.accountId, model: b.model)
            var a = agg[k] ?? Aggregate()
            a.add(b)
            agg[k] = a
            if b.costSource == .unpriced { unpriced.insert(k) }
        }
        let filter = accountFilter?.lowercased()
        var rows: [[String: Any]] = []
        for (k, a) in agg {
            let account = ctx.account(for: k.account)
            if let filter, !(account.id.lowercased().contains(filter) || account.displayName.lowercased().contains(filter) || account.provider.rawValue == filter) { continue }
            var row: [String: Any] = [
                "account": account.displayName,
                "accountId": account.id,
                "provider": account.provider.rawValue,
                "group": ctx.group(for: account).rawValue,
                "model": k.model,
                "priced": !unpriced.contains(k),
            ]
            row.merge(aggregateJSON(a)) { _, new in new }
            rows.append(row)
        }
        rows.sort {
            let c0 = $0["costUsd"] as? Double ?? 0, c1 = $1["costUsd"] as? Double ?? 0
            if c0 != c1 { return c0 > c1 }
            return ($0["tokens"] as? Int ?? 0) > ($1["tokens"] as? Int ?? 0)
        }
        return ["days": days, "rows": rows]
    }

    public static func timeline(_ ctx: ReportContext, days: Int, resolution: Resolution) -> [String: Any] {
        let w = window(days: days)
        let buckets = self.buckets(ctx, days: days, resolution: resolution)
        var periods: [Date: [String: Aggregate]] = [:]
        for b in buckets {
            var perAccount = periods[b.periodStart] ?? [:]
            var a = perAccount[b.accountId] ?? Aggregate()
            a.add(b)
            perAccount[b.accountId] = a
            periods[b.periodStart] = perAccount
        }
        let all = Aggregation.periods(from: w.from, to: w.to, resolution: resolution)
        let rows: [[String: Any]] = all.map { start in
            let perAccount = periods[start] ?? [:]
            var accounts: [[String: Any]] = []
            var groups: [String: Double] = [:]
            var total = 0.0
            var tokens = 0
            for (id, a) in perAccount {
                let account = ctx.account(for: id)
                let group = ctx.group(for: account)
                accounts.append(["accountId": id, "name": account.displayName, "group": group.rawValue, "costUsd": round(a.costUsd), "tokens": a.totals.total])
                groups[group.rawValue, default: 0] += a.costUsd
                total += a.costUsd
                tokens += a.totals.total
            }
            return [
                "period": iso(start),
                "costUsd": round(total),
                "tokens": tokens,
                "byGroup": groups.mapValues(round),
                "accounts": accounts.sorted { ($0["costUsd"] as? Double ?? 0) > ($1["costUsd"] as? Double ?? 0) },
            ]
        }
        return ["days": days, "resolution": resolution.rawValue, "periods": rows]
    }

    public static func limits(_ ctx: ReportContext) -> [String: Any] {
        var rows: [[String: Any]] = []
        for account in ctx.accounts where account.provider == .codex {
            let plan = account.id.replacingOccurrences(of: "codex:plan:", with: "")
            var row = accountJSON(account, group: ctx.group(for: account))
            if let s = ctx.scan.rateLimits[plan] {
                row["asOf"] = iso(Date(timeIntervalSince1970: TimeInterval(s.timestampMs) / 1000))
                func window(_ w: RateLimitWindow?) -> [String: Any]? {
                    guard let w else { return nil }
                    return ["usedPercent": w.usedPercent, "windowMinutes": w.windowMinutes, "resetsAt": iso(w.resetDate)]
                }
                if let p = window(s.primary) { row["primary"] = p }
                if let sec = window(s.secondary) { row["secondary"] = sec }
                var credits: [String: Any] = [:]
                if let h = s.hasCredits { credits["hasCredits"] = h }
                if let u = s.unlimitedCredits { credits["unlimited"] = u }
                if let b = s.creditsBalance { credits["balance"] = b }
                if !credits.isEmpty { row["credits"] = credits }
            } else {
                row["status"] = "no readings in scanned sessions"
            }
            rows.append(row)
        }
        return [
            "codex": rows,
            "note": "Codex writes rate-limit windows into every session transcript; readings reflect the last turn each account ran. Claude Code does not store limits locally.",
        ]
    }

    public static func accounts(_ ctx: ReportContext) -> [String: Any] {
        [
            "accounts": ctx.accounts.map { accountJSON($0, group: ctx.group(for: $0)) + ["source": $0.sourceDescription] },
            "sources": ctx.scan.sources.map { ["provider": $0.provider.rawValue, "path": $0.path, "status": $0.status.rawValue, "parsedFiles": $0.scannedFiles, "cachedFiles": $0.reusedFiles, "message": $0.message ?? ""] },
            "unsupported": ctx.discovery.unsupported.map { ["name": $0.displayName, "driver": $0.driver, "reason": $0.reason] },
            "notes": ctx.discovery.notes,
            "scannedAt": iso(ctx.scan.scannedAt),
        ]
    }
}

private func + (lhs: [String: Any], rhs: [String: Any]) -> [String: Any] {
    lhs.merging(rhs) { _, new in new }
}
