import SwiftUI
import PlanMeterCore

struct BreakdownRow: Identifiable {
    var id: String { "\(accountId):\(model)" }
    var accountId: String
    var accountName: String
    var group: PlanGroup
    var provider: ProviderKind
    var model: String
    var aggregate: Aggregate
    var costSource: CostSource
}

struct BreakdownCard: View {
    @Environment(AppModel.self) private var model
    @State private var filter: PlanGroup? = nil
    @State private var sortOrder = [KeyPathComparator(\BreakdownRow.aggregate.costUsd, order: .reverse)]

    var body: some View {
        Card {
            HStack {
                Text("Breakdown by model").font(.headline)
                Spacer()
                Picker("Group", selection: $filter) {
                    Text("All").tag(PlanGroup?.none)
                    ForEach(PlanGroup.allCases) { Text($0.displayName).tag(PlanGroup?.some($0)) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            let rows = self.rows.sorted(using: sortOrder)
            if rows.isEmpty {
                Text("No usage in this range.").foregroundStyle(.secondary).frame(minHeight: 120)
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Account", value: \.accountName) { row in
                        HStack(spacing: 6) {
                            Circle().fill(Palette.color(for: row.group)).frame(width: 7, height: 7)
                            Text(row.accountName).lineLimit(1)
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Provider", value: \.provider.rawValue) { row in
                        Text(row.provider.displayName).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Model", value: \.model) { row in
                        HStack(spacing: 6) {
                            Text(row.model).lineLimit(1).truncationMode(.middle)
                            if row.costSource == .unpriced {
                                Text("unpriced").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).background(Capsule().fill(Color.secondary.opacity(0.12)))
                                    .help("No rate found for this model; cost shows $0.")
                            }
                        }
                    }
                    .width(min: 160, ideal: 220)
                    TableColumn("Cost", value: \.aggregate.costUsd) { row in
                        Text(Format.usd(row.aggregate.costUsd)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                    TableColumn("Tokens", value: \.aggregate.totals.total) { row in
                        Text(Format.tokens(row.aggregate.totals.total)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(80)
                    TableColumn("Cached", value: \.aggregate.totals.cachedInput) { row in
                        Text(Format.percent(cachedShare(row.aggregate.totals))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(60)
                    TableColumn("Sessions", value: \.aggregate.sessions) { row in
                        Text("\(row.aggregate.sessions)").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(70)
                }
                .frame(minHeight: 200, idealHeight: CGFloat(rows.count) * 26 + 40, maxHeight: 460)
            }
        }
    }

    private var rows: [BreakdownRow] {
        struct Key: Hashable { var account: String; var model: String }
        var agg: [Key: (Aggregate, Set<CostSource>)] = [:]
        for b in model.buckets {
            let key = Key(account: b.accountId, model: b.model)
            var entry = agg[key] ?? (Aggregate(), [])
            entry.0.add(b)
            entry.1.insert(b.costSource)
            agg[key] = entry
        }
        return agg.compactMap { key, entry in
            let account = model.account(for: key.account)
            let group = model.group(for: account)
            if let filter, filter != group { return nil }
            let source: CostSource = entry.1.count == 1 ? entry.1.first! : (entry.1.contains(.unpriced) && entry.1.count > 1 ? .mixed : .mixed)
            return BreakdownRow(accountId: account.id, accountName: account.displayName, group: group, provider: account.provider, model: key.model, aggregate: entry.0, costSource: source)
        }
    }

    private func cachedShare(_ t: TokenTotals) -> Double {
        t.input > 0 ? Double(t.cachedInput) / Double(t.input) : 0
    }
}
