package com.neilgoldader.planmeter.mobile

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.neilgoldader.planmeter.mobile.ui.AppRoot
import com.neilgoldader.planmeter.mobile.ui.AppViewModel
import com.neilgoldader.planmeter.mobile.ui.theme.PlanMeterTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** A FragmentActivity because androidx.biometric's prompt is fragment-based. */
class MainActivity : FragmentActivity() {
    private val viewModel: AppViewModel by viewModels()

    /** Biometrics or the screen lock, like iOS's deviceOwnerAuthentication. Works back to API 28. */
    private val authenticators = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
    private var authInProgress = false

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleIntent(intent)

        setContent {
            PlanMeterTheme {
                AppRoot(viewModel, biometricsAvailable = canAuthenticate(), onUnlockRequest = ::authenticate)
            }
        }

        // Keep usage out of the recents thumbnail while the app lock is on. The lock
        // itself starts in onStop, after the thumbnail is taken. Before Android 13 the
        // only way is FLAG_SECURE, which also blocks screenshots while the lock is on.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.CREATED) {
                viewModel.state.map { it.requireBiometrics }.distinctUntilChanged().collect { hide ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        setRecentsScreenshotEnabled(!hide)
                    } else if (hide) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val link = intent.dataString ?: return
        if (link.startsWith("planmeter://pair", ignoreCase = true)) viewModel.openPairingLink(link)
    }

    override fun onStop() {
        super.onStop()
        // The screen-lock credential screen is a separate activity; don't re-lock for it.
        if (!authInProgress && !isChangingConfigurations) viewModel.lockIfNeeded()
    }

    private fun canAuthenticate(): Boolean =
        BiometricManager.from(this).canAuthenticate(authenticators) == BiometricManager.BIOMETRIC_SUCCESS

    private fun authenticate() {
        if (authInProgress) return
        if (!canAuthenticate()) {
            // No screen lock: the lock cannot be enforced, so don't brick the app.
            viewModel.unlocked()
            return
        }
        authInProgress = true
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    authInProgress = false
                    viewModel.unlocked()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    authInProgress = false
                }
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Unlock PlanMeter")
                .setAllowedAuthenticators(authenticators)
                .build(),
        )
    }
}
