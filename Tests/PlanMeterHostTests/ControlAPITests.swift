import XCTest
import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeterHost

@MainActor
final class ControlAPITests: XCTestCase {
    func testStatus() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let response = await h.call("GET", "/v1/status")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try response.decoded(DaemonStatus.self), DaemonStatus(version: "0.3.6", serverName: "devbox", isScanning: false, lastScanAt: ControlHarness.now,
                                                                         lastError: nil, pricingSource: "LiteLLM", pricingError: nil, accountCount: 2))
        // Unset optionals are explicit nulls, so clients can rely on every key.
        let object = try XCTUnwrap(response.object)
        XCTAssertEqual(Set(object.keys), ["apiVersion", "version", "serverName", "isScanning", "lastScanAt", "lastError", "pricingSource", "pricingError", "accountCount"])
        XCTAssertTrue(object["lastError"] is NSNull)
        XCTAssertEqual(object["lastScanAt"] as? String, "2026-10-19T12:30:00Z")
    }

    func testRefresh() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let bare = await h.call("POST", "/v1/refresh")
        XCTAssertEqual(bare.status, 200)
        let forced = await h.call("POST", "/v1/refresh", json: "{\"forceAccountUsage\": true}")
        XCTAssertEqual(try forced.decoded(DaemonStatus.self).isScanning, false)
        let bad = await h.call("POST", "/v1/refresh", json: "{\"forceAccountUsage\": \"yes\"}")
        XCTAssertEqual(bad.status, 400)
    }

    func testRPCReturnsTheSameReplyPhonesGet() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        for method in RemoteMethod.allCases {
            let request = RemoteRequest(method: method, days: 1, resolution: "hour")
            let response = await h.call("POST", "/v1/rpc", json: String(decoding: try RemoteJSON.encoder.encode(request), as: UTF8.self))
            XCTAssertEqual(response.status, 200, "\(method)")
            let expected = RemoteReportBuilder.reply(for: request, model: h.engine, now: ControlHarness.now)
            XCTAssertEqual(response.body, try RemoteJSON.encoder.encode(expected), "\(method)")
        }
        let summary = try await h.call("POST", "/v1/rpc", json: "{\"method\":\"summary\",\"days\":1}").decoded(RemoteReply.self).summary
        XCTAssertEqual(summary?.total.costUsd, 1.75)
        // The Claude account was moved to Work, so both land in one group.
        XCTAssertEqual(summary?.groups.map(\.group), ["work"])
        let bad = await h.call("POST", "/v1/rpc", json: "{\"method\":\"everything\"}")
        XCTAssertEqual(bad.status, 400)
    }

    func testSettingsGroups() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let initial = try await h.call("GET", "/v1/settings").decoded(HostSettings.self)
        XCTAssertEqual(initial.groupOverrides, [ControlHarness.personalId: .work])

        // Percent-encoded and raw account ids (Claude ids contain "/") both work.
        let encoded = ControlHarness.workId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let moved = try await h.call("PUT", "/v1/settings/groups/\(encoded)", json: "{\"group\":\"personal\"}").decoded(HostSettings.self)
        XCTAssertEqual(moved.groupOverrides[ControlHarness.workId], .personal)
        XCTAssertEqual(h.engine.group(for: h.engine.account(for: ControlHarness.workId)), .personal)

        // Choosing the suggested group, or null, clears the override.
        let restored = try await h.call("PUT", "/v1/settings/groups/\(ControlHarness.workId)", json: "{\"group\":\"work\"}").decoded(HostSettings.self)
        XCTAssertNil(restored.groupOverrides[ControlHarness.workId])
        let cleared = try await h.call("PUT", "/v1/settings/groups/\(ControlHarness.personalId)", json: "{\"group\":null}").decoded(HostSettings.self)
        XCTAssertEqual(cleared.groupOverrides, [:])

        let unknown = await h.call("PUT", "/v1/settings/groups/x", json: "{\"group\":\"family\"}")
        XCTAssertEqual(unknown.status, 400)
        let empty = await h.call("PUT", "/v1/settings/groups/", json: "{\"group\":null}")
        XCTAssertEqual(empty.status, 400)
        let wrongMethod = await h.call("GET", "/v1/settings/groups/x")
        XCTAssertEqual(wrongMethod.status, 405)

        // Persisted.
        let reloaded = HostSettingsStore(url: h.settings.url)
        XCTAssertEqual(reloaded.settings.groupOverrides, [:])
    }

    func testSettingsSpend() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let updated = try await h.call("PUT", "/v1/settings/spend", json: "{\"groups\":[\"work\"],\"thresholds\":{\"week\":{\"limit\":100,\"warningPercent\":75}}}").decoded(HostSettings.self)
        XCTAssertEqual(updated.spendGroups, [.work])
        XCTAssertEqual(updated.spendThresholds, ["week": SpendThreshold(limit: 100, warningPercent: 75)])
        // Absent fields are left alone.
        let partial = try await h.call("PUT", "/v1/settings/spend", json: "{\"groups\":[\"other\",\"personal\",\"other\"]}").decoded(HostSettings.self)
        XCTAssertEqual(partial.spendGroups, [.personal, .other])
        XCTAssertEqual(partial.spendThresholds.keys.sorted(), ["week"])

        for body in ["{\"groups\":[]}", "{\"groups\":[\"family\"]}", "{\"thresholds\":{\"fortnight\":{\"limit\":5,\"warningPercent\":80}}}",
                     "{\"thresholds\":{\"today\":{\"limit\":0,\"warningPercent\":80}}}", "{\"thresholds\":{\"today\":{\"limit\":5,\"warningPercent\":100}}}", "not json"] {
            let response = await h.call("PUT", "/v1/settings/spend", json: body)
            XCTAssertEqual(response.status, 400, body)
            XCTAssertNotNil(response.errorMessage, body)
        }
        XCTAssertEqual(HostSettingsStore(url: h.settings.url).settings.spendGroups, [.personal, .other])
    }

    func testRemoteStatusInvitesAndDevices() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let status = try await h.call("GET", "/v1/remote").decoded(RemoteStatus.self)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.status, "listening")
        XCTAssertEqual(status.bindAddresses, ["100.64.0.7"])
        XCTAssertEqual(status.tailscale, .init(available: true, address: "100.64.0.7", dnsName: "devbox.tail1234.ts.net"))
        XCTAssertNil(status.invite)
        XCTAssertEqual(status.devices.map(\.name), ["Pixel 9"])

        let invited = try await h.call("POST", "/v1/remote/invite").decoded(RemoteStatus.self)
        let invite = try XCTUnwrap(invited.invite)
        let parsed = try XCTUnwrap(PairingInvite(url: try XCTUnwrap(URL(string: invite.url))))
        XCTAssertEqual(parsed.serverHost, "devbox.tail1234.ts.net")
        XCTAssertEqual(parsed.port, 7787)
        XCTAssertEqual(parsed.serverPublicKey, TestKeys.server.publicKeyRaw)
        XCTAssertEqual(invite.webCode, "12345678")
        XCTAssertEqual(invite.expiresAt, ControlHarness.now.addingTimeInterval(300))
        XCTAssertNil(invite.localUrl, "no loopback listener")
        XCTAssertNil(invite.webUrl, "no HTTPS and no loopback")

        let cancelled = try await h.call("DELETE", "/v1/remote/invite").decoded(RemoteStatus.self)
        XCTAssertNil(cancelled.invite)

        let id = try XCTUnwrap(status.devices.first?.id)
        let revoked = try await h.call("DELETE", "/v1/remote/devices/\(id)").decoded(RemoteStatus.self)
        XCTAssertTrue(revoked.devices.isEmpty)
        let again = await h.call("DELETE", "/v1/remote/devices/\(id)")
        XCTAssertEqual(again.status, 404)
    }

    func testRemoteSettings() async throws {
        let h = try await ControlHarness.make(remoteEnabled: false)
        defer { h.cleanUp() }
        let off = try await h.call("GET", "/v1/remote").decoded(RemoteStatus.self)
        XCTAssertEqual(off.status, "off")
        let noInvite = await h.call("POST", "/v1/remote/invite")
        XCTAssertEqual(noInvite.status, 409)

        let on = try await h.call("PUT", "/v1/remote", json: "{\"enabled\":true,\"port\":8800}").decoded(RemoteStatus.self)
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.port, 8800)
        XCTAssertEqual(on.status, "listening")
        XCTAssertEqual(h.settings.remote, RemoteSettings(enabled: true, port: 8800, httpsEnabled: false))

        // HTTPS needs the loopback listener that Tailscale Serve proxies to.
        let https = try await h.call("PUT", "/v1/remote", json: "{\"httpsEnabled\":true}").decoded(RemoteStatus.self)
        XCTAssertTrue(https.https.enabled)
        XCTAssertEqual(https.bindAddresses, ["100.64.0.7", "127.0.0.1"])
        XCTAssertFalse(https.https.active)
        XCTAssertEqual(https.https.certificateStatus, "serve is disabled in tests")
        let invited = try await h.call("POST", "/v1/remote/invite").decoded(RemoteStatus.self)
        XCTAssertNotNil(invited.invite?.localUrl)
        XCTAssertTrue(invited.invite?.webUrl?.hasPrefix("http://127.0.0.1:8800/#") ?? false)

        for body in ["{\"port\":80}", "{\"port\":70000}", "[]"] {
            let response = await h.call("PUT", "/v1/remote", json: body)
            XCTAssertEqual(response.status, 400, body)
        }
        let disabled = try await h.call("PUT", "/v1/remote", json: "{\"enabled\":false}").decoded(RemoteStatus.self)
        XCTAssertEqual(disabled.status, "off")
        XCTAssertTrue(disabled.bindAddresses.isEmpty)
    }

    func testNoRemoteFlagWins() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        h.remote.forceEnabled = false
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .off)
        let still = try await h.call("PUT", "/v1/remote", json: "{\"enabled\":true}").decoded(RemoteStatus.self)
        XCTAssertFalse(still.enabled)
        XCTAssertEqual(still.message, "Disabled for this run (--no-remote).")
    }

    func testTailnetLossAndRecovery() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        h.remote.environment = .fake(addresses: [], dnsName: nil)
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .unavailable)
        XCTAssertEqual(h.remote.status().message, "Tailscale is not connected. Remote access only listens on the tailnet.")
        h.remote.environment = .fake(addresses: ["100.64.0.8", "fd7a:115c:a1e0::8"])
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .listening)
        XCTAssertEqual(h.remote.boundAddresses, ["100.64.0.8", "fd7a:115c:a1e0::8"])
    }

    /// Desktop clients percent-encode ids down to unreserved characters;
    /// Claude account ids contain both "/" and ":".
    func testPercentEncodedIdsWithSlashesAndColons() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let id = ControlHarness.personalId
        let encoded = try XCTUnwrap(id.addingPercentEncoding(withAllowedCharacters: unreserved))
        XCTAssertEqual(encoded, "claude%3Ahome%3A%2Fhome%2Fdev%2F.claude%2Fprojects")
        let moved = try await h.call("PUT", "/v1/settings/groups/\(encoded)", json: #"{"group":"other"}"#).decoded(HostSettings.self)
        XCTAssertEqual(moved.groupOverrides[id], .other)
        XCTAssertEqual(h.engine.group(for: h.engine.account(for: id)), .other)

        let device = try XCTUnwrap(h.service.devices.first)
        let unknown = await h.call("DELETE", "/v1/remote/devices/\(device.id)%2Fx%3Ay")
        XCTAssertEqual(unknown.status, 404)
        let encodedDevice = try XCTUnwrap(device.id.addingPercentEncoding(withAllowedCharacters: unreserved))
        let revoked = try await h.call("DELETE", "/v1/remote/devices/\(encodedDevice)").decoded(RemoteStatus.self)
        XCTAssertTrue(revoked.devices.isEmpty)
    }

    /// The GTK client asks for "Today" as `minutes` since local midnight
    /// (rounded up to five minutes), "1 hour" as 60, and "24h" as `days: 1`.
    func testMinuteWindowsMatchTheMacBuilder() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        for request in [RemoteRequest(method: .summary, minutes: 755), RemoteRequest(method: .models, minutes: 755),
                        RemoteRequest(method: .timeline, resolution: "5m", minutes: 755), RemoteRequest(method: .summary, minutes: 60),
                        RemoteRequest(method: .summary, days: 1)] {
            let response = await h.call("POST", "/v1/rpc", json: String(decoding: try RemoteJSON.encoder.encode(request), as: UTF8.self))
            let expected = RemoteReportBuilder.reply(for: request, model: h.engine, now: ControlHarness.now)
            XCTAssertEqual(response.body, try RemoteJSON.encoder.encode(expected))
        }
        let todayReply = try await h.call("POST", "/v1/rpc", json: #"{"method":"summary","minutes":755}"#).decoded(RemoteReply.self)
        let today = try XCTUnwrap(todayReply.summary)
        XCTAssertEqual(today.minutes, 755)
        XCTAssertEqual(today.to.timeIntervalSince(today.from), 755 * 60)
        XCTAssertEqual(today.total.costUsd, 1.75)
    }

    func testFailedAddressIsRetriedWithoutRestartingTheOthers() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        final class Attempts { var byAddress: [String: Int] = [:]; var listeners: [String: FakeListener] = [:] }
        let attempts = Attempts()
        var ipv6Binds = false
        h.remote.environment = .fake(addresses: ["100.64.0.7", "fd7a:115c:a1e0::7"])
        h.remote.stop()
        h.remote.listenerFactory = { _, addresses, _ in
            for address in addresses { attempts.byAddress[address, default: 0] += 1 }
            let listener = FakeListener(addresses: addresses.filter { ipv6Binds || !$0.contains(":") })
            for address in listener.boundAddresses { attempts.listeners[address] = listener }
            return listener
        }
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .listening)
        XCTAssertEqual(h.remote.boundAddresses, ["100.64.0.7"])
        XCTAssertEqual(h.remote.message, "Some addresses could not be bound: could not bind fd7a:115c:a1e0::7")
        try h.remote.newInvite()

        // Each tick retries the address that failed and leaves the rest alone.
        await h.remote.apply()
        await h.remote.apply()
        XCTAssertEqual(attempts.byAddress["fd7a:115c:a1e0::7"], 3)
        XCTAssertEqual(attempts.byAddress["100.64.0.7"], 1)
        XCTAssertEqual(attempts.listeners["100.64.0.7"]?.stopped, false)
        XCTAssertNotNil(h.service.activeInvite)

        // Once it binds, it joins the others; the invite survives.
        ipv6Binds = true
        await h.remote.apply()
        XCTAssertEqual(h.remote.boundAddresses, ["100.64.0.7", "fd7a:115c:a1e0::7"])
        XCTAssertNil(h.remote.message)
        XCTAssertEqual(attempts.listeners["100.64.0.7"]?.stopped, false)
        XCTAssertNotNil(h.service.activeInvite)

        // An address that goes away is stopped on its own, and the invite,
        // which may name it, is cancelled.
        h.remote.environment = .fake(addresses: ["100.64.0.7"])
        await h.remote.apply()
        XCTAssertEqual(h.remote.boundAddresses, ["100.64.0.7"])
        XCTAssertEqual(attempts.listeners["fd7a:115c:a1e0::7"]?.stopped, true)
        XCTAssertEqual(attempts.listeners["100.64.0.7"]?.stopped, false)
        XCTAssertNil(h.service.activeInvite)
    }

    func testNothingBoundIsAnErrorThatKeepsRetrying() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        h.remote.stop()
        var calls = 0
        h.remote.listenerFactory = { _, _, _ in
            calls += 1
            throw RemoteController.ControllerError.bindFailed("bind 100.64.0.7:7787 failed: Address already in use")
        }
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .error)
        XCTAssertEqual(h.remote.message, "Could not start: bind 100.64.0.7:7787 failed: Address already in use")
        XCTAssertTrue(h.remote.boundAddresses.isEmpty)
        await h.remote.apply()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(h.service.events.filter { $0.contains("Could not start") }.count, 1, "an unchanged failure is logged once")
    }

    /// Waits off the main actor; synchronous so the wait is allowed.
    nonisolated private static func block(on semaphore: DispatchSemaphore) { semaphore.wait() }

    /// Shutdown cancels the 30-second tick and stops the controller while the
    /// tick may be waiting on `tailscale status`; it must not bind afterwards.
    func testStopWinsOverAnApplyWaitingOnTailscale() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        h.remote.stop()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var gated = RemoteController.Environment.fake(addresses: ["100.64.0.10"])
        gated.tailnet = {
            entered.signal()
            release.wait()
            return .init(addresses: ["100.64.0.10"], dnsName: nil)
        }
        h.remote.environment = gated
        var binds = 0
        h.remote.listenerFactory = { _, addresses, _ in
            binds += 1
            return FakeListener(addresses: addresses)
        }
        let pending = Task { await h.remote.apply() }
        await Task.detached { Self.block(on: entered) }.value
        h.remote.stop()
        release.signal()
        await pending.value
        XCTAssertEqual(h.remote.state, .off)
        XCTAssertTrue(h.remote.boundAddresses.isEmpty)
        XCTAssertEqual(binds, 0)

        h.remote.environment = .fake(addresses: ["100.64.0.10"])
        await h.remote.apply()
        XCTAssertEqual(h.remote.state, .listening)
        XCTAssertEqual(binds, 1)
    }

    func testUnknownRoutesAndMethods() async throws {
        let h = try await ControlHarness.make()
        defer { h.cleanUp() }
        let missing = await h.call("GET", "/v2/status")
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.errorMessage, "not found")
        for (method, path) in [("POST", "/v1/status"), ("GET", "/v1/refresh"), ("GET", "/v1/rpc"), ("POST", "/v1/settings"), ("GET", "/v1/settings/spend"),
                               ("POST", "/v1/remote"), ("GET", "/v1/remote/invite"), ("GET", "/v1/remote/devices/x")] {
            let response = await h.call(method, path)
            XCTAssertEqual(response.status, 405, "\(method) \(path)")
        }
    }
}
