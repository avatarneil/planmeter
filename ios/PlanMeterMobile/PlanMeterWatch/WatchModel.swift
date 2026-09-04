import Foundation
import Observation
import PlanMeterWatchShared
import WatchConnectivity
import WidgetKit

/// Receives the relayed summary from the iPhone and asks it to refresh.
@Observable
@MainActor
final class WatchModel: NSObject, WCSessionDelegate {
    var payload: WatchPayload? = WatchPayload.load()
    var isRefreshing = false
    var status: String?
    private var activated = false

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Asks the phone to fetch from the Mac now. Falls back to whatever the
    /// phone last pushed when it is not reachable.
    func refresh() {
        let session = WCSession.default
        guard session.activationState == .activated else { status = "Connecting…"; return }
        guard session.isReachable else {
            status = "iPhone not reachable. Showing last sync."
            return
        }
        isRefreshing = true
        status = nil
        session.sendMessage(["refresh": true], replyHandler: { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshing = false
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

    private func apply(_ p: WatchPayload) {
        payload = p
        p.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: WCSessionDelegate (watchOS has only these)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            if let data = context[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) {
                self.apply(p)
            }
            if self.payload == nil { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchPayload.contextKey] as? Data, let p = WatchPayload.decode(data) else { return }
        Task { @MainActor in self.apply(p) }
    }
}
