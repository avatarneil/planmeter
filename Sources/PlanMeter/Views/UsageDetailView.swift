import Charts
import SwiftUI
import PlanMeterCore

struct UsageDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var scope: UsageScope

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            HStack {
                Text("Usage details").font(.headline)
                Spacer()
                Picker("Range", selection: $model.range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 120)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                UsageDetailView(scope: scope)
            }
        }
        .padding(20)
        .frame(width: 660, height: 600)
    }
}

/// Shared by the main window's drill-down sheet and the compact menu bar view.
struct UsageDetailView: View {
    @Environment(AppModel.self) private var model
    var scope: UsageScope
    var compact = false

    var body: some View {
        let metric: Metric = compact ? .cost : model.metric
        let accountCount = model.accounts(in: scope).count
        let buckets = model.buckets(in: scope)
        let total = Aggregation.total(buckets)
        let modelRows = Aggregation.byModel(buckets).sorted {
            $0.value.costUsd == $1.value.costUsd ? $0.key < $1.key : $0.value.costUsd > $1.value.costUsd
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title(for: scope)).font(compact ? .headline : .title2.bold())
            Text("\(model.range.rawValue) · \(accountCount) \(accountCount == 1 ? "account" : "accounts") · Estimated usage cost")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Stat(label: "Cost", value: Format.usd(total.costUsd))
                Stat(label: "Tokens", value: Format.tokens(total.totals.total))
                if !compact { Stat(label: "Cache savings", value: Format.usd(total.cacheSavingsUsd)) }
            }
            if buckets.isEmpty {
                Text("No usage in this range.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                let points = Dictionary(grouping: buckets, by: \.periodStart).map { date, rows in
                    let total = Aggregation.total(rows)
                    return (date: date, value: metric == .cost ? total.costUsd : Double(total.totals.total))
                }.sorted { $0.date < $1.date }
                Chart(points, id: \.date) { point in
                    BarMark(
                        x: .value("Period", point.date, unit: model.range.resolution == .hour ? .hour : .day),
                        y: .value(metric.rawValue, point.value)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let value = value.as(Double.self) {
                                Text(metric == .cost ? Format.usd(value) : Format.tokens(Int(value)))
                            }
                        }
                    }
                }
                .frame(height: compact ? 110 : 200)
                Text("Models").font(.subheadline.weight(.semibold))
                ForEach(modelRows, id: \.key) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.key).font(.caption).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Text(Format.usd(row.value.costUsd)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        HStack {
                            Text("\(Format.tokens(row.value.totals.total)) tokens")
                            Spacer()
                            if row.value.unpricedTokens > 0 { Text("Includes unpriced tokens") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        ShareBar(fraction: total.costUsd > 0 ? row.value.costUsd / total.costUsd : 0, color: .accentColor)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
