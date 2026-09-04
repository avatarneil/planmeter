import Charts
import SwiftUI
import PlanMeterCore

struct ChartPoint: Identifiable {
    var id: String { "\(period.timeIntervalSince1970):\(series)" }
    var period: Date
    var series: String
    var value: Double
}

struct UsageChartCard: View {
    @Environment(AppModel.self) private var model
    @State private var seriesMode: SeriesMode = .account

    enum SeriesMode: String, CaseIterable, Identifiable {
        case account = "By account"
        case group = "Personal vs Work"
        var id: String { rawValue }
    }

    var body: some View {
        Card {
            HStack {
                Text(model.metric == .cost ? "Cost over time" : "Tokens over time").font(.headline)
                Spacer()
                Picker("Series", selection: $seriesMode) {
                    ForEach(SeriesMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            let (points, names, colors) = data
            if points.isEmpty {
                Text("No usage in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Period", point.period, unit: model.range.resolution == .hour ? .hour : .day),
                        y: .value(model.metric.rawValue, point.value)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: model.range.resolution == .hour ? 8 : 7)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(model.range.resolution == .hour
                                     ? date.formatted(.dateTime.hour())
                                     : date.formatted(.dateTime.month(.abbreviated).day()))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(model.metric == .cost ? Format.usd(v) : Format.tokens(Int(v)))
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(minHeight: 240)
            }
        }
    }

    private var data: ([ChartPoint], [String], [Color]) {
        var byKey: [String: ChartPoint] = [:]
        var names: [String] = []
        var colors: [Color] = []

        switch seriesMode {
        case .account:
            let ordered = model.accounts
            for account in ordered {
                let rows = model.buckets.filter { $0.accountId == account.id }
                if rows.isEmpty { continue }
                names.append(account.displayName)
                colors.append(model.color(for: account))
                for b in rows {
                    let key = "\(b.periodStart.timeIntervalSince1970):\(account.displayName)"
                    var p = byKey[key] ?? ChartPoint(period: b.periodStart, series: account.displayName, value: 0)
                    p.value += value(b)
                    byKey[key] = p
                }
            }
        case .group:
            for group in PlanGroup.allCases {
                let ids = Set(model.accounts.filter { model.group(for: $0) == group }.map(\.id))
                let rows = model.buckets.filter { ids.contains($0.accountId) }
                if rows.isEmpty { continue }
                names.append(group.displayName)
                colors.append(Palette.color(for: group))
                for b in rows {
                    let key = "\(b.periodStart.timeIntervalSince1970):\(group.displayName)"
                    var p = byKey[key] ?? ChartPoint(period: b.periodStart, series: group.displayName, value: 0)
                    p.value += value(b)
                    byKey[key] = p
                }
            }
        }
        let points = byKey.values.sorted { $0.period < $1.period || ($0.period == $1.period && $0.series < $1.series) }
        return (points, names, colors)
    }

    private func value(_ bucket: Bucket) -> Double {
        model.metric == .cost ? bucket.costUsd : Double(bucket.totals.total)
    }
}
