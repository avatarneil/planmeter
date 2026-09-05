import Foundation
import PlanMeterCore
import PlanMeterDesktopShared
import WidgetKit

extension AppModel {
    /// Uses the same account selection, pricing, and period as the menu bar.
    func desktopSnapshot(now: Date = Date()) -> DesktopSnapshot? {
        guard let lastScan else { return nil }
        let window = menuBarSpendRange.window(now: now)
        let selected = accounts.filter { menuBarSpendGroups.contains(group(for: $0)) }
        let ids = Set(selected.map(\.id))
        let buckets = Aggregation.buckets(cells: cells.filter { ids.contains($0.key.accountId) }, rates: rates,
                                          from: window.from, to: window.to, resolution: .day)
        let total = Aggregation.total(buckets)
        let providers = ProviderKind.allCases.compactMap { provider -> DesktopSnapshot.Provider? in
            let providerIDs = Set(selected.filter { $0.provider == provider }.map(\.id))
            guard !providerIDs.isEmpty else { return nil }
            let cost = Aggregation.total(buckets.filter { providerIDs.contains($0.accountId) }).costUsd
            return .init(id: provider.rawValue, name: provider.displayName, cost: cost)
        }.sorted { $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost }
        return DesktopSnapshot(scannedAt: lastScan, generatedAt: now, rangeID: menuBarSpendRange.rawValue,
                               rangeName: menuBarSpendRange.displayName, groups: menuBarSpendGroups.map(\.displayName).sorted(),
                               cost: total.costUsd, tokens: total.totals.total, unpricedTokens: total.unpricedTokens,
                               limit: menuBarSpendThreshold?.limit, warningPercent: menuBarSpendThreshold?.warningPercent ?? 80,
                               providers: providers)
    }

    func publishDesktopWidget() {
        guard let snapshot = desktopSnapshot(), let directory = DesktopWidgetStore.container else { return }
        do {
            try DesktopWidgetStore.save(snapshot, to: directory)
            desktopWidgetError = nil
            WidgetCenter.shared.reloadTimelines(ofKind: DesktopWidgetStore.kind)
        } catch {
            desktopWidgetError = "Desktop widget could not update: \(error.localizedDescription)"
        }
    }
}
