import XCTest
import PlanMeterRemote
@testable import PlanMeterHost
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Writes or checks the host-behaviour fixtures that live beside the protocol
/// vectors: `protocol/fixtures/web-pairing/` (the browser pairing link and
/// the code-for-invite exchange) and `protocol/fixtures/http/` (every status
/// the remote API returns, and the HTTP framing limits). Everything runs
/// through the real `RemoteService`, request parser, and response serializer.
///
/// Inputs match ProtocolFixtureTests: keys derived from the same labels, the
/// same host name and version, and the clock at 1792500000
/// (2026-10-20T12:40:00Z). Sealed bodies contain randomized signatures, so
/// fixtures describe them instead of embedding them.
@MainActor
final class RemoteFixtureTests: XCTestCase {
    enum Keys {
        static func bytes(_ label: String) -> Data { Data(SHA256.hash(data: Data("planmeter-fixture|\(label)".utf8))) }
        static let server = try! SoftwareAgreementKey(rawRepresentation: bytes("server-static-key"))
        static let otherServer = try! SoftwareAgreementKey(rawRepresentation: bytes("other-server-static-key"))
        static let device = try! SoftwareSigningKey(rawRepresentation: bytes("device-signing-key"))
        static let otherDevice = try! SoftwareSigningKey(rawRepresentation: bytes("other-device-signing-key"))
        static var deviceId: String { DeviceId.derive(fromPublicKey: device.publicKeyRaw) }
        static let pairingToken = bytes("pairing-token").base64URLEncodedString()
        static let timestamp: Int64 = 1_792_500_000
        static var now: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    }

    static let serverName = "Ada’s MacBook Pro"
    static let webCode = "12345678"

    private var mismatches: [String] = []

    override func setUp() async throws {
        mismatches = []
    }

    private func check(_ path: String, _ document: Any) throws {
        if let mismatch = try ProtocolFixtures.check(path, document) { mismatches.append(mismatch) }
    }

    private func assertNoMismatches() {
        XCTAssertTrue(mismatches.isEmpty, "Host fixtures are out of date. \(ProtocolFixtures.hint)\n" + mismatches.joined(separator: "\n"))
    }

    private func makeService(store: SecretStore = MemorySecretStore()) -> RemoteService {
        let service = RemoteService(serverName: Self.serverName, serverKey: Keys.server, store: store, version: "0.3.6")
        service.clock = { Keys.now }
        service.makeToken = { Keys.pairingToken }
        service.makeWebCode = { Self.webCode }
        service.dataProvider = { _ in RemoteReply(accounts: RemoteAccounts(accounts: [], sources: [], scannedAt: nil)) }
        return service
    }

    private func response(_ response: HTTPResponse, sealed: Bool = false) -> [String: Any] {
        ["status": response.status, "body": sealed ? "a SealedResponse (see secure-channel/*-response.json)" : ProtocolFixtures.body(response.body)]
    }

    // MARK: Web pairing

    func testWebPairingFixtures() async throws {
        let service = makeService()
        let invite = service.newInvite(host: "ada-mbp.tail1234.ts.net", port: 7787)
        var links: [[String: Any]] = []
        for origin in ["https://ada-mbp.tail1234.ts.net/", "http://127.0.0.1:7787/"] {
            links.append(["origin": origin, "url": try XCTUnwrap(service.webPairingURL(for: invite, origin: origin)).absoluteString])
        }
        try check("web-pairing/link.json", [
            "description": "The browser pairing link: the invite's server key (base64url), token, expiry (Unix seconds), and server name in the URL fragment, on the HTTPS origin when Tailscale Serve is on, else loopback. Same invite as `inviteUrl`.",
            "inviteUrl": invite.url.absoluteString,
            "links": links,
        ] as [String: Any])

        // One service, one ordered sequence: the failure budget carries over.
        var cases: [[String: Any]] = []
        func claim(_ name: String, _ body: String, note: String) async {
            let request = HTTPRequest(method: "POST", path: RemoteService.webPairingPath, body: Data(body.utf8), remoteHost: "100.64.0.9")
            let result = await service.handle(request)
            cases.append([
                "name": name,
                "note": note,
                "request": ["method": "POST", "path": RemoteService.webPairingPath, "body": ProtocolFixtures.body(Data(body.utf8))] as [String: Any],
                "response": response(result),
                "after": ["inviteActive": service.activeInvite != nil, "pairFailures": service.pairFailures] as [String: Any],
            ])
        }
        service.cancelInvite()
        await claim("no-invite", #"{"code":"12345678"}"#, note: "No unexpired invite.")
        service.newInvite(host: "ada-mbp.tail1234.ts.net", port: 7787)
        await claim("exact-code", #"{"code":"12345678"}"#, note: "The offer: standard base64 key, the invite token, integer Unix expiry. Claiming does not consume the invite.")
        await claim("spaced-code", #"{"code":"1234 5678"}"#, note: "Non-digits are stripped.")
        await claim("dashed-code", #"{"code":"1234-5678"}"#, note: "Non-digits are stripped.")
        await claim("wrong-code", #"{"code":"87654321"}"#, note: "Counts toward the invite's failure budget of 5.")
        await claim("seven-digits", #"{"code":"1234567"}"#, note: "Exactly 8 digits are required.")
        await claim("invalid-json", "not json", note: "Counts as a failure.")
        await claim("missing-code", "{}", note: "Counts as a failure.")
        await claim("fifth-failure", #"{"code":"00000000"}"#, note: "The fifth failure cancels the invite and its code.")
        await claim("after-cancel", #"{"code":"12345678"}"#, note: "The right code no longer works.")
        service.newInvite(host: "ada-mbp.tail1234.ts.net", port: 7787)
        service.clock = { Keys.now.addingTimeInterval(RemoteService.inviteLifetime + 1) }
        await claim("expired", #"{"code":"12345678"}"#, note: "Invites expire 300 seconds after they are issued.")
        try check("web-pairing/exchange.json", [
            "description": "POST /v1/web-pairing-invite, in order against one host with the clock at 1792500000; the web code is 12345678 and the invite expires at 1792500300. `after` is the host state following each request.",
            "serverPublicKey": Keys.server.publicKeyRaw.base64EncodedString(),
            "token": Keys.pairingToken,
            "cases": cases,
        ] as [String: Any])
        assertNoMismatches()
    }

    // MARK: Status codes

    func testStatusCodeFixtures() async throws {
        let service = makeService()
        var cases: [[String: Any]] = []
        func record(_ name: String, method: String, path: String, peer: String = "100.64.0.9", headers: [String: String] = [:],
                    body: Data = Data(), describe: String? = nil, sealed: Bool = false, note: String? = nil) async {
            let result = await service.handle(HTTPRequest(method: method, path: path, headers: headers, body: body, remoteHost: peer))
            var request: [String: Any] = ["method": method, "path": path, "peer": peer]
            if !headers.isEmpty { request["headers"] = headers }
            request["body"] = describe ?? ProtocolFixtures.body(body)
            var entry: [String: Any] = ["name": name, "request": request, "response": response(result, sealed: sealed && result.status == 200)]
            if let note { entry["note"] = note }
            cases.append(entry)
        }
        func sealed<T: Encodable>(_ value: T, deviceId: String, signer: DeviceSigningKey, path: String, serverKey: Data = Keys.server.publicKeyRaw,
                                  now: Date = Keys.now) throws -> Data {
            let request = try SecureChannel.seal(plaintext: RemoteJSON.encoder.encode(value), serverPublicKeyRaw: serverKey, deviceId: deviceId,
                                                 signer: signer, method: "POST", path: path, now: now)
            return try RemoteJSON.encoder.encode(request.request)
        }
        let rpc = RemoteRequest(method: .accounts)
        let pair = PairRequest(token: Keys.pairingToken, deviceName: "Ada’s iPhone", devicePublicKey: Keys.device.publicKeyRaw, platform: "ios")

        await record("info", method: "GET", path: RemoteClient.infoPath)
        await record("non-tailnet-peer", method: "GET", path: RemoteClient.infoPath, peer: "203.0.113.5")
        await record("forwarded-tailnet-peer", method: "GET", path: RemoteClient.infoPath, peer: "127.0.0.1", headers: ["X-Forwarded-For": "100.64.0.9"],
                     note: "From loopback, the first X-Forwarded-For entry (Tailscale Serve) is the peer.")
        await record("forwarded-outside-peer", method: "GET", path: RemoteClient.infoPath, peer: "127.0.0.1", headers: ["X-Forwarded-For": "203.0.113.5, 127.0.0.1"])
        await record("forwarded-header-from-remote-peer", method: "GET", path: RemoteClient.infoPath, peer: "203.0.113.5", headers: ["X-Forwarded-For": "127.0.0.1"],
                     note: "X-Forwarded-For is ignored unless the connection comes from loopback.")
        for (method, path) in [("POST", RemoteClient.infoPath), ("GET", RemoteClient.pairPath), ("GET", RemoteClient.rpcPath), ("GET", RemoteService.webPairingPath)] {
            await record("wrong-method-\(path.split(separator: "/").last!)", method: method, path: path)
        }
        await record("unknown-path", method: "GET", path: "/v1/nope")
        await record("static-file-not-bundled", method: "GET", path: "/app.js", note: "A host built without the web client.")

        // Pairing.
        await record("pair-undecodable", method: "POST", path: RemoteClient.pairPath, body: Data("{}".utf8))
        await record("pair-not-pairing-device", method: "POST", path: RemoteClient.pairPath,
                     body: try sealed(pair, deviceId: Keys.deviceId, signer: Keys.device, path: RemoteClient.pairPath),
                     describe: "a SealedRequest for /v1/pair whose deviceId is not \"pairing\"")
        await record("pair-no-invite", method: "POST", path: RemoteClient.pairPath,
                     body: try sealed(pair, deviceId: "pairing", signer: Keys.device, path: RemoteClient.pairPath),
                     describe: "a valid pairing SealedRequest while no invite is active")
        service.newInvite(host: "ada-mbp.tail1234.ts.net", port: 7787)
        let wrongToken = PairRequest(token: "wrong-token", deviceName: "Mallory", devicePublicKey: Keys.otherDevice.publicKeyRaw, platform: "web")
        await record("pair-wrong-token", method: "POST", path: RemoteClient.pairPath,
                     body: try sealed(wrongToken, deviceId: "pairing", signer: Keys.otherDevice, path: RemoteClient.pairPath),
                     describe: "a pairing SealedRequest carrying the wrong token", note: "Counts toward the failure budget of 5.")
        await record("pair-wrong-signer", method: "POST", path: RemoteClient.pairPath,
                     body: try sealed(pair, deviceId: "pairing", signer: Keys.otherDevice, path: RemoteClient.pairPath),
                     describe: "a pairing SealedRequest signed by a key other than devicePublicKey")
        let pairBody = try sealed(pair, deviceId: "pairing", signer: Keys.device, path: RemoteClient.pairPath)
        await record("pair", method: "POST", path: RemoteClient.pairPath, body: pairBody,
                     describe: "a valid pairing SealedRequest (see secure-channel/chacha20poly1305-pair-request.json)", sealed: true,
                     note: "Registers the device and consumes the invite.")
        await record("pair-replayed", method: "POST", path: RemoteClient.pairPath, body: pairBody, describe: "the same pairing SealedRequest again",
                     note: "The invite is gone, which is checked before the replay cache.")

        // RPC.
        await record("rpc-undecodable", method: "POST", path: RemoteClient.rpcPath, body: Data("not json".utf8))
        await record("rpc-stale", method: "POST", path: RemoteClient.rpcPath,
                     body: try sealed(rpc, deviceId: Keys.deviceId, signer: Keys.device, path: RemoteClient.rpcPath,
                                      now: Keys.now.addingTimeInterval(-SecureChannel.maxClockSkew - 1)),
                     describe: "an RPC SealedRequest timestamped 121 seconds before the host clock")
        await record("rpc-unknown-device", method: "POST", path: RemoteClient.rpcPath,
                     body: try sealed(rpc, deviceId: DeviceId.derive(fromPublicKey: Keys.otherDevice.publicKeyRaw), signer: Keys.otherDevice, path: RemoteClient.rpcPath),
                     describe: "an RPC SealedRequest from a device that is not paired")
        await record("rpc-bad-signature", method: "POST", path: RemoteClient.rpcPath,
                     body: try sealed(rpc, deviceId: Keys.deviceId, signer: Keys.otherDevice, path: RemoteClient.rpcPath),
                     describe: "an RPC SealedRequest for the paired device, signed by another key")
        await record("rpc-undecryptable", method: "POST", path: RemoteClient.rpcPath,
                     body: try sealed(rpc, deviceId: Keys.deviceId, signer: Keys.device, path: RemoteClient.rpcPath, serverKey: Keys.otherServer.publicKeyRaw),
                     describe: "an RPC SealedRequest correctly signed but encrypted to a different host key")
        let rpcBody = try sealed(rpc, deviceId: Keys.deviceId, signer: Keys.device, path: RemoteClient.rpcPath)
        await record("rpc", method: "POST", path: RemoteClient.rpcPath, body: rpcBody,
                     describe: "a valid RPC SealedRequest from the paired device", sealed: true)
        await record("rpc-replayed", method: "POST", path: RemoteClient.rpcPath, body: rpcBody, describe: "the same RPC SealedRequest again")

        try check("http/status-codes.json", [
            "description": "Remote API responses for each condition in protocol/README.md (Errors and status codes), in order against one host with the clock at 1792500000. `peer` is the connection's address. Sealed bodies are described, not embedded, because signatures are randomized.",
            "cases": cases,
        ] as [String: Any])
        assertNoMismatches()
    }

    // MARK: Framing

    func testFramingFixtures() async throws {
        var cases: [[String: Any]] = []
        func record(_ name: String, raw: Data, display: String, closed: Bool) {
            var entry: [String: Any] = ["name": name, "request": display, "connectionClosedAfterSending": closed]
            switch HTTPRequestParser.parse(raw, isComplete: closed, remoteHost: "100.64.0.9") {
            case .request(let request):
                entry["parsed"] = ["method": request.method, "path": request.path, "bodyLength": request.body.count] as [String: Any]
            case .failure(let status, let message):
                let response = HTTPResponse.error(status, message)
                entry["response"] = ["status": status, "head": head(response), "body": ProtocolFixtures.body(response.body)] as [String: Any]
            case .close:
                entry["result"] = "the host closes the connection without a reply"
            case .incomplete:
                entry["result"] = "the host waits for more bytes, up to 20 seconds from accepting the connection"
            }
            cases.append(entry)
        }
        let big = String(repeating: "a", count: HTTPLimits.maxHeaderBytes)
        record("query-string-ignored", raw: Data("GET /v1/info?x=1 HTTP/1.1\r\nHost: h\r\n\r\n".utf8),
               display: "GET /v1/info?x=1 HTTP/1.1\\r\\nHost: h\\r\\n\\r\\n", closed: false)
        record("body-by-content-length", raw: Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8),
               display: "POST /v1/rpc HTTP/1.1\\r\\nContent-Length: 2\\r\\n\\r\\n{}", closed: false)
        record("head-too-large", raw: Data("GET / HTTP/1.1\r\nX-Big: \(big)\r\n\r\n".utf8),
               display: "GET / HTTP/1.1\\r\\nX-Big: <16384 × a>\\r\\n\\r\\n", closed: false)
        record("body-too-large", raw: Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: \(HTTPLimits.maxBodyBytes + 1)\r\n\r\n".utf8),
               display: "POST /v1/rpc HTTP/1.1\\r\\nContent-Length: 1048577\\r\\n\\r\\n", closed: false)
        record("truncated-body", raw: Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8),
               display: "POST /v1/rpc HTTP/1.1\\r\\nContent-Length: 10\\r\\n\\r\\n{}", closed: true)
        record("negative-content-length", raw: Data("POST /v1/rpc HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8),
               display: "POST /v1/rpc HTTP/1.1\\r\\nContent-Length: -1\\r\\n\\r\\n", closed: false)
        record("malformed-request-line", raw: Data("HELLO\r\n\r\n".utf8), display: "HELLO\\r\\n\\r\\n", closed: false)
        record("closed-before-head", raw: Data("GET / HTTP/1.1\r\n".utf8), display: "GET / HTTP/1.1\\r\\n", closed: true)
        record("incomplete-head", raw: Data("GET / HTTP/1.1\r\n".utf8), display: "GET / HTTP/1.1\\r\\n", closed: false)

        // Response heads, byte for byte.
        let web = try makeTemporaryDirectory("pmweb")
        defer { try? FileManager.default.removeItem(at: web) }
        try Data("<!doctype html>".utf8).write(to: web.appendingPathComponent("index.html"))
        let service = makeService()
        service.webDirectory = { web }
        let page = await service.handle(HTTPRequest(method: "GET", path: "/", remoteHost: "100.64.0.9"))
        let info = await service.handle(HTTPRequest(method: "GET", path: RemoteClient.infoPath, remoteHost: "100.64.0.9"))
        try check("http/framing.json", [
            "description": "How the host parses a request and frames every response: one request per connection, Content-Length bodies only, 16 KiB head, 1 MiB body. `head` is the exact response head, CRLF-terminated lines without the blank line.",
            "requests": cases,
            "responses": [
                ["name": "api-json", "request": "GET /v1/info", "status": info.status, "head": head(info)] as [String: Any],
                ["name": "static-file", "request": "GET / (a 15-byte index.html)", "status": page.status, "head": head(page)] as [String: Any],
            ],
        ] as [String: Any])
        assertNoMismatches()
    }

    private func head(_ response: HTTPResponse) -> [String] {
        let text = String(decoding: response.serialized().prefix(response.serialized().count - response.body.count), as: UTF8.self)
        return text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    func testFixtureManifest() async throws {
        guard !ProtocolFixtures.regenerating else { return }
        XCTAssertEqual(try ProtocolFixtures.files(in: "web-pairing"), ["link.json", "exchange.json"])
        XCTAssertEqual(try ProtocolFixtures.files(in: "http"), ["status-codes.json", "framing.json"])
    }
}
