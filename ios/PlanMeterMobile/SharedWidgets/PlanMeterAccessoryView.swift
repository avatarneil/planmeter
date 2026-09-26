import PlanMeterWatchShared
import SwiftUI
import WidgetKit

struct PlanMeterAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    var entry: PlanMeterEntry

    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                // Only this non-sensitive status opts out of redaction. Never reveal
                // cached amounts when watchOS or the Lock Screen hides content.
                status(redactionReasons.contains(.privacy) ? "Usage hidden" : "Open app to sync", symbol: "chart.bar.fill")
                    .unredacted()
            } else if let payload = entry.payload {
                if payload.isStale(at: entry.date) {
                    status("Open app to refresh", symbol: "arrow.clockwise")
                } else {
                    content(payload)
                }
            } else {
                status("Open iPhone app to sync", symbol: "iphone")
            }
        }
        .widgetURL(URL(string: "planmeter://dashboard"))
    }

    @ViewBuilder
    private func content(_ p: WatchPayload) -> some View {
        switch family {
        case .accessoryCircular:
            if let limit = p.limits.first(where: { $0.resetsAt > entry.date }) {
                Gauge(value: min(100, max(0, limit.usedPercent)), in: 0...100) {
                    Image(systemName: "chart.bar.fill")
                } currentValueLabel: {
                    Text("\(Int(min(100, max(0, limit.usedPercent)).rounded()))")
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "chart.bar.fill").font(.caption2)
                    Text(WatchPayload.compactUsd(p.todayCostUsd)).font(.caption2.weight(.semibold))
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill").widgetAccentable()
                    Text("Today")
                    Spacer(minLength: 0)
                    Text(WatchPayload.compactUsd(p.todayCostUsd)).fontWeight(.bold)
                }
                .font(.caption.weight(.semibold))
                HStack(spacing: 4) {
                    Text("Personal · \(p.rangeLabel)")
                    Spacer(minLength: 0)
                    Text(WatchPayload.compactUsd(p.personalCostUsd)).fontWeight(.medium)
                }
                HStack(spacing: 4) {
                    Text("Work · \(p.rangeLabel)")
                    Spacer(minLength: 0)
                    Text(WatchPayload.compactUsd(p.workCostUsd)).fontWeight(.medium)
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        case .accessoryInline:
            Text("PlanMeter \(WatchPayload.compactUsd(p.todayCostUsd)) today")
        #if os(watchOS)
        case .accessoryCorner:
            Text(WatchPayload.compactUsd(p.todayCostUsd))
                .font(.headline.weight(.semibold))
                .widgetLabel { Text("Today · PlanMeter") }
        #endif
        default:
            Text(WatchPayload.compactUsd(p.todayCostUsd))
        }
    }

    @ViewBuilder
    private func status(_ message: String, symbol: String) -> some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                Label("PlanMeter", systemImage: symbol).font(.caption.weight(.semibold))
                Text(message).font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text("PlanMeter · \(message)")
        default:
            Image(systemName: symbol).accessibilityLabel("PlanMeter. \(message)")
        }
    }
}
