import Foundation
import PlanMeterRemote
import PlanMeterWatchShared

public enum WatchCloudError: LocalizedError {
    case chooseMac, signedOut
    public var errorDescription: String? {
        switch self {
        case .chooseMac: return "Choose a Mac in the watch app."
        case .signedOut: return "Sign in to iCloud on your Apple Watch."
        }
    }
}

/// CloudKit reads shared by the independent watch app and its timeline provider.
public enum WatchCloudSync {
    public static var selectedMacID: String? {
        get { WatchPayload.sharedDefaults().string(forKey: "watch.cloudMacID") }
        set { WatchPayload.sharedDefaults().set(newValue, forKey: "watch.cloudMacID") }
    }

    public static func fetch() async throws -> [WatchPayload] {
        do { return try await CloudSnapshotStore().fetch().map { try payload(from: $0) } }
        catch CloudSyncError.signedOut { throw WatchCloudError.signedOut }
    }

    public static func select(_ choices: [WatchPayload], cached: WatchPayload?, selectedMacID: String? = nil) throws -> WatchPayload? {
        let selected: WatchPayload?
        if let id = selectedMacID ?? cached?.cloudMacID {
            selected = choices.first { $0.cloudMacID == id }
        } else if choices.isEmpty {
            // A direct-connection phone payload can still be used without a cloud Mac.
            return cached
        } else if choices.count == 1 {
            selected = choices.first
        } else {
            throw WatchCloudError.chooseMac
        }
        guard var selected else { return nil }
        if let cached, cached.cloudMacID == selected.cloudMacID, cached.updatedAt > selected.updatedAt {
            selected = cached
        }
        selected.complicationPreferences = cached?.complicationPreferences
        return selected
    }

    public static func payload(from snapshot: CloudSnapshot) throws -> WatchPayload {
        let report = try snapshot.report(days: 30)
        guard let summary = report.summary else { throw CloudSyncError.incompleteSnapshot }
        func group(_ name: String) -> RemoteGroupUsage? { summary.groups.first { $0.group == name } }
        return WatchPayload(
            updatedAt: snapshot.generatedAt, days: summary.days, serverName: snapshot.name,
            personalCostUsd: group("personal")?.totals.costUsd ?? 0,
            workCostUsd: group("work")?.totals.costUsd ?? 0,
            otherCostUsd: group("other")?.totals.costUsd ?? 0,
            personalTokens: Int64(group("personal")?.totals.tokens ?? 0),
            workTokens: Int64(group("work")?.totals.tokens ?? 0),
            todayCostUsd: summary.todayCostUsd,
            accounts: summary.groups.flatMap { group in group.accounts.map {
                WatchPayload.Account(name: $0.account.name, group: group.group, provider: $0.account.provider, costUsd: $0.totals.costUsd, tokens: Int64($0.totals.tokens))
            }}.sorted { $0.costUsd > $1.costUsd },
            limits: (report.limits?.accounts ?? []).flatMap { row in row.windows.map {
                WatchPayload.Limit(account: row.account.name, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
            }},
            todayCostByGroup: report.timeline?.costByGroup(on: snapshot.generatedAt),
            cloudMacID: snapshot.id)
    }
}
