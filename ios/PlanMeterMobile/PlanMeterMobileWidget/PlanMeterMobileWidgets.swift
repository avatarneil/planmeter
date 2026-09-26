import PlanMeterWatchShared
import SwiftUI
import WidgetKit

struct PlanMeterSpendView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PlanMeterEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.configuration.label, systemImage: "chart.bar.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.teal).widgetAccentable()
            if let p = entry.payload {
                if family == .systemSmall {
                    total(p)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        total(p).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Last \(p.rangeLabel)").font(.caption).foregroundStyle(.secondary)
                            if entry.configuration.personal { amount("Personal", p.personalCostUsd) }
                            if entry.configuration.work { amount("Work", p.workCostUsd) }
                            if entry.configuration.other && p.otherCostUsd > 0 { amount("Other", p.otherCostUsd) }
                        }
                        .frame(maxWidth: .infinity)
                        .privacySensitive()
                    }
                }
                if family == .systemLarge {
                    Divider()
                    Text("Top accounts · \(p.rangeLabel)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(entry.accounts.prefix(3).enumerated()), id: \.offset) { _, account in
                        amount(account.name, account.costUsd).privacySensitive()
                    }
                    if let limit = p.limits.first(where: { limit in limit.resetsAt > entry.date && entry.accounts.contains(where: { $0.name == limit.account }) }) {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(limit.account) · \(limit.label)").font(.caption).lineLimit(1)
                            ProgressView(value: min(100, max(0, limit.usedPercent)), total: 100)
                                .progressViewStyle(.linear)
                                .tint(.teal)
                            Text("\(Int(min(100, max(0, limit.usedPercent)).rounded()))% used")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.privacySensitive()
                    }
                }
                Spacer(minLength: 0)
                if p.isStale(at: entry.date) {
                    Label("Open app to refresh", systemImage: "arrow.clockwise")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Updated \(p.updatedAt, style: .time)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 0)
                Text("Ready to sync").font(.headline)
                Text("Open PlanMeter on iPhone to connect and sync.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "planmeter://dashboard"))
    }

    private func total(_ p: WatchPayload) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.isStale(at: entry.date) ? "Today at last sync" : "Today")
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.todayText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            if let target = entry.configuration.target {
                Text("Target \(WatchPayload.compactUsd(target))/day").font(.caption2)
                if let today = entry.today {
                    ProgressView(value: min(1, max(0, today / target))).tint(today >= target ? .orange : .teal)
                }
            } else {
                Text("API-equivalent spend").font(.caption2).foregroundStyle(.secondary)
            }
            if entry.today == nil { Text("Open iPhone app to sync").font(.caption2) }
        }.privacySensitive()
    }

    private func amount(_ name: String, _ cost: Double) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            Text(WatchPayload.compactUsd(cost)).fontWeight(.semibold).monospacedDigit()
        }.font(.caption).minimumScaleFactor(0.7)
    }
}

struct PlanMeterSpendWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.neilgoldader.planmeter.mobile.spend", intent: PlanMeterConfiguration.self, provider: PlanMeterProvider()) { entry in
            PlanMeterSpendView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Spend")
        .description("Choose plans and a daily spend target. Sync usage by opening the iPhone app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PlanMeterLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.neilgoldader.planmeter.mobile.lockscreen", intent: PlanMeterConfiguration.self, provider: PlanMeterProvider()) { entry in
            PlanMeterAccessoryView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description("Selected plans’ daily AI spend and optional target on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PlanMeterMobileWidgets: WidgetBundle {
    var body: some Widget {
        PlanMeterSpendWidget()
        PlanMeterLockScreenWidget()
    }
}
