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
                } currentValueLabel: { Text(entry.todayText).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6) }
                .gaugeStyle(.accessoryCircular)
            } else {
                Text(entry.todayText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    Text(entry.todayText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .layoutPriority(1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.configuration.label).fontWeight(.semibold)
                        if let target = entry.configuration.target {
                            Text("of \(WatchPayload.compactUsd(target)) today")
                        } else {
                            Text("Today")
                        }
                    }.font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                if let target = entry.configuration.target, let today = entry.today {
                    ProgressView(value: min(1, max(0, today / target)))
                        .progressViewStyle(.linear).tint(.primary).frame(height: 3)
                    Text(today > target
                         ? "\(WatchPayload.compactUsd(today - target)) over target"
                         : "\(WatchPayload.compactUsd(target - today)) remaining")
                        .font(.system(size: 11, weight: .medium))
                } else if entry.today == nil {
                    Text("Open iPhone app to sync").font(.system(size: 11))
                } else if entry.configuration.groups.count > 1, let groups = p.todayCostByGroup {
                    Text([("personal", "P"), ("work", "W"), ("other", "Other")]
                        .filter { entry.configuration.groups.contains($0.0) }
                        .map { "\($0.1) \(WatchPayload.compactUsd(groups[$0.0] ?? 0))" }
                        .joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
