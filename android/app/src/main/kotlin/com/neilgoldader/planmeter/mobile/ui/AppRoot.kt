package com.neilgoldader.planmeter.mobile.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.neilgoldader.planmeter.mobile.BuildConfig
import com.neilgoldader.planmeter.mobile.ui.dashboard.DashboardScreen
import com.neilgoldader.planmeter.mobile.ui.pairing.PairingRoute
import com.neilgoldader.planmeter.mobile.ui.settings.SettingsScreen
import com.neilgoldader.planmeter.mobile.ui.settings.SettingsUiState
import com.neilgoldader.planmeter.mobile.ui.theme.Surfaces
import com.neilgoldader.planmeter.mobile.ui.theme.tabular
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.PairingInvite
import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable

@Serializable
private object DashboardRoute

@Serializable
private object SettingsRoute

/** Refresh cadence while the app is in the foreground, as on the iPhone. */
private const val FOREGROUND_REFRESH_MILLIS = 30_000L

@Composable
fun AppRoot(viewModel: AppViewModel, biometricsAvailable: Boolean, onUnlockRequest: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    if (!state.ready) {
        Surface(Modifier.fillMaxSize(), color = Surfaces.screen) {}
        return
    }

    val paired = state.dashboard.server != null
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, paired, state.isLocked) {
        if (!paired || state.isLocked) return@LaunchedEffect
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                viewModel.refresh(userInitiated = false)
                delay(FOREGROUND_REFRESH_MILLIS)
            }
        }
    }

    when {
        state.isLocked -> LockScreen(onUnlockRequest)
        !paired -> PairingRoute(state.pairing, onPairText = viewModel::pair, onDismissError = viewModel::dismissPairingError)
        else -> PairedNavigation(viewModel, state, biometricsAvailable)
    }

    state.pairing.pendingInvite?.takeIf { !state.isLocked }?.let { invite ->
        PendingInviteDialog(
            invite = invite,
            current = state.dashboard.server,
            onConfirm = viewModel::confirmPendingInvite,
            onDismiss = viewModel::dismissPendingInvite,
        )
    }
    if (paired && !state.isLocked) {
        state.pairing.error?.let { error ->
            AlertDialog(
                onDismissRequest = viewModel::dismissPairingError,
                title = { Text("Couldn't pair") },
                text = { Text(error) },
                confirmButton = { TextButton(onClick = viewModel::dismissPairingError) { Text("OK") } },
            )
        }
    }
}

@Composable
private fun PairedNavigation(viewModel: AppViewModel, state: AppUiState, biometricsAvailable: Boolean) {
    val navController = rememberNavController()
    NavHost(navController, startDestination = DashboardRoute) {
        composable<DashboardRoute> {
            DashboardScreen(
                state = state.dashboard,
                onRefresh = { viewModel.refresh(userInitiated = true) },
                onRangeChange = viewModel::setRange,
                onGranularityChange = viewModel::setGranularity,
                onOpenSettings = { navController.navigate(SettingsRoute) { launchSingleTop = true } },
            )
        }
        composable<SettingsRoute> {
            SettingsScreen(
                state = SettingsUiState(
                    server = state.dashboard.server,
                    deviceId = state.device.deviceId,
                    keyStorage = state.device.keyStorage,
                    requireBiometrics = state.requireBiometrics,
                    biometricsAvailable = biometricsAvailable,
                    versionName = BuildConfig.VERSION_NAME,
                    versionCode = BuildConfig.VERSION_CODE,
                ),
                onBack = { navController.popBackStack() },
                onRefresh = {
                    viewModel.refresh(userInitiated = true)
                    navController.popBackStack()
                },
                onUnpair = viewModel::unpair,
                onRequireBiometricsChange = viewModel::setRequireBiometrics,
            )
        }
    }
}

/**
 * Confirms a pairing link opened from outside the app. The name is whatever
 * the link says, so the address and the key fingerprint (as Settings shows it
 * once paired) tell the user which computer it really is.
 */
@Composable
private fun PendingInviteDialog(invite: PairingInvite, current: PairedServer?, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Pair with ${invite.serverName}?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (current != null) "This phone is paired with ${current.serverName}. Pairing with ${invite.serverName} replaces it."
                    else "Only continue if this link came from your own computer.",
                )
                Text("Address: ${invite.address}\nKey: ${invite.serverKeyFingerprint}", style = MaterialTheme.typography.bodySmall.tabular())
            }
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text("Pair") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun LockScreen(onUnlockRequest: () -> Unit) {
    // Prompt as soon as the lock appears; the button covers a cancelled prompt.
    LaunchedEffect(Unit) { onUnlockRequest() }
    Surface(Modifier.fillMaxSize(), color = Surfaces.screen) {
        Box(contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(AppIcons.Lock, contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("PlanMeter is locked", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(4.dp))
                Button(onClick = onUnlockRequest) { Text("Unlock") }
            }
        }
    }
}
