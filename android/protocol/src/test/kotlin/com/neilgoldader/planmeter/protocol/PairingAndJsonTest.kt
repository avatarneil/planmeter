package com.neilgoldader.planmeter.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.interfaces.ECPublicKey
import java.time.Instant
import java.time.ZoneId

class PairingAndJsonTest {
    private val key = P256.x963(P256.generateKeyPair().public as ECPublicKey)

    @Test
    fun inviteUrlRoundTrips() {
        val invite = PairingInvite("devbox.tail1234.ts.net", 7787, "Neil’s Mac & Co = 1", key, "a-b_c", Instant.ofEpochSecond(1792411500))
        val url = invite.toUrl()
        assertTrue(url.startsWith("planmeter://pair?h=devbox.tail1234.ts.net&p=7787&n=Neil%E2%80%99s%20Mac%20%26%20Co%20%3D%201&k="))
        assertEquals(invite, PairingInvite.parse(url))
        assertEquals(invite, PairingInvite.parse("  $url\n"))
    }

    @Test
    fun inviteSchemeIsCaseInsensitive() {
        val url = PairingInvite("h", 1, "n", key, "t", Instant.EPOCH).toUrl()
        assertEquals("h", PairingInvite.parse(url.replace("planmeter://pair", "PlanMeter://PAIR"))?.serverHost)
    }

    @Test
    fun extremeExpiriesParseInsteadOfThrowing() {
        val url = PairingInvite("h", 7787, "n", key, "t", Instant.ofEpochSecond(1792411500)).toUrl()
        val far = PairingInvite.parse(url.replace("e=1792411500", "e=${Long.MAX_VALUE}"))
        assertEquals(Instant.MAX, far?.expiresAt)
        assertFalse(far!!.isExpired())
        val past = PairingInvite.parse(url.replace("e=1792411500", "e=${Long.MIN_VALUE}"))
        assertEquals(Instant.MIN, past?.expiresAt)
        assertTrue(past!!.isExpired())
        assertNull(PairingInvite.parse(url.replace("e=1792411500", "e=9223372036854775808")))
    }

    @Test
    fun invalidPercentEscapesAreRejected() {
        val url = PairingInvite("h", 1, "n", key, "t", Instant.EPOCH).toUrl()
        assertNull(PairingInvite.parse(url.replace("n=n", "n=%G1")))
        assertNull(PairingInvite.parse(url.replace("n=n", "n=%E2%80")))
        assertNull(PairingInvite.parse(url.replace("n=n", "n=%4")))
    }

    @Test
    fun deviceIdIs22Base64UrlCharacters() {
        val id = DeviceId.derive(key)
        assertEquals(22, id.length)
        assertTrue(id.all { it.isLetterOrDigit() || it == '-' || it == '_' })
    }

    @Test
    fun datesEncodeLikeSwiftAndDecodeTolerantly() {
        assertEquals("2026-10-19T12:00:00Z", Iso8601.format(Instant.parse("2026-10-19T12:00:00.987Z")))
        assertEquals(Instant.parse("2026-10-19T12:00:00Z"), Iso8601.parse("2026-10-19T12:00:00Z"))
        assertEquals(Instant.parse("2026-10-19T12:00:00.250Z"), Iso8601.parse("2026-10-19T12:00:00.25Z"))
        assertEquals(Instant.parse("2026-10-19T10:00:00Z"), Iso8601.parse("2026-10-19T12:00:00+02:00"))
        assertNull(Iso8601.parse("yesterday"))
    }

    @Test
    fun requestsEncodeWithSortedKeysAndNoNulls() {
        assertEquals("""{"method":"limits"}""", RemoteJson.encodeToString(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.LIMITS)))
        assertEquals(
            """{"account":"a","days":7,"method":"models"}""",
            RemoteJson.encodeToString(RemoteRequest.serializer(), RemoteRequest(RemoteMethod.MODELS, days = 7, account = "a")),
        )
        val pair = PairRequest("t", "Pixel", byteArrayOf(1, 2, 3, -1), "Android")
        assertEquals(
            """{"deviceName":"Pixel","devicePublicKey":"AQID/w==","platform":"Android","token":"t"}""",
            RemoteJson.encodeToString(PairRequest.serializer(), pair),
        )
    }

    @Test
    fun pairedServerPersistsAsJson() {
        val server = PairedServer("100.64.0.7", 7787, "Mac", key, "dev", Instant.parse("2026-10-19T12:00:00Z"))
        val json = RemoteJson.encodeToString(PairedServer.serializer(), server)
        assertTrue(json.contains("\"pairedAt\":\"2026-10-19T12:00:00Z\""))
        val back = RemoteJson.decode(PairedServer.serializer(), json.toByteArray())
        assertEquals(server, back)
        assertArrayEquals(key, back.serverPublicKey)
        assertEquals(16, back.serverKeyFingerprint.length)
    }

    @Test
    fun unknownFieldsAreIgnored() {
        val json = """{"error":"x","future":{"a":1}}"""
        assertEquals("x", RemoteJson.decode(RemoteReply.serializer(), json.toByteArray()).error)
    }

    @Test
    fun rebucketsFineTimelines() {
        val accounts = listOf(RemoteAccount("a", "A", "codex", "Codex", "personal"), RemoteAccount("b", "B", "claude", "Claude", "work"))
        val base = Instant.parse("2026-10-19T12:00:00Z")
        val periods = (0 until 6).map { base.plusSeconds(it * 300L) }
        val timeline = RemoteTimeline(
            days = 1,
            resolution = "5m",
            periods = periods,
            points = listOf(
                RemoteTimelinePoint(periods[0], "a", 1.0, 10),
                RemoteTimelinePoint(periods[1], "a", 2.0, 20, baselineCostUsd = 0.5),
                RemoteTimelinePoint(periods[4], "b", 4.0, 40),
            ),
            accounts = accounts,
        )
        val quarter = timeline.rebucketed("15m")!!
        assertEquals("15m", quarter.resolution)
        assertEquals(listOf(base, base.plusSeconds(900)), quarter.periods)
        assertEquals(3.0, quarter.points[0].costUsd, 0.0)
        assertEquals(30, quarter.points[0].tokens)
        assertEquals(0.5, quarter.points[0].baselineCostUsd!!, 0.0)
        assertEquals("b", quarter.points[1].accountId)
        assertNull(timeline.rebucketed("day"))
        assertNull(quarter.rebucketed("5m"))
        assertTrue(RemoteTimeline.coarsens("minute", "15m"))
        assertTrue(!RemoteTimeline.coarsens("15m", "15m"))

        val utc = ZoneId.of("UTC")
        val bars = timeline.groupBars(zone = utc)
        assertEquals(6, bars.size)
        assertEquals(2.0, bars[1].costs["personal"]!!, 0.0)
        assertEquals(0.5, bars[1].baselines["personal"]!!, 0.0)
        assertEquals(mapOf("personal" to 3.0, "work" to 4.0), timeline.costByGroup(base, utc))
        assertEquals(emptyMap<String, Double>(), timeline.costByGroup(base.minusSeconds(86_400), utc))
    }
}
