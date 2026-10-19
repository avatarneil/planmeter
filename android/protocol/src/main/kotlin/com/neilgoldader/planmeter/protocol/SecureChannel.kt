package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.security.GeneralSecurityException
import java.security.KeyPair
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.time.Instant
import java.util.Base64
import kotlin.math.abs

/** The phone's long-lived identity: a P-256 signing key. */
interface DeviceSigner {
    /** X9.63 uncompressed public point (65 bytes). */
    val publicKeyRaw: ByteArray

    /** ECDSA P-256 / SHA-256 over [message], returned as raw `r || s` (64 bytes). */
    fun sign(message: ByteArray): ByteArray
}

/** A software key, for tests and as a fallback. The app normally uses an Android Keystore key. */
class SoftwareSigner(private val keyPair: KeyPair = P256.generateKeyPair()) : DeviceSigner {
    override val publicKeyRaw: ByteArray = P256.x963(keyPair.public as ECPublicKey)

    override fun sign(message: ByteArray): ByteArray {
        val signature = java.security.Signature.getInstance("SHA256withECDSA")
        signature.initSign(keyPair.private)
        signature.update(message)
        return EcdsaSignature.derToRaw(signature.sign())
    }

    companion object {
        /** From CryptoKit's `rawRepresentation` (32-byte scalar) and the matching public point. */
        fun fromRaw(privateKey: ByteArray, publicKeyRaw: ByteArray): SoftwareSigner =
            SoftwareSigner(KeyPair(P256.publicKey(publicKeyRaw), P256.privateKey(privateKey)))
    }
}

enum class ChannelError(val description: String) {
    UNSUPPORTED_VERSION("Unsupported protocol version."),
    TIME_WINDOW("Request timestamp outside the allowed window."),
    BAD_SIGNATURE("Device signature did not verify."),
    REPLAY("Nonce already seen."),
    DECRYPT_FAILED("Could not decrypt payload."),
    MALFORMED("Malformed envelope."),
    UNKNOWN_DEVICE("Device is not paired."),
}

class ChannelException(val error: ChannelError, cause: Throwable? = null) : Exception(error.description, cause)

/**
 * End-to-end encryption and proof of possession for one request/response,
 * byte-compatible with Sources/PlanMeterRemote/SecureChannel.swift.
 *
 * Request: a fresh ephemeral P-256 key agrees a secret with the server's static
 * key; HKDF-SHA256 (salt = the 12-byte nonce, info =
 * `planmeter-remote-v1|<deviceId>|request` or `|response`) derives two 32-byte
 * keys; the body is sealed with the AEAD using the header as additional data;
 * and `header || SHA-256(ciphertext)` is signed by the device key. Responses are
 * sealed under the response key with their own nonce as additional data.
 */
object SecureChannel {
    const val PROTOCOL_VERSION = 1
    const val LABEL = "planmeter-remote-v1"
    const val MAX_CLOCK_SKEW_SECONDS = 120L
    const val NONCE_LENGTH = 12
    const val KEY_LENGTH = 32

    @Serializable(with = CipherSerializer::class)
    enum class Cipher(val wireName: String) {
        CHACHA20_POLY1305("chacha20poly1305"),
        AES_256_GCM("aes-256-gcm"),
        ;

        companion object {
            fun fromWire(name: String): Cipher? = entries.firstOrNull { it.wireName == name }
        }
    }

    @Serializable
    class SealedRequest(
        val v: Int,
        val deviceId: String,
        val ephemeralPublicKey: WireData,
        val nonce: WireData,
        val timestamp: Long,
        val ciphertext: WireData,
        val signature: WireData,
        val cipher: Cipher? = null,
    ) {
        val effectiveCipher: Cipher get() = cipher ?: Cipher.CHACHA20_POLY1305
    }

    @Serializable
    class SealedResponse(
        val nonce: WireData,
        val ciphertext: WireData,
        val cipher: Cipher? = null,
    ) {
        val effectiveCipher: Cipher get() = cipher ?: Cipher.CHACHA20_POLY1305
    }

    /** A sealed request plus the key its response will be sealed under. */
    class Sealed(val request: SealedRequest, val responseKey: ByteArray)

    class DerivedKeys(val request: ByteArray, val response: ByteArray)

    class Opened(val plaintext: ByteArray, val responseKey: ByteArray, val cipher: Cipher)

    // Key derivation and framing

    fun deriveKeys(sharedSecret: ByteArray, nonce: ByteArray, deviceId: String): DerivedKeys {
        fun key(direction: String) = Hkdf.sha256(sharedSecret, nonce, "$LABEL|$deviceId|$direction".toByteArray(Charsets.UTF_8), KEY_LENGTH)
        return DerivedKeys(request = key("request"), response = key("response"))
    }

    /** Bytes bound into both the AEAD (as additional data) and the signature. */
    fun header(deviceId: String, ephemeral: ByteArray, nonce: ByteArray, timestamp: Long, method: String, path: String, cipher: Cipher): ByteArray {
        val b64 = Base64.getEncoder()
        return "$LABEL\n${method.uppercase()}\n$path\n$deviceId\n$timestamp\n${b64.encodeToString(nonce)}\n${b64.encodeToString(ephemeral)}\n${cipher.wireName}\n"
            .toByteArray(Charsets.UTF_8)
    }

    fun signingInput(header: ByteArray, ciphertext: ByteArray): ByteArray = header + sha256(ciphertext)

    // Client side

    fun seal(
        plaintext: ByteArray,
        serverPublicKeyRaw: ByteArray,
        deviceId: String,
        signer: DeviceSigner,
        method: String,
        path: String,
        cipher: Cipher = Cipher.CHACHA20_POLY1305,
        now: Instant = Instant.now(),
        random: SecureRandom = SecureRandom(),
    ): Sealed = seal(plaintext, serverPublicKeyRaw, deviceId, signer, method, path, cipher, now, P256.generateKeyPair(), randomNonce(random))

    /** Deterministic core of [seal], with the ephemeral key and nonce supplied (for vectors). */
    fun seal(
        plaintext: ByteArray,
        serverPublicKeyRaw: ByteArray,
        deviceId: String,
        signer: DeviceSigner,
        method: String,
        path: String,
        cipher: Cipher,
        now: Instant,
        ephemeral: KeyPair,
        nonce: ByteArray,
    ): Sealed {
        require(nonce.size == NONCE_LENGTH)
        val serverKey = try {
            P256.publicKey(serverPublicKeyRaw)
        } catch (e: GeneralSecurityException) {
            throw ChannelException(ChannelError.MALFORMED, e)
        }
        val secret = P256.sharedSecret(ephemeral.private, serverKey)
        val timestamp = now.epochSecond
        val ephemeralRaw = P256.x963(ephemeral.public as ECPublicKey)
        val keys = deriveKeys(secret, nonce, deviceId)
        val hdr = header(deviceId, ephemeralRaw, nonce, timestamp, method, path, cipher)
        val ciphertext = Aead.seal(cipher, keys.request, nonce, plaintext, hdr)
        val signature = signer.sign(signingInput(hdr, ciphertext))
        val request = SealedRequest(
            v = PROTOCOL_VERSION,
            deviceId = deviceId,
            ephemeralPublicKey = ephemeralRaw,
            nonce = nonce,
            timestamp = timestamp,
            ciphertext = ciphertext,
            signature = signature,
            cipher = cipher,
        )
        return Sealed(request, keys.response)
    }

    fun openResponse(response: SealedResponse, key: ByteArray): ByteArray {
        if (response.nonce.size != NONCE_LENGTH) throw ChannelException(ChannelError.MALFORMED)
        return Aead.open(response.effectiveCipher, key, response.ciphertext, response.nonce)
    }

    // Server side (used by tests and the interop harness)

    /** Verifies the proof-of-possession signature against the paired (or, when pairing, the offered) key. */
    fun verifySignature(request: SealedRequest, devicePublicKeyRaw: ByteArray, method: String, path: String): Boolean {
        val hdr = header(request.deviceId, request.ephemeralPublicKey, request.nonce, request.timestamp, method, path, request.effectiveCipher)
        return P256.verify(request.signature, signingInput(hdr, request.ciphertext), devicePublicKeyRaw)
    }

    fun checkTimestamp(request: SealedRequest, now: Instant = Instant.now()) {
        if (request.v != PROTOCOL_VERSION) throw ChannelException(ChannelError.UNSUPPORTED_VERSION)
        if (request.nonce.size != NONCE_LENGTH || request.ephemeralPublicKey.size != P256.PUBLIC_KEY_LENGTH) throw ChannelException(ChannelError.MALFORMED)
        if (abs(request.timestamp - now.epochSecond) > MAX_CLOCK_SKEW_SECONDS) throw ChannelException(ChannelError.TIME_WINDOW)
    }

    /** Decrypts without verifying the signature; callers verify first, or afterwards for pairing. */
    fun open(request: SealedRequest, serverPrivateKey: PrivateKey, method: String, path: String): Opened {
        val peer = try {
            P256.publicKey(request.ephemeralPublicKey)
        } catch (e: GeneralSecurityException) {
            throw ChannelException(ChannelError.MALFORMED, e)
        }
        val keys = deriveKeys(P256.sharedSecret(serverPrivateKey, peer), request.nonce, request.deviceId)
        val cipher = request.effectiveCipher
        val hdr = header(request.deviceId, request.ephemeralPublicKey, request.nonce, request.timestamp, method, path, cipher)
        val plaintext = Aead.open(cipher, keys.request, request.ciphertext, hdr)
        return Opened(plaintext, keys.response, cipher)
    }

    fun sealResponse(plaintext: ByteArray, key: ByteArray, cipher: Cipher = Cipher.CHACHA20_POLY1305, nonce: ByteArray = randomNonce(SecureRandom())): SealedResponse {
        require(nonce.size == NONCE_LENGTH)
        return SealedResponse(nonce, Aead.seal(cipher, key, nonce, plaintext, nonce), cipher)
    }

    fun randomNonce(random: SecureRandom): ByteArray = ByteArray(NONCE_LENGTH).also(random::nextBytes)
}

internal object CipherSerializer : KSerializer<SecureChannel.Cipher> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("planmeter.Cipher", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: SecureChannel.Cipher) = encoder.encodeString(value.wireName)
    override fun deserialize(decoder: Decoder): SecureChannel.Cipher {
        val name = decoder.decodeString()
        return SecureChannel.Cipher.fromWire(name) ?: throw kotlinx.serialization.SerializationException("Unknown cipher $name")
    }
}
