import XCTest
import PlanMeterCore
import PlanMeterRemote
@testable import PlanMeterHost
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class RemoteServiceTests: XCTestCase {
    private func makeService(store: SecretStore = MemorySecretStore(), key: ServerAgreementKey = SoftwareAgreementKey()) -> RemoteService {
        let service = RemoteService(serverName: "devbox", serverKey: key, store: store, version: "9.9.9")
        service.dataProvider = { request in
            RemoteReply(accounts: RemoteAccounts(accounts: [RemoteAccount(id: "a", name: "A", provider: "codex", providerName: "Codex", group: "work")],
                                                 sources: [], scannedAt: nil), error: request.method == .accounts ? nil : "only accounts here")
        }
        return service
    }

    private func sealedBody<T: Encodable>(_ value: T, service: RemoteService, deviceId: String, signer: DeviceSigningKey, path: String, now: Date = Date()) throws -> Data {
        let plaintext = try RemoteJSON.encoder.encode(value)
        let sealed = try SecureChannel.seal(plaintext: plaintext, serverPublicKeyRaw: service.serverKey.publicKeyRaw, deviceId: deviceId, signer: signer, method: "POST", path: path, now: now)
        return try RemoteJSON.encoder.encode(sealed.request)
    }

    private func post(_ service: RemoteService, _ path: String, _ body: Data, from host: String = "100.64.0.5", headers: [String: String] = [:]) async -> HTTPResponse {
        await service.handle(HTTPRequest(method: "POST", path: path, headers: headers, body: body, remoteHost: host))
    }

    // MARK: End to end

    /// A real phone client against the portable listener on loopback:
    /// info, pairing, every RPC, single-use invites, and revocation.
    func testPairAndCallOverLoopbackWithRemoteClient() async throws {
        let harness = try await ControlHarness.make()
        defer { harness.cleanUp() }
        let service = harness.service
        let endpoint = POSIXHTTPServer.Endpoint.tcp(host: "127.0.0.1", port: 0)
        let server = POSIXHTTPServer(endpoints: [endpoint]) { request in await service.handle(request) }
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort(for: endpoint))
        // The harness pins the clock for fixtures; this test needs real time.
        service.clock = { Date() }
        harness.engine.clock = { ControlHarness.now }

        let info = try await RemoteClient.info(host: "127.0.0.1", port: Int(port))
        XCTAssertEqual(info.serverName, "devbox")
        XCTAssertEqual(info.version, "0.3.6")
        XCTAssertEqual(info.protocolVersion, SecureChannel.protocolVersion)

        let invite = service.newInvite(host: "127.0.0.1", port: port)
        XCTAssertEqual(invite.serverPublicKey, TestKeys.server.publicKeyRaw)
        let signer = SoftwareSigningKey()
        let paired = try await RemoteClient.pair(invite: invite, deviceName: "  Test Phone  ", platform: "android", signer: signer)
        XCTAssertEqual(paired.deviceId, DeviceId.derive(fromPublicKey: signer.publicKeyRaw))
        XCTAssertEqual(paired.serverName, "devbox")
        XCTAssertNil(service.invite, "invites are single use")
        XCTAssertNil(service.webPairingCode)
        let device = try XCTUnwrap(service.devices.first { $0.id == paired.deviceId })
        XCTAssertEqual(device.name, "Test Phone")
        XCTAssertEqual(device.platform, "android")

        let client = RemoteClient(server: paired, signer: signer)
        let summary = try await client.call(RemoteRequest(method: .summary, days: 1))
        XCTAssertEqual(summary.summary?.total.costUsd, 1.75)
        XCTAssertEqual(summary.summary?.serverName, "devbox")
        XCTAssertEqual(summary.summary?.todayCostUsd, 1.75)
        for method in RemoteMethod.allCases {
            let reply = try await client.call(RemoteRequest(method: method, days: 7, resolution: "hour"))
            XCTAssertNil(reply.error, "\(method)")
        }
        let limits = try await client.call(RemoteRequest(method: .limits))
        XCTAssertEqual(limits.limits?.accounts.first?.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(service.devices.first { $0.id == paired.deviceId }?.requestCount, 2 + RemoteMethod.allCases.count)

        // The used invite cannot pair another device.
        do {
            _ = try await RemoteClient.pair(invite: invite, deviceName: "Second", platform: "web", signer: SoftwareSigningKey())
            XCTFail("a consumed invite paired a device")
        } catch RemoteClientError.http(let status, _) {
            XCTAssertEqual(status, 403)
        }

        // Paired devices survive a restart.
        let reloaded = RemoteService(serverName: "devbox", serverKey: TestKeys.server,
                                     store: PrivateFileStore(directory: harness.directory.appendingPathComponent("state/remote")), version: "0.3.6")
        XCTAssertTrue(reloaded.devices.contains { $0.id == paired.deviceId })

        XCTAssertNotNil(service.revoke(id: paired.deviceId))
        do {
            _ = try await client.call(RemoteRequest(method: .summary))
            XCTFail("a revoked device was served")
        } catch RemoteClientError.http(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    // MARK: Security properties

    func testOnlyTailnetAndLoopbackPeers() async {
        let service = makeService()
        let outside = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, remoteHost: "203.0.113.5"))
        XCTAssertEqual(outside.status, 403)
        XCTAssertEqual(outside.errorMessage, "tailnet peers only")
        for host in ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1", "127.0.0.1", "::1"] {
            let ok = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, remoteHost: host))
            XCTAssertEqual(ok.status, 200, host)
        }
        for host in ["100.63.255.255", "100.128.0.1", "10.0.0.1", "fd7a:115c:a1e1::1"] {
            let refused = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, remoteHost: host))
            XCTAssertEqual(refused.status, 403, host)
        }
        // X-Forwarded-For counts only from loopback (Tailscale Serve), where
        // it names the real peer.
        let forwardedOutside = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, headers: ["x-forwarded-for": "203.0.113.5"], remoteHost: "127.0.0.1"))
        XCTAssertEqual(forwardedOutside.status, 403)
        let forwardedTailnet = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, headers: ["x-forwarded-for": "100.64.0.9, 127.0.0.1"], remoteHost: "127.0.0.1"))
        XCTAssertEqual(forwardedTailnet.status, 200)
        let spoofed = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, headers: ["x-forwarded-for": "127.0.0.1"], remoteHost: "203.0.113.5"))
        XCTAssertEqual(spoofed.status, 403, "a remote peer cannot claim to be loopback")
    }

    func testRoutingAndMethods() async {
        let service = makeService()
        let wrongMethod = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.rpcPath, remoteHost: "100.64.0.5"))
        XCTAssertEqual(wrongMethod.status, 405)
        let missing = await service.handle(HTTPRequest(method: "GET", path: "/etc/passwd", remoteHost: "100.64.0.5"))
        XCTAssertEqual(missing.status, 404)
        let info = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, remoteHost: "100.64.0.5"))
        XCTAssertEqual(try? RemoteJSON.decoder.decode(ServerInfo.self, from: info.body), ServerInfo(version: "9.9.9", serverName: "devbox"))
    }

    func testWebAssetsServedWithSecurityHeaders() async throws {
        let service = makeService()
        let none = await service.handle(HTTPRequest(method: "GET", path: "/", remoteHost: "100.64.0.5"))
        XCTAssertEqual(none.status, 404)
        XCTAssertEqual(none.errorMessage, "web client not bundled")
        let web = try XCTUnwrap(WebAssetCatalog.sourceTreeDirectory)
        service.webDirectory = { web }
        let index = await service.handle(HTTPRequest(method: "GET", path: "/", remoteHost: "100.64.0.5"))
        XCTAssertEqual(index.status, 200)
        XCTAssertEqual(index.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(index.headers["X-Frame-Options"], "DENY")
        XCTAssertNotNil(index.headers["Content-Security-Policy"])
        let script = await service.handle(HTTPRequest(method: "GET", path: "/app.js", remoteHost: "100.64.0.5"))
        XCTAssertEqual(script.contentType, "application/javascript; charset=utf-8")
        let traversal = await service.handle(HTTPRequest(method: "GET", path: "/../Package.swift", remoteHost: "100.64.0.5"))
        XCTAssertEqual(traversal.status, 404)
    }

    func testFiveFailedPairingAttemptsCancelTheInvite() async throws {
        let service = makeService()
        let invite = service.newInvite(host: "100.64.0.7", port: 7787)
        XCTAssertNotNil(service.webPairingCode)
        for attempt in 1...RemoteService.maxPairFailures {
            let signer = SoftwareSigningKey()
            let body = try sealedBody(PairRequest(token: "wrong-\(attempt)", deviceName: "Mallory", devicePublicKey: signer.publicKeyRaw, platform: "web"),
                                      service: service, deviceId: "pairing", signer: signer, path: RemoteClient.pairPath)
            let response = await post(service, RemoteClient.pairPath, body)
            XCTAssertEqual(response.status, 403)
            XCTAssertEqual(response.errorMessage, "pairing rejected")
            XCTAssertEqual(service.invite == nil, attempt == RemoteService.maxPairFailures, "attempt \(attempt)")
        }
        XCTAssertNil(service.webPairingCode)
        // The right token no longer works either.
        let signer = SoftwareSigningKey()
        let late = try sealedBody(PairRequest(token: invite.token, deviceName: "Late", devicePublicKey: signer.publicKeyRaw, platform: "web"),
                                  service: service, deviceId: "pairing", signer: signer, path: RemoteClient.pairPath)
        let response = await post(service, RemoteClient.pairPath, late)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.errorMessage, "no active pairing code")
        XCTAssertTrue(service.devices.isEmpty)
    }

    func testInvitesExpireAfterFiveMinutes() async throws {
        let service = makeService()
        let start = Date()
        service.clock = { start }
        let invite = service.newInvite(host: "100.64.0.7", port: 7787)
        XCTAssertEqual(invite.expiresAt.timeIntervalSince(start), 300)
        service.clock = { start.addingTimeInterval(301) }
        XCTAssertNil(service.activeInvite)
        let signer = SoftwareSigningKey()
        let body = try sealedBody(PairRequest(token: invite.token, deviceName: "Late", devicePublicKey: signer.publicKeyRaw, platform: "ios"),
                                  service: service, deviceId: "pairing", signer: signer, path: RemoteClient.pairPath, now: start.addingTimeInterval(301))
        let response = await post(service, RemoteClient.pairPath, body)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.errorMessage, "no active pairing code")
        let web = await post(service, RemoteService.webPairingPath, Data("{\"code\":\"\(service.webPairingCode ?? "")\"}".utf8))
        XCTAssertEqual(web.status, 403)
    }

    func testWebPairingCodeExchangesForTheInviteSecret() async throws {
        let service = makeService()
        service.makeWebCode = { "24681357" }
        let invite = service.newInvite(host: "100.64.0.7", port: 7787)
        let wrong = await post(service, RemoteService.webPairingPath, Data("{\"code\":\"1111 1111\"}".utf8))
        XCTAssertEqual(wrong.status, 403)
        XCTAssertEqual(service.pairFailures, 1)
        let right = await post(service, RemoteService.webPairingPath, Data("{\"code\":\"2468-1357\"}".utf8))
        XCTAssertEqual(right.status, 200)
        let offer = try XCTUnwrap(right.object)
        XCTAssertEqual(offer["token"] as? String, invite.token)
        XCTAssertEqual(offer["serverName"] as? String, "devbox")
        XCTAssertEqual(offer["serverPublicKey"] as? String, invite.serverPublicKey.base64EncodedString())
        XCTAssertEqual((offer["expiresAt"] as? NSNumber)?.int64Value, Int64(invite.expiresAt.timeIntervalSince1970))
        XCTAssertNotNil(service.invite, "claiming the code does not consume the invite")
    }

    func testReplayedAndStaleRequestsAreRefused() async throws {
        let service = makeService()
        let invite = service.newInvite(host: "127.0.0.1", port: 7787)
        let signer = SoftwareSigningKey()
        let pairBody = try sealedBody(PairRequest(token: invite.token, deviceName: "Phone", devicePublicKey: signer.publicKeyRaw, platform: "android"),
                                      service: service, deviceId: "pairing", signer: signer, path: RemoteClient.pairPath)
        let paired = await post(service, RemoteClient.pairPath, pairBody)
        XCTAssertEqual(paired.status, 200)
        let deviceId = DeviceId.derive(fromPublicKey: signer.publicKeyRaw)

        let rpc = try sealedBody(RemoteRequest(method: .accounts), service: service, deviceId: deviceId, signer: signer, path: RemoteClient.rpcPath)
        let first = await post(service, RemoteClient.rpcPath, rpc)
        XCTAssertEqual(first.status, 200)
        let replayed = await post(service, RemoteClient.rpcPath, rpc)
        XCTAssertEqual(replayed.status, 409)
        XCTAssertEqual(replayed.errorMessage, "replay")

        let stale = try sealedBody(RemoteRequest(method: .accounts), service: service, deviceId: deviceId, signer: signer, path: RemoteClient.rpcPath,
                                   now: Date().addingTimeInterval(-SecureChannel.maxClockSkew - 10))
        let staleResponse = await post(service, RemoteClient.rpcPath, stale)
        XCTAssertEqual(staleResponse.status, 400)

        let forged = try sealedBody(RemoteRequest(method: .accounts), service: service, deviceId: deviceId, signer: SoftwareSigningKey(), path: RemoteClient.rpcPath)
        let forgedResponse = await post(service, RemoteClient.rpcPath, forged)
        XCTAssertEqual(forgedResponse.status, 401)
        XCTAssertEqual(forgedResponse.errorMessage, "signature failed")

        let unknown = try sealedBody(RemoteRequest(method: .accounts), service: service, deviceId: "nobody", signer: signer, path: RemoteClient.rpcPath)
        let unknownResponse = await post(service, RemoteClient.rpcPath, unknown)
        XCTAssertEqual(unknownResponse.status, 401)

        // The signature binds the path: an RPC body replayed at /v1/pair fails.
        let crossPath = await post(service, RemoteClient.pairPath, try sealedBody(RemoteRequest(method: .accounts), service: service, deviceId: deviceId, signer: signer, path: RemoteClient.rpcPath))
        XCTAssertEqual(crossPath.status, 400)
    }

    func testEventsAreBoundedAndNewestFirst() async {
        let service = makeService()
        for i in 0..<60 { service.log("line \(i)") }
        XCTAssertEqual(service.events.count, 50)
        XCTAssertTrue(service.events[0].hasSuffix("line 59"))
    }

    func testSoftwareServerKeyPersistsInAPrivateFile() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PrivateFileStore(directory: dir.appendingPathComponent("remote"))
        let first = RemoteService.loadSoftwareServerKey(store: store)
        let second = RemoteService.loadSoftwareServerKey(store: store)
        XCTAssertEqual(first.publicKeyRaw, second.publicKeyRaw)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("remote/server-key.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("remote").path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try store.write("../escape", Data()))
    }
}
