import XCTest
import PlanMeterRemote
@testable import PlanMeterHost

/// Writes or checks `protocol/fixtures/control/*.json`: one request/response
/// example per control API endpoint, produced by the real router over the
/// deterministic `ControlHarness`. Desktop clients (the Rust GTK app, later
/// Windows) test their decoding against these files.
///
/// Set PLANMETER_REGENERATE_FIXTURES=1 to rewrite them after an intended
/// change; otherwise any difference fails.
///
/// Tests in `@MainActor` classes are all `async`: Linux XCTest's generated
/// manifest cannot mix main-actor synchronous and asynchronous tests.
@MainActor
final class ControlFixtureTests: XCTestCase {
    static let directory = ProtocolFixtures.root.appendingPathComponent("control", isDirectory: true)

    struct Example {
        var name: String
        var method: String
        var path: String
        var body: String?
    }

    /// In order: later examples see the state earlier ones left.
    static let examples: [Example] = [
        Example(name: "get-status", method: "GET", path: "/v1/status"),
        Example(name: "post-refresh", method: "POST", path: "/v1/refresh", body: #"{"forceAccountUsage":false}"#),
        Example(name: "post-rpc", method: "POST", path: "/v1/rpc", body: #"{"days":1,"method":"summary"}"#),
        Example(name: "get-settings", method: "GET", path: "/v1/settings"),
        Example(name: "put-settings-groups", method: "PUT", path: "/v1/settings/groups/codex%3Aplan%3Abusiness", body: #"{"group":"personal"}"#),
        Example(name: "put-settings-spend", method: "PUT", path: "/v1/settings/spend",
                body: #"{"groups":["personal","work"],"thresholds":{"today":{"limit":25,"warningPercent":80},"week":{"limit":120,"warningPercent":90}}}"#),
        Example(name: "get-remote", method: "GET", path: "/v1/remote"),
        Example(name: "put-remote", method: "PUT", path: "/v1/remote", body: #"{"enabled":true,"httpsEnabled":false,"port":7787}"#),
        Example(name: "post-remote-invite", method: "POST", path: "/v1/remote/invite"),
        Example(name: "delete-remote-invite", method: "DELETE", path: "/v1/remote/invite"),
        Example(name: "delete-remote-device", method: "DELETE", path: "/v1/remote/devices/{deviceId}"),
        Example(name: "error-not-found", method: "GET", path: "/v1/unknown"),
        Example(name: "error-bad-request", method: "PUT", path: "/v1/settings/spend", body: #"{"groups":[]}"#),
    ]

    func testControlFixtures() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let deviceId = try XCTUnwrap(h.service.devices.first?.id)
        var mismatches: [String] = []
        for example in Self.examples {
            let path = example.path.replacingOccurrences(of: "{deviceId}", with: deviceId)
            let response = await h.call(example.method, path, json: example.body)
            let document: [String: Any] = [
                "request": ["method": example.method, "path": path, "body": ProtocolFixtures.body(Data((example.body ?? "").utf8))] as [String: Any],
                "response": ["status": response.status, "body": ProtocolFixtures.body(response.body)] as [String: Any],
            ]
            if let mismatch = try ProtocolFixtures.check("control/\(example.name).json", document) { mismatches.append(mismatch) }
        }
        XCTAssertTrue(mismatches.isEmpty, "Control fixtures are out of date. \(ProtocolFixtures.hint)\n" + mismatches.joined(separator: "\n"))
    }

    /// The directory holds exactly one file per example, so a renamed or
    /// removed endpoint cannot leave a stale fixture behind.
    func testFixtureManifest() async throws {
        guard !ProtocolFixtures.regenerating else { return }
        XCTAssertEqual(try ProtocolFixtures.files(in: "control"), Set(Self.examples.map { "\($0.name).json" }))
    }

    /// Every fixture decodes into the public wire types.
    func testFixturesDecodeIntoWireTypes() async throws {
        func body(_ name: String) throws -> Data {
            let data = try XCTUnwrap(FileManager.default.contents(atPath: Self.directory.appendingPathComponent("\(name).json").path), name)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let response = try XCTUnwrap(document["response"] as? [String: Any])
            return try JSONSerialization.data(withJSONObject: XCTUnwrap(response["body"]))
        }
        for name in ["get-status", "post-refresh"] { _ = try RemoteJSON.decoder.decode(DaemonStatus.self, from: body(name)) }
        _ = try RemoteJSON.decoder.decode(RemoteReply.self, from: body("post-rpc"))
        for name in ["get-settings", "put-settings-groups", "put-settings-spend"] { _ = try RemoteJSON.decoder.decode(HostSettings.self, from: body(name)) }
        for name in ["get-remote", "put-remote", "post-remote-invite", "delete-remote-invite", "delete-remote-device"] {
            _ = try RemoteJSON.decoder.decode(RemoteStatus.self, from: body(name))
        }
        let invite = try RemoteJSON.decoder.decode(RemoteStatus.self, from: body("post-remote-invite")).invite
        XCTAssertNotNil(invite)
        for name in ["error-not-found", "error-bad-request"] { _ = try RemoteJSON.decoder.decode(ControlError.self, from: body(name)) }
    }
}
