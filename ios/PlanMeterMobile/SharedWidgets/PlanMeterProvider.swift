import AppIntents
import PlanMeterWatchShared
import WidgetKit
#if os(watchOS)
import PlanMeterWatchCloud
#endif

struct PlanMeterConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Plans and daily target"
    static var description = IntentDescription("Choose the plans to display and an optional daily API-equivalent spend target for this widget.")

    #if os(watchOS)
    @Parameter(title: "Use iPhone watch settings", default: true) var usePhoneSettings: Bool
    #endif

    func resolved(for payload: WatchPayload?) -> PlanMeterConfiguration {
        #if os(watchOS)
        if usePhoneSettings, let preferences = payload?.complicationPreferences {
            let resolved = PlanMeterConfiguration()
            resolved.personal = preferences.personal
            resolved.work = preferences.work
            resolved.other = preferences.other
            resolved.dailyTarget = preferences.target ?? 0
            return resolved
        }
        #endif
        return self
    }

    @Parameter(title: "Personal", default: true) var personal: Bool
    @Parameter(title: "Work", default: true) var work: Bool
    @Parameter(title: "Other", default: true) var other: Bool
    @Parameter(title: "Daily target (USD, 0 = off)", default: 0) var dailyTarget: Double

    var groups: Set<String> {
        Set([(personal, "personal"), (work, "work"), (other, "other")].filter { $0.0 }.map { $0.1 })
    }
    var label: String {
        if groups.count == 3 { return "All plans" }
        if groups.isEmpty { return "No plans selected" }
        return ["personal", "work", "other"].filter { groups.contains($0) }.map { $0.capitalized }.joined(separator: " + ")
    }
    var target: Double? { dailyTarget.isFinite && dailyTarget > 0 ? dailyTarget : nil }
}

struct PlanMeterEntry: TimelineEntry {
    var date: Date
    var payload: WatchPayload?
    var configuration = PlanMeterConfiguration()

    var today: Double? { payload?.todayCost(groups: configuration.groups) }
    var todayText: String { today.map(WatchPayload.compactUsd) ?? "—" }
    var accounts: [WatchPayload.Account] { (payload?.accounts ?? []).filter { configuration.groups.contains($0.group) } }
}

struct PlanMeterProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlanMeterEntry {
        PlanMeterEntry(date: Date(), payload: nil)
    }

    func snapshot(for configuration: PlanMeterConfiguration, in context: Context) async -> PlanMeterEntry {
        let payload: WatchPayload? = context.isPreview ? .preview : WatchPayload.load()
        return PlanMeterEntry(date: Date(), payload: payload, configuration: configuration.resolved(for: payload))
    }

    func timeline(for configuration: PlanMeterConfiguration, in context: Context) async -> Timeline<PlanMeterEntry> {
        let now = Date()
        var payload = WatchPayload.load()
        #if os(watchOS)
        do {
            let choices = try await WatchCloudSync.fetch()
            let latest = WatchPayload.load() ?? payload
            payload = try WatchCloudSync.select(choices, cached: latest, selectedMacID: WatchCloudSync.selectedMacID)
            if var current = payload {
                current.complicationPreferences = current.complicationPreferences ?? ComplicationPreferences.load(from: WatchPayload.sharedDefaults())
                WatchCloudSync.selectedMacID = current.cloudMacID
                current.save()
                payload = current
            } else { WatchPayload.clear() }
        } catch WatchCloudError.signedOut {
            payload = nil
            WatchPayload.clear()
        } catch {
            // Offline or waiting for Mac selection: retain the last known summary.
        }
        #endif
        let refresh = payload?.nextWidgetRefresh(after: now) ?? now.addingTimeInterval(15 * 60)
        let entries = [now, refresh].map { PlanMeterEntry(date: $0, payload: payload, configuration: configuration.resolved(for: payload)) }
        return Timeline(entries: entries, policy: .after(refresh))
    }

    func recommendations() -> [AppIntentRecommendation<PlanMeterConfiguration>] {
        [AppIntentRecommendation(intent: PlanMeterConfiguration(), description: "All plans")]
    }
}
