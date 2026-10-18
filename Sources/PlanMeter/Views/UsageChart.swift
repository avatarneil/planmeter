import Charts
import SwiftUI
import PlanMeterCore

struct ChartPoint: Identifiable {
    var id: String { "\(period.timeIntervalSince1970):\(scope.id):\(baseline)" }
    var period: Date
    var end: Date
    var scope: UsageScope
    var value: Double
    var lowerBound: Double = 0
    /// Workspace credits without timing, spread evenly over the reported hours.
    var baseline = false
    var upperBound: Double { lowerBound + value }
    var series: String { baseline ? "\(scope.id)|baseline" : scope.id }

    static func selected(in points: [ChartPoint], date: Date, value: Double) -> UsageScope? {
        points.first {
            date >= $0.period && date < $0.end && $0.value > 0 && value >= $0.lowerBound && value < $0.upperBound
        }?.scope
    }
}

/// Shared x-axis formatting for usage charts at any granularity.
enum ChartTime {
    static func end(of period: Date, resolution: Resolution, calendar: Calendar = .current) -> Date {
        if let step = resolution.stepMs { return period.addingTimeInterval(TimeInterval(step) / 1000) }
        return calendar.dateInterval(of: .day, for: period)?.end ?? period.addingTimeInterval(86_400)
    }

    /// A small gap between adjacent bars, so dense minute charts stay legible.
    static func barEnd(of period: Date, resolution: Resolution) -> Date {
        let end = self.end(of: period, resolution: resolution)
        return end.addingTimeInterval(-end.timeIntervalSince(period) * 0.12)
    }

    static func label(_ date: Date, resolution: Resolution, multiDay: Bool) -> String {
        switch resolution {
        case .day: return date.formatted(.dateTime.month(.abbreviated).day())
        case .hour, .fifteenMinutes:
            return multiDay ? date.formatted(.dateTime.weekday(.abbreviated).hour()) : date.formatted(.dateTime.hour())
        case .minute, .fiveMinutes: return date.formatted(.dateTime.hour().minute())
        }
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
        @Bindable var model = model
        Card {
            let (points, scopes, colors) = data
            let resolution = model.chartResolution
            HStack(spacing: 4) {
                Text(model.metric == .cost ? "Cost over time" : "Tokens over time").font(.headline)
                InfoButton(text: model.usageNote + " Click a bar or a name to explore its usage.", topic: "these estimates")
                Spacer()
                Picker("Granularity", selection: $model.granularity) {
                    ForEach(model.range.granularities, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.range.granularities.count < 2)
                .help("Bucket size")
                Picker("Series", selection: $seriesMode) {
                    ForEach(SeriesMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            if points.isEmpty {
                Text("No usage in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                let multiDay = model.range.dayCount > 1
                let titles = Dictionary(scopes.map { ($0.id, model.title(for: $0)) }, uniquingKeysWith: { first, _ in first })
                Chart(points) { point in
                    RectangleMark(
                        xStart: .value("Start", point.period),
                        xEnd: .value("End", ChartTime.barEnd(of: point.period, resolution: resolution)),
                        yStart: .value(model.metric.rawValue, point.lowerBound),
                        yEnd: .value(model.metric.rawValue, point.upperBound)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .accessibilityLabel((titles[point.scope.id] ?? "") + (point.baseline ? ", even baseline" : ""))
                    .accessibilityValue(model.metric == .cost ? Format.usd(point.value) : Format.tokens(Int(point.value)))
                }
                .chartForegroundStyleScale(domain: scopes.flatMap { [$0.id, "\($0.id)|baseline"] },
                                           range: colors.flatMap { [$0, $0.opacity(0.35)] })
                // Extend to the end of the current bucket so it isn't clipped at "now".
                .chartXScale(domain: model.range.window().from...max(model.range.window().to, points.map(\.end).max() ?? model.range.window().to))
                .chartXAxis {
                    AxisMarks(values: resolution == .day ? .stride(by: .day, count: max(1, model.range.dayCount / 7)) : .automatic(desiredCount: 8)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(ChartTime.label(date, resolution: resolution, multiDay: multiDay)) }
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
                                if let scope = ChartPoint.selected(in: points, date: date, value: value) {
                                    model.usageDetail = scope
                                }
                            }
                    }
                }
                .frame(minHeight: 220)
                if points.contains(where: \.baseline) {
                    Text("Lighter bars: workspace credits without timing (Chat, voice, image), spread evenly over the hours the provider reported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !points.isEmpty {
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
        let resolution = model.chartResolution
        var scopes: [UsageScope] = []
        var colors: [Color] = []
        var points: [ChartPoint] = []
        var totals: [Date: Double] = [:]
        func value(_ rows: [Bucket]) -> Double {
            rows.reduce(0) { $0 + (model.metric == .cost ? $1.costUsd : Double($1.totals.total)) }
        }
        // Baselines stack first, under every series' timed usage.
        for baseline in [true, false] {
            for (scope, color) in candidates {
                let rows = model.buckets(in: scope)
                guard !rows.isEmpty else { continue }
                if baseline == false, !scopes.contains(scope) { scopes.append(scope); colors.append(color) }
                let periods = Dictionary(grouping: rows.filter { ($0.costSource == .workspaceBaseline) == baseline }, by: \.periodStart)
                for date in periods.keys.sorted() {
                    let amount = value(periods[date, default: []])
                    guard amount > 0 else { continue }
                    let lower = totals[date, default: 0]
                    points.append(ChartPoint(period: date, end: ChartTime.end(of: date, resolution: resolution), scope: scope,
                                             value: amount, lowerBound: lower, baseline: baseline))
                    totals[date] = lower + amount
                }
            }
        }
        return (points, scopes, colors)
    }
}
