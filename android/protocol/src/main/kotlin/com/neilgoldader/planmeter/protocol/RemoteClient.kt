package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.time.Instant

sealed class RemoteClientException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** A non-200 status, or a 200 reply carrying `error`. [serverMessage] is the server's `error` text. */
    class Http(val status: Int, val serverMessage: String) :
        RemoteClientException(serverMessage.ifEmpty { "Server returned HTTP $status." })

    class Transport(val kind: Kind, message: String, cause: Throwable? = null) : RemoteClientException(message, cause) {
        enum class Kind {
            /** Nothing answered: DNS failure, refused, no route, or connect timeout. */
            UNREACHABLE,
            /** Connected, but the reply did not arrive in time. */
            TIMEOUT,
            /** The address is outside the tailnet ranges this client is allowed to use. */
            NOT_TAILNET,
            OTHER,
        }
    }

    class MalformedReply(cause: Throwable? = null) : RemoteClientException("Unreadable reply from server.", cause)

    class InviteExpired : RemoteClientException("This pairing code has expired. Make a new one on the Mac.")

    class Channel(val error: ChannelError, cause: Throwable? = null) : RemoteClientException(error.description, cause)
}

/** Which hosts the client may send (cleartext HTTP, end-to-end encrypted) requests to. */
fun interface HostPolicy {
    /** Throws [RemoteClientException.Transport] when [host] must not be contacted. */
    fun check(host: String)

    companion object {
        val ANY = HostPolicy { }

        /**
         * Only Tailscale addresses: every address [host] resolves to must be in
         * 100.64.0.0/10 or fd7a:115c:a1e0::/48. [allowLoopback] additionally
         * admits loopback and the emulator's host alias 10.0.2.2, for development.
         */
        fun tailnetOnly(allowLoopback: Boolean = false, resolver: (String) -> List<InetAddress> = { InetAddress.getAllByName(it).toList() }) =
            HostPolicy { host ->
                val bare = host.removePrefix("[").removeSuffix("]")
                val addresses = try {
                    resolver(bare)
                } catch (e: UnknownHostException) {
                    throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "Could not find $bare.", e)
                }
                val allowed = addresses.isNotEmpty() && addresses.all {
                    Tailnet.isTailnetAddress(it) || (allowLoopback && (it.isLoopbackAddress || it.hostAddress == "10.0.2.2"))
                }
                if (!allowed) {
                    throw RemoteClientException.Transport(
                        RemoteClientException.Transport.Kind.NOT_TAILNET,
                        "$bare is not a Tailscale address.",
                    )
                }
            }
    }
}

object Tailnet {
    /** 100.64.0.0/10 (Tailscale's CGNAT range) or fd7a:115c:a1e0::/48 (its IPv6 ULA). */
    fun isTailnetAddress(address: InetAddress): Boolean {
        val b = address.address
        return when (b.size) {
            4 -> (b[0].toInt() and 0xFF) == 100 && (b[1].toInt() and 0xC0) == 0x40
            16 -> b[0] == 0xfd.toByte() && b[1] == 0x7a.toByte() && b[2] == 0x11.toByte() && b[3] == 0x5c.toByte() &&
                b[4] == 0xa1.toByte() && b[5] == 0xe0.toByte()
            else -> false
        }
    }
}

/** Connection settings; the defaults match the iPhone's URLSession configuration. */
data class HttpSettings(
    val connectTimeoutMillis: Int = 10_000,
    val readTimeoutMillis: Int = 20_000,
    val userAgent: String = "PlanMeterAndroid/${SecureChannel.PROTOCOL_VERSION}",
    val hostPolicy: HostPolicy = HostPolicy.ANY,
    val maxReplyBytes: Int = 8 * 1024 * 1024,
)

/**
 * Talks to a PlanMeter host over the encrypted channel. Calls block; run them
 * off the main thread.
 */
class RemoteClient(
    val server: PairedServer,
    private val signer: DeviceSigner,
    private val settings: HttpSettings = HttpSettings(),
) {
    fun call(request: RemoteRequest): RemoteReply {
        val body = RemoteJson.encode(RemoteRequest.serializer(), request)
        val data = exchange(server.host, server.baseUrl, RPC_PATH, body, server.serverPublicKey, server.deviceId, signer, settings)
        val reply = decode(data) { RemoteJson.decode(RemoteReply.serializer(), it) }
        reply.error?.let { throw RemoteClientException.Http(200, it) }
        return reply
    }

    companion object {
        const val RPC_PATH = "/v1/rpc"
        const val PAIR_PATH = "/v1/pair"
        const val INFO_PATH = "/v1/info"
        const val PAIRING_DEVICE_ID = "pairing"

        /**
         * Completes pairing. The request is encrypted to the invite's server key
         * and signed by the new device key, so neither the token nor the key
         * travels in the clear, even inside the tailnet.
         */
        fun pair(
            invite: PairingInvite,
            deviceName: String,
            platform: String,
            signer: DeviceSigner,
            settings: HttpSettings = HttpSettings(),
            now: Instant = Instant.now(),
        ): PairedServer {
            if (invite.isExpired(now)) throw RemoteClientException.InviteExpired()
            val request = PairRequest(token = invite.token, deviceName = deviceName, devicePublicKey = signer.publicKeyRaw, platform = platform)
            val body = RemoteJson.encode(PairRequest.serializer(), request)
            val stub = PairedServer(invite.serverHost, invite.port, invite.serverName, invite.serverPublicKey, PAIRING_DEVICE_ID, now)
            val data = exchange(invite.serverHost, stub.baseUrl, PAIR_PATH, body, invite.serverPublicKey, PAIRING_DEVICE_ID, signer, settings)
            val response = decode(data) { RemoteJson.decode(PairResponse.serializer(), it) }
            return PairedServer(invite.serverHost, invite.port, response.serverName, invite.serverPublicKey, response.deviceId, Instant.now())
        }

        fun info(host: String, port: Int, settings: HttpSettings = HttpSettings()): ServerInfo {
            val stub = PairedServer(host, port, "", ByteArray(0), "", Instant.EPOCH)
            settings.hostPolicy.check(host)
            val (status, data) = perform(URL(stub.baseUrl + INFO_PATH), "GET", null, settings)
            if (status != 200) throw RemoteClientException.Http(status, "")
            return decode(data) { RemoteJson.decode(ServerInfo.serializer(), it) }
        }

        internal fun exchange(
            host: String,
            baseUrl: String,
            path: String,
            plaintext: ByteArray,
            serverPublicKey: ByteArray,
            deviceId: String,
            signer: DeviceSigner,
            settings: HttpSettings,
        ): ByteArray {
            settings.hostPolicy.check(host)
            val sealed = try {
                SecureChannel.seal(plaintext, serverPublicKey, deviceId, signer, "POST", path)
            } catch (e: ChannelException) {
                throw RemoteClientException.Channel(e.error, e)
            }
            val body = RemoteJson.encode(SecureChannel.SealedRequest.serializer(), sealed.request)
            val (status, data) = perform(URL(baseUrl + path), "POST", body, settings)
            if (status != 200) throw RemoteClientException.Http(status, errorMessage(data))
            val envelope = decode(data) { RemoteJson.decode(SecureChannel.SealedResponse.serializer(), it) }
            return try {
                SecureChannel.openResponse(envelope, sealed.responseKey)
            } catch (e: ChannelException) {
                throw RemoteClientException.Channel(e.error, e)
            }
        }

        private fun errorMessage(data: ByteArray): String = try {
            val obj = Json.parseToJsonElement(data.toString(Charsets.UTF_8)) as? JsonObject
            (obj?.get("error") as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
        } catch (_: SerializationException) {
            ""
        } catch (_: IllegalArgumentException) {
            ""
        }

        private fun perform(url: URL, method: String, body: ByteArray?, settings: HttpSettings): Pair<Int, ByteArray> {
            val connection = try {
                url.openConnection() as HttpURLConnection
            } catch (e: IOException) {
                throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.OTHER, e.message ?: "Could not open a connection.", e)
            }
            try {
                connection.requestMethod = method
                connection.connectTimeout = settings.connectTimeoutMillis
                connection.readTimeout = settings.readTimeoutMillis
                connection.useCaches = false
                connection.instanceFollowRedirects = false
                connection.setRequestProperty("User-Agent", settings.userAgent)
                connection.setRequestProperty("Accept", "application/json")
                if (body != null) {
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json")
                    // No streaming mode: bodies are small, and buffered requests let the
                    // JDK hand back 401 error bodies instead of an HttpRetryException.
                    connection.outputStream.use { it.write(body) }
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val data = stream?.use { readBounded(it, settings.maxReplyBytes) } ?: ByteArray(0)
                return status to data
            } catch (e: RemoteClientException) {
                throw e
            } catch (e: SocketTimeoutException) {
                val connected = e.message?.contains("connect", ignoreCase = true) != true
                throw if (connected) {
                    RemoteClientException.Transport(RemoteClientException.Transport.Kind.TIMEOUT, "The request timed out.", e)
                } else {
                    RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "Could not connect to ${url.host}.", e)
                }
            } catch (e: UnknownHostException) {
                throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "Could not find ${url.host}.", e)
            } catch (e: ConnectException) {
                throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "Could not connect to ${url.host}.", e)
            } catch (e: NoRouteToHostException) {
                throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "No route to ${url.host}.", e)
            } catch (e: IOException) {
                throw RemoteClientException.Transport(RemoteClientException.Transport.Kind.OTHER, e.message ?: "The connection failed.", e)
            } finally {
                connection.disconnect()
            }
        }

        private fun readBounded(input: InputStream, limit: Int): ByteArray {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                if (out.size() + n > limit) throw RemoteClientException.MalformedReply()
                out.write(buffer, 0, n)
            }
            return out.toByteArray()
        }

        private inline fun <T> decode(data: ByteArray, block: (ByteArray) -> T): T = try {
            block(data)
        } catch (e: SerializationException) {
            throw RemoteClientException.MalformedReply(e)
        } catch (e: IllegalArgumentException) {
            throw RemoteClientException.MalformedReply(e)
        }
    }
}
