import Foundation
import PlanMeterWatchCloud
import Observation
import PlanMeterWatchShared
import WatchConnectivity
import WidgetKit

/// Reads iCloud directly; the phone relay remains available as a fallback.
@Observable
@MainActor
final class WatchModel: NSObject, WCSessionDelegate {
    var payload: WatchPayload? = WatchPayload.load()
    var isRefreshing = false
    var status: String?
    var cloudChoices: [WatchPayload] = []
    private var activated = false

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = "Syncing with iCloud…"
        Task {
            do {
                cloudChoices = try await WatchCloudSync.fetch()
                if let p = try WatchCloudSync.select(cloudChoices, cached: payload, selectedMacID: WatchCloudSync.selectedMacID) {
                    apply(p)
                    status = "Synced directly with iCloud"
                } else {
                    clear()
                    status = cloudChoices.isEmpty ? "Enable iCloud sync in PlanMeter on your Mac." : "Choose a Mac below."
                }
                isRefreshing = false
            } catch WatchCloudError.signedOut {
                clear()
                isRefreshing = false
                status = WatchCloudError.signedOut.localizedDescription
            } catch WatchCloudError.chooseMac {
                isRefreshing = false
                status = WatchCloudError.chooseMac.localizedDescription
            } catch {
                status = "iCloud: \(error.localizedDescription)"
                refreshFromPhone()
            }
        }
    }

    func selectCloudMac(_ choice: WatchPayload) {
        var choice = choice
        choice.complicationPreferences = payload?.complicationPreferences
            ?? ComplicationPreferences.load(from: WatchPayload.sharedDefaults())
        apply(choice)
        status = "Synced directly with iCloud"
    }

    private func refreshFromPhone() {
        let session = WCSession.default
        guard session.activationState == .activated else { isRefreshing = false; return }
        guard session.isReachable else {
            isRefreshing = false
            status = (status ?? "iCloud unavailable.") + " Showing last sync; iPhone is also unreachable."
            return
        }
        isRefreshing = true
        status = nil
        session.sendMessage(["refresh": true], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshing = false
                if reply[WatchPayload.clearContextKey] as? Bool == true { self.clear() }
                if let data = reply[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) {
                    self.apply(p)
                } else if let error = reply["error"] as? String {
                    self.status = error
                }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isRefreshing = false
                self?.status = error.localizedDescription
            }
        })
    }

    private func clear() {
        payload = nil
        WatchPayload.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func apply(_ p: WatchPayload) {
        var incoming = p
        if let payload, payload.cloudMacID == p.cloudMacID, payload.serverName == p.serverName, payload.updatedAt > p.updatedAt {
            incoming = payload
            incoming.complicationPreferences = p.complicationPreferences ?? payload.complicationPreferences
        }
        incoming.complicationPreferences = incoming.complicationPreferences ?? ComplicationPreferences.load(from: WatchPayload.sharedDefaults())
        payload = incoming
        WatchCloudSync.selectedMacID = incoming.cloudMacID
        incoming.complicationPreferences?.save(to: WatchPayload.sharedDefaults())
        incoming.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: WCSessionDelegate (watchOS has only these)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            if context[WatchPayload.clearContextKey] as? Bool == true { self.clear() }
            if let data = context[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) {
                self.apply(p)
            }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) else { return }
        Task { @MainActor in self.apply(p) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if applicationContext[WatchPayload.clearContextKey] as? Bool == true {
            Task { @MainActor in self.clear() }
            return
        }
        guard let data = applicationContext[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) else { return }
        Task { @MainActor in self.apply(p) }
    }
}
