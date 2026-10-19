package com.neilgoldader.planmeter.protocol

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * P-256 helpers over the platform JCA providers (SunEC on desktop JVMs,
 * Conscrypt/BoringSSL on Android). Keys travel as X9.63 uncompressed points
 * (`0x04 || X || Y`, 65 bytes) and signatures as raw `r || s` (64 bytes),
 * matching CryptoKit's `x963Representation` and `rawRepresentation`.
 */
object P256 {
    const val PUBLIC_KEY_LENGTH = 65
    const val SIGNATURE_LENGTH = 64
    private const val COORDINATE_LENGTH = 32

    /** The provider's own named-curve parameters, so keys it builds stay "named". */
    val params: ECParameterSpec by lazy { (generateKeyPair().public as ECPublicKey).params }

    fun generateKeyPair(random: SecureRandom? = null): KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        if (random != null) generator.initialize(ECGenParameterSpec("secp256r1"), random)
        else generator.initialize(ECGenParameterSpec("secp256r1"))
        return generator.generateKeyPair()
    }

    fun x963(key: ECPublicKey): ByteArray =
        byteArrayOf(0x04) + unsigned(key.w.affineX, COORDINATE_LENGTH) + unsigned(key.w.affineY, COORDINATE_LENGTH)

    /** Parses and validates an uncompressed point; throws [GeneralSecurityException] if it is not on the curve. */
    fun publicKey(x963: ByteArray): ECPublicKey {
        if (x963.size != PUBLIC_KEY_LENGTH || x963[0] != 0x04.toByte()) throw GeneralSecurityException("Not an uncompressed P-256 point")
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        val curve = params.curve
        val p = (curve.field as ECFieldFp).p
        if (x >= p || y >= p) throw GeneralSecurityException("Coordinate out of range")
        val rhs = x.pow(3).add(curve.a.multiply(x)).add(curve.b).mod(p)
        if (y.pow(2).mod(p) != rhs) throw GeneralSecurityException("Point is not on P-256")
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params)) as ECPublicKey
    }

    /** A private key from CryptoKit's `rawRepresentation` (the 32-byte scalar). */
    fun privateKey(raw: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, raw), params))

    /** ECDH; the shared secret is the X coordinate, 32 bytes, as in CryptoKit's `SharedSecret`. */
    fun sharedSecret(privateKey: PrivateKey, peer: ECPublicKey): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(peer, true)
        val secret = agreement.generateSecret()
        return if (secret.size == COORDINATE_LENGTH) secret else unsigned(BigInteger(1, secret), COORDINATE_LENGTH)
    }

    fun verify(signatureRaw: ByteArray, message: ByteArray, publicKeyRaw: ByteArray): Boolean = try {
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(publicKey(publicKeyRaw))
        verifier.update(message)
        verifier.verify(EcdsaSignature.rawToDer(signatureRaw))
    } catch (_: GeneralSecurityException) {
        false
    } catch (_: IllegalArgumentException) {
        false
    }

    internal fun unsigned(value: BigInteger, length: Int): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == length -> bytes
            bytes.size == length + 1 && bytes[0] == 0.toByte() -> bytes.copyOfRange(1, bytes.size)
            bytes.size < length -> ByteArray(length - bytes.size) + bytes
            else -> throw IllegalArgumentException("Value does not fit in $length bytes")
        }
    }
}

/**
 * ECDSA signature encodings. JCA and the Android Keystore produce and expect
 * ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }`; the wire format is CryptoKit's
 * raw fixed-width `r || s`.
 */
object EcdsaSignature {
    fun derToRaw(der: ByteArray, coordinateLength: Int = 32): ByteArray {
        var i = 0
        fun byte(): Int = if (i < der.size) der[i++].toInt() and 0xFF else throw IllegalArgumentException("Truncated DER")
        fun length(): Int {
            val first = byte()
            if (first < 0x80) return first
            val count = first and 0x7F
            if (count == 0 || count > 2) throw IllegalArgumentException("Unsupported DER length")
            var value = 0
            repeat(count) { value = (value shl 8) or byte() }
            return value
        }
        fun integer(): BigInteger {
            if (byte() != 0x02) throw IllegalArgumentException("Expected INTEGER")
            val len = length()
            if (len == 0 || i + len > der.size) throw IllegalArgumentException("Bad INTEGER length")
            val value = BigInteger(1, der.copyOfRange(i, i + len))
            i += len
            return value
        }
        if (byte() != 0x30) throw IllegalArgumentException("Expected SEQUENCE")
        val seqLen = length()
        if (i + seqLen != der.size) throw IllegalArgumentException("Trailing or missing DER bytes")
        val r = integer()
        val s = integer()
        if (i != der.size) throw IllegalArgumentException("Trailing DER bytes")
        return P256.unsigned(r, coordinateLength) + P256.unsigned(s, coordinateLength)
    }

    fun rawToDer(raw: ByteArray): ByteArray {
        if (raw.isEmpty() || raw.size % 2 != 0) throw IllegalArgumentException("Raw signature must be r || s")
        val half = raw.size / 2
        fun integer(bytes: ByteArray): ByteArray {
            val minimal = BigInteger(1, bytes).toByteArray() // Adds 0x00 when the high bit is set.
            return byteArrayOf(0x02) + derLength(minimal.size) + minimal
        }
        val body = integer(raw.copyOfRange(0, half)) + integer(raw.copyOfRange(half, raw.size))
        return byteArrayOf(0x30) + derLength(body.size) + body
    }

    private fun derLength(length: Int): ByteArray = when {
        length < 0x80 -> byteArrayOf(length.toByte())
        length <= 0xFF -> byteArrayOf(0x81.toByte(), length.toByte())
        else -> byteArrayOf(0x82.toByte(), (length shr 8).toByte(), length.toByte())
    }
}

/** HKDF-SHA256 (RFC 5869), as CryptoKit's `hkdfDerivedSymmetricKey`. */
object Hkdf {
    fun sha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            out.write(previous)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }
}

/**
 * The two AEADs, both with a 12-byte nonce, a 16-byte tag, and CryptoKit's
 * combined `nonce || ciphertext || tag` layout.
 */
internal object Aead {
    const val TAG_LENGTH = 16

    /**
     * Android (Conscrypt, API 28+) names the cipher `ChaCha20/Poly1305/NoPadding`;
     * desktop JVMs (SunJCE, Java 11+) call it `ChaCha20-Poly1305`.
     */
    private val chachaTransformations = listOf("ChaCha20/Poly1305/NoPadding", "ChaCha20-Poly1305")

    @Volatile private var chachaName: String? = null

    private fun chacha(): Cipher {
        chachaName?.let { return Cipher.getInstance(it) }
        var failure: GeneralSecurityException? = null
        for (name in chachaTransformations) {
            try {
                return Cipher.getInstance(name).also { chachaName = name }
            } catch (e: GeneralSecurityException) {
                failure = e
            }
        }
        throw failure ?: GeneralSecurityException("ChaCha20-Poly1305 unavailable")
    }

    private fun init(cipher: SecureChannel.Cipher, mode: Int, key: ByteArray, nonce: ByteArray): Cipher = when (cipher) {
        SecureChannel.Cipher.CHACHA20_POLY1305 -> chacha().apply { init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce)) }
        SecureChannel.Cipher.AES_256_GCM -> Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
        }
    }

    fun seal(cipher: SecureChannel.Cipher, key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val c = init(cipher, Cipher.ENCRYPT_MODE, key, nonce)
        c.updateAAD(aad)
        return nonce + c.doFinal(plaintext)
    }

    /** Opens a combined box; the nonce is the box's own prefix, as in `SealedBox(combined:)`. */
    fun open(cipher: SecureChannel.Cipher, key: ByteArray, combined: ByteArray, aad: ByteArray): ByteArray {
        val nonceLength = SecureChannel.NONCE_LENGTH
        if (combined.size < nonceLength + TAG_LENGTH) throw ChannelException(ChannelError.DECRYPT_FAILED)
        return try {
            val c = init(cipher, Cipher.DECRYPT_MODE, key, combined.copyOfRange(0, nonceLength))
            c.updateAAD(aad)
            c.doFinal(combined, nonceLength, combined.size - nonceLength)
        } catch (e: GeneralSecurityException) {
            throw ChannelException(ChannelError.DECRYPT_FAILED, e)
        }
    }
}
