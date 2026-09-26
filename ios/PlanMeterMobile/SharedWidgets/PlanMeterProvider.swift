import PlanMeterWatchShared
import WidgetKit

struct PlanMeterEntry: TimelineEntry {
    var date: Date
    var payload: WatchPayload?
}

struct PlanMeterProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlanMeterEntry {
        // Do not show fictitious amounts or proportion bars on a hidden watch face.
        PlanMeterEntry(date: Date(), payload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanMeterEntry) -> Void) {
        completion(PlanMeterEntry(date: Date(), payload: context.isPreview ? .preview : WatchPayload.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanMeterEntry>) -> Void) {
        let now = Date()
        let payload = WatchPayload.load()
        let refresh = payload?.nextWidgetRefresh(after: now) ?? now.addingTimeInterval(15 * 60)
        // Include expiry as an entry: freshness changes even if a reload is deferred.
        let entries = [PlanMeterEntry(date: now, payload: payload), PlanMeterEntry(date: refresh, payload: payload)]
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}
