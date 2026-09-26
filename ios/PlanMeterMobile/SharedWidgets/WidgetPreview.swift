import Foundation
import PlanMeterWatchShared

extension WatchPayload {
    static let preview = WatchPayload(
        updatedAt: Date(), days: 30, serverName: "Mac",
        personalCostUsd: 184.2, workCostUsd: 421.5, otherCostUsd: 0,
        personalTokens: 320_000_000, workTokens: 3_480_000_000, todayCostUsd: 42.1,
        accounts: [
            Account(name: "Personal Codex", group: "personal", provider: "codex", costUsd: 151, tokens: 290_000_000),
            Account(name: "Work Codex", group: "work", provider: "codex", costUsd: 421, tokens: 3_480_000_000),
        ],
        limits: [Limit(account: "Personal Codex", label: "Weekly", usedPercent: 15, resetsAt: Date().addingTimeInterval(4 * 86_400))]
    )
}
