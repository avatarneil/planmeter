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
            if let target = entry.configuration.target, let today = entry.today {
                Gauge(value: min(1, max(0, today / target))) {
                    Text(entry.configuration.label)
                } currentValueLabel: { Text(entry.todayText).minimumScaleFactor(0.5) }
                .gaugeStyle(.accessoryCircular)
            } else {
                Text(entry.todayText).font(.caption.weight(.semibold)).minimumScaleFactor(0.5)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill").widgetAccentable()
                    Text("Today")
                    Spacer(minLength: 0)
                    Text(entry.todayText).fontWeight(.bold)
                }
                .font(.caption.weight(.semibold))
                Text(entry.configuration.label)
                if let target = entry.configuration.target {
                    Text("Target \(WatchPayload.compactUsd(target))/day")
                } else if entry.today == nil {
                    Text("Open iPhone app to sync")
                } else {
                    Text("API-equivalent spend")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        case .accessoryInline:
            Text("\(entry.configuration.label) \(entry.todayText) today")
        #if os(watchOS)
        case .accessoryCorner:
            Text(entry.todayText)
                .font(.headline.weight(.semibold))
                .widgetLabel { Text("Today · PlanMeter") }
        #endif
        default:
            Text(entry.todayText)
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
