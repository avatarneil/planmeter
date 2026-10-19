package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.Serializable
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.time.Instant

/**
 * What the QR code carries: where the server is, its public key (so the phone
 * pins it), and a single-use token that expires in minutes. Mirrors
 * `PairingInvite` in Pairing.swift, including its parsing rules.
 */
class PairingInvite(
    val serverHost: String,
    val port: Int,
    val serverName: String,
    val serverPublicKey: ByteArray,
    val token: String,
    val expiresAt: Instant,
) {
    fun isExpired(now: Instant = Instant.now()): Boolean = now.isAfter(expiresAt)

    /** Where the link points, as `host:port` (IPv6 hosts bracketed), for the user to check. */
    val address: String
        get() = (if (serverHost.contains(':') && !serverHost.startsWith("[")) "[$serverHost]" else serverHost) + ":$port"

    /** The same fingerprint [PairedServer.serverKeyFingerprint] shows once paired. */
    val serverKeyFingerprint: String get() = Base64Url.encode(sha256(serverPublicKey)).take(16)

    /** `planmeter://pair?h=&p=&n=&k=&t=&e=` with a base64url key. */
    fun toUrl(): String {
        val items = listOf(
            "h" to serverHost,
            "p" to port.toString(),
            "n" to serverName,
            "k" to Base64Url.encode(serverPublicKey),
            "t" to token,
            "e" to expiresAt.epochSecond.toString(),
        )
        return "$SCHEME://$HOST?" + items.joinToString("&") { (k, v) -> "$k=${PercentCoding.encodeQueryValue(v)}" }
    }

    override fun equals(other: Any?): Boolean = other is PairingInvite &&
        serverHost == other.serverHost && port == other.port && serverName == other.serverName &&
        serverPublicKey.contentEquals(other.serverPublicKey) && token == other.token && expiresAt == other.expiresAt

    override fun hashCode(): Int = listOf(serverHost, port, serverName, serverPublicKey.contentHashCode(), token, expiresAt).hashCode()

    override fun toString(): String = "PairingInvite(serverHost=$serverHost, port=$port, serverName=$serverName, expiresAt=$expiresAt)"

    companion object {
        const val SCHEME = "planmeter"
        const val HOST = "pair"

        private val urlPattern = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)(?:\\?([^#]*))?(?:#.*)?$")

        /**
         * Parses a pairing link. Accepts the same links as `PairingInvite(url:)`:
         * scheme `planmeter`, host `pair`, a non-empty host `h`, a port `p` in
         * 1...65535, a 65-byte base64url key `k`, a non-empty token `t`, and an
         * expiry `e` in Unix seconds. `n` defaults to the host. Later duplicate
         * query items win, as with the Swift dictionary build.
         */
        fun parse(text: String): PairingInvite? {
            val match = urlPattern.matchEntire(text.trim()) ?: return null
            val (scheme, authority, _, query) = match.destructured
            if (!scheme.equals(SCHEME, ignoreCase = true)) return null
            val host = authority.substringAfterLast('@').substringBefore(':')
            if (!host.equals(HOST, ignoreCase = true)) return null
            val map = HashMap<String, String?>()
            if (query.isNotEmpty()) {
                for (item in query.split('&')) {
                    val eq = item.indexOf('=')
                    val name = PercentCoding.decode(if (eq < 0) item else item.substring(0, eq)) ?: return null
                    val value = if (eq < 0) null else PercentCoding.decode(item.substring(eq + 1)) ?: return null
                    // A Swift dictionary assignment of nil removes the key.
                    if (value == null) map.remove(name) else map[name] = value
                }
            }
            val h = map["h"]?.takeIf { it.isNotEmpty() } ?: return null
            val port = map["p"]?.let(::parseSwiftInt)?.takeIf { it in 1..65535 }?.toInt() ?: return null
            val key = map["k"]?.let(Base64Url::decode)?.takeIf { it.size == 65 } ?: return null
            val token = map["t"]?.takeIf { it.isNotEmpty() } ?: return null
            val expires = map["e"]?.let(::parseSwiftInt) ?: return null
            return PairingInvite(
                serverHost = h,
                port = port,
                serverName = map["n"] ?: h,
                serverPublicKey = key,
                token = token,
                expiresAt = Instant.ofEpochSecond(expires),
            )
        }

        /** Swift `Int(String)`/`Int64(String)`: optional sign, ASCII digits only. */
        private fun parseSwiftInt(text: String): Long? {
            if (text.isEmpty()) return null
            val digits = if (text[0] == '+' || text[0] == '-') text.substring(1) else text
            if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
            return text.toLongOrNull()
        }
    }
}

@Serializable
class PairRequest(
    val token: String,
    val deviceName: String,
    val devicePublicKey: WireData,
    val platform: String,
)

@Serializable
data class PairResponse(
    val deviceId: String,
    val serverName: String,
    val serverVersion: String,
)

/** What the phone keeps after pairing. */
@Serializable
class PairedServer(
    val host: String,
    val port: Int,
    val serverName: String,
    val serverPublicKey: WireData,
    val deviceId: String,
    val pairedAt: WireDate,
) {
    val baseUrl: String
        get() {
            val h = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
            return "http://$h:$port"
        }

    /** First 16 base64url characters of SHA-256(server key), as the iPhone shows it. */
    val serverKeyFingerprint: String get() = Base64Url.encode(sha256(serverPublicKey)).take(16)

    fun copy(serverName: String = this.serverName) = PairedServer(host, port, serverName, serverPublicKey, deviceId, pairedAt)

    override fun equals(other: Any?): Boolean = other is PairedServer &&
        host == other.host && port == other.port && serverName == other.serverName &&
        serverPublicKey.contentEquals(other.serverPublicKey) && deviceId == other.deviceId && pairedAt == other.pairedAt

    override fun hashCode(): Int = listOf(host, port, serverName, serverPublicKey.contentHashCode(), deviceId, pairedAt).hashCode()

    override fun toString(): String = "PairedServer(host=$host, port=$port, serverName=$serverName, deviceId=$deviceId, pairedAt=$pairedAt)"
}

/** What a host keeps per paired device. */
@Serializable
class PairedDevice(
    val id: String,
    val name: String,
    val platform: String,
    val publicKey: WireData,
    val pairedAt: WireDate,
    val lastSeenAt: WireDate? = null,
    val requestCount: Long = 0,
)

object DeviceId {
    /** Stable id derived from the device's public key: 22 base64url characters of its SHA-256. */
    fun derive(publicKey: ByteArray): String = Base64Url.encode(sha256(publicKey)).take(22)
}

internal fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

/** RFC 3986 percent coding without form-encoding's `+` for space, like URLComponents. */
internal object PercentCoding {
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    fun encodeQueryValue(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val c = (byte.toInt() and 0xFF).toChar()
            if (c in UNRESERVED) out.append(c) else out.append('%').append("%02X".format(byte.toInt() and 0xFF))
        }
        return out.toString()
    }

    /** Returns null for malformed escapes or invalid UTF-8, which URLComponents also rejects. */
    fun decode(text: String): String? {
        if ('%' !in text) return text
        val bytes = ByteArrayOutputStream()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '%') {
                if (i + 3 > text.length) return null
                val hex = text.substring(i + 1, i + 3)
                if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                bytes.write(hex.toInt(16))
                i += 3
            } else {
                bytes.write(c.toString().toByteArray(Charsets.UTF_8))
                i += 1
            }
        }
        val decoder = Charsets.UTF_8.newDecoder()
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes.toByteArray())).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            null
        }
    }
}
