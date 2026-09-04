import CryptoKit
import XCTest
@testable import PlanMeterRemote

final class SecureChannelTests: XCTestCase {
    let server = SoftwareAgreementKey()
    let device = SoftwareSigningKey()

    func testRoundTrip() throws {
        let plaintext = Data("{\"method\":\"summary\"}".utf8)
        let (req, responseKey) = try SecureChannel.seal(plaintext: plaintext, serverPublicKeyRaw: server.publicKeyRaw, deviceId: "dev1", signer: device, method: "POST", path: "/v1/rpc")
        try SecureChannel.checkTimestamp(req)
        XCTAssertTrue(SecureChannel.verifySignature(req, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/rpc"))
        let opened = try SecureChannel.open(req, serverKey: server, method: "POST", path: "/v1/rpc")
        XCTAssertEqual(opened.plaintext, plaintext)

        let reply = Data("{\"ok\":true}".utf8)
        let sealed = try SecureChannel.sealResponse(plaintext: reply, key: opened.responseKey)
        XCTAssertEqual(try SecureChannel.openResponse(sealed, key: responseKey), reply)
    }

    func testAESGCMRoundTripForBrowsers() throws {
        let plaintext = Data("{\"method\":\"limits\"}".utf8)
        let (req, responseKey) = try SecureChannel.seal(plaintext: plaintext, serverPublicKeyRaw: server.publicKeyRaw, deviceId: "web1", signer: device, method: "POST", path: "/v1/rpc", cipher: .aes256gcm)
        XCTAssertEqual(req.cipher, .aes256gcm)
        // nonce || ciphertext || tag
        XCTAssertEqual(req.ciphertext.count, 12 + plaintext.count + 16)
        XCTAssertTrue(SecureChannel.verifySignature(req, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/rpc"))
        let opened = try SecureChannel.open(req, serverKey: server, method: "POST", path: "/v1/rpc")
        XCTAssertEqual(opened.plaintext, plaintext)
        XCTAssertEqual(opened.cipher, .aes256gcm)
        let sealed = try SecureChannel.sealResponse(plaintext: Data("ok".utf8), key: opened.responseKey, cipher: opened.cipher)
        XCTAssertEqual(sealed.cipher, .aes256gcm)
        XCTAssertEqual(try SecureChannel.openResponse(sealed, key: responseKey), Data("ok".utf8))
        // Lying about the cipher after the fact breaks the signature.
        var swapped = req
        swapped.cipher = .chacha20poly1305
        XCTAssertFalse(SecureChannel.verifySignature(swapped, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/rpc"))
    }

    func testMissingCipherFieldDefaultsToChaCha() throws {
        let (req, _) = try SecureChannel.seal(plaintext: Data("x".utf8), serverPublicKeyRaw: server.publicKeyRaw, deviceId: "dev1", signer: device, method: "POST", path: "/v1/rpc")
        var json = try JSONSerialization.jsonObject(with: RemoteJSON.encoder.encode(req)) as! [String: Any]
        json.removeValue(forKey: "cipher")
        let decoded = try RemoteJSON.decoder.decode(SecureChannel.SealedRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.cipher)
        XCTAssertEqual(decoded.effectiveCipher, .chacha20poly1305)
        XCTAssertTrue(SecureChannel.verifySignature(decoded, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/rpc"))
    }

    func testSignatureBindsMethodPathAndBody() throws {
        let (req, _) = try SecureChannel.seal(plaintext: Data("x".utf8), serverPublicKeyRaw: server.publicKeyRaw, deviceId: "dev1", signer: device, method: "POST", path: "/v1/rpc")
        XCTAssertFalse(SecureChannel.verifySignature(req, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/pair"))
        XCTAssertFalse(SecureChannel.verifySignature(req, devicePublicKeyRaw: device.publicKeyRaw, method: "GET", path: "/v1/rpc"))
        var tampered = req
        tampered.ciphertext[0] ^= 0xFF
        XCTAssertFalse(SecureChannel.verifySignature(tampered, devicePublicKeyRaw: device.publicKeyRaw, method: "POST", path: "/v1/rpc"))
        XCTAssertThrowsError(try SecureChannel.open(tampered, serverKey: server, method: "POST", path: "/v1/rpc"))
        let other = SoftwareSigningKey()
        XCTAssertFalse(SecureChannel.verifySignature(req, devicePublicKeyRaw: other.publicKeyRaw, method: "POST", path: "/v1/rpc"))
    }

    func testWrongServerKeyCannotDecrypt() throws {
        let (req, _) = try SecureChannel.seal(plaintext: Data("secret".utf8), serverPublicKeyRaw: server.publicKeyRaw, deviceId: "dev1", signer: device, method: "POST", path: "/v1/rpc")
        let impostor = SoftwareAgreementKey()
        XCTAssertThrowsError(try SecureChannel.open(req, serverKey: impostor, method: "POST", path: "/v1/rpc"))
    }

    func testClockWindow() throws {
        let (req, _) = try SecureChannel.seal(plaintext: Data("x".utf8), serverPublicKeyRaw: server.publicKeyRaw, deviceId: "dev1", signer: device, method: "POST", path: "/v1/rpc", now: Date().addingTimeInterval(-600))
        XCTAssertThrowsError(try SecureChannel.checkTimestamp(req)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .timeWindow)
        }
    }

    func testReplayCache() throws {
        let cache = ReplayCache(ttl: 60)
        let nonce = Data(repeating: 7, count: 12)
        XCTAssertTrue(cache.record(deviceId: "a", nonce: nonce))
        XCTAssertFalse(cache.record(deviceId: "a", nonce: nonce))
        XCTAssertTrue(cache.record(deviceId: "b", nonce: nonce))
    }

    func testEnclaveOrSoftwareKeysPersist() throws {
        let made = SigningKeys.make()
        let loaded = try SigningKeys.load(made.blob)
        XCTAssertEqual(loaded.publicKeyRaw, made.key.publicKeyRaw)
        let message = Data("hello".utf8)
        XCTAssertTrue(SigningKeys.verify(signature: try loaded.sign(message), for: message, publicKeyRaw: made.key.publicKeyRaw))

        let agreement = AgreementKeys.make()
        let loadedAgreement = try AgreementKeys.load(agreement.blob)
        XCTAssertEqual(loadedAgreement.publicKeyRaw, agreement.key.publicKeyRaw)
    }
}

final class PairingTests: XCTestCase {
    func testInviteURLRoundTrip() throws {
        let key = SoftwareAgreementKey().publicKeyRaw
        let invite = PairingInvite(serverHost: "planmeter.example.ts.net", port: 7787, serverName: "Example Mac", serverPublicKey: key, token: PairingInvite.makeToken(), expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let parsed = PairingInvite(url: invite.url)
        XCTAssertEqual(parsed, invite)
        XCTAssertEqual(invite.url.scheme, "planmeter")
        XCTAssertNil(PairingInvite(url: URL(string: "planmeter://pair?h=x&p=70000&k=abc&t=t&e=1")!))
    }

    func testDeviceIdIsStable() {
        let key = SoftwareSigningKey().publicKeyRaw
        XCTAssertEqual(DeviceId.derive(fromPublicKey: key), DeviceId.derive(fromPublicKey: key))
        XCTAssertEqual(DeviceId.derive(fromPublicKey: key).count, 22)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(Data("abc".utf8).constantTimeEquals(Data("abc".utf8)))
        XCTAssertFalse(Data("abc".utf8).constantTimeEquals(Data("abd".utf8)))
        XCTAssertFalse(Data("abc".utf8).constantTimeEquals(Data("ab".utf8)))
    }

    func testIPv6BaseURL() {
        let s = PairedServer(host: "fd7a::1", port: 7787, serverName: "x", serverPublicKey: Data(), deviceId: "d", pairedAt: Date())
        XCTAssertEqual(s.baseURL.absoluteString, "http://[fd7a::1]:7787")
    }
}
