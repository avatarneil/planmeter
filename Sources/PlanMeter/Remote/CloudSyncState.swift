import CloudKit
import Foundation
import Observation
import PlanMeterHost
import PlanMeterRemote

@Observable
@MainActor
final class CloudSyncState {
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: "cloudSync.enabled")
    private(set) var isBusy = false
    private(set) var lastUploaded: Date?
    private(set) var status = "Enable iCloud to read this Mac’s usage on your iPhone without Tailscale."
    private let store = CloudSnapshotStore()
    private let account = CloudAccountGuard()
    /// When the signed-in account last matched; rechecked periodically in case
    /// a change notification is missed.
    private var accountVerifiedAt: Date?
    private var accountGeneration = 0
    private var retryAfter = Date.distantPast
    /// Usage totals at the last upload; unchanged totals upload at most every five minutes.
    private var lastFingerprint: Data?
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
                guard let self, self.isEnabled else { return }
                // Re-check the account before the next upload instead of pausing:
                // this notification also fires when nothing about the account changed.
                self.accountGeneration += 1
                self.accountVerifiedAt = nil
                _ = await self.verifyAccount()
            }
        }
    }

    deinit { if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) } }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "cloudSync.enabled")
        if enabled {
            // Turning sync on is consent to upload to whichever account is signed in now.
            account.reset()
            accountGeneration += 1
            accountVerifiedAt = nil
            retryAfter = .distantPast
        } else {
            status = "Uploads paused. The last snapshot stays in iCloud until you delete it."
        }
    }

    /// Pauses uploads only when a different Apple Account is signed in.
    private func verifyAccount() async -> Bool {
        let generation = accountGeneration
        do {
            let identifier = try await store.accountIdentifier()
            // A newer notification arrived meanwhile; its own check decides.
            guard isEnabled, generation == accountGeneration else { return false }
            if account.verify(identifier) == .changed {
                setEnabled(false)
                lastUploaded = nil
                status = "A different iCloud account is signed in. Turn sync on again to upload to this account."
                return false
            }
            accountVerifiedAt = Date()
            return true
        } catch {
            guard generation == accountGeneration else { return false }
            // Signed out or offline: nothing can reach another account, so keep
            // sync on and retry once iCloud is available again.
            retryAfter = Date().addingTimeInterval(60)
            fail(error)
            return false
        }
    }

    func publish(model: AppModel) async {
        guard isEnabled, !isBusy, Date() >= retryAfter, let scannedAt = model.lastScan else { return }
        isBusy = true
        defer { isBusy = false }
        if accountVerifiedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            guard await verifyAccount() else { return }
        }
        let now = Date()
        var reports = CloudSnapshot.supportedDays.map { days in
            RemoteReply(
                summary: RemoteReportBuilder.summary(model: model, days: days, now: now),
                models: RemoteReportBuilder.models(model: model, days: days, filter: nil, now: now),
                timeline: RemoteReportBuilder.timeline(model: model, days: days, resolution: days == 1 ? .hour : .day, now: now),
                limits: RemoteReportBuilder.limits(model: model)
            )
        }
        // After the day reports, so older clients still find those first.
        reports.append(RemoteReply(
            summary: RemoteReportBuilder.summary(model: model, days: 1, minutes: 60, now: now),
            models: RemoteReportBuilder.models(model: model, days: 1, minutes: 60, filter: nil, now: now),
            timeline: RemoteReportBuilder.timeline(model: model, days: 1, minutes: 60, resolution: .minute, now: now),
            limits: RemoteReportBuilder.limits(model: model)
        ))
        let fingerprint = Self.fingerprint(reports)
        if fingerprint == lastFingerprint, let lastUploaded, now.timeIntervalSince(lastUploaded) < 300 { return }
        let timelines = [
            RemoteReportBuilder.timeline(model: model, days: 1, resolution: .fiveMinutes, now: now),
            RemoteReportBuilder.timeline(model: model, days: 7, resolution: .hour, now: now),
        ]
        let snapshot = CloudSnapshot(id: publisherID, name: model.remote.serverName, generatedAt: scannedAt, reports: reports, timelines: timelines)
        do {
            try await store.save(snapshot)
            guard isEnabled else { return }
            let uploadedAt = Date()
            retryAfter = .distantPast
            lastFingerprint = fingerprint
            lastUploaded = uploadedAt
            status = "Uploaded \(uploadedAt.formatted(date: .abbreviated, time: .shortened))"
        } catch {
            // Respect CloudKit's backoff, and avoid retrying every scan while offline.
            let delay = (error as? CKError)?.retryAfterSeconds ?? 60
            retryAfter = Date().addingTimeInterval(max(30, delay))
            fail(error)
        }
    }

    /// Totals and limits only: rolling windows and timestamps change every scan
    /// even when no usage did.
    private static func fingerprint(_ reports: [RemoteReply]) -> Data? {
        struct Parts: Encodable { var groups: [RemoteGroupUsage]?; var today: Double?; var limits: RemoteLimits? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(reports.map { Parts(groups: $0.summary?.groups, today: $0.summary?.todayCostUsd, limits: $0.limits) })
    }

    private func fail(_ error: Error) {
        status = "Upload failed; will retry automatically. \(error.localizedDescription)"
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
