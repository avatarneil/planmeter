import Charts
import SwiftUI
import PlanMeterCore

struct ChartPoint: Identifiable {
    var id: String { "\(period.timeIntervalSince1970):\(scope.id)" }
    var period: Date
    var scope: UsageScope
    var value: Double
    var lowerBound: Double = 0
    var upperBound: Double { lowerBound + value }

    static func selected(in points: [ChartPoint], date: Date, value: Double, resolution: Resolution, calendar: Calendar = .current) -> UsageScope? {
        let component: Calendar.Component = resolution == .hour ? .hour : .day
        return points.first {
            calendar.isDate($0.period, equalTo: date, toGranularity: component)
                && $0.value > 0 && value >= $0.lowerBound && value < $0.upperBound
        }?.scope
    }
}

struct UsageChartCard: View {
    @Environment(AppModel.self) private var model
    @State private var seriesMode: SeriesMode = .account

    enum SeriesMode: String, CaseIterable, Identifiable {
        case account = "By account"
        case provider = "By provider"
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
                .frame(width: 360)
            }
            let (points, scopes, colors) = data
            if points.isEmpty {
                Text("No usage in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Period", point.period, unit: model.range.resolution == .hour ? .hour : .day),
                        yStart: .value(model.metric.rawValue, point.lowerBound),
                        yEnd: .value(model.metric.rawValue, point.upperBound)
                    )
                    .foregroundStyle(by: .value("Series", point.scope.id))
                    .accessibilityLabel(model.title(for: point.scope))
                    .accessibilityValue(model.metric == .cost ? Format.usd(point.value) : Format.tokens(Int(point.value)))
                }
                .chartForegroundStyleScale(domain: scopes.map(\.id), range: colors)
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
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let anchor = proxy.plotFrame else { return }
                                let frame = geometry[anchor]
                                guard frame.contains(location),
                                      let date = proxy.value(atX: location.x - frame.minX, as: Date.self),
                                      let value = proxy.value(atY: location.y - frame.minY, as: Double.self) else { return }
                                if let scope = ChartPoint.selected(in: points, date: date, value: value, resolution: model.range.resolution) {
                                    model.usageDetail = scope
                                }
                            }
                    }
                }
                .frame(minHeight: 240)
                Text("Click a bar or a name to explore its usage.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Array(scopes.enumerated()), id: \.element.id) { index, scope in
                        Button {
                            model.usageDetail = scope
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(colors[index]).frame(width: 8, height: 8)
                                Text(model.title(for: scope)).font(.caption).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Explore \(model.title(for: scope))")
                        .accessibilityLabel("Explore \(model.title(for: scope))")
                    }
                }
            }
        }
    }

    private var data: ([ChartPoint], [UsageScope], [Color]) {
        let candidates: [(UsageScope, Color)]
        switch seriesMode {
        case .account:
            candidates = model.accounts.map { (.account($0.id), model.color(for: $0)) }
        case .provider:
            candidates = ProviderKind.allCases.enumerated().map { (.provider($0.element), Palette.series[$0.offset % Palette.series.count]) }
        case .group:
            candidates = PlanGroup.allCases.map { (.group($0), Palette.color(for: $0)) }
        }
        var scopes: [UsageScope] = []
        var colors: [Color] = []
        var points: [ChartPoint] = []
        var totals: [Date: Double] = [:]
        for (scope, color) in candidates {
            let rows = model.buckets(in: scope)
            guard !rows.isEmpty else { continue }
            scopes.append(scope)
            colors.append(color)
            let periods = Dictionary(grouping: rows, by: \.periodStart)
            for date in periods.keys.sorted() {
                let value = periods[date, default: []].reduce(0) {
                    $0 + (model.metric == .cost ? $1.costUsd : Double($1.totals.total))
                }
                let lower = totals[date, default: 0]
                points.append(ChartPoint(period: date, scope: scope, value: value, lowerBound: lower))
                totals[date] = lower + value
            }
        }
        return (points, scopes, colors)
    }
}
