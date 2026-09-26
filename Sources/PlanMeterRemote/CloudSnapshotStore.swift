import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// One asset per Mac in the signed-in user's private database. Separate records
/// prevent two Macs from overwriting each other. No public database or sharing.
public struct CloudSnapshotStore {
    public static let containerIdentifier = "iCloud.com.neilgoldader.planmeter"
    public static let recordType = "UsageSnapshot"

    public static let subscriptionIdentifier = "usage-snapshots-v1"

    public init() {}

    /// Query subscriptions also work in the default record zone used by existing installs.
    public func subscribeToChanges() async throws {
        let database = try await database()
        do {
            _ = try await database.subscription(for: Self.subscriptionIdentifier)
            return
        } catch let error as CKError where error.code == .unknownItem {}
        _ = try await database.save(Self.changeSubscription())
    }

    static func changeSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: Self.recordType, predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionIdentifier,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    private func database() async throws -> CKDatabase {
        #if os(macOS)
        // CKContainer can terminate an unentitled SwiftPM/ad-hoc process.
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(Self.containerIdentifier) else { throw CloudSyncError.unavailable }
        #elseif os(iOS) || os(watchOS)
        // Xcode expands this build setting in the host's Info.plist. Unsigned
        // simulator builds have no CloudKit entitlement and CKContainer traps.
        guard Bundle.main.object(forInfoDictionaryKey: "PlanMeterCodeSigningAllowed") as? String == "YES" else {
            throw CloudSyncError.unavailable
        }
        #endif
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CloudSyncError.signedOut }
        return container.privateCloudDatabase
    }

    public func save(_ snapshot: CloudSnapshot) async throws {
        let database = try await database()
        let id = CKRecord.ID(recordName: snapshot.id)
        let record: CKRecord
        do { record = try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // Each operation owns its encoder; RemoteJSON's shared encoder is not used concurrently.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        record["payload"] = CKAsset(fileURL: url)
        _ = try await database.save(record)
    }

    public func fetch() async throws -> [CloudSnapshot] {
        let database = try await database()
        var page = try await database.records(matching: CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true)))
        var snapshots: [CloudSnapshot] = []
        while true {
            for (_, result) in page.matchResults {
                let record = try result.get()
                guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw CloudSyncError.incompleteSnapshot }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(CloudSnapshot.self, from: Data(contentsOf: url))
                // Refuse unrecognized schemas instead of displaying misleading totals.
                for days in CloudSnapshot.supportedDays { _ = try snapshot.report(days: days) }
                snapshots.append(snapshot)
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor)
        }
        return snapshots.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    public func delete(id: String) async throws {
        let database = try await database()
        do { _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id)) }
        catch let error as CKError where error.code == .unknownItem { return }
    }
}
