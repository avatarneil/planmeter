import Foundation
import PlanMeterCore
import PlanMeterDesktopShared
import WidgetKit

extension AppModel {
    /// Uses the same account selection, pricing, and period as the menu bar.
    func desktopSnapshot(now: Date = Date()) -> DesktopSnapshot? {
        guard let lastScan else { return nil }
        let window = range.window(now: now)
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
        let hourly = range.resolution == .hour
        let trendBuckets = hourly
            ? Aggregation.buckets(cells: cells.filter { ids.contains($0.key.accountId) }, rates: rates,
                                  from: window.from, to: window.to, resolution: .hour)
            : buckets
        let costsByDate = Dictionary(grouping: trendBuckets, by: \.periodStart).mapValues { Aggregation.total($0).costUsd }
        var trend: [DesktopSnapshot.Detail.Point] = []
        let calendar = Calendar.current
        var period = hourly ? Date(timeIntervalSince1970: floor(window.from.timeIntervalSince1970 / 3600) * 3600)
            : calendar.startOfDay(for: window.from)
        let end = min(window.to, now)
        while period < end {
            trend.append(.init(date: period, cost: costsByDate[period] ?? 0))
            guard let next = calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: period), next > period else { break }
            period = next
        }
        let byAccount = Aggregation.byAccount(buckets)
        var accountDetails: [DesktopSnapshot.Detail.Account] = []
        for account in selected {
            let aggregate: Aggregate = byAccount[account.id] ?? Aggregate()
            accountDetails.append(.init(id: account.id, name: account.displayName, provider: account.provider.displayName,
                                        cost: aggregate.costUsd, tokens: aggregate.totals.total))
        }
        accountDetails.sort { $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost }
        let detail = DesktopSnapshot.Detail(hourly: hourly, trend: trend, accounts: accountDetails,
                                            cacheSavings: total.cacheSavingsUsd,
                                            cachedInputShare: total.totals.input > 0 ? Double(total.totals.cachedInput) / Double(total.totals.input) : 0)
        return DesktopSnapshot(scannedAt: lastScan, generatedAt: now, rangeID: range.id,
                               rangeName: range.displayName, groups: menuBarSpendGroups.map(\.displayName).sorted(),
                               cost: total.costUsd, tokens: total.totals.total, unpricedTokens: total.unpricedTokens,
                               limit: menuBarSpendThreshold?.limit, warningPercent: menuBarSpendThreshold?.warningPercent ?? 80,
                               providers: providers, detail: detail)
    }

    func publishDesktopWidget(now: Date = Date()) {
        guard let snapshot = desktopSnapshot(now: now), let directory = DesktopWidgetStore.container else { return }
        do {
            try DesktopWidgetStore.save(snapshot, to: directory)
            desktopWidgetError = nil
            WidgetCenter.shared.reloadTimelines(ofKind: DesktopWidgetStore.kind)
        } catch {
            desktopWidgetError = "Desktop widget could not update: \(error.localizedDescription)"
        }
    }
}
