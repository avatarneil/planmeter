package com.neilgoldader.planmeter.mobile.data

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import com.neilgoldader.planmeter.protocol.DeviceSigner
import com.neilgoldader.planmeter.protocol.EcdsaSignature
import com.neilgoldader.planmeter.protocol.P256
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

enum class KeyStorage(val label: String) {
    STRONGBOX("StrongBox secure element"),
    TEE("Trusted execution environment"),
    SOFTWARE("Software keystore"),
    UNKNOWN("Android Keystore"),
}

/**
 * The phone's identity: a P-256 signing key in the Android Keystore, the
 * counterpart of the iPhone's Secure Enclave key. StrongBox-backed when the
 * device has a secure element, otherwise TEE-backed. The private key never
 * leaves the keystore; the Keystore returns DER signatures, which are
 * converted to the raw r||s form the protocol uses.
 */
class KeystoreSigner private constructor(
    private val privateKey: PrivateKey,
    override val publicKeyRaw: ByteArray,
    val storage: KeyStorage,
) : DeviceSigner {
    override fun sign(message: ByteArray): ByteArray {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(message)
        return EcdsaSignature.derToRaw(signature.sign())
    }

    companion object {
        private const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "planmeter-device-signing-key"

        fun loadOrCreate(context: Context): KeystoreSigner {
            val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
            if (!keyStore.containsAlias(ALIAS)) generate(context)
            val privateKey = keyStore.getKey(ALIAS, null) as PrivateKey
            val publicKey = keyStore.getCertificate(ALIAS).publicKey as ECPublicKey
            return KeystoreSigner(privateKey, P256.x963(publicKey), storageOf(privateKey))
        }

        private fun generate(context: Context) {
            val strongBox = context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
            if (strongBox) {
                try {
                    generate(strongBox = true)
                    return
                } catch (_: StrongBoxUnavailableException) {
                    // Advertised but unusable (or busy): fall back to the TEE.
                } catch (_: java.security.ProviderException) {
                    // Some secure elements reject P-256 generation; fall back too.
                }
            }
            generate(strongBox = false)
        }

        private fun generate(strongBox: Boolean) {
            val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(strongBox)
                .build()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply { initialize(spec) }.generateKeyPair()
        }

        private fun storageOf(key: PrivateKey): KeyStorage = try {
            val info = KeyFactory.getInstance(key.algorithm, PROVIDER).getKeySpec(key, KeyInfo::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                when (info.securityLevel) {
                    KeyProperties.SECURITY_LEVEL_STRONGBOX -> KeyStorage.STRONGBOX
                    KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> KeyStorage.TEE
                    KeyProperties.SECURITY_LEVEL_SOFTWARE -> KeyStorage.SOFTWARE
                    else -> KeyStorage.UNKNOWN
                }
            } else {
                @Suppress("DEPRECATION")
                if (info.isInsideSecureHardware) KeyStorage.TEE else KeyStorage.SOFTWARE
            }
        } catch (_: Exception) {
            KeyStorage.UNKNOWN
        }
    }
}
