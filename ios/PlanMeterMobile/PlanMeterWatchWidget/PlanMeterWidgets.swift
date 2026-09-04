import PlanMeterWatchShared
import SwiftUI
import WidgetKit

/// Complications fed from the payload the watch app cached in the app group.
struct PlanMeterEntry: TimelineEntry {
    var date: Date
    var payload: WatchPayload?
}

struct PlanMeterProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlanMeterEntry {
        PlanMeterEntry(date: Date(), payload: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanMeterEntry) -> Void) {
        completion(PlanMeterEntry(date: Date(), payload: context.isPreview ? .preview : WatchPayload.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanMeterEntry>) -> Void) {
        let entry = PlanMeterEntry(date: Date(), payload: WatchPayload.load())
        // The watch app reloads timelines whenever the phone pushes; this is a
        // fallback so relative times stay roughly right.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct PlanMeterComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PlanMeterEntry

    var body: some View {
        let p = entry.payload
        switch family {
        case .accessoryCircular:
            if let limit = p?.limits.first {
                Gauge(value: min(100, max(0, limit.usedPercent)), in: 0...100) {
                    Image(systemName: "chart.bar.fill")
                } currentValueLabel: {
                    Text("\(Int(limit.usedPercent.rounded()))")
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "chart.bar.fill").font(.caption2)
                    Text(p.map { WatchPayload.compactUsd($0.todayCostUsd) } ?? "–").font(.caption2.weight(.semibold)).minimumScaleFactor(0.6)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("PlanMeter").font(.caption2.weight(.semibold))
                    Spacer()
                    Text(p.map { "today \(WatchPayload.compactUsd($0.todayCostUsd))" } ?? "no sync").font(.caption2).foregroundStyle(.secondary)
                }
                if let p {
                    line("Personal", p.personalCostUsd, total: p.totalCostUsd)
                    line("Work", p.workCostUsd, total: p.totalCostUsd)
                } else {
                    Text("Open PlanMeter on iPhone").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .accessoryInline:
            if let p {
                Text("PlanMeter \(WatchPayload.compactUsd(p.todayCostUsd)) today · P \(WatchPayload.compactUsd(p.personalCostUsd)) W \(WatchPayload.compactUsd(p.workCostUsd))")
            } else {
                Text("PlanMeter: no sync")
            }
        case .accessoryCorner:
            Text(p.map { WatchPayload.compactUsd($0.todayCostUsd) } ?? "–")
                .font(.headline.weight(.semibold))
                .widgetLabel { Text(p.map { "P \(WatchPayload.compactUsd($0.personalCostUsd)) · W \(WatchPayload.compactUsd($0.workCostUsd))" } ?? "PlanMeter") }
        default:
            Text(p.map { WatchPayload.compactUsd($0.todayCostUsd) } ?? "–")
        }
    }

    private func line(_ name: String, _ cost: Double, total: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption2)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.3))
                    Capsule().fill(.primary).frame(width: max(0, min(1, total > 0 ? cost / total : 0)) * geo.size.width)
                }
            }
            .frame(height: 4)
            Text(WatchPayload.compactUsd(cost)).font(.caption2.weight(.medium)).monospacedDigit()
        }
    }
}

struct PlanMeterComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.neilgoldader.planmeter.complication", provider: PlanMeterProvider()) { entry in
            PlanMeterComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PlanMeter")
        .description("Today's AI spend, personal vs work, and Codex limits.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct PlanMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlanMeterComplication()
    }
}

extension WatchPayload {
    static let preview = WatchPayload(
        updatedAt: Date(), days: 30, serverName: "Mac",
        personalCostUsd: 184.2, workCostUsd: 421.5, otherCostUsd: 0,
        personalTokens: 320_000_000, workTokens: 3_480_000_000, todayCostUsd: 42.1,
        accounts: [
            Account(name: "Personal Codex", group: "personal", provider: "codex", costUsd: 151, tokens: 290_000_000),
            Account(name: "Work Codex", group: "work", provider: "codex", costUsd: 421, tokens: 3_480_000_000),
        ],
        limits: [Limit(account: "Personal Codex", label: "Weekly", usedPercent: 15, resetsAt: Date().addingTimeInterval(4 * 86_400))]
    )
}
