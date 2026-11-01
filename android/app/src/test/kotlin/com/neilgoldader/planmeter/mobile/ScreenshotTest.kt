package com.neilgoldader.planmeter.mobile

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import com.neilgoldader.planmeter.mobile.data.KeyStorage
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.ui.LockScreen
import com.neilgoldader.planmeter.mobile.ui.PairingUiState
import com.neilgoldader.planmeter.mobile.ui.dashboard.DashboardScreen
import com.neilgoldader.planmeter.mobile.ui.pairing.CameraAccess
import com.neilgoldader.planmeter.mobile.ui.pairing.PairingScreen
import com.neilgoldader.planmeter.mobile.ui.settings.SettingsScreen
import com.neilgoldader.planmeter.mobile.ui.settings.SettingsUiState
import com.neilgoldader.planmeter.mobile.ui.theme.PlanMeterTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private const val PHONE = "w411dp-h891dp-normal-long-notround-any-420dpi-keyshidden-nonav"
private const val PHONE_TALL = "w411dp-h2600dp-normal-long-notround-any-420dpi-keyshidden-nonav"
private const val TABLET = "w1280dp-h800dp-xlarge-long-notround-any-hdpi-keyshidden-nonav"
private const val PHONE_TALL_NIGHT = "w411dp-h2600dp-normal-long-notround-any-night-420dpi-keyshidden-nonav"
private const val TABLET_NIGHT = "w1280dp-h800dp-xlarge-long-notround-any-night-hdpi-keyshidden-nonav"

/**
 * Screenshots of every screen with fake data. `recordRoborazziDebug` writes
 * them to app/build/outputs/roborazzi. Plain `testDebugUnitTest` still renders
 * each screen and checks its content, without writing images.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = PHONE)
class ScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun capture(name: String) {
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/android-$name.png")
    }

    private fun show(content: @Composable () -> Unit) {
        compose.setContent {
            PlanMeterTheme(darkTheme = isSystemInDarkTheme(), dynamicColor = false, content = content)
        }
    }

    private fun dashboard(range: MobileRange = MobileRange.MONTH, granularity: String = range.defaultGranularity) = show {
        DashboardScreen(
            state = FakeData.dashboard(range, granularity),
            onRefresh = {},
            onRangeChange = {},
            onGranularityChange = {},
            onOpenSettings = {},
            now = FakeData.now,
            zone = FakeData.zone,
        )
    }

    @Test
    fun dashboardPhoneLight() {
        dashboard()
        compose.onNodeWithText("Last 30 days").assertExists()
        compose.onNodeWithText("Personal").assertExists()
        capture("dashboard-phone-light")
    }

    @Test
    @Config(qualifiers = "+night")
    fun dashboardPhoneDark() {
        dashboard()
        capture("dashboard-phone-dark")
    }

    @Test
    @Config(qualifiers = PHONE_TALL)
    fun dashboardPhoneFullLight() {
        dashboard()
        compose.onNodeWithText("Cost over time").assertExists()
        compose.onNodeWithText("Plan limits").assertExists()
        compose.onNodeWithText("By model").assertExists()
        compose.onNodeWithText("Accounts & sources").assertExists()
        capture("dashboard-phone-full-light")
    }

    @Test
    @Config(qualifiers = PHONE_TALL_NIGHT)
    fun dashboardPhoneFullDark() {
        dashboard(MobileRange.DAY, "hour")
        capture("dashboard-phone-full-dark")
    }

    @Test
    @Config(qualifiers = PHONE_TALL)
    fun chartInspectorShowsTappedBucket() {
        dashboard(MobileRange.WEEK, "hour")
        compose.onNodeWithContentDescription("Cost over time chart", substring = true).performTouchInput { click(center) }
        compose.onNodeWithText("Tap or drag across the bars for details.").assertDoesNotExist()
        capture("dashboard-chart-inspect")
    }

    @Test
    @Config(qualifiers = TABLET)
    fun dashboardTabletLight() {
        dashboard()
        capture("dashboard-tablet-light")
    }

    @Test
    @Config(qualifiers = TABLET_NIGHT)
    fun dashboardTabletDark() {
        dashboard()
        capture("dashboard-tablet-dark")
    }

    @Test
    fun dashboardOffline() {
        show {
            DashboardScreen(
                state = FakeData.dashboard().copy(
                    error = "Couldn't reach Neil’s MacBook Pro (devbox.tail1234.ts.net:7787). Is Tailscale connected, and is PlanMeter running with Remote access on?",
                    lastUpdated = FakeData.now.minusSeconds(12 * 60),
                ),
                onRefresh = {}, onRangeChange = {}, onGranularityChange = {}, onOpenSettings = {},
                now = FakeData.now, zone = FakeData.zone,
            )
        }
        compose.onNodeWithText("Retry").assertExists()
        capture("dashboard-offline")
    }

    private fun pairing(state: PairingUiState = PairingUiState(), access: CameraAccess = CameraAccess.NOT_REQUESTED) = show {
        PairingScreen(
            state = state,
            cameraAccess = access,
            onRequestCamera = {},
            onOpenAppSettings = {},
            onPairText = {},
            onDismissError = {},
            readClipboard = { null },
            scanner = {},
        )
    }

    @Test
    fun pairingPhoneLight() {
        pairing()
        compose.onNodeWithText("Pair with your computer").assertExists()
        capture("pairing-phone-light")
    }

    @Test
    @Config(qualifiers = "+night")
    fun pairingPhoneDarkWithError() {
        pairing(PairingUiState(error = "This pairing code has expired. Create a new one in PlanMeter on your computer."), CameraAccess.PERMANENTLY_DENIED)
        capture("pairing-phone-dark-error")
    }

    @Test
    @Config(qualifiers = TABLET)
    fun pairingTablet() {
        pairing()
        capture("pairing-tablet-light")
    }

    private fun settings() = show {
        SettingsScreen(
            state = SettingsUiState(
                server = FakeData.server,
                deviceId = FakeData.server.deviceId,
                keyStorage = KeyStorage.STRONGBOX,
                requireBiometrics = true,
                biometricsAvailable = true,
                versionName = "0.3.6",
                versionCode = 14,
            ),
            onBack = {}, onRefresh = {}, onUnpair = {}, onRequireBiometricsChange = {},
            zone = FakeData.zone,
        )
    }

    @Test
    @Config(qualifiers = PHONE_TALL)
    fun settingsPhoneLight() {
        settings()
        compose.onNodeWithText("Unpair from Neil’s MacBook Pro").assertExists()
        capture("settings-phone-light")
    }

    @Test
    @Config(qualifiers = "+night")
    fun settingsPhoneDark() {
        settings()
        capture("settings-phone-dark")
    }

    @Test
    fun lockScreen() {
        show { LockScreen(onUnlockRequest = {}) }
        capture("lock-phone-light")
    }
}
