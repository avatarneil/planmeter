package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.security.KeyPair
import java.time.Instant

/**
 * The shared golden fixtures in protocol/fixtures (repository root), generated
 * by the Swift implementation. See protocol/README.md, "Fixtures".
 */
class GoldenFixturesTest {
    private val root: File = File(requireNotNull(System.getProperty("planmeter.fixtures")) { "planmeter.fixtures not set" }).also {
        check(it.isDirectory) { "Missing protocol fixtures at $it" }
    }

    private fun load(path: String): JsonObject = Json.parseToJsonElement(File(root, path).readText()).jsonObject

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.hex(key: String) = str(key).hexToBytes()

    private fun String.hexToBytes(): ByteArray {
        require(length % 2 == 0)
        return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    private val requestVectors = listOf(
        "chacha20poly1305-request", "aes-256-gcm-request", "chacha20poly1305-pair-request", "aes-256-gcm-pair-request",
    )

    @Test
    fun requestVectorsReproduceEveryIntermediate() {
        for (name in requestVectors) {
            val v = load("secure-channel/$name.json")
            val cipher = requireNotNull(SecureChannel.Cipher.fromWire(v.str("cipher")))
            val serverPrivate = P256.privateKey(v.hex("serverStaticPrivateKeyHex"))
            val serverPublic = v.hex("serverStaticPublicKeyHex")
            val ephemeral = KeyPair(P256.publicKey(v.hex("ephemeralPublicKeyHex")), P256.privateKey(v.hex("ephemeralPrivateKeyHex")))
            val signer = SoftwareSigner.fromRaw(v.hex("deviceSigningPrivateKeyHex"), v.hex("deviceSigningPublicKeyHex"))
            val nonce = v.hex("requestNonceHex")
            val deviceId = v.str("deviceId")
            val plaintext = v.str("plaintext").toByteArray(Charsets.UTF_8)
            val timestamp = v.getValue("timestamp").jsonPrimitive.long

            // ECDH from both sides, then HKDF.
            val secret = P256.sharedSecret(ephemeral.private, P256.publicKey(serverPublic))
            assertEquals(name, v.str("sharedSecretHex"), secret.hex())
            assertEquals(name, v.str("sharedSecretHex"), P256.sharedSecret(serverPrivate, ephemeral.public as java.security.interfaces.ECPublicKey).hex())
            val keys = SecureChannel.deriveKeys(secret, nonce, deviceId)
            assertEquals(name, "planmeter-remote-v1|$deviceId|request", v.str("requestKeyInfo"))
            assertEquals(name, v.str("requestKeyHex"), keys.request.hex())
            assertEquals(name, v.str("responseKeyHex"), keys.response.hex())

            val header = SecureChannel.header(deviceId, P256.x963(ephemeral.public as java.security.interfaces.ECPublicKey), nonce, timestamp, v.str("method"), v.str("path"), cipher)
            assertEquals(name, v.str("header"), header.toString(Charsets.UTF_8))
            assertEquals(name, v.str("headerBase64"), java.util.Base64.getEncoder().encodeToString(header))

            // Deterministic seal: everything but the (randomized) signature is byte-identical.
            val sealed = SecureChannel.seal(plaintext, serverPublic, deviceId, signer, v.str("method"), v.str("path"), cipher, Instant.ofEpochSecond(timestamp), ephemeral, nonce)
            assertEquals(name, v.str("ciphertextHex"), sealed.request.ciphertext.hex())
            assertEquals(name, v.str("ciphertextSha256Hex"), sha256(sealed.request.ciphertext).hex())
            assertEquals(name, v.str("signingInputHex"), SecureChannel.signingInput(header, sealed.request.ciphertext).hex())
            assertArrayEquals(name, keys.response, sealed.responseKey)
            val expectedBody = v.getValue("sealedRequest").jsonObject
            val ourBody = Json.parseToJsonElement(RemoteJson.encodeToString(SecureChannel.SealedRequest.serializer(), sealed.request)).jsonObject
            assertEquals(name, JsonObject(expectedBody - "signature"), JsonObject(ourBody - "signature"))
            assertTrue(name, SecureChannel.verifySignature(sealed.request, signer.publicKeyRaw, v.str("method"), v.str("path")))

            // The committed signature verifies, raw and inside the committed body.
            assertTrue(name, P256.verify(v.hex("signatureHex"), v.hex("signingInputHex"), signer.publicKeyRaw))
            val body = RemoteJson.decode(SecureChannel.SealedRequest.serializer(), expectedBody.toString().toByteArray())
            assertTrue(name, SecureChannel.verifySignature(body, signer.publicKeyRaw, v.str("method"), v.str("path")))
            SecureChannel.checkTimestamp(body, Instant.ofEpochSecond(timestamp))

            // Host side: open with the server key.
            val opened = SecureChannel.open(body, serverPrivate, v.str("method"), v.str("path"))
            assertArrayEquals(name, plaintext, opened.plaintext)
            assertArrayEquals(name, keys.response, opened.responseKey)
            assertEquals(name, cipher, opened.cipher)

            if (deviceId == RemoteClient.PAIRING_DEVICE_ID) {
                // Pairing: the signature verifies against the key inside the decrypted PairRequest.
                val pair = RemoteJson.decode(PairRequest.serializer(), opened.plaintext)
                assertArrayEquals(name, signer.publicKeyRaw, pair.devicePublicKey)
            } else {
                assertEquals(name, DeviceId.derive(signer.publicKeyRaw), deviceId)
                RemoteJson.decode(RemoteRequest.serializer(), opened.plaintext)
            }
        }
    }

    @Test
    fun clientEncodesTheRequestPlaintextsIdentically() {
        val chacha = load("secure-channel/chacha20poly1305-request.json")
        assertEquals(
            chacha.str("plaintext"),
            RemoteJson.encodeToString(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "hour")),
        )
        val aes = load("secure-channel/aes-256-gcm-request.json")
        assertEquals(aes.str("plaintext"), RemoteJson.encodeToString(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.SUMMARY, days = 7)))
    }

    @Test
    fun responseVectorsOpenAndReproduce() {
        for (name in listOf("chacha20poly1305-response", "aes-256-gcm-response", "chacha20poly1305-pair-response", "aes-256-gcm-pair-response")) {
            val v = load("secure-channel/$name.json")
            val cipher = requireNotNull(SecureChannel.Cipher.fromWire(v.str("cipher")))
            val key = v.hex("responseKeyHex")
            val plaintext = v.str("plaintext").toByteArray(Charsets.UTF_8)
            val body = RemoteJson.decode(SecureChannel.SealedResponse.serializer(), v.getValue("sealedResponse").toString().toByteArray())
            assertEquals(name, cipher, body.effectiveCipher)
            assertArrayEquals(name, plaintext, SecureChannel.openResponse(body, key))
            assertEquals(name, v.str("aadHex"), v.str("responseNonceHex"))

            val ours = SecureChannel.sealResponse(plaintext, key, cipher, v.hex("responseNonceHex"))
            assertEquals(name, v.str("ciphertextHex"), ours.ciphertext.hex())
            assertEquals(
                name,
                v.getValue("sealedResponse"),
                Json.parseToJsonElement(RemoteJson.encodeToString(SecureChannel.SealedResponse.serializer(), ours)),
            )
            // The decrypted body is a model this client reads.
            if (name.contains("pair")) RemoteJson.decode(PairResponse.serializer(), plaintext)
            else RemoteJson.decode(RemoteReply.serializer(), plaintext)
        }
    }

    @Test
    fun negativeVectors() {
        val file = load("secure-channel/negative.json")
        val serverPrivate = P256.privateKey(file.hex("serverStaticPrivateKeyHex"))
        val vectors = file.getValue("vectors").jsonArray.map { it.jsonObject }
        assertTrue(vectors.size >= 20)
        for (v in vectors) {
            val name = v.str("name")
            val expect = v.getValue("expect").jsonObject
            when (v.str("kind")) {
                "request" -> {
                    val body = RemoteJson.decode(SecureChannel.SealedRequest.serializer(), v.getValue("sealedRequest").toString().toByteArray())
                    val method = v.str("method")
                    val path = v.str("path")

                    val timestamp = outcome { SecureChannel.checkTimestamp(body, Instant.ofEpochSecond(v.getValue("now").jsonPrimitive.long)) }
                    assertEquals("$name checkTimestamp", expect.str("checkTimestamp"), timestamp.first)

                    val verified = SecureChannel.verifySignature(body, v.hex("devicePublicKeyHex"), method, path)
                    assertEquals("$name verifySignature", expect.getValue("verifySignature").jsonPrimitive.boolean, verified)

                    val (openResult, opened) = outcome { SecureChannel.open(body, serverPrivate, method, path) }
                    when (val want = expect.str("open")) {
                        "ok" -> {
                            assertEquals("$name open", "ok", openResult)
                            assertEquals("$name plaintext", expect.str("plaintext"), opened!!.plaintext.toString(Charsets.UTF_8))
                        }
                        "error" -> assertTrue("$name open should fail, got $openResult", openResult != "ok")
                        else -> assertEquals("$name open", want, openResult)
                    }
                }
                "response" -> {
                    val body = RemoteJson.decode(SecureChannel.SealedResponse.serializer(), v.getValue("sealedResponse").toString().toByteArray())
                    val (result, plaintext) = outcome { SecureChannel.openResponse(body, v.hex("responseKeyHex")) }
                    assertEquals("$name openResponse", expect.str("openResponse"), result)
                    if (result == "ok") assertEquals("$name plaintext", expect.str("plaintext"), plaintext!!.toString(Charsets.UTF_8))
                }
                else -> fail("Unknown kind in $name")
            }
        }
    }

    /** Runs [block] and names the outcome as the fixtures do. */
    private fun <T> outcome(block: () -> T): Pair<String, T?> = try {
        "ok" to block()
    } catch (e: ChannelException) {
        val label = when (e.error) {
            ChannelError.UNSUPPORTED_VERSION -> "unsupportedVersion"
            ChannelError.TIME_WINDOW -> "timeWindow"
            ChannelError.MALFORMED -> "malformed"
            ChannelError.DECRYPT_FAILED -> "decryptFailed"
            else -> e.error.name
        }
        label to null
    } catch (e: Exception) {
        "error" to null
    }

    @Test
    fun invites() {
        val file = load("pairing/invites.json")
        val valid = file.getValue("valid").jsonArray.map { it.jsonObject }
        val invalid = file.getValue("invalid").jsonArray.map { it.jsonObject }
        assertEquals(4, valid.size)
        assertEquals(15, invalid.size)
        for (case in valid) {
            val url = case.str("url")
            val expected = case.getValue("expected").jsonObject
            val invite = PairingInvite.parse(url)
            assertNotNull(url, invite)
            invite!!
            assertEquals(url, expected.str("serverHost"), invite.serverHost)
            assertEquals(url, expected.getValue("port").jsonPrimitive.int, invite.port)
            assertEquals(url, expected.str("serverName"), invite.serverName)
            assertEquals(url, expected.str("serverPublicKeyHex"), invite.serverPublicKey.hex())
            assertEquals(url, expected.str("token"), invite.token)
            assertEquals(url, expected.getValue("expiresAt").jsonPrimitive.long, invite.expiresAt.epochSecond)
        }
        for (case in invalid) assertNull("${case.str("reason")}: ${case.str("url")}", PairingInvite.parse(case.str("url")))
    }

    @Test
    fun deviceIds() {
        for (case in load("pairing/device-ids.json").getValue("vectors").jsonArray.map { it.jsonObject }) {
            val key = case.hex("publicKeyHex")
            assertEquals(case.str("sha256Hex"), sha256(key).hex())
            assertEquals(case.str("sha256Base64Url"), Base64Url.encode(sha256(key)))
            assertEquals(case.str("deviceId"), DeviceId.derive(key))
        }
    }

    @Test
    fun pairBodiesRoundTrip() {
        val request = File(root, "pairing/pair-request.json").readBytes()
        val decoded = RemoteJson.decode(PairRequest.serializer(), request)
        assertEquals(65, decoded.devicePublicKey.size)
        assertEquals(JsonTrees.normalize(request.toString(Charsets.UTF_8)), JsonTrees.normalize(RemoteJson.encodeToString(PairRequest.serializer(), decoded)))
        // It is the plaintext of the native pairing vector, byte for byte apart from formatting.
        val vector = load("secure-channel/chacha20poly1305-pair-request.json")
        assertEquals(JsonTrees.normalize(vector.str("plaintext")), JsonTrees.normalize(request.toString(Charsets.UTF_8)))

        val response = File(root, "pairing/pair-response.json").readBytes()
        val pairResponse = RemoteJson.decode(PairResponse.serializer(), response)
        assertEquals("0nfkgpQ6iVXlNxiZqqW0aF", pairResponse.deviceId)
    }

    @Test
    fun repliesDecodeAndReencode() {
        for (method in listOf("summary", "models", "timeline", "limits", "accounts", "error")) {
            val text = File(root, "replies/$method.json").readText()
            val reply = RemoteJson.decode(RemoteReply.serializer(), text.toByteArray())
            val element: JsonElement = Json.parseToJsonElement(text)
            assertEquals(method, setOf(method), element.jsonObject.keys)
            assertEquals(method, JsonTrees.normalize(text), JsonTrees.normalize(RemoteJson.encodeToString(RemoteReply.serializer(), reply)))
        }
        val timeline = RemoteJson.decode(RemoteReply.serializer(), File(root, "replies/timeline.json").readBytes()).timeline!!
        assertEquals("5m", timeline.resolution)
        assertEquals(60, timeline.minutes)
        assertTrue(timeline.points.any { it.baselineCostUsd != null })
        assertEquals("server not ready", RemoteJson.decode(RemoteReply.serializer(), File(root, "replies/error.json").readBytes()).error)
    }
}
