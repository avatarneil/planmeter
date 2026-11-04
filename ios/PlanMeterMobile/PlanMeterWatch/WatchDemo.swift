#if DEBUG
import Foundation
import PlanMeterWatchShared

/// Sample data for simulator screenshots: launch with `--demo`. Never saved to
/// the shared app group, so it can't leak into real complications.
enum WatchDemo {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo") }

    /// `--page N` opens on that tab, for screenshots.
    static var initialPage: Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--page"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    static func payload(now: Date = Date(), calendar: Calendar = .current) -> WatchPayload {
        let midnight = calendar.startOfDay(for: now)
        // Deterministic noise so screenshots are stable between runs.
        func wave(_ i: Int, _ salt: Double) -> Double {
            let x = Double(i)
            return max(0, sin(x * 0.37 + salt) * 0.5 + sin(x * 0.11 + salt * 2) * 0.35 + 0.3)
        }

        let hourStart = calendar.date(bySetting: .second, value: 0, of: now.addingTimeInterval(-59 * 60)) ?? now
        let lastHour = (0..<60).map { i in
            WatchPayload.Bar(start: hourStart.addingTimeInterval(Double(i) * 60),
                             costs: ["personal": wave(i, 0.4) * 0.06, "work": wave(i, 2.1) * 0.14 * (i > 35 ? 1.8 : 1)])
        }

        // Shaped like a busy day, then scaled so screenshots read the same at any hour.
        let quarters = Int(now.timeIntervalSince(midnight) / 900) + 1
        let raw = (0..<quarters).map { i -> WatchPayload.Bar in
            WatchPayload.Bar(start: midnight.addingTimeInterval(Double(i) * 900),
                             costs: ["personal": wave(i, 1.3) * 0.55, "work": wave(i, 0.2) * 1.6],
                             baselines: ["work": i % 8 < 4 ? 0.25 : 0])
        }
        let rawTotal = max(raw.reduce(0) { $0 + $1.total }, .ulpOfOne)
        let today = raw.map { bar in
            WatchPayload.Bar(start: bar.start, costs: bar.costs.mapValues { $0 * 46.2 / rawTotal },
                             baselines: bar.baselines.mapValues { $0 * 46.2 / rawTotal })
        }
        let hourTotal = max(lastHour.reduce(0) { $0 + $1.total }, .ulpOfOne)
        let lastHourScaled = lastHour.map { WatchPayload.Bar(start: $0.start, costs: $0.costs.mapValues { $0 * 5.26 / hourTotal }) }
        let personalToday = today.reduce(0) { $0 + ($1.costs["personal"] ?? 0) }
        let workToday = today.reduce(0) { $0 + ($1.costs["work"] ?? 0) }

        var preferences = ComplicationPreferences()
        preferences.dailyTarget = 75

        var payload = WatchPayload(
            updatedAt: now.addingTimeInterval(-90), days: 30, serverName: "Studio",
            personalCostUsd: 284.17, workCostUsd: 1_142.60, otherCostUsd: 38.4,
            personalTokens: 412_000_000, workTokens: 3_910_000_000, todayCostUsd: personalToday + workToday + 1.2,
            accounts: [
                .init(name: "Work Codex", group: "work", provider: "codex", costUsd: 791.3, tokens: 2_700_000_000),
                .init(name: "Work Claude", group: "work", provider: "claude", costUsd: 351.3, tokens: 1_210_000_000),
                .init(name: "Claude Max", group: "personal", provider: "claude", costUsd: 196.8, tokens: 288_000_000),
                .init(name: "ChatGPT Pro", group: "personal", provider: "codex", costUsd: 87.37, tokens: 124_000_000),
                .init(name: "Antigravity", group: "other", provider: "antigravity", costUsd: 38.4, tokens: 61_000_000),
            ],
            limits: [
                .init(account: "Claude Max", label: "5-hour", usedPercent: 82, resetsAt: now.addingTimeInterval(74 * 60)),
                .init(account: "Claude Max", label: "Weekly", usedPercent: 46, resetsAt: now.addingTimeInterval(3.4 * 86_400)),
                .init(account: "ChatGPT Pro", label: "5-hour", usedPercent: 23, resetsAt: now.addingTimeInterval(3.1 * 3600)),
                .init(account: "ChatGPT Pro", label: "Weekly", usedPercent: 94, resetsAt: now.addingTimeInterval(19 * 3600)),
            ],
            todayCostByGroup: ["personal": personalToday, "work": workToday, "other": 1.2],
            complicationPreferences: preferences,
            usesProviderDates: false
        )
        payload.lastHour = lastHourScaled
        payload.today = today
        return payload
    }
}
#endif
