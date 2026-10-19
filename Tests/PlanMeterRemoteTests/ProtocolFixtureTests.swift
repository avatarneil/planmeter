#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import PlanMeterRemote

/// Golden fixtures for other implementations of the remote protocol (web,
/// Kotlin, Rust), described in protocol/README.md.
///
/// By default every test compares what the Swift code produces today with the
/// committed files under protocol/fixtures and fails on any semantic
/// difference. To change the protocol deliberately, regenerate on a Mac and
/// review the diff:
///
///     PLANMETER_REGENERATE_FIXTURES=1 swift test --filter ProtocolFixtureTests
///
/// Everything is deterministic except ECDSA signatures, which are randomized.
/// A committed signature is kept as long as it still verifies, so
/// regeneration is idempotent.
final class ProtocolFixtureTests: XCTestCase {
    // MARK: Secure channel

    func testSecureChannelVectors() throws {
        let chacha = try requestAndResponse(
            name: "chacha20poly1305", cipher: .chacha20poly1305, path: RemoteClient.rpcPath, deviceId: FixtureKeys.deviceId,
            description: "A paired device asks for today's hourly timeline over ChaCha20-Poly1305, as the iOS app does.",
            request: try RemoteJSON.encoder.encode(RemoteRequest(method: .timeline, days: 1, resolution: "hour")),
            reply: try RemoteJSON.encoder.encode(Replies.accounts))
        let aes = try requestAndResponse(
            name: "aes-256-gcm", cipher: .aes256gcm, path: RemoteClient.rpcPath, deviceId: FixtureKeys.deviceId,
            description: "A paired browser asks for the seven-day summary over AES-256-GCM, as the web client does.",
            request: try RemoteJSON.encoder.encode(RemoteRequest(method: .summary, days: 7)),
            reply: try RemoteJSON.encoder.encode(Replies.limits))
        _ = try requestAndResponse(
            name: "chacha20poly1305-pair", cipher: .chacha20poly1305, path: RemoteClient.pairPath, deviceId: "pairing",
            description: "Pairing from a native app: deviceId is the literal \"pairing\", and the signature verifies against the key inside the decrypted PairRequest.",
            request: try RemoteJSON.encoder.encode(Pairing.request(deviceName: "Ada’s Pixel 9", platform: "android")),
            reply: try RemoteJSON.encoder.encode(Pairing.response))
        _ = try requestAndResponse(
            name: "aes-256-gcm-pair", cipher: .aes256gcm, path: RemoteClient.pairPath, deviceId: "pairing",
            description: "Pairing from the web client, which can only use AES-256-GCM.",
            request: try RemoteJSON.encoder.encode(Pairing.request(deviceName: "Safari on iPhone", platform: "web")),
            reply: try RemoteJSON.encoder.encode(Pairing.response))
        try negativeVectors(chacha: chacha, aes: aes)
    }

    struct Exchange {
        var request: SecureChannel.SealedRequest
        var responseKey: SymmetricKey
        var response: SecureChannel.SealedResponse
        var path: String
    }

    /// Writes `<name>-request.json` and `<name>-response.json`.
    private func requestAndResponse(name: String, cipher: SecureChannel.Cipher, path: String, deviceId: String,
                                    description: String, request plaintext: Data, reply: Data) throws -> Exchange {
        let requestFile = "secure-channel/\(name)-request.json"
        let responseFile = "secure-channel/\(name)-response.json"
        let server = FixtureKeys.server, device = FixtureKeys.device
        let ephemeral = try FixtureKeys.ephemeral(name)
        let nonce = FixtureKeys.nonce("\(name)-request")
        let timestamp = FixtureKeys.timestamp

        let result = try SecureChannel.seal(
            plaintext: plaintext, serverPublicKeyRaw: server.publicKeyRaw, deviceId: deviceId, signer: device,
            method: "POST", path: path, cipher: cipher, timestamp: timestamp, ephemeral: ephemeral, nonce: nonce)
        var sealed = result.request
        let responseKey = result.responseKey
        let header = SecureChannel.header(deviceId: deviceId, ephemeral: sealed.ephemeralPublicKey, nonce: nonce,
                                          timestamp: timestamp, method: "POST", path: path, cipher: cipher)
        let signingInput = SecureChannel.signingInput(header: header, ciphertext: sealed.ciphertext)
        sealed.signature = Fixtures.stableSignature(committed: Fixtures.committedObject(requestFile)?["signatureHex"],
                                                    input: signingInput, publicKey: device.publicKeyRaw, fresh: sealed.signature)

        // The server side must accept what the client side produced.
        try SecureChannel.checkTimestamp(sealed, now: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        XCTAssertTrue(SecureChannel.verifySignature(sealed, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: path))
        let opened = try SecureChannel.open(sealed, serverKey: server, method: "POST", path: path)
        XCTAssertEqual(opened.plaintext, plaintext)
        XCTAssertEqual(opened.responseKey.rawBytes, responseKey.rawBytes)

        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: server.key.publicKey)
        XCTAssertEqual(try server.sharedSecret(withPublicKeyRaw: sealed.ephemeralPublicKey).rawBytes, secret.rawBytes)
        let keys = SecureChannel.derive(secret, nonce: nonce, deviceId: deviceId)
        let keyMaterial: [String: Any] = [
            "serverStaticPrivateKeyHex": server.key.rawRepresentation.hex,
            "serverStaticPublicKeyHex": server.publicKeyRaw.hex,
            "ephemeralPrivateKeyHex": ephemeral.rawRepresentation.hex,
            "ephemeralPublicKeyHex": ephemeral.publicKey.x963Representation.hex,
            "deviceSigningPrivateKeyHex": device.key.rawRepresentation.hex,
            "deviceSigningPublicKeyHex": device.publicKeyRaw.hex,
            "deviceId": deviceId,
            "requestNonceHex": nonce.hex,
            "sharedSecretHex": secret.rawBytes.hex,
            "requestKeyInfo": "\(SecureChannel.label)|\(deviceId)|request",
            "responseKeyInfo": "\(SecureChannel.label)|\(deviceId)|response",
            "requestKeyHex": keys.request.rawBytes.hex,
            "responseKeyHex": keys.response.rawBytes.hex,
        ]
        XCTAssertEqual(keys.request.rawBytes.count, 32)
        XCTAssertEqual(keys.response.rawBytes, responseKey.rawBytes)

        var requestVector = keyMaterial
        requestVector.merge([
            "name": "\(name)-request",
            "description": description,
            "cipher": cipher.rawValue,
            "method": "POST",
            "path": path,
            "timestamp": Int(timestamp),
            "header": String(decoding: header, as: UTF8.self),
            "headerBase64": header.base64EncodedString(),
            "plaintext": String(decoding: plaintext, as: UTF8.self),
            "ciphertextHex": sealed.ciphertext.hex,
            "ciphertextSha256Hex": Data(SHA256.hash(data: sealed.ciphertext)).hex,
            "signingInputHex": signingInput.hex,
            "signatureHex": sealed.signature.hex,
            "signatureNote": "ECDSA P-256 signatures are randomized: verify this one, do not expect to reproduce it.",
            "sealedRequest": try Fixtures.jsonObject(RemoteJSON.encoder.encode(sealed)),
        ]) { _, new in new }
        try Fixtures.check(requestFile, object: requestVector)

        let responseNonce = FixtureKeys.nonce("\(name)-response")
        let response = try SecureChannel.sealResponse(plaintext: reply, key: opened.responseKey, cipher: opened.cipher, nonce: responseNonce)
        XCTAssertEqual(try SecureChannel.openResponse(response, key: responseKey), reply)
        var responseVector = keyMaterial
        responseVector.merge([
            "name": "\(name)-response",
            "description": "The server's reply to \(name)-request.json, sealed under the response key with a fresh nonce.",
            "requestVector": "\(name)-request.json",
            "cipher": cipher.rawValue,
            "responseNonceHex": responseNonce.hex,
            "aadHex": responseNonce.hex,
            "plaintext": String(decoding: reply, as: UTF8.self),
            "ciphertextHex": response.ciphertext.hex,
            "sealedResponse": try Fixtures.jsonObject(RemoteJSON.encoder.encode(response)),
        ]) { _, new in new }
        try Fixtures.check(responseFile, object: responseVector)
        return Exchange(request: sealed, responseKey: responseKey, response: response, path: path)
    }

    private func negativeVectors(chacha: Exchange, aes: Exchange) throws {
        let file = "secure-channel/negative.json"
        let device = FixtureKeys.device, other = FixtureKeys.otherDevice
        let timestamp = FixtureKeys.timestamp
        var vectors: [[String: Any]] = []

        func request(_ name: String, _ description: String, _ sealed: SecureChannel.SealedRequest, method: String = "POST", path: String = RemoteClient.rpcPath,
                     publicKey: Data? = nil, now: Int64? = nil, wire: [String: Any]? = nil) throws {
            let publicKey = publicKey ?? device.publicKeyRaw
            let now = now ?? timestamp
            let clock = Self.outcome { try SecureChannel.checkTimestamp(sealed, now: Date(timeIntervalSince1970: TimeInterval(now))) }
            let signature = SecureChannel.verifySignature(sealed, devicePublicKeyRaw: publicKey, method: method, path: path)
            var plaintext: Data?
            let open = Self.outcome { plaintext = try SecureChannel.open(sealed, serverKey: FixtureKeys.server, method: method, path: path).plaintext }
            var expect: [String: Any] = ["checkTimestamp": clock, "verifySignature": signature, "open": open]
            if let plaintext { expect["plaintext"] = String(decoding: plaintext, as: UTF8.self) }
            vectors.append([
                "name": name, "description": description, "kind": "request",
                "sealedRequest": try wire ?? Fixtures.jsonObject(RemoteJSON.encoder.encode(sealed)),
                "method": method, "path": path, "devicePublicKeyHex": publicKey.hex, "now": Int(now), "expect": expect,
            ])
        }

        func response(_ name: String, _ description: String, _ sealed: SecureChannel.SealedResponse, key: SymmetricKey) throws {
            var plaintext: Data?
            let open = Self.outcome { plaintext = try SecureChannel.openResponse(sealed, key: key) }
            var expect: [String: Any] = ["openResponse": open]
            if let plaintext { expect["plaintext"] = String(decoding: plaintext, as: UTF8.self) }
            vectors.append([
                "name": name, "description": description, "kind": "response",
                "sealedResponse": try Fixtures.jsonObject(RemoteJSON.encoder.encode(sealed)),
                "responseKeyHex": key.rawBytes.hex, "expect": expect,
            ])
        }

        let base = chacha.request
        try request("valid-baseline", "chacha20poly1305-request.json unchanged: every check passes.", base)

        var legacy = try Fixtures.jsonObject(RemoteJSON.encoder.encode(base))
        legacy.removeValue(forKey: "cipher")
        let legacyRequest = try RemoteJSON.decoder.decode(SecureChannel.SealedRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
        try request("missing-cipher-field", "Clients from before cipher negotiation omit `cipher`; it means chacha20poly1305, including in the header.",
                    legacyRequest, wire: legacy)

        var tampered = base
        tampered.ciphertext[SecureChannel.nonceLength] ^= 0x01
        try request("tampered-ciphertext", "First ciphertext byte after the embedded nonce flipped: the signature and the AEAD both fail.", tampered)

        var tag = base
        tag.ciphertext[tag.ciphertext.count - 1] ^= 0x80
        try request("tampered-tag", "Last tag byte flipped.", tag)

        try request("wrong-path", "Signed and sealed for /v1/rpc but checked as /v1/pair: the header differs, so the signature and the AEAD fail.",
                    base, path: RemoteClient.pairPath)
        try request("wrong-method", "Checked as GET instead of POST.", base, method: "GET")

        var forged = base
        let input = SecureChannel.signingInput(
            header: SecureChannel.header(deviceId: base.deviceId, ephemeral: base.ephemeralPublicKey, nonce: base.nonce, timestamp: base.timestamp,
                                         method: "POST", path: RemoteClient.rpcPath, cipher: base.effectiveCipher),
            ciphertext: base.ciphertext)
        let committedForged = (Fixtures.committedVectors(file)["bad-signature"]?["sealedRequest"] as? [String: Any])?["signature"] as? String
        forged.signature = Fixtures.stableSignature(committed: committedForged.flatMap { Data(base64Encoded: $0) }?.hex,
                                                    input: input, publicKey: other.publicKeyRaw, fresh: try other.sign(input))
        try request("bad-signature", "Signed by a different device key over the right input. The AEAD still opens, which is why servers verify first.", forged)

        var complement = base
        complement.signature = base.signature.prefix(32) + Self.p256OrderMinus(base.signature.suffix(32))
        try request("s-complement-signature", "(r, n - s) is the other encoding of the same ECDSA signature. The Swift server accepts it on Apple platforms and Linux, so clients need not normalize to low S.", complement)

        var swapped = aes.request
        swapped.cipher = .chacha20poly1305
        try request("cipher-swapped", "aes-256-gcm-request.json relabelled as chacha20poly1305: the cipher is bound into the header.", swapped)

        try request("clock-skew-edge", "Exactly 120 seconds of skew is accepted.", base, now: timestamp + Int64(SecureChannel.maxClockSkew))
        try request("stale-timestamp", "121 seconds of skew is rejected before any cryptography.", base, now: timestamp + Int64(SecureChannel.maxClockSkew) + 1)
        try request("future-timestamp", "Skew counts in both directions.", base, now: timestamp - Int64(SecureChannel.maxClockSkew) - 1)

        var version = base
        version.v = 2
        try request("unsupported-version", "Only v = 1 exists. The version is not part of the header, so the signature still verifies.", version)

        var shortNonce = base
        shortNonce.nonce = base.nonce.prefix(8)
        try request("short-nonce", "The nonce field must be exactly 12 bytes.", shortNonce)

        var shortKey = base
        shortKey.ephemeralPublicKey = base.ephemeralPublicKey.dropFirst()
        try request("compressed-or-truncated-ephemeral-key", "ephemeralPublicKey must be the 65-byte X9.63 uncompressed point.", shortKey)

        try response("response-valid-baseline", "chacha20poly1305-response.json unchanged.", chacha.response, key: chacha.responseKey)
        var responseTampered = chacha.response
        responseTampered.ciphertext[SecureChannel.nonceLength] ^= 0x01
        try response("response-tampered-ciphertext", "First ciphertext byte after the embedded nonce flipped.", responseTampered, key: chacha.responseKey)
        var wrongAAD = chacha.response
        wrongAAD.nonce = FixtureKeys.nonce("unrelated")
        try response("response-nonce-field-mismatch", "The `nonce` field is the AEAD's additional data; it must equal the nonce embedded in `ciphertext`.",
                     wrongAAD, key: chacha.responseKey)
        try response("response-wrong-key", "Opened with the request key instead of the response key.", chacha.response,
                     key: SecureChannel.derive(try FixtureKeys.ephemeral("chacha20poly1305").sharedSecretFromKeyAgreement(with: FixtureKeys.server.key.publicKey),
                                               nonce: chacha.request.nonce, deviceId: chacha.request.deviceId).request)
        var responseShortNonce = chacha.response
        responseShortNonce.nonce = chacha.response.nonce.prefix(8)
        try response("response-short-nonce", "The response nonce must be exactly 12 bytes.", responseShortNonce, key: chacha.responseKey)

        try Fixtures.check(file, object: [
            "description": "Server-side checks applied to altered requests and client-side checks applied to altered responses. Each vector lists the result of checkTimestamp (at `now`), verifySignature (against devicePublicKeyHex, method, path), and open (with the server key) for requests, or openResponse for responses. Error names: unsupportedVersion, malformed, timeWindow, decryptFailed.",
            "serverStaticPrivateKeyHex": FixtureKeys.server.key.rawRepresentation.hex,
            "serverStaticPublicKeyHex": FixtureKeys.server.publicKeyRaw.hex,
            "vectors": vectors,
        ])
    }

    /// n - s for the P-256 group order n, on 32-byte big-endian integers.
    static func p256OrderMinus(_ s: Data) -> Data {
        let n = Array(Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)
        let s = Array(s)
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in (0..<32).reversed() {
            var digit = Int(n[index]) - Int(s[index]) - borrow
            borrow = digit < 0 ? 1 : 0
            if digit < 0 { digit += 256 }
            result[index] = UInt8(digit)
        }
        return Data(result)
    }

    static func outcome(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "ok"
        } catch let error as SecureChannel.ChannelError {
            return "\(error)"
        } catch {
            return "error"
        }
    }

    // MARK: Pairing

    func testPairingVectors() throws {
        let key = FixtureKeys.server.publicKeyRaw
        let k = key.base64URLEncodedString()
        let token = FixtureKeys.pairingToken
        let invite = PairingInvite(serverHost: "ada-mbp.tail1234.ts.net", port: 7787, serverName: "Ada’s MacBook Pro",
                                   serverPublicKey: key, token: token, expiresAt: Date(timeIntervalSince1970: 1_792_500_300))
        XCTAssertEqual(PairingInvite(url: invite.url), invite)

        func expected(_ invite: PairingInvite) -> [String: Any] {
            ["serverHost": invite.serverHost, "port": invite.port, "serverName": invite.serverName,
             "serverPublicKeyHex": invite.serverPublicKey.hex, "token": invite.token, "expiresAt": Int64(invite.expiresAt.timeIntervalSince1970)]
        }
        var valid: [[String: Any]] = []
        func accept(_ url: String, _ description: String) throws {
            let parsed = try XCTUnwrap(PairingInvite(url: XCTUnwrap(URL(string: url))), url)
            valid.append(["url": url, "description": description, "expected": expected(parsed)])
        }
        try accept(invite.url.absoluteString, "As the Mac generates it. The key is base64url without padding; the name is percent-encoded UTF-8.")
        try accept("planmeter://pair?h=100.101.102.103&p=7787&k=\(k)&t=\(token)&e=1792500300",
                   "`n` is optional and defaults to the host.")
        try accept("planmeter://pair?v=2&t=\(token)&e=1792500300&n=Build%20Box&k=\(k)&p=443&h=build.tail1234.ts.net",
                   "Parameter order does not matter and unknown parameters are ignored.")
        try accept("planmeter://pair?h=old.tail1234.ts.net&p=7787&k=\(k)&t=\(token)&e=1",
                   "An expired invite still parses; clients check `expiresAt` against the clock before pairing.")

        var invalid: [[String: Any]] = []
        func reject(_ url: String, _ reason: String) throws {
            XCTAssertNil(PairingInvite(url: try XCTUnwrap(URL(string: url), url)), url)
            invalid.append(["url": url, "reason": reason])
        }
        let rest = "k=\(k)&t=\(token)&e=1792500300"
        try reject("https://ada-mbp.tail1234.ts.net/pair?h=ada-mbp.tail1234.ts.net&p=7787&\(rest)", "scheme must be planmeter")
        try reject("planmeter://invite?h=ada-mbp.tail1234.ts.net&p=7787&\(rest)", "host must be pair")
        try reject("planmeter://pair?p=7787&\(rest)", "h missing")
        try reject("planmeter://pair?h=&p=7787&\(rest)", "h empty")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&\(rest)", "p missing")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=0&\(rest)", "p below 1")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=65536&\(rest)", "p above 65535")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=http&\(rest)", "p not a decimal integer")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&t=\(token)&e=1792500300", "k missing")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=\(key.prefix(64).base64URLEncodedString())&t=\(token)&e=1792500300",
                   "k decodes to 64 bytes, not a 65-byte X9.63 point")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=not*base64&t=\(token)&e=1792500300", "k is not base64url")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=\(k)&e=1792500300", "t missing")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=\(k)&t=&e=1792500300", "t empty")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=\(k)&t=\(token)", "e missing")
        try reject("planmeter://pair?h=ada-mbp.tail1234.ts.net&p=7787&k=\(k)&t=\(token)&e=1792500300.5", "e not an integer")

        try Fixtures.check("pairing/invites.json", object: [
            "description": "planmeter://pair invite URLs. Valid URLs list the parsed fields; invalid URLs must be rejected.",
            "valid": valid,
            "invalid": invalid,
        ])

        let request = Pairing.request(deviceName: "Ada’s Pixel 9", platform: "android")
        XCTAssertEqual(try RemoteJSON.decoder.decode(PairRequest.self, from: RemoteJSON.encoder.encode(request)), request)
        try Fixtures.check("pairing/pair-request.json", encodable: request)
        try Fixtures.check("pairing/pair-response.json", encodable: Pairing.response)

        var ids: [[String: Any]] = []
        for (label, publicKey) in [("device", FixtureKeys.device.publicKeyRaw), ("other-device", FixtureKeys.otherDevice.publicKeyRaw),
                                   ("server", FixtureKeys.server.publicKeyRaw)] {
            let digest = Data(SHA256.hash(data: publicKey))
            ids.append(["label": label, "publicKeyHex": publicKey.hex, "sha256Hex": digest.hex,
                        "sha256Base64Url": digest.base64URLEncodedString(), "deviceId": DeviceId.derive(fromPublicKey: publicKey)])
        }
        try Fixtures.check("pairing/device-ids.json", object: [
            "description": "deviceId = the first 22 characters of unpadded base64url(SHA-256(65-byte X9.63 public key)).",
            "vectors": ids,
        ])
    }

    // MARK: Replies

    func testReplyFixtures() throws {
        let replies: [(String, RemoteReply)] = [
            ("summary", Replies.summary), ("models", Replies.models), ("timeline", Replies.timeline),
            ("limits", Replies.limits), ("accounts", Replies.accounts), ("error", RemoteReply(error: "server not ready")),
        ]
        XCTAssertEqual(Set(replies.map(\.0)), Set(RemoteMethod.allCases.map(\.rawValue) + ["error"]), "Add a fixture for every RemoteMethod.")
        for (name, reply) in replies {
            let data = try RemoteJSON.encoder.encode(reply)
            XCTAssertEqual(try RemoteJSON.decoder.decode(RemoteReply.self, from: data), reply, name)
            try Fixtures.check("replies/\(name).json", encodable: reply)
        }
    }

    // MARK: Manifest

    /// Keeps the file list in protocol/README.md honest: other implementations
    /// load these paths by name.
    func testFixtureManifest() throws {
        guard !Fixtures.regenerating else { return }
        let names = ["chacha20poly1305", "aes-256-gcm", "chacha20poly1305-pair", "aes-256-gcm-pair"]
        let expected = Set(names.flatMap { ["secure-channel/\($0)-request.json", "secure-channel/\($0)-response.json"] }
            + ["secure-channel/negative.json", "pairing/invites.json", "pairing/pair-request.json", "pairing/pair-response.json",
               "pairing/device-ids.json"]
            + ["summary", "models", "timeline", "limits", "accounts", "error"].map { "replies/\($0).json" })
        let root = Fixtures.root.standardizedFileURL.path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        var found: Set<String> = []
        while let path = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            // control/ holds the local control API examples, generated and
            // checked by PlanMeterHostTests.ControlFixtureTests.
            if FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue, !path.hasPrefix("."),
               !path.hasPrefix("control/") {
                found.insert(path)
            }
        }
        XCTAssertEqual(found, expected)
    }
}

// MARK: - Inputs

/// Fixed key material: P-256 scalars derived from labels, never random.
enum FixtureKeys {
    static func bytes(_ label: String) -> Data { Data(SHA256.hash(data: Data("planmeter-fixture|\(label)".utf8))) }

    static let server = try! SoftwareAgreementKey(rawRepresentation: bytes("server-static-key"))
    static let device = try! SoftwareSigningKey(rawRepresentation: bytes("device-signing-key"))
    static let otherDevice = try! SoftwareSigningKey(rawRepresentation: bytes("other-device-signing-key"))
    static var deviceId: String { DeviceId.derive(fromPublicKey: device.publicKeyRaw) }
    static let pairingToken = bytes("pairing-token").base64URLEncodedString()
    /// 2026-10-20T12:40:00Z.
    static let timestamp: Int64 = 1_792_500_000

    static func ephemeral(_ name: String) throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes("ephemeral-key|\(name)"))
    }

    static func nonce(_ name: String) -> Data { bytes("nonce|\(name)").prefix(SecureChannel.nonceLength) }
}

enum Pairing {
    static func request(deviceName: String, platform: String) -> PairRequest {
        PairRequest(token: FixtureKeys.pairingToken, deviceName: deviceName, devicePublicKey: FixtureKeys.device.publicKeyRaw, platform: platform)
    }

    static var response: PairResponse {
        PairResponse(deviceId: FixtureKeys.deviceId, serverName: "Ada’s MacBook Pro", serverVersion: "0.3.6")
    }
}

/// Plausible fake data: a Mac with personal and work logins for Codex and Claude Code.
enum Replies {
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static let codexPro = RemoteAccount(id: "codex:plan:pro", name: "Personal Codex", provider: "codex", providerName: "Codex",
                                        group: "personal", email: "ada@example.com", plan: "Pro", accentColorHex: "#10A37F")
    static let claudeMax = RemoteAccount(id: "claude:home:/Users/ada/.claude-personal/projects", name: "Personal Claude", provider: "claude",
                                         providerName: "Claude Code", group: "personal", email: "ada@example.com", plan: "Max", accentColorHex: "#D97757")
    static let codexBusiness = RemoteAccount(id: "codex:plan:business", name: "Work Codex", provider: "codex", providerName: "Codex",
                                             group: "work", email: "ada.lovelace@example.org", plan: "Business")
    static let claudeEnterprise = RemoteAccount(id: "claude:home:/Users/ada/.claude/projects", name: "Work Claude", provider: "claude",
                                                providerName: "Claude Code", group: "work", email: "ada.lovelace@example.org", plan: "Enterprise")
    static let openCode = RemoteAccount(id: "opencode:local", name: "OpenCode", provider: "opencode", providerName: "OpenCode", group: "other", plan: "local")

    static func totals(_ cost: Double, input: Int, cached: Int, output: Int, sessions: Int, savings: Double) -> RemoteTotals {
        RemoteTotals(costUsd: cost, tokens: input + output, inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                     sessions: sessions, cacheSavingsUsd: savings)
    }

    static var summary: RemoteReply {
        let codexPro = totals(48.25, input: 61_204_880, cached: 55_871_232, output: 402_118, sessions: 14, savings: 62.875)
        let claudeMax = totals(12.5, input: 18_220_406, cached: 17_310_220, output: 96_531, sessions: 6, savings: 23.25)
        let codexBusiness = totals(96.125, input: 140_663_012, cached: 131_002_880, output: 911_402, sessions: 22, savings: 120.5)
        let claudeEnterprise = totals(31.875, input: 40_118_660, cached: 38_004_118, output: 210_975, sessions: 9, savings: 51.125)
        let personal = totals(60.75, input: 79_425_286, cached: 73_181_452, output: 498_649, sessions: 20, savings: 86.125)
        let work = totals(128.0, input: 180_781_672, cached: 169_006_998, output: 1_122_377, sessions: 31, savings: 171.625)
        return RemoteReply(summary: RemoteSummary(
            days: 7, from: date("2026-10-13T04:00:00Z"), to: date("2026-10-20T04:00:00Z"),
            groups: [
                RemoteGroupUsage(group: "personal", totals: personal, accounts: [
                    RemoteAccountUsage(account: Self.codexPro, totals: codexPro),
                    RemoteAccountUsage(account: Self.claudeMax, totals: claudeMax),
                ]),
                RemoteGroupUsage(group: "work", totals: work, accounts: [
                    RemoteAccountUsage(account: Self.codexBusiness, totals: codexBusiness),
                    RemoteAccountUsage(account: Self.claudeEnterprise, totals: claudeEnterprise),
                ]),
            ],
            total: totals(188.75, input: 260_206_958, cached: 242_188_450, output: 1_621_026, sessions: 51, savings: 257.75),
            todayCostUsd: 21.375, generatedAt: date("2026-10-19T16:00:00Z"), serverName: "Ada’s MacBook Pro",
            pricingSource: "LiteLLM"))
    }

    static var models: RemoteReply {
        RemoteReply(models: [
            RemoteModelRow(accountId: codexBusiness.id, accountName: codexBusiness.name, group: "work", provider: "codex", model: "gpt-5.5-codex",
                           totals: totals(96.125, input: 140_663_012, cached: 131_002_880, output: 911_402, sessions: 22, savings: 120.5), priced: true),
            RemoteModelRow(accountId: codexPro.id, accountName: codexPro.name, group: "personal", provider: "codex", model: "gpt-5.5-codex",
                           totals: totals(48.25, input: 61_204_880, cached: 55_871_232, output: 402_118, sessions: 14, savings: 62.875), priced: true),
            RemoteModelRow(accountId: claudeEnterprise.id, accountName: claudeEnterprise.name, group: "work", provider: "claude", model: "claude-opus-5-5",
                           totals: totals(31.875, input: 40_118_660, cached: 38_004_118, output: 210_975, sessions: 9, savings: 51.125), priced: true),
            RemoteModelRow(accountId: claudeMax.id, accountName: claudeMax.name, group: "personal", provider: "claude", model: "claude-sonnet-5",
                           totals: totals(12.5, input: 18_220_406, cached: 17_310_220, output: 96_531, sessions: 6, savings: 23.25), priced: true),
            RemoteModelRow(accountId: openCode.id, accountName: openCode.name, group: "other", provider: "opencode", model: "local/qwen3-coder",
                           totals: totals(0, input: 1_204_332, cached: 0, output: 30_118, sessions: 2, savings: 0), priced: false),
        ])
    }

    /// The last hour in five-minute buckets. The work Codex account has
    /// workspace credits without timing, spread evenly as `baselineCostUsd`.
    static var timeline: RemoteReply {
        let start = date("2026-10-19T15:05:00Z")
        let periods = (0..<12).map { start.addingTimeInterval(TimeInterval($0 * 300)) }
        var points: [RemoteTimelinePoint] = []
        for (index, period) in periods.enumerated() {
            points.append(RemoteTimelinePoint(period: period, accountId: codexBusiness.id, costUsd: 0.125 + Double(index % 3) * 0.25,
                                              tokens: 180_000 + index * 12_500, baselineCostUsd: 0.125))
            if index % 4 == 1 {
                points.append(RemoteTimelinePoint(period: period, accountId: codexPro.id, costUsd: 0.75, tokens: 410_000 + index * 1_000))
            }
        }
        return RemoteReply(timeline: RemoteTimeline(days: 1, resolution: "5m", periods: periods, points: points,
                                                    accounts: [codexPro, codexBusiness], minutes: 60))
    }

    static var limits: RemoteReply {
        RemoteReply(limits: RemoteLimits(accounts: [
            RemoteAccountLimits(account: codexPro, windows: [
                RemoteLimitWindow(label: "5-hour", usedPercent: 42.5, windowMinutes: 300, resetsAt: date("2026-10-19T18:12:00Z")),
                RemoteLimitWindow(label: "Weekly", usedPercent: 18.0, windowMinutes: 10_080, resetsAt: date("2026-10-23T09:00:00Z")),
            ], asOf: date("2026-10-19T15:58:41Z")),
            RemoteAccountLimits(account: codexBusiness, windows: [], note: "Billed against credits; no usage windows.", asOf: date("2026-10-19T14:20:07Z")),
        ], note: "Codex windows come from the last session each account ran. Claude Code does not store limits locally."))
    }

    static var accounts: RemoteReply {
        RemoteReply(accounts: RemoteAccounts(
            accounts: [codexBusiness, codexPro, claudeMax, claudeEnterprise, openCode],
            sources: [
                RemoteSource(provider: "codex", path: "/Users/ada/.codex/sessions", status: "ok"),
                RemoteSource(provider: "codex", path: "/Users/ada/.codex/archived_sessions", status: "ok"),
                RemoteSource(provider: "claude", path: "/Users/ada/.claude-personal/projects", status: "ok"),
                RemoteSource(provider: "claude", path: "/Users/ada/.claude/projects", status: "partial"),
                RemoteSource(provider: "opencode", path: "/Users/ada/.local/share/opencode/opencode.db", status: "missing"),
            ],
            scannedAt: date("2026-10-19T16:00:00Z")))
    }
}

// MARK: - Fixture files

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures", isDirectory: true)

    static var regenerating: Bool { ProcessInfo.processInfo.environment["PLANMETER_REGENERATE_FIXTURES"] == "1" }

    /// RemoteJSON's encoding, pretty-printed for review. Same values, so the
    /// semantic comparison treats them alike.
    static let fileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func committed(_ path: String) -> Any? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func committedObject(_ path: String) -> [String: Any]? { committed(path) as? [String: Any] }

    static func committedVectors(_ path: String) -> [String: [String: Any]] {
        let vectors = committedObject(path)?["vectors"] as? [[String: Any]] ?? []
        return Dictionary(vectors.compactMap { vector in (vector["name"] as? String).map { ($0, vector) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The committed signature while it still verifies, else the fresh one.
    static func stableSignature(committed: Any?, input: Data, publicKey: Data, fresh: Data) -> Data {
        if let hex = committed as? String, let signature = Data(hex: hex),
           SigningKeys.verify(signature: signature, for: input, publicKeyRaw: publicKey) {
            return signature
        }
        return fresh
    }

    static func check<T: Encodable>(_ path: String, encodable value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        try check(path, canonical: RemoteJSON.encoder.encode(value), pretty: fileEncoder.encode(value), file: file, line: line)
    }

    static func check(_ path: String, object: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try check(path, canonical: pretty, pretty: pretty, file: file, line: line)
    }

    /// Writes `pretty` when regenerating; otherwise compares `canonical` with
    /// the committed file as parsed JSON values.
    static func check(_ path: String, canonical: Data, pretty: Data, file: StaticString, line: UInt) throws {
        let url = root.appendingPathComponent(path)
        if regenerating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (pretty + Data("\n".utf8)).write(to: url, options: .atomic)
            return
        }
        guard let committed = committed(path) else {
            XCTFail("protocol/fixtures/\(path) is missing or unreadable. \(hint)", file: file, line: line)
            return
        }
        let generated = try JSONSerialization.jsonObject(with: canonical)
        if let difference = difference(committed, generated, at: "$") {
            XCTFail("protocol/fixtures/\(path) differs from the Swift implementation at \(difference). \(hint)", file: file, line: line)
        }
    }

    static let hint = "If the protocol change is intended, run `PLANMETER_REGENERATE_FIXTURES=1 swift test --filter ProtocolFixtureTests` on a Mac and review the diff."

    /// The first path where two parsed JSON values differ, or nil.
    static func difference(_ a: Any, _ b: Any, at path: String) -> String? {
        switch (a, b) {
        case let (a as [String: Any], b as [String: Any]):
            if Set(a.keys) != Set(b.keys) {
                return "\(path) (keys \(a.keys.sorted()) vs \(b.keys.sorted()))"
            }
            for key in a.keys.sorted() {
                if let found = difference(a[key]!, b[key]!, at: "\(path).\(key)") { return found }
            }
            return nil
        case let (a as [Any], b as [Any]):
            guard a.count == b.count else { return "\(path) (\(a.count) vs \(b.count) elements)" }
            for (index, pair) in zip(a, b).enumerated() {
                if let found = difference(pair.0, pair.1, at: "\(path)[\(index)]") { return found }
            }
            return nil
        case let (a as String, b as String):
            return a == b ? nil : "\(path) (\"\(a)\" vs \"\(b)\")"
        case (is NSNull, is NSNull):
            return nil
        case let (a as NSNumber, b as NSNumber):
            return isBoolean(a) == isBoolean(b) && a == b ? nil : "\(path) (\(a) vs \(b))"
        default:
            return "\(path) (\(type(of: a)) vs \(type(of: b)))"
        }
    }

    private static let booleanType = type(of: NSNumber(value: true))
    static func isBoolean(_ number: NSNumber) -> Bool { type(of: number) == booleanType }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension ContiguousBytes {
    /// Named to stay clear of the `bytes: RawSpan` that newer SDKs add.
    var rawBytes: Data { withUnsafeBytes { Data($0) } }
}
