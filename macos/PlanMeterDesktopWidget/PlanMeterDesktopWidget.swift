import PlanMeterDesktopShared
import SwiftUI
import WidgetKit

struct SpendEntry: TimelineEntry {
    var date: Date
    var snapshot: DesktopSnapshot?
}

struct SpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendEntry {
        SpendEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendEntry) -> Void) {
        completion(SpendEntry(date: Date(), snapshot: context.isPreview ? .preview : DesktopWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendEntry>) -> Void) {
        let now = Date()
        let snapshot = DesktopWidgetStore.load()
        // A future entry makes stale data visibly stale even if the app stops.
        let expiry = snapshot?.scannedAt.addingTimeInterval(15 * 60) ?? now
        let staleAt = expiry > now ? expiry : now.addingTimeInterval(15 * 60)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(24 * 60 * 60)
        let next = min(staleAt, midnight)
        completion(Timeline(entries: [SpendEntry(date: now, snapshot: snapshot), SpendEntry(date: next, snapshot: snapshot)],
                            policy: .after(next)))
    }
}

struct SpendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SpendEntry

    var body: some View {
        DesktopSpendView(snapshot: entry.snapshot, date: entry.date, medium: family == .systemMedium)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color(.windowBackgroundColor), Color.teal.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .widgetURL(URL(string: "planmeter-desktop://dashboard"))
    }
}

@main
struct PlanMeterDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DesktopWidgetStore.kind, provider: SpendProvider()) { entry in
            SpendWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Spend")
        .description("Your selected tools, spending limit, and room to go. Follows PlanMeter’s menu bar settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
