package com.neilgoldader.planmeter.mobile

import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.testing.WorkManagerTestInitHelper
import com.neilgoldader.planmeter.mobile.data.KeyStorage
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.data.SigningIdentity
import com.neilgoldader.planmeter.mobile.ui.AppViewModel
import com.neilgoldader.planmeter.protocol.DeviceId
import com.neilgoldader.planmeter.protocol.DeviceSigner
import com.neilgoldader.planmeter.protocol.PairingInvite
import com.neilgoldader.planmeter.protocol.RemoteMethod
import com.neilgoldader.planmeter.protocol.RemoteRequest
import com.neilgoldader.planmeter.protocol.SoftwareSigner
import com.neilgoldader.planmeter.protocol.TestHost
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.net.ServerSocket
import java.time.Instant

/** The real app with a software key, since Robolectric has no Android Keystore. */
class TestApplication : PlanMeterApplication() {
    override val graph: AppGraph by lazy { AppGraph(this) { SoftwareIdentity() } }
}

class SoftwareIdentity(signer: SoftwareSigner = SoftwareSigner()) : SigningIdentity, DeviceSigner by signer {
    override val storage = KeyStorage.SOFTWARE
}

/**
 * The view model end to end against a JVM port of the host (TestHost) over
 * real HTTP on loopback: pairing, the dashboard requests, range fallback,
 * persistence, the widget snapshot, and unpairing.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], application = TestApplication::class)
class PairingFlowTest {
    private val app: TestApplication = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(app)
        io {
            app.graph.store.clearPairing()
            app.graph.store.setRequireBiometrics(false)
        }
    }

    /** Runs suspending storage calls off the main thread while the main looper keeps turning. */
    private fun <T> io(block: suspend () -> T): T {
        val future = java.util.concurrent.CompletableFuture.supplyAsync { runBlocking { block() } }
        await("storage") { future.isDone }
        return future.get()
    }

    private fun await(what: String, timeoutMillis: Long = 15_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition()) {
            shadowOf(Looper.getMainLooper()).idle()
            if (System.currentTimeMillis() > deadline) fail("Timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    @Test
    fun pairsLoadsTheDashboardAndUnpairs() {
        TestHost(FakeData::reply).use { host ->
            val vm = AppViewModel(app)
            await("settings") { vm.state.value.ready }

            vm.pair(host.invite().toUrl())
            await("dashboard data") { vm.state.value.dashboard.data != null }

            val state = vm.state.value
            val server = assertNotNull(state.dashboard.server).let { state.dashboard.server!! }
            assertEquals("Test Host", server.serverName)
            assertEquals(DeviceId.derive(app.graph.signer.publicKeyRaw), server.deviceId)
            assertNull(state.pairing.error)
            assertEquals(MobileRange.MONTH, state.dashboard.range)
            // The iPhone's requests for 30 days at the default daily buckets.
            assertTrue(host.requests.containsAll(listOf(
                RemoteRequest(RemoteMethod.SUMMARY, days = 30),
                RemoteRequest(RemoteMethod.TIMELINE, days = 30, resolution = "day"),
                RemoteRequest(RemoteMethod.LIMITS),
                RemoteRequest(RemoteMethod.MODELS, days = 30),
            )))
            assertEquals(FakeData.models.size, state.dashboard.data!!.models.size)

            // Persisted, along with a widget snapshot.
            assertEquals(server, io { app.graph.store.current().server })
            assertNotNull(io { app.graph.store.widgetSnapshot() })

            // The last hour asks for a sub-day window plus a day for the widget.
            vm.setRange(MobileRange.HOUR)
            await("hour data") { vm.state.value.dashboard.data?.summary?.minutes == 60 && !vm.state.value.dashboard.isLoading }
            assertTrue(host.requests.contains(RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "minute", minutes = 60)))
            assertTrue(host.requests.contains(RemoteRequest(RemoteMethod.SUMMARY, days = 1)))

            // An older host ignores `minutes`: fall back to the day and hide 1h.
            host.reply = { FakeData.reply(it.copy(minutes = null)) }
            vm.setRange(MobileRange.WEEK)
            await("week") { !vm.state.value.dashboard.isLoading && vm.state.value.dashboard.data?.summary?.days == 7 }
            vm.setRange(MobileRange.HOUR)
            await("fallback") { vm.state.value.dashboard.range == MobileRange.DAY && !vm.state.value.dashboard.isLoading }
            assertTrue(MobileRange.HOUR !in vm.state.value.dashboard.availableRanges)

            // A revoked phone gets a clear message, and the last data stays.
            host.devices.clear()
            vm.refresh(userInitiated = true)
            await("revoked error") { vm.state.value.dashboard.error != null }
            assertTrue(vm.state.value.dashboard.error!!.contains("no longer recognizes"))
            assertNotNull(vm.state.value.dashboard.data)

            vm.unpair()
            await("unpaired") { vm.state.value.dashboard.server == null }
            await("store cleared") { io { app.graph.store.current().server == null && app.graph.store.widgetSnapshot() == null } }
        }
    }

    @Test
    fun externalLinksWaitForConfirmationAndUnlock() {
        TestHost(FakeData::reply).use { host ->
            io { app.graph.store.setRequireBiometrics(true) }
            // A cold start: the link arrives before settings have loaded.
            val vm = AppViewModel(app)
            vm.openPairingLink(host.invite().toUrl())
            await("settings") { vm.state.value.ready }
            assertTrue(vm.state.value.isLocked)
            assertNotNull(vm.state.value.pairing.pendingInvite)

            // Confirming does nothing until the app is unlocked.
            vm.confirmPendingInvite()
            assertTrue(host.devices.isEmpty())
            assertNull(vm.state.value.dashboard.server)

            vm.unlocked()
            vm.confirmPendingInvite()
            await("paired") { vm.state.value.dashboard.server != null }
            assertNull(vm.state.value.pairing.pendingInvite)
            assertEquals(1, host.devices.size)

            // Already paired: another link still waits, and dismissing it keeps the pairing.
            vm.openPairingLink(host.invite().toUrl())
            assertNotNull(vm.state.value.pairing.pendingInvite)
            vm.dismissPendingInvite()
            assertNull(vm.state.value.pairing.pendingInvite)
            assertEquals("Test Host", vm.state.value.dashboard.server?.serverName)
        }
    }

    @Test
    fun pairingErrorsAreExplained() {
        TestHost().use { host ->
            val vm = AppViewModel(app)
            await("settings") { vm.state.value.ready }

            vm.pair("https://devbox.tail1234.ts.net/#k=abc&t=def&e=1")
            assertTrue(vm.state.value.pairing.error!!.contains("browser pairing link"))

            val expired = PairingInvite("127.0.0.1", host.port, "Test Host", host.publicKeyRaw, host.token, Instant.now().minusSeconds(5))
            vm.pair(expired.toUrl())
            await("expired") { vm.state.value.pairing.error?.contains("expired") == true }

            host.token = "different"
            vm.pair(host.invite().toUrl().replace("t=different", "t=wrong"))
            await("rejected") { vm.state.value.pairing.error?.contains("rejected") == true && !vm.state.value.pairing.isPairing }

            val closed = ServerSocket(0).use { it.localPort }
            vm.pair(PairingInvite("127.0.0.1", closed, "Nobody", host.publicKeyRaw, "t", Instant.now().plusSeconds(60)).toUrl())
            await("unreachable") { vm.state.value.pairing.error?.contains("Is Tailscale connected") == true }

            // Hosts outside the tailnet are refused before any request (debug builds allow loopback only).
            vm.pair(PairingInvite("192.0.2.10", 7787, "Elsewhere", host.publicKeyRaw, "t", Instant.now().plusSeconds(60)).toUrl())
            await("not tailnet") { vm.state.value.pairing.error?.contains("isn't a Tailscale address") == true }
            assertNull(vm.state.value.dashboard.server)
        }
    }
}
