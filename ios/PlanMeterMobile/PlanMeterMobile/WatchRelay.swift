import Foundation
import PlanMeterWatchShared
import WatchConnectivity

/// Pushes the latest summary to the paired watch and answers its refresh
/// requests. The phone stays the trust anchor: it holds the pairing keys and
/// talks to the Mac; the watch only receives this derived payload.
final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()

    /// Set by the model: refreshes from the Mac and returns the new payload.
    var onRefreshRequest: (() async -> WatchPayload?)?
    private var pending: WatchPayload?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(_ payload: WatchPayload) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { pending = payload; return }
        guard session.isPaired, session.isWatchAppInstalled, let data = payload.encoded() else { return }
        // Application context is "latest state wins": delivered when the watch
        // app next runs, replacing anything undelivered. Exactly right here.
        try? session.updateApplicationContext([WatchPayload.contextKey: data])
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated, let pending { push(pending); self.pending = nil }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches; activate again for the new one.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        if let pending, session.isWatchAppInstalled { push(pending); self.pending = nil }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["refresh"] != nil else { replyHandler([:]); return }
        Task {
            let payload = await onRefreshRequest?()
            if let data = payload?.encoded() {
                replyHandler([WatchPayload.contextKey: data])
            } else {
                replyHandler(["error": "not paired with a Mac"])
            }
        }
    }
}
