import XCTest
import PlanMeterRemote
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pairs with a running `planmeterd` and calls every RPC, as a phone would.
/// Skipped unless PLANMETER_LIVE_PAIRING_LINK holds a link from
/// `planmeterd --remote --loopback --pairing-link` (use the
/// `pairing-link-local` line to reach it over loopback).
final class LiveDaemonTests: XCTestCase {
    func testPairAndCallRunningDaemon() async throws {
        guard let link = ProcessInfo.processInfo.environment["PLANMETER_LIVE_PAIRING_LINK"], !link.isEmpty else {
            throw XCTSkip("set PLANMETER_LIVE_PAIRING_LINK to run against a live daemon")
        }
        let invite = try XCTUnwrap(URL(string: link).flatMap(PairingInvite.init(url:)), "not a pairing link")
        let info = try await RemoteClient.info(host: invite.serverHost, port: invite.port)
        XCTAssertEqual(info.app, "planmeter")
        let signer = SoftwareSigningKey()
        let server = try await RemoteClient.pair(invite: invite, deviceName: "LiveDaemonTests", platform: "test", signer: signer)
        let client = RemoteClient(server: server, signer: signer)
        for method in RemoteMethod.allCases {
            let reply = try await client.call(RemoteRequest(method: method, days: 1, resolution: "hour"))
            XCTAssertNil(reply.error, "\(method)")
        }
        let summary = try await client.call(RemoteRequest(method: .summary, days: 7))
        let accounts = try await client.call(RemoteRequest(method: .accounts))
        print("live: \(info.serverName) \(info.version); 7-day total $\(summary.summary?.total.costUsd ?? 0) across \(accounts.accounts?.accounts.count ?? 0) accounts; device \(server.deviceId)")
    }
}
