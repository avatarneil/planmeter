import CloudKit
import XCTest
@testable import PlanMeterRemote

final class CloudSubscriptionTests: XCTestCase {
    func testChangesWakeAppSilentlyIncludingDeletedMacs() throws {
        let subscription = CloudSnapshotStore.changeSubscription()
        XCTAssertEqual(subscription.recordType, CloudSnapshotStore.recordType)
        XCTAssertEqual(subscription.subscriptionID, CloudSnapshotStore.subscriptionIdentifier)
        XCTAssertTrue(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
        XCTAssertTrue(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
        XCTAssertTrue(subscription.querySubscriptionOptions.contains(.firesOnRecordDeletion))
        XCTAssertNil(subscription.zoneID) // Existing snapshots live in the default zone.
        let info = try XCTUnwrap(subscription.notificationInfo)
        XCTAssertTrue(info.shouldSendContentAvailable)
        XCTAssertNil(info.alertBody)
        XCTAssertNil(info.soundName)
        XCTAssertFalse(info.shouldBadge)
    }
}
