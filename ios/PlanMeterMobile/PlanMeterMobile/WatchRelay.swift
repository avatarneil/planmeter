import Foundation
import PlanMeterWatchShared
import WatchConnectivity

/// Pushes the latest summary to the paired watch and answers its refresh
/// requests. The phone stays the trust anchor: it holds the pairing keys and
/// talks to the Mac; the watch only receives this derived payload.
@MainActor
final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()

    /// Set by the model: refreshes from the Mac and returns the new payload.
    var onRefreshRequest: (() async -> WatchPayload?)?
    private var pending: WatchPayload?
    private var pendingClear = false

    func clear() {
        pending = nil
        pendingClear = true
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([WatchPayload.clearContextKey: true])
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func push(_ payload: WatchPayload) {
        pendingClear = false
        pending = payload
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled, let data = payload.encoded() else { return }
        // Application context is "latest state wins": delivered when the watch
        // app next runs, replacing anything undelivered. Exactly right here.
        do {
            try session.updateApplicationContext([WatchPayload.contextKey: data])
            pending = nil
        } catch { /* Retry when the session becomes available again. */ }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if activationState == .activated {
                if pendingClear { clear() }
                else if let pending { push(pending) }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches; activate again for the new one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            if pendingClear { clear() }
            else if let pending, session.isWatchAppInstalled { push(pending) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["refresh"] != nil else { replyHandler([:]); return }
        Task { @MainActor in
            let payload = await onRefreshRequest?()
            if let data = payload?.encoded() {
                replyHandler([WatchPayload.contextKey: data])
            } else {
                replyHandler([WatchPayload.clearContextKey: true, "error": "Open PlanMeter on your iPhone to connect and sync."])
            }
        }
    }
}
