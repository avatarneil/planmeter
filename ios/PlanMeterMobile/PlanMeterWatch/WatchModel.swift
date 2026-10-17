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
                if cloudChoices.isEmpty, WatchCloudSync.selectedMacID == nil, payload?.cloudMacID == nil {
                    status = "No iCloud snapshot yet."
                    refreshFromPhone()
                    return
                }
                if let p = try WatchCloudSync.select(cloudChoices, cached: payload, selectedMacID: WatchCloudSync.selectedMacID) {
                    apply(p)
                    status = nil
                    // The Mac may have stopped uploading; the phone can still
                    // reach it directly, so ask it for anything newer.
                    if Date().timeIntervalSince(p.updatedAt) >= Self.outdatedAfter {
                        status = Self.staleMessage
                        refreshFromPhone(keepCurrent: true)
                        return
                    }
                } else {
                    clear()
                    status = cloudChoices.isEmpty ? "Enable iCloud sync in PlanMeter on your Mac." : "Choose a Mac below."
                    // No Mac publishes to iCloud any more; the phone may still reach
                    // one directly. With other Macs listed, let the user choose.
                    if cloudChoices.isEmpty {
                        refreshFromPhone()
                        return
                    }
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
        status = Date().timeIntervalSince(payload?.updatedAt ?? choice.updatedAt) >= Self.outdatedAfter ? Self.staleMessage : nil
    }

    private static let outdatedAfter: TimeInterval = 15 * 60
    private static let staleMessage = "Your Mac hasn’t uploaded recently. Keep PlanMeter open on your Mac with iCloud sync on."

    /// `keepCurrent` supplements a cloud summary that is already shown: a phone
    /// that cannot reach the Mac must not clear it.
    private func refreshFromPhone(keepCurrent: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated else { isRefreshing = false; return }
        guard session.isReachable else {
            isRefreshing = false
            if !keepCurrent { status = (status ?? "iCloud unavailable.") + " Showing last sync; iPhone is also unreachable." }
            return
        }
        isRefreshing = true
        if !keepCurrent { status = nil }
        session.sendMessage(["refresh": true], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshing = false
                if let data = reply[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) {
                    // A supplement must describe the Mac already shown; the phone
                    // may be connected to a different one.
                    if keepCurrent, let current = self.payload, !current.isSameSource(as: p) { return }
                    self.apply(p)
                    if let current = self.payload, Date().timeIntervalSince(current.updatedAt) < Self.outdatedAfter { self.status = nil }
                } else if !keepCurrent {
                    if reply[WatchPayload.clearContextKey] as? Bool == true { self.clear() }
                    if let error = reply["error"] as? String { self.status = error }
                }
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isRefreshing = false
                if !keepCurrent { self?.status = error.localizedDescription }
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
        if let payload, payload.isSameSource(as: p) {
            if payload.updatedAt > p.updatedAt {
                incoming = payload
                incoming.complicationPreferences = p.complicationPreferences ?? payload.complicationPreferences
            }
            // A direct relay has no iCloud record ID; keep the selected Mac's.
            incoming.cloudMacID = p.cloudMacID ?? payload.cloudMacID
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
