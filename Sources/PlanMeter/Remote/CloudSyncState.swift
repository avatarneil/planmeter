import CloudKit
import Foundation
import Observation
import PlanMeterRemote

@Observable
@MainActor
final class CloudSyncState {
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: "cloudSync.enabled")
    private(set) var isBusy = false
    private(set) var lastUploaded: Date?
    private(set) var status = "Enable iCloud to read this Mac’s usage on your iPhone without Tailscale."
    private let store = CloudSnapshotStore()
    private var retryAfter = Date.distantPast
    private let publisherID: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "cloudSync.publisherID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "cloudSync.publisherID")
        return id
    }()
    @ObservationIgnored nonisolated(unsafe) private var accountObserver: NSObjectProtocol?

    init() {
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setEnabled(false)
                self?.lastUploaded = nil
                self?.status = "Your iCloud account changed. Enable sync again to upload to the current account."
            }
        }
    }

    deinit { if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) } }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "cloudSync.enabled")
        if !enabled { status = "Uploads paused. The last snapshot stays in iCloud until you delete it." }
    }

    func publish(model: AppModel) async {
        guard isEnabled, !isBusy, Date() >= retryAfter, let scannedAt = model.lastScan else { return }
        isBusy = true
        defer { isBusy = false }
        let now = Date()
        let reports = CloudSnapshot.supportedDays.map { days in
            RemoteReply(
                summary: RemoteReportBuilder.summary(model: model, days: days, now: now),
                models: RemoteReportBuilder.models(model: model, days: days, filter: nil, now: now),
                timeline: RemoteReportBuilder.timeline(model: model, days: days, resolution: days == 1 ? .hour : .day, now: now),
                limits: RemoteReportBuilder.limits(model: model)
            )
        }
        let snapshot = CloudSnapshot(id: publisherID, name: model.remote.serverName, generatedAt: scannedAt, reports: reports)
        do {
            try await store.save(snapshot)
            guard isEnabled else { return }
            let uploadedAt = Date()
            retryAfter = .distantPast
            lastUploaded = uploadedAt
            status = "Uploaded \(uploadedAt.formatted(date: .abbreviated, time: .shortened))"
        } catch {
            // Respect CloudKit's backoff, and avoid retrying every scan while offline.
            let delay = (error as? CKError)?.retryAfterSeconds ?? 60
            retryAfter = Date().addingTimeInterval(max(30, delay))
            status = "Upload failed; will retry automatically. \(error.localizedDescription)"
        }
    }

    func deleteSnapshot() async {
        guard !isBusy else { return }
        setEnabled(false)
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.delete(id: publisherID)
            lastUploaded = nil
            status = "This Mac’s snapshot was deleted from iCloud."
        } catch { status = "Could not delete the snapshot: \(error.localizedDescription)" }
    }
}
