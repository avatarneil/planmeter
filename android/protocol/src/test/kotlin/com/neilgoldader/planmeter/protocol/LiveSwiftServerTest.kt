package com.neilgoldader.planmeter.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.time.Instant

/**
 * End-to-end against the Swift host in android/interop/swift (`serve`), which
 * handles requests with the real PlanMeterRemote SecureChannel exactly as the
 * Mac's RemoteState does. Skipped unless PLANMETER_INTEROP_PAIR_URL is set; see
 * android/interop/README.md.
 */
class LiveSwiftServerTest {
    @Test
    fun pairsAndCallsEveryMethod() {
        val url = System.getProperty("planmeter.interop.pairUrl")
        assumeTrue("PLANMETER_INTEROP_PAIR_URL not set", !url.isNullOrBlank())
        val invite = requireNotNull(PairingInvite.parse(url!!)) { "Unreadable pairing link: $url" }
        val signer = SoftwareSigner()
        val server = RemoteClient.pair(invite, "Kotlin JVM", "JVM ${System.getProperty("java.version")}", signer)
        assertEquals(DeviceId.derive(signer.publicKeyRaw), server.deviceId)
        assertEquals("Interop Host ✓", server.serverName)

        val client = RemoteClient(server, signer)
        val summary = client.call(RemoteRequest(RemoteMethod.SUMMARY, days = 1, minutes = 60)).summary!!
        assertEquals(60, summary.minutes) // Swift decoded our request's optional fields.
        assertEquals(1, summary.days)
        assertEquals(Instant.parse("2026-10-19T12:00:00Z"), summary.generatedAt)
        assertEquals(Instant.parse("2026-10-19T11:00:00Z"), summary.from)
        assertEquals(3_421_000_000L, summary.total.tokens)
        assertEquals(92.75, summary.total.costUsd, 1e-9)

        val timeline = client.call(RemoteRequest(RemoteMethod.TIMELINE, days = 7, resolution = "15m")).timeline!!
        assertEquals("15m", timeline.resolution)
        assertEquals(7, timeline.days)
        assertEquals(900, timeline.periods[1].epochSecond - timeline.periods[0].epochSecond)

        val limits = client.call(RemoteRequest(RemoteMethod.LIMITS)).limits!!
        assertEquals(42.5, limits.accounts.single().windows[0].usedPercent, 0.0)

        val models = client.call(RemoteRequest(RemoteMethod.MODELS, days = 30, account = "claude-work")).models!!
        assertEquals(listOf("claude-opus-4-1"), models.map { it.model })

        val accounts = client.call(RemoteRequest(RemoteMethod.ACCOUNTS)).accounts!!
        assertEquals("/Users/me/.codex/sessions", accounts.sources[0].path)

        // Many more signed requests, so random signatures with short r or s are exercised.
        repeat(200) { client.call(RemoteRequest(RemoteMethod.SUMMARY, days = it % 90 + 1)) }

        // The web client's AES-256-GCM variant, sealed by Kotlin, opened by Swift.
        repeat(20) {
            val body = RemoteJson.encode(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.LIMITS))
            val sealed = SecureChannel.seal(body, server.serverPublicKey, server.deviceId, signer, "POST", RemoteClient.RPC_PATH, SecureChannel.Cipher.AES_256_GCM)
            val reply = rawPost(server.baseUrl + RemoteClient.RPC_PATH, RemoteJson.encode(SecureChannel.SealedRequest.serializer(), sealed.request))
            val envelope = RemoteJson.decode(SecureChannel.SealedResponse.serializer(), reply)
            assertEquals(SecureChannel.Cipher.AES_256_GCM, envelope.cipher)
            val opened = RemoteJson.decode(RemoteReply.serializer(), SecureChannel.openResponse(envelope, sealed.responseKey))
            assertTrue(opened.limits != null)
        }

        // A second pairing attempt with the consumed invite is refused, like the Mac.
        val e = runCatching { RemoteClient.pair(invite, "Again", "JVM", SoftwareSigner()) }.exceptionOrNull()
        assertTrue("$e", e is RemoteClientException.Http && e.status == 403)
    }

    private fun rawPost(url: String, body: ByteArray): ByteArray {
        val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.outputStream.use { it.write(body) }
        assertEquals(200, connection.responseCode)
        return connection.inputStream.use { it.readBytes() }
    }
}
