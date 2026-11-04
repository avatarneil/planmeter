import Charts
import PlanMeterRemote
import SwiftUI

/// The headline numbers for the selected range: total spend, the plan split,
/// today, the daily average and a sparkline of spend over the range.
struct OverviewCard: View {
    var summary: RemoteSummary
    var timeline: RemoteTimeline?

    private var rangeTitle: String {
        if let minutes = summary.minutes { return minutes == 60 ? "Last hour" : "Last \(minutes) minutes" }
        if summary.days == 1 { return summary.usesProviderDates == true ? "Today" : "Last 24 hours" }
        return "Last \(summary.days) days"
    }

    private var groups: [RemoteGroupUsage] { summary.groups.filter { $0.totals.costUsd > 0 } }

    /// Spend per period, zero-filled across the whole window.
    private var series: [(period: Date, cost: Double)] {
        guard let timeline else { return [] }
        let costs = Dictionary(grouping: timeline.points, by: \.period).mapValues { $0.reduce(0) { $0 + $1.costUsd } }
        let periods = timeline.periods.isEmpty ? costs.keys.sorted() : timeline.periods
        return periods.map { ($0, costs[$0] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rangeTitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(Fmt.usd(summary.total.costUsd))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: summary.total.costUsd))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(Fmt.tokens(summary.total.tokens)) tokens · \(summary.total.sessions) sessions")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !groups.isEmpty { donut }
            }

            HStack(spacing: 8) {
                tile("Today", Fmt.usd(summary.todayCostUsd), symbol: "sun.max.fill", color: .orange)
                if summary.minutes == nil, summary.days > 1 {
                    tile("Daily avg", Fmt.usd(summary.total.costUsd / Double(summary.days)), symbol: "chart.line.flattrend.xyaxis", color: .blue)
                }
                tile("Cache saved", Fmt.usd(summary.total.cacheSavingsUsd), symbol: "bolt.fill", color: .green)
            }

            let series = self.series
            if series.count > 2, series.contains(where: { $0.cost > 0 }) {
                sparkline(series)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            shape.fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    shape.fill(LinearGradient(colors: [Palette.group("work").opacity(0.20), Palette.group("personal").opacity(0.10), .clear],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay { shape.strokeBorder(Color.primary.opacity(0.06)) }
        }
    }

    private var donut: some View {
        let top = groups.max { $0.totals.costUsd < $1.totals.costUsd }
        return Chart(groups) { group in
            SectorMark(angle: .value("Cost", group.totals.costUsd), innerRadius: .ratio(0.64), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(Palette.group(group.group).gradient)
        }
        .chartLegend(.hidden)
        .frame(width: 88, height: 88)
        .overlay {
            if let top, summary.total.costUsd > 0 {
                VStack(spacing: 0) {
                    Text(Fmt.percent(top.totals.costUsd / summary.total.costUsd)).font(.system(.subheadline, design: .rounded, weight: .bold))
                    Text(Fmt.groupName(top.group)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(groups.map { "\(Fmt.groupName($0.group)) \(Fmt.usd($0.totals.costUsd))" }.joined(separator: ", "))
    }

    private func tile(_ label: String, _ value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol)
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(color: color))
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sparkline(_ series: [(period: Date, cost: Double)]) -> some View {
        let tint = Palette.group("work")
        return Chart {
            ForEach(series, id: \.period) { point in
                AreaMark(x: .value("Period", point.period), y: .value("Cost", point.cost))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Period", point.period), y: .value("Cost", point.cost))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint.gradient)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let last = series.last {
                PointMark(x: .value("Period", last.period), y: .value("Cost", last.cost))
                    .symbolSize(30)
                    .foregroundStyle(tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 48)
        .accessibilityHidden(true)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title
        }
    }
}
