package com.neilgoldader.planmeter.mobile.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.Widgets
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.neilgoldader.planmeter.mobile.data.KeyStorage
import com.neilgoldader.planmeter.mobile.ui.theme.Surfaces
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.SecureChannel
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

data class SettingsUiState(
    val server: PairedServer?,
    val deviceId: String,
    val keyStorage: KeyStorage,
    val requireBiometrics: Boolean,
    /** False when the phone has no screen lock, so the app lock cannot be enforced. */
    val biometricsAvailable: Boolean,
    val versionName: String,
    val versionCode: Int,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onUnpair: () -> Unit,
    onRequireBiometricsChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    zone: ZoneId = ZoneId.systemDefault(),
) {
    var confirmUnpair by rememberSaveable { mutableStateOf(false) }
    Scaffold(
        modifier = modifier,
        containerColor = Surfaces.screen,
        contentWindowInsets = WindowInsets(0),
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Surfaces.screen, scrolledContainerColor = Surfaces.screen),
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            state.server?.let { server ->
                item {
                    Section("Host") {
                        InfoRow(Icons.Outlined.Dns, "Name", server.serverName)
                        Divider()
                        InfoRow(null, "Address", "${server.host}:${server.port}")
                        Divider()
                        InfoRow(null, "Paired", DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).format(server.pairedAt.atZone(zone)))
                        Divider()
                        InfoRow(Icons.Outlined.Key, "Server key", server.serverKeyFingerprint, monospace = true)
                    }
                }
            }
            item {
                Section("This device", footer = if (!state.biometricsAvailable) "Set a screen lock on this phone to use the app lock." else null) {
                    InfoRow(Icons.Outlined.Smartphone, "Device ID", state.deviceId, monospace = true)
                    Divider()
                    InfoRow(Icons.Outlined.Lock, "Key storage", state.keyStorage.label)
                    Divider()
                    ListItem(
                        headlineContent = { Text("Require fingerprint, face, or screen lock") },
                        supportingContent = { Text("Locks PlanMeter when you leave it. Background widget updates pause while this is on.") },
                        leadingContent = { Icon(Icons.Outlined.Fingerprint, contentDescription = null) },
                        trailingContent = {
                            Switch(
                                checked = state.requireBiometrics,
                                onCheckedChange = onRequireBiometricsChange,
                                enabled = state.biometricsAvailable || state.requireBiometrics,
                            )
                        },
                        colors = ListItemDefaults.colors(containerColor = Surfaces.card),
                    )
                }
            }
            item {
                Section("Automatic refresh") {
                    InfoRow(Icons.Outlined.Schedule, "While open", "Every 30 seconds")
                    Divider()
                    InfoRow(Icons.Outlined.Widgets, "Home-screen widget", "About every 15 minutes")
                    Divider()
                    ListItem(
                        headlineContent = { Text("Refresh now") },
                        leadingContent = { Icon(Icons.Outlined.Refresh, contentDescription = null) },
                        modifier = Modifier.clickableRow(onRefresh),
                        colors = ListItemDefaults.colors(containerColor = Surfaces.card),
                    )
                }
            }
            if (state.server != null) {
                item {
                    Section(
                        null,
                        footer = "Unpairing deletes the saved host on this phone. Also revoke this phone on your computer (PlanMeter → Remote → Paired devices) so its key can never reconnect.",
                    ) {
                        ListItem(
                            headlineContent = { Text("Unpair from ${state.server.serverName}", color = MaterialTheme.colorScheme.error) },
                            leadingContent = { Icon(Icons.Outlined.LinkOff, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                            modifier = Modifier.clickableRow { confirmUnpair = true },
                            colors = ListItemDefaults.colors(containerColor = Surfaces.card),
                        )
                    }
                }
            }
            item {
                Section("Security") {
                    Text(
                        "Transport: your tailnet (WireGuard). Payloads: ChaCha20-Poly1305 under a fresh ECDH key for every request, signed by this phone's Android Keystore key. The host only listens on its Tailscale address and only answers paired devices.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            item {
                Section("About") {
                    InfoRow(Icons.Outlined.Info, "Version", "${state.versionName} (${state.versionCode})")
                    Divider()
                    InfoRow(null, "Protocol", "planmeter-remote-v${SecureChannel.PROTOCOL_VERSION}")
                }
            }
            item { Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars).height(16.dp)) }
        }
    }

    if (confirmUnpair && state.server != null) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            icon = { Icon(Icons.Outlined.LinkOff, contentDescription = null) },
            title = { Text("Unpair from ${state.server.serverName}?") },
            text = { Text("This phone will stop showing usage. Revoke it on your computer too: PlanMeter → Remote → Paired devices.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmUnpair = false
                    onUnpair()
                }) { Text("Unpair", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Section(title: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.widthIn(max = 680.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title != null) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 16.dp).semantics { heading() },
            )
        }
        Surface(shape = RoundedCornerShape(20.dp), color = Surfaces.card) {
            Column(content = content)
        }
        if (footer != null) {
            Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))
        }
    }
}

@Composable
private fun InfoRow(icon: ImageVector?, label: String, value: String, monospace: Boolean = false) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = {
            Text(
                value,
                style = if (monospace) MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace) else MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                modifier = Modifier.widthIn(max = 220.dp),
            )
        },
        leadingContent = icon?.let { { Icon(it, contentDescription = null) } } ?: { Spacer(Modifier.widthIn(min = 24.dp)) },
        colors = ListItemDefaults.colors(containerColor = Surfaces.card),
    )
}

@Composable
private fun Divider() {
    HorizontalDivider(Modifier.padding(start = 56.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
}

private fun Modifier.clickableRow(onClick: () -> Unit): Modifier = clickable(onClick = onClick)
