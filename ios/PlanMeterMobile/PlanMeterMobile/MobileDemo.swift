#if DEBUG
import Foundation
import PlanMeterRemote

/// Sample data for simulator screenshots: launch with `--demo`. Shown without
/// pairing or iCloud, and never relayed to the watch or widgets.
enum MobileDemo {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo") }

    struct Data {
        var summary: RemoteSummary
        var timeline: RemoteTimeline
        var limits: RemoteLimits
        var models: [RemoteModelRow]
    }

    static func data(now: Date = Date(), calendar: Calendar = .current) -> Data {
        let accounts = [
            RemoteAccount(id: "codex-work", name: "Work Codex", provider: "codex", providerName: "Codex", group: "work", plan: "Business"),
            RemoteAccount(id: "claude-work", name: "Work Claude", provider: "claude", providerName: "Claude Code", group: "work", plan: "Team"),
            RemoteAccount(id: "claude-max", name: "Claude Max", provider: "claude", providerName: "Claude Code", group: "personal", plan: "Max 20x"),
            RemoteAccount(id: "codex-pro", name: "ChatGPT Pro", provider: "codex", providerName: "Codex", group: "personal", plan: "Pro"),
            RemoteAccount(id: "antigravity", name: "Antigravity", provider: "antigravity", providerName: "Antigravity", group: "other"),
        ]
        let scale: [String: Double] = ["codex-work": 26, "claude-work": 12, "claude-max": 6.5, "codex-pro": 2.9, "antigravity": 1.3]
        let today = calendar.startOfDay(for: now)
        let periods = (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var points: [RemoteTimelinePoint] = []
        for (i, period) in periods.enumerated() {
            let weekday = calendar.component(.weekday, from: period)
            let weekend = weekday == 1 || weekday == 7
            for (j, account) in accounts.enumerated() {
                let wave = max(0.05, sin(Double(i) * 0.6 + Double(j)) * 0.45 + sin(Double(i) * 0.21 + Double(j) * 2) * 0.3 + 0.8)
                let work = account.group == "work"
                let cost = (scale[account.id] ?? 1) * wave * (weekend ? (work ? 0.15 : 1.6) : 1)
                points.append(RemoteTimelinePoint(period: period, accountId: account.id, costUsd: cost, tokens: Int(cost * 3_100_000),
                                                  baselineCostUsd: account.id == "codex-work" ? cost * 0.2 : nil))
            }
        }
        let timeline = RemoteTimeline(days: 30, resolution: "day", periods: periods, points: points, accounts: accounts)

        func totals(_ id: String) -> RemoteTotals {
            let cost = points.filter { $0.accountId == id }.reduce(0) { $0 + $1.costUsd }
            let tokens = points.filter { $0.accountId == id }.reduce(0) { $0 + $1.tokens }
            return RemoteTotals(costUsd: cost, tokens: tokens, inputTokens: Int(Double(tokens) * 0.93), cachedInputTokens: Int(Double(tokens) * 0.81),
                                outputTokens: Int(Double(tokens) * 0.07), sessions: Int(cost / 2.4), cacheSavingsUsd: cost * 2.7)
        }
        func sum(_ rows: [RemoteTotals]) -> RemoteTotals {
            rows.reduce(RemoteTotals()) { a, b in
                RemoteTotals(costUsd: a.costUsd + b.costUsd, tokens: a.tokens + b.tokens, inputTokens: a.inputTokens + b.inputTokens,
                             cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens, outputTokens: a.outputTokens + b.outputTokens,
                             sessions: a.sessions + b.sessions, cacheSavingsUsd: a.cacheSavingsUsd + b.cacheSavingsUsd)
            }
        }
        let groups = ["work", "personal", "other"].map { group in
            let rows = accounts.filter { $0.group == group }.map { RemoteAccountUsage(account: $0, totals: totals($0.id)) }
            return RemoteGroupUsage(group: group, totals: sum(rows.map(\.totals)), accounts: rows)
        }
        let todayCost = points.filter { $0.period == today }.reduce(0) { $0 + $1.costUsd }
        let summary = RemoteSummary(days: 30, from: periods.first ?? today, to: now, groups: groups, total: sum(groups.map(\.totals)),
                                    todayCostUsd: todayCost, generatedAt: now.addingTimeInterval(-75), serverName: "Studio", pricingSource: "demo")

        let limits = RemoteLimits(accounts: [
            RemoteAccountLimits(account: accounts[2], windows: [
                RemoteLimitWindow(label: "5-hour", usedPercent: 82, windowMinutes: 300, resetsAt: now.addingTimeInterval(74 * 60)),
                RemoteLimitWindow(label: "Weekly", usedPercent: 46, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3.4 * 86_400)),
            ], asOf: now.addingTimeInterval(-120)),
            RemoteAccountLimits(account: accounts[3], windows: [
                RemoteLimitWindow(label: "5-hour", usedPercent: 23, windowMinutes: 300, resetsAt: now.addingTimeInterval(3.1 * 3600)),
                RemoteLimitWindow(label: "Weekly", usedPercent: 94, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(19 * 3600)),
            ], asOf: now.addingTimeInterval(-300)),
        ], note: "Limits as reported by each provider's CLI.")

        let models: [(String, String, Double)] = [
            ("codex-work", "gpt-5.5-codex", 0.71), ("claude-work", "claude-opus-5-5", 0.84), ("codex-work", "gpt-5.5", 0.29),
            ("claude-max", "claude-opus-5-5", 0.62), ("claude-max", "claude-sonnet-5-5", 0.38), ("codex-pro", "gpt-5.5-codex", 1),
            ("claude-work", "claude-haiku-5-5", 0.16), ("antigravity", "gemini-3.5-pro", 1),
        ]
        let modelRows = models.map { id, model, share -> RemoteModelRow in
            let account = accounts.first { $0.id == id }!
            let t = totals(id)
            return RemoteModelRow(accountId: id, accountName: account.name, group: account.group, provider: account.provider, model: model,
                                  totals: RemoteTotals(costUsd: t.costUsd * share, tokens: Int(Double(t.tokens) * share)), priced: true)
        }.sorted { $0.totals.costUsd > $1.totals.costUsd }

        return Data(summary: summary, timeline: timeline, limits: limits, models: modelRows)
    }
}
#endif
