package com.neilgoldader.planmeter.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Instant

class RemoteClientTest {
    private val now: Instant = Instant.parse("2026-10-19T12:00:00Z")

    private fun summary(request: RemoteRequest) = RemoteReply(
        summary = RemoteSummary(
            days = request.days ?: 30,
            from = now.minusSeconds(86_400),
            to = now,
            groups = emptyList(),
            total = RemoteTotals(costUsd = 1.5),
            todayCostUsd = 0.5,
            generatedAt = now,
            serverName = "Test Host",
            pricingSource = "litellm",
            minutes = request.minutes,
        ),
    )

    @Test
    fun pairsAndCalls() {
        TestHost(::summary).use { host ->
            val signer = SoftwareSigner()
            val server = RemoteClient.pair(host.invite(), "Pixel", "Android 17", signer)
            assertEquals(DeviceId.derive(signer.publicKeyRaw), server.deviceId)
            assertEquals("Test Host", server.serverName)
            assertArrayEquals(host.publicKeyRaw, server.serverPublicKey)

            val client = RemoteClient(server, signer)
            val reply = client.call(RemoteRequest(RemoteMethod.SUMMARY, days = 1, minutes = 60))
            assertEquals(60, reply.summary!!.minutes)
            assertEquals(1.5, reply.summary.total.costUsd, 0.0)
            assertEquals(RemoteRequest(RemoteMethod.SUMMARY, days = 1, minutes = 60), host.requests.single())

            repeat(25) { client.call(RemoteRequest(RemoteMethod.SUMMARY, days = it + 1)) }
            assertEquals(26, host.requests.size)
        }
    }

    @Test
    fun infoIsUnauthenticated() {
        TestHost().use { host ->
            val info = RemoteClient.info("127.0.0.1", host.port)
            assertEquals("planmeter", info.app)
            assertEquals(1, info.protocolVersion)
        }
    }

    @Test
    fun replyErrorsSurfaceAsHttp200() {
        TestHost { RemoteReply(error = "server not ready") }.use { host ->
            val signer = SoftwareSigner()
            val client = RemoteClient(RemoteClient.pair(host.invite(), "Pixel", "Android", signer), signer)
            val e = expect<RemoteClientException.Http> { client.call(RemoteRequest(RemoteMethod.LIMITS)) }
            assertEquals(200, e.status)
            assertEquals("server not ready", e.message)
        }
    }

    @Test
    fun wrongTokenIsRejected() {
        TestHost().use { host ->
            val invite = host.invite()
            host.token = "something-else"
            val e = expect<RemoteClientException.Http> { RemoteClient.pair(invite, "Pixel", "Android", SoftwareSigner()) }
            assertEquals(403, e.status)
            assertEquals("pairing rejected", e.message)
        }
    }

    @Test
    fun usedInviteIsRejected() {
        TestHost().use { host ->
            RemoteClient.pair(host.invite(), "Pixel", "Android", SoftwareSigner())
            val e = expect<RemoteClientException.Http> { RemoteClient.pair(host.invite(), "Pixel 2", "Android", SoftwareSigner()) }
            assertEquals(403, e.status)
            assertEquals("no active pairing code", e.message)
        }
    }

    @Test
    fun expiredInviteFailsBeforeAnyRequest() {
        TestHost().use { host ->
            host.inviteExpiresAt = Instant.now().minusSeconds(1)
            expect<RemoteClientException.InviteExpired> { RemoteClient.pair(host.invite(), "Pixel", "Android", SoftwareSigner()) }
        }
    }

    @Test
    fun revokedDeviceGets401() {
        TestHost(::summary).use { host ->
            val signer = SoftwareSigner()
            val server = RemoteClient.pair(host.invite(), "Pixel", "Android", signer)
            host.devices.clear()
            val e = expect<RemoteClientException.Http> { RemoteClient(server, signer).call(RemoteRequest(RemoteMethod.SUMMARY)) }
            assertEquals(401, e.status)
            assertEquals("unknown device", e.message)
        }
    }

    @Test
    fun wrongSignerGets401() {
        TestHost(::summary).use { host ->
            val server = RemoteClient.pair(host.invite(), "Pixel", "Android", SoftwareSigner())
            val e = expect<RemoteClientException.Http> { RemoteClient(server, SoftwareSigner()).call(RemoteRequest(RemoteMethod.SUMMARY)) }
            assertEquals(401, e.status)
        }
    }

    @Test
    fun pinnedKeyMismatchCannotOpenReplies() {
        TestHost(::summary).use { host ->
            val signer = SoftwareSigner()
            val server = RemoteClient.pair(host.invite(), "Pixel", "Android", signer)
            // A different server key: the host cannot decrypt, so it rejects the request.
            val other = P256.x963(P256.generateKeyPair().public as java.security.interfaces.ECPublicKey)
            val impostor = PairedServer(server.host, server.port, server.serverName, other, server.deviceId, server.pairedAt)
            val e = expect<RemoteClientException.Http> { RemoteClient(impostor, signer).call(RemoteRequest(RemoteMethod.SUMMARY)) }
            assertEquals(400, e.status)
        }
    }

    @Test
    fun closedPortIsUnreachable() {
        val port = ServerSocket(0).use { it.localPort }
        val invite = PairingInvite("127.0.0.1", port, "Nobody", P256.x963(P256.generateKeyPair().public as java.security.interfaces.ECPublicKey), "t", Instant.now().plusSeconds(60))
        val e = expect<RemoteClientException.Transport> { RemoteClient.pair(invite, "Pixel", "Android", SoftwareSigner()) }
        assertEquals(RemoteClientException.Transport.Kind.UNREACHABLE, e.kind)
    }

    @Test
    fun tailnetPolicy() {
        val resolver = { host: String -> listOf(InetAddress.getByName(host)) }
        val strict = HostPolicy.tailnetOnly(resolver = resolver)
        strict.check("100.64.0.7")
        strict.check("100.127.255.254")
        strict.check("fd7a:115c:a1e0::1")
        strict.check("[fd7a:115c:a1e0:ab12::1]")
        for (host in listOf("100.63.255.255", "100.128.0.1", "10.0.2.2", "127.0.0.1", "192.168.1.10", "fd7a:115c:a1e1::1")) {
            val e = expect<RemoteClientException.Transport> { strict.check(host) }
            assertEquals(host, RemoteClientException.Transport.Kind.NOT_TAILNET, e.kind)
        }
        val dev = HostPolicy.tailnetOnly(allowLoopback = true, resolver = resolver)
        dev.check("127.0.0.1")
        dev.check("10.0.2.2")
        // A MagicDNS name is fine as long as it resolves into the tailnet.
        HostPolicy.tailnetOnly { listOf(InetAddress.getByName("100.101.102.103")) }.check("devbox.tail1234.ts.net")
        val e = expect<RemoteClientException.Transport> {
            HostPolicy.tailnetOnly { throw java.net.UnknownHostException(it) }.check("devbox.tail1234.ts.net")
        }
        assertEquals(RemoteClientException.Transport.Kind.UNREACHABLE, e.kind)
    }

    @Test
    fun tailnetPolicyRefusesHostsThatWouldBendTheUrl() {
        // The resolver would vouch for anything; the host's shape is checked first.
        val policy = HostPolicy.tailnetOnly { listOf(InetAddress.getByName("100.101.102.103")) }
        policy.check("devbox.tail1234.ts.net")
        policy.check("devbox.tail1234.ts.net.")
        policy.check("100.101.102.103")
        for (host in listOf(
            "evil.example@100.101.102.103", "100.101.102.103/x", "100.101.102.103#", "100.101.102.103?a",
            "devbox:80", "dev box", "", "-devbox", "devbox..ts.net", "[devbox]", "fd7a:115c:a1e0::1%wlan0", "100.101.102.103\\x",
        )) {
            val e = expect<RemoteClientException.Transport> { policy.check(host) }
            assertEquals(host, RemoteClientException.Transport.Kind.NOT_TAILNET, e.kind)
        }
    }

    @Test
    fun ipv6HostsAreBracketed() {
        val server = PairedServer("fd7a:115c:a1e0::1", 7787, "Mac", ByteArray(65), "id", now)
        assertEquals("http://[fd7a:115c:a1e0::1]:7787", server.baseUrl)
        assertEquals("http://devbox.tail1234.ts.net:7787", PairedServer("devbox.tail1234.ts.net", 7787, "Mac", ByteArray(65), "id", now).baseUrl)
    }

    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try {
            block()
        } catch (t: Throwable) {
            if (t is T) return t
            throw AssertionError("Expected ${T::class.simpleName}, got $t", t)
        }
        fail("Expected ${T::class.simpleName}")
        throw IllegalStateException()
    }
}
