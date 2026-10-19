package com.neilgoldader.planmeter.mobile

import android.app.Application
import android.content.Context
import android.os.Build
import android.provider.Settings
import com.neilgoldader.planmeter.mobile.data.AppStore
import com.neilgoldader.planmeter.mobile.data.KeystoreSigner
import com.neilgoldader.planmeter.mobile.data.SigningIdentity
import com.neilgoldader.planmeter.protocol.HostPolicy
import com.neilgoldader.planmeter.protocol.HttpSettings
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.RemoteClient

open class PlanMeterApplication : Application() {
    open val graph: AppGraph by lazy { AppGraph(this) }
}

/** The app's few singletons. Tests swap the signer, which needs the Android Keystore. */
class AppGraph(
    private val context: Context,
    signerFactory: (Context) -> SigningIdentity = KeystoreSigner::loadOrCreate,
) {
    val store = AppStore(context)

    /** Created on first use: generating a StrongBox key can take a moment. */
    val signer: SigningIdentity by lazy { signerFactory(context) }

    /**
     * Requests go only to Tailscale addresses (see network_security_config.xml);
     * debug builds also allow loopback and the emulator's host alias for local testing.
     */
    val httpSettings = HttpSettings(hostPolicy = HostPolicy.tailnetOnly(allowLoopback = BuildConfig.DEBUG))

    fun client(server: PairedServer) = RemoteClient(server, signer, httpSettings)

    val deviceName: String
        get() = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /** Like the iPhone's "iPhone · iOS 26.0"; the host keeps 32 characters. */
    val platformName: String get() = "${Build.MODEL} · Android ${Build.VERSION.RELEASE}"

    companion object {
        fun from(context: Context): AppGraph = (context.applicationContext as PlanMeterApplication).graph
    }
}
