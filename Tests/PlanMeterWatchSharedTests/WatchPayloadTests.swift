import Foundation
import XCTest
import PlanMeterWatchShared

final class WatchPayloadTests: XCTestCase {
    func testLargeTokenCountsSurvivePhoneToWatchTransport() throws {
        let payload = WatchPayload(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), days: 30, serverName: "Mac",
            personalCostUsd: 1, workCostUsd: 2, otherCostUsd: 0,
            personalTokens: 3_480_000_000, workTokens: 6_960_000_000, todayCostUsd: 1,
            accounts: [.init(name: "Work", group: "work", provider: "codex", costUsd: 2, tokens: 6_960_000_000)],
            limits: []
        )
        let data = try XCTUnwrap(payload.encoded())
        XCTAssertEqual(WatchPayload.decode(data), payload)
        XCTAssertEqual(MemoryLayout.size(ofValue: payload.workTokens), 8)
        XCTAssertEqual(MemoryLayout.size(ofValue: payload.accounts[0].tokens), 8)
        XCTAssertEqual(WatchPayload.tokens(payload.workTokens), "7.0B")
    }
}
