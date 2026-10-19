package com.neilgoldader.planmeter.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.math.BigInteger
import java.security.interfaces.ECPublicKey
import java.time.Instant

class SecureChannelTest {
    private val server = P256.generateKeyPair()
    private val serverRaw = P256.x963(server.public as ECPublicKey)
    private val signer = SoftwareSigner()
    private val now = Instant.parse("2026-10-19T12:00:00Z")

    @Test
    fun roundTripsBothCiphers() {
        for (cipher in SecureChannel.Cipher.entries) {
            val body = """{"method":"summary"}""".toByteArray()
            val sealed = SecureChannel.seal(body, serverRaw, "dev", signer, "post", "/v1/rpc", cipher, now)
            val request = sealed.request
            assertEquals(1, request.v)
            assertEquals(12, request.nonce.size)
            assertEquals(65, request.ephemeralPublicKey.size)
            assertEquals(64, request.signature.size)
            assertEquals(body.size + 12 + 16, request.ciphertext.size)
            assertArrayEquals(request.nonce, request.ciphertext.copyOfRange(0, 12))
            assertEquals(now.epochSecond, request.timestamp)
            assertTrue(SecureChannel.verifySignature(request, signer.publicKeyRaw, "POST", "/v1/rpc"))
            val opened = SecureChannel.open(request, server.private, "POST", "/v1/rpc")
            assertArrayEquals(body, opened.plaintext)
            assertArrayEquals(sealed.responseKey, opened.responseKey)
            assertEquals(cipher, opened.cipher)
            val response = SecureChannel.sealResponse("ok".toByteArray(), opened.responseKey, cipher)
            assertArrayEquals("ok".toByteArray(), SecureChannel.openResponse(response, sealed.responseKey))
        }
    }

    @Test
    fun headerLayout() {
        val header = SecureChannel.header("dev", ByteArray(65) { 1 }, ByteArray(12) { 2 }, 1792411200, "post", "/v1/rpc", SecureChannel.Cipher.CHACHA20_POLY1305)
        assertEquals(
            "planmeter-remote-v1\nPOST\n/v1/rpc\ndev\n1792411200\nAgICAgICAgICAgIC\n" +
                "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nchacha20poly1305\n",
            header.toString(Charsets.UTF_8),
        )
    }

    @Test
    fun tamperingIsDetected() {
        val sealed = SecureChannel.seal("secret".toByteArray(), serverRaw, "dev", signer, "POST", "/v1/rpc", now = now).request
        // Wrong path: the header (AAD and signature input) differs.
        assertFalse(SecureChannel.verifySignature(sealed, signer.publicKeyRaw, "POST", "/v1/pair"))
        expectChannel(ChannelError.DECRYPT_FAILED) { SecureChannel.open(sealed, server.private, "POST", "/v1/pair") }
        // Flipped ciphertext byte.
        val flipped = sealed.ciphertext.copyOf().also { it[20] = (it[20].toInt() xor 0x80).toByte() }
        val tampered = SecureChannel.SealedRequest(sealed.v, sealed.deviceId, sealed.ephemeralPublicKey, sealed.nonce, sealed.timestamp, flipped, sealed.signature, sealed.cipher)
        assertFalse(SecureChannel.verifySignature(tampered, signer.publicKeyRaw, "POST", "/v1/rpc"))
        expectChannel(ChannelError.DECRYPT_FAILED) { SecureChannel.open(tampered, server.private, "POST", "/v1/rpc") }
        // Changed timestamp.
        val late = SecureChannel.SealedRequest(sealed.v, sealed.deviceId, sealed.ephemeralPublicKey, sealed.nonce, sealed.timestamp + 1, sealed.ciphertext, sealed.signature, sealed.cipher)
        assertFalse(SecureChannel.verifySignature(late, signer.publicKeyRaw, "POST", "/v1/rpc"))
        // Cipher downgrade label changes the header.
        val relabeled = SecureChannel.SealedRequest(sealed.v, sealed.deviceId, sealed.ephemeralPublicKey, sealed.nonce, sealed.timestamp, sealed.ciphertext, sealed.signature, SecureChannel.Cipher.AES_256_GCM)
        assertFalse(SecureChannel.verifySignature(relabeled, signer.publicKeyRaw, "POST", "/v1/rpc"))
    }

    @Test
    fun missingCipherMeansChaCha() {
        val json = """{"v":1,"deviceId":"d","ephemeralPublicKey":"","nonce":"","timestamp":0,"ciphertext":"","signature":""}"""
        val request = RemoteJson.decode(SecureChannel.SealedRequest.serializer(), json.toByteArray())
        assertEquals(SecureChannel.Cipher.CHACHA20_POLY1305, request.effectiveCipher)
    }

    @Test
    fun timestampWindow() {
        val sealed = SecureChannel.seal(ByteArray(0), serverRaw, "dev", signer, "POST", "/v1/rpc", now = now).request
        SecureChannel.checkTimestamp(sealed, now.plusSeconds(120))
        expectChannel(ChannelError.TIME_WINDOW) { SecureChannel.checkTimestamp(sealed, now.plusSeconds(121)) }
        expectChannel(ChannelError.TIME_WINDOW) { SecureChannel.checkTimestamp(sealed, now.minusSeconds(121)) }
    }

    @Test
    fun responseNonceMustBe12Bytes() {
        val key = ByteArray(32)
        val good = SecureChannel.sealResponse("x".toByteArray(), key)
        val bad = SecureChannel.SealedResponse(good.nonce.copyOf(11), good.ciphertext, good.cipher)
        expectChannel(ChannelError.MALFORMED) { SecureChannel.openResponse(bad, key) }
        // The response nonce is the AAD: a different one fails authentication.
        val other = SecureChannel.SealedResponse(ByteArray(12), good.ciphertext, good.cipher)
        expectChannel(ChannelError.DECRYPT_FAILED) { SecureChannel.openResponse(other, key) }
    }

    @Test
    fun rejectsPointsOffTheCurve() {
        val bogus = serverRaw.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        expectChannel(ChannelError.MALFORMED) { SecureChannel.seal(ByteArray(0), bogus, "dev", signer, "POST", "/v1/rpc") }
    }

    @Test
    fun hkdfRfc5869Vectors() {
        // RFC 5869 A.1
        val okm = Hkdf.sha256(hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), hex("000102030405060708090a0b0c"), hex("f0f1f2f3f4f5f6f7f8f9"), 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", okm.toHex())
        // RFC 5869 A.3: empty salt and info.
        val okm3 = Hkdf.sha256(hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), ByteArray(0), ByteArray(0), 42)
        assertEquals("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", okm3.toHex())
    }

    @Test
    fun chachaRfc8439Vector() {
        // RFC 8439 2.8.2 AEAD test vector.
        val key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        val nonce = hex("070000004041424344454647")
        val aad = hex("50515253c0c1c2c3c4c5c6c7")
        val plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".toByteArray()
        val combined = Aead.seal(SecureChannel.Cipher.CHACHA20_POLY1305, key, nonce, plaintext, aad)
        assertEquals("1ae10b594f09e26a7e902ecbd0600691", combined.copyOfRange(combined.size - 16, combined.size).toHex())
        assertEquals("d31a8d34648e60db7b86afbc53ef7ec2", combined.copyOfRange(12, 28).toHex())
        assertArrayEquals(plaintext, Aead.open(SecureChannel.Cipher.CHACHA20_POLY1305, key, combined, aad))
    }

    @Test
    fun derConversionEdgeCases() {
        // Small r and s (leading zero bytes in raw form) and high-bit values (0x00 pad in DER).
        val cases = listOf(
            BigInteger.ONE to BigInteger.TWO,
            BigInteger("80" + "00".repeat(31), 16) to BigInteger("7f" + "ff".repeat(31), 16),
            BigInteger("00ff" + "11".repeat(30), 16) to BigInteger("ff".repeat(32), 16),
        )
        for ((r, s) in cases) {
            val raw = P256.unsigned(r, 32) + P256.unsigned(s, 32)
            val der = EcdsaSignature.rawToDer(raw)
            assertArrayEquals(raw, EcdsaSignature.derToRaw(der))
            val sig = java.security.Signature.getInstance("SHA256withECDSA")
            // The DER must at least be structurally valid for the JCA parser.
            sig.initVerify(server.public)
            sig.update(ByteArray(1))
            try { sig.verify(der) } catch (e: java.security.SignatureException) { fail("JCA rejected DER: $e") }
        }
        // Many real signatures, including ones whose r or s has a leading zero byte.
        repeat(300) {
            val message = "m$it".toByteArray()
            val raw = signer.sign(message)
            assertEquals(64, raw.size)
            assertTrue(P256.verify(raw, message, signer.publicKeyRaw))
        }
    }

    private fun expectChannel(error: ChannelError, block: () -> Unit) {
        try {
            block()
            fail("Expected $error")
        } catch (e: ChannelException) {
            assertEquals(error, e.error)
        }
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
