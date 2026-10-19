package com.neilgoldader.planmeter.protocol

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.security.interfaces.ECPublicKey
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

/**
 * A Kotlin port of RemoteState's pairing and RPC handlers, for end-to-end tests
 * of [RemoteClient] on the JVM. Not used by the app.
 */
class TestHost(
    private val reply: (RemoteRequest) -> RemoteReply = { RemoteReply(error = "no data") },
) : AutoCloseable {
    private val keyPair = P256.generateKeyPair()
    val publicKeyRaw: ByteArray = P256.x963(keyPair.public as ECPublicKey)
    val serverName = "Test Host"
    var token = "test-token"
    var inviteExpiresAt: Instant = Instant.now().plusSeconds(300)
    var inviteActive = true
    val devices = ConcurrentHashMap<String, ByteArray>()
    private val seen = ConcurrentHashMap.newKeySet<String>()
    val requests = mutableListOf<RemoteRequest>()

    private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
        createContext("/") { exchange ->
            val body = exchange.requestBody.readBytes()
            val (status, response) = handle(exchange.requestMethod, exchange.requestURI.path, body)
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.sendResponseHeaders(status, response.size.toLong())
            exchange.responseBody.use { it.write(response) }
        }
        start()
    }

    val port: Int get() = server.address.port

    fun invite(host: String = "127.0.0.1"): PairingInvite =
        PairingInvite(host, port, serverName, publicKeyRaw, token, inviteExpiresAt)

    private fun error(status: Int, message: String) = status to """{"error":"$message"}""".toByteArray()

    @Synchronized
    fun handle(method: String, path: String, body: ByteArray): Pair<Int, ByteArray> = when {
        method == "GET" && path == RemoteClient.INFO_PATH ->
            200 to RemoteJson.encode(ServerInfo.serializer(), ServerInfo(version = "test", serverName = serverName))
        method == "POST" && path == RemoteClient.PAIR_PATH -> pair(body)
        method == "POST" && path == RemoteClient.RPC_PATH -> rpc(body)
        else -> error(404, "not found")
    }

    private fun decodeSealed(body: ByteArray): SecureChannel.SealedRequest? = try {
        RemoteJson.decode(SecureChannel.SealedRequest.serializer(), body).also { SecureChannel.checkTimestamp(it) }
    } catch (_: Exception) {
        null
    }

    private fun pair(body: ByteArray): Pair<Int, ByteArray> {
        val sealed = decodeSealed(body)?.takeIf { it.deviceId == "pairing" } ?: return error(400, "bad pairing request")
        if (!inviteActive || Instant.now().isAfter(inviteExpiresAt)) return error(403, "no active pairing code")
        if (!seen.add("pairing:" + java.util.Base64.getEncoder().encodeToString(sealed.nonce))) return error(409, "replay")
        val opened: SecureChannel.Opened
        val request: PairRequest
        try {
            opened = SecureChannel.open(sealed, keyPair.private, "POST", RemoteClient.PAIR_PATH)
            request = RemoteJson.decode(PairRequest.serializer(), opened.plaintext)
        } catch (_: Exception) {
            return error(403, "pairing rejected")
        }
        if (request.devicePublicKey.size != 65 ||
            !SecureChannel.verifySignature(sealed, request.devicePublicKey, "POST", RemoteClient.PAIR_PATH)
        ) return error(403, "pairing rejected")
        if (request.token != token) return error(403, "pairing rejected")
        val id = DeviceId.derive(request.devicePublicKey)
        devices[id] = request.devicePublicKey
        inviteActive = false
        val response = PairResponse(id, serverName, "test")
        return 200 to RemoteJson.encode(
            SecureChannel.SealedResponse.serializer(),
            SecureChannel.sealResponse(RemoteJson.encode(PairResponse.serializer(), response), opened.responseKey, opened.cipher),
        )
    }

    private fun rpc(body: ByteArray): Pair<Int, ByteArray> {
        val sealed = decodeSealed(body) ?: return error(400, "bad request")
        val key = devices[sealed.deviceId] ?: return error(401, "unknown device")
        if (!SecureChannel.verifySignature(sealed, key, "POST", RemoteClient.RPC_PATH)) return error(401, "signature failed")
        if (!seen.add(sealed.deviceId + ":" + java.util.Base64.getEncoder().encodeToString(sealed.nonce))) return error(409, "replay")
        val opened = try {
            SecureChannel.open(sealed, keyPair.private, "POST", RemoteClient.RPC_PATH)
        } catch (_: Exception) {
            return error(400, "undecryptable request")
        }
        val request = RemoteJson.decode(RemoteRequest.serializer(), opened.plaintext)
        requests += request
        val plaintext = RemoteJson.encode(RemoteReply.serializer(), reply(request))
        return 200 to RemoteJson.encode(
            SecureChannel.SealedResponse.serializer(),
            SecureChannel.sealResponse(plaintext, opened.responseKey, opened.cipher),
        )
    }

    override fun close() = server.stop(0)
}
