package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.Serializable
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Checks the Kotlin implementation against data produced by the Swift
 * PlanMeterRemote module (android/interop/swift, `planmeter-interop vectors`):
 * Swift-sealed requests must open and verify here, keys must derive to the
 * same bytes, Swift-sealed responses must open, CryptoKit signatures must
 * verify, and pairing links must parse exactly as `PairingInvite(url:)` does.
 */
class SwiftVectorsTest {
    @Serializable
    class SealCase(
        val name: String,
        val method: String,
        val path: String,
        val deviceId: String,
        val cipher: String,
        val requestPlaintext: WireData,
        val sealedRequest: String,
        val responseKey: WireData,
        val responsePlaintext: WireData,
        val sealedResponse: String,
    )

    @Serializable
    class SignatureCase(val message: WireData, val signature: WireData)

    @Serializable
    class PairingUrlCase(
        val url: String,
        val valid: Boolean,
        val serverHost: String? = null,
        val port: Int? = null,
        val serverName: String? = null,
        val serverPublicKey: WireData? = null,
        val token: String? = null,
        val expiresAt: Long? = null,
    )

    @Serializable
    class Vectors(
        val serverPrivateKey: WireData,
        val serverPublicKey: WireData,
        val devicePrivateKey: WireData,
        val devicePublicKey: WireData,
        val deviceId: String,
        val seals: List<SealCase>,
        val signatures: List<SignatureCase>,
        val pairingURLs: List<PairingUrlCase>,
        val replies: Map<String, String>,
    )

    private val vectors: Vectors by lazy {
        val bytes = requireNotNull(javaClass.getResourceAsStream("/interop/swift-vectors.json")).use { it.readBytes() }
        RemoteJson.decode(Vectors.serializer(), bytes)
    }

    @Test
    fun keysMatchTheirPublicHalves() {
        val server = P256.privateKey(vectors.serverPrivateKey)
        val probe = P256.generateKeyPair()
        val probePublic = probe.public as java.security.interfaces.ECPublicKey
        // ECDH with the raw private scalar must agree with ECDH against the X9.63 public key.
        assertArrayEquals(
            P256.sharedSecret(server, probePublic),
            P256.sharedSecret(probe.private, P256.publicKey(vectors.serverPublicKey)),
        )
        assertEquals(vectors.deviceId, DeviceId.derive(vectors.devicePublicKey))
    }

    @Test
    fun swiftSealedRequestsOpenAndVerify() {
        val serverKey = P256.privateKey(vectors.serverPrivateKey)
        assertEquals(5, vectors.seals.size)
        for (case in vectors.seals) {
            val request = RemoteJson.decode(SecureChannel.SealedRequest.serializer(), case.sealedRequest.toByteArray())
            assertEquals(case.name, case.cipher, request.effectiveCipher.wireName)
            assertEquals(case.name, case.deviceId, request.deviceId)
            SecureChannel.checkTimestamp(request, Instant.ofEpochSecond(request.timestamp + 30))
            assertTrue(case.name, SecureChannel.verifySignature(request, vectors.devicePublicKey, case.method, case.path))
            assertFalse(case.name, SecureChannel.verifySignature(request, vectors.devicePublicKey, case.method, "/v1/other"))
            val opened = SecureChannel.open(request, serverKey, case.method, case.path)
            assertArrayEquals(case.name, case.requestPlaintext, opened.plaintext)
            // HKDF output is byte-identical to CryptoKit's.
            assertArrayEquals(case.name, case.responseKey, opened.responseKey)

            val response = RemoteJson.decode(SecureChannel.SealedResponse.serializer(), case.sealedResponse.toByteArray())
            assertArrayEquals(case.name, case.responsePlaintext, SecureChannel.openResponse(response, opened.responseKey))

            // And a Kotlin-sealed response under the same key opens with the same code path.
            val kotlinResponse = SecureChannel.sealResponse(case.responsePlaintext, opened.responseKey, opened.cipher)
            assertArrayEquals(case.responsePlaintext, SecureChannel.openResponse(kotlinResponse, case.responseKey))
        }
    }

    @Test
    fun swiftPlaintextsDecode() {
        val rpc = vectors.seals.first { it.name == "rpc-chacha20poly1305" }
        assertEquals(
            RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "minute", minutes = 60),
            RemoteJson.decode(RemoteRequest.serializer(), rpc.requestPlaintext),
        )
        // Kotlin encodes the same request to the same bytes (sorted keys, nils omitted).
        assertEquals(
            rpc.requestPlaintext.toString(Charsets.UTF_8),
            RemoteJson.encodeToString(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "minute", minutes = 60)),
        )
        val pair = vectors.seals.first { it.name == "pair-chacha20poly1305" }
        val pairRequest = RemoteJson.decode(PairRequest.serializer(), pair.requestPlaintext)
        assertEquals("tok_-123", pairRequest.token)
        assertArrayEquals(vectors.devicePublicKey, pairRequest.devicePublicKey)
        val pairResponse = RemoteJson.decode(PairResponse.serializer(), pair.responsePlaintext)
        assertEquals(vectors.deviceId, pairResponse.deviceId)
        assertEquals("Interop Host ✓", pairResponse.serverName)
    }

    @Test
    fun cryptoKitSignaturesVerify() {
        assertEquals(64, vectors.signatures.size)
        for (case in vectors.signatures) {
            assertEquals(64, case.signature.size)
            assertTrue(P256.verify(case.signature, case.message, vectors.devicePublicKey))
            // Round-trips through DER unchanged.
            assertArrayEquals(case.signature, EcdsaSignature.derToRaw(EcdsaSignature.rawToDer(case.signature)))
            val tampered = case.message.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
            assertFalse(P256.verify(case.signature, tampered, vectors.devicePublicKey))
        }
    }

    @Test
    fun pairingLinksParseLikeSwift() {
        assertTrue(vectors.pairingURLs.size > 20)
        for (case in vectors.pairingURLs) {
            val parsed = PairingInvite.parse(case.url)
            if (!case.valid) {
                assertNull(case.url, parsed)
                continue
            }
            assertNotNull(case.url, parsed)
            parsed!!
            assertEquals(case.url, case.serverHost, parsed.serverHost)
            assertEquals(case.url, case.port, parsed.port)
            assertEquals(case.url, case.serverName, parsed.serverName)
            assertArrayEquals(case.url, case.serverPublicKey, parsed.serverPublicKey)
            assertEquals(case.url, case.token, parsed.token)
            assertEquals(case.url, case.expiresAt, parsed.expiresAt.epochSecond)
        }
    }

    @Test
    fun swiftRepliesDecode() {
        val summary = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("summary").toByteArray()).summary!!
        assertEquals(7, summary.days)
        assertEquals(Instant.parse("2026-10-19T12:00:00Z"), summary.generatedAt)
        assertEquals("Interop Host ✓", summary.serverName)
        assertEquals(3_400_000_000L, summary.groups.first { it.group == "personal" }.totals.tokens)
        assertEquals(true, summary.usesProviderDates)
        assertNull(summary.minutes)

        val timeline = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("timeline").toByteArray()).timeline!!
        assertEquals("hour", timeline.resolution)
        assertEquals(3, timeline.periods.size)
        assertEquals(0.5, timeline.points[1].baselineCostUsd!!, 0.0)
        assertNull(timeline.points[0].baselineCostUsd)
        assertEquals("#10a37f", timeline.accounts[0].accentColorHex)

        val limits = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("limits").toByteArray()).limits!!
        assertEquals(91.0, limits.accounts[0].windows[1].usedPercent, 0.0)
        assertEquals(Instant.parse("2026-10-19T13:00:00Z"), limits.accounts[0].windows[0].resetsAt)

        val models = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("models").toByteArray()).models!!
        assertEquals(listOf(true, true, false), models.map { it.priced })

        val accounts = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("accounts").toByteArray()).accounts!!
        assertEquals("/Users/me/.codex/sessions", accounts.sources[0].path) // Swift escapes "/" as "\/".

        val error = RemoteJson.decode(RemoteReply.serializer(), vectors.replies.getValue("error").toByteArray())
        assertEquals("server not ready", error.error)

        val info = RemoteJson.decode(ServerInfo.serializer(), vectors.replies.getValue("info").toByteArray())
        assertEquals(ServerInfo(version = "interop-1", serverName = "Interop Host ✓"), info)

        // Re-encoding a decoded reply yields the same JSON tree (numbers compared as values).
        for ((method, text) in vectors.replies) {
            if (method == "info") continue
            val decoded = RemoteJson.decode(RemoteReply.serializer(), text.toByteArray())
            val reencoded = RemoteJson.encodeToString(RemoteReply.serializer(), decoded)
            assertEquals(method, JsonTrees.normalize(text), JsonTrees.normalize(reencoded))
        }
    }
}
