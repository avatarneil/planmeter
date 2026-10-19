package com.neilgoldader.planmeter.mobile.ui.pairing

import com.neilgoldader.planmeter.mobile.ui.AppIcons
import android.Manifest
import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.neilgoldader.planmeter.mobile.R
import com.neilgoldader.planmeter.mobile.ui.PairingUiState
import com.neilgoldader.planmeter.mobile.ui.theme.Surfaces

enum class CameraAccess { GRANTED, NOT_REQUESTED, DENIED, PERMANENTLY_DENIED, UNAVAILABLE }

/** Pairing with permission handling and the live camera; [PairingScreen] is the stateless layout. */
@Composable
fun PairingRoute(state: PairingUiState, onPairText: (String) -> Unit, onDismissError: () -> Unit) {
    val context = LocalContext.current
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    var access by remember {
        mutableStateOf(
            when {
                !hasCamera -> CameraAccess.UNAVAILABLE
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED -> CameraAccess.GRANTED
                else -> CameraAccess.NOT_REQUESTED
            },
        )
    }
    // Access may change in system Settings (the "Open settings" button) while this screen waits.
    LifecycleResumeEffect(hasCamera) {
        if (hasCamera) {
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            if (granted) access = CameraAccess.GRANTED else if (access == CameraAccess.GRANTED) access = CameraAccess.NOT_REQUESTED
        }
        onPauseOrDispose {}
    }
    var lastScan by remember { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val activity = context.findActivity()
        access = when {
            granted -> CameraAccess.GRANTED
            activity != null && !activity.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) -> CameraAccess.PERMANENTLY_DENIED
            else -> CameraAccess.DENIED
        }
    }
    PairingScreen(
        state = state,
        cameraAccess = access,
        onRequestCamera = { launcher.launch(Manifest.permission.CAMERA) },
        onOpenAppSettings = {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        },
        onPairText = onPairText,
        onDismissError = {
            lastScan = null
            onDismissError()
        },
        readClipboard = { context.clipboardText() },
        scanner = { modifier ->
            QrScanner(
                onCode = { code ->
                    // A code that just failed stays in view; don't retry it every few seconds
                    // (failed attempts count toward the host's limit) until the error is dismissed.
                    if (!state.isPairing && code != lastScan) {
                        lastScan = code
                        onPairText(code)
                    }
                },
                modifier = modifier,
            )
        },
    )
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

private fun Context.clipboardText(): String? {
    val clipboard = getSystemService(ClipboardManager::class.java) ?: return null
    val clip = clipboard.primaryClip ?: return null
    if (clip.itemCount == 0) return null
    return clip.getItemAt(0).coerceToText(this)?.toString()
}

@Composable
fun PairingScreen(
    state: PairingUiState,
    cameraAccess: CameraAccess,
    onRequestCamera: () -> Unit,
    onOpenAppSettings: () -> Unit,
    onPairText: (String) -> Unit,
    onDismissError: () -> Unit,
    readClipboard: () -> String?,
    scanner: @Composable (Modifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    var link by rememberSaveable { mutableStateOf("") }
    Surface(modifier.fillMaxSize(), color = Surfaces.screen) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 840.dp
            val scroll = rememberScrollState()
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(scroll)
                    .padding(horizontal = if (wide) 48.dp else 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
                Spacer(Modifier.height(if (wide) 40.dp else 24.dp))
                if (wide) {
                    Row(Modifier.widthIn(max = 1100.dp), horizontalArrangement = Arrangement.spacedBy(40.dp)) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) {
                            Intro()
                            Facts()
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                            ErrorCard(state.error, onDismissError)
                            ScannerCard(cameraAccess, onRequestCamera, onOpenAppSettings, scanner)
                            PasteLink(link, { link = it }, state, onPairText, readClipboard)
                        }
                    }
                } else {
                    Column(Modifier.widthIn(max = 560.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        Intro()
                        ErrorCard(state.error, onDismissError)
                        ScannerCard(cameraAccess, onRequestCamera, onOpenAppSettings, scanner)
                        PasteLink(link, { link = it }, state, onPairText, readClipboard)
                        Facts()
                    }
                }
                Spacer(Modifier.height(24.dp))
                Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
            }
        }
    }
}

@Composable
private fun Intro() {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Surface(shape = RoundedCornerShape(16.dp), color = Color(0xFF1C1E26), modifier = Modifier.size(56.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Image(painterResource(R.drawable.ic_widget_mark), contentDescription = null, modifier = Modifier.size(32.dp))
            }
        }
        Text("Pair with your computer", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.semantics { heading() })
        Text(
            "On your Mac or Linux computer, open PlanMeter → Remote and create a pairing code. This phone and the computer need to be on the same tailnet.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ScannerCard(
    access: CameraAccess,
    onRequestCamera: () -> Unit,
    onOpenAppSettings: () -> Unit,
    scanner: @Composable (Modifier) -> Unit,
) {
    val shape = RoundedCornerShape(24.dp)
    Surface(
        Modifier.fillMaxWidth().aspectRatio(1.15f).heightIn(max = 420.dp),
        shape = shape,
        color = if (access == CameraAccess.GRANTED) Color.Black else Surfaces.card,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
    ) {
        if (access == CameraAccess.GRANTED) {
            Box(Modifier.fillMaxSize().clip(shape)) {
                scanner(Modifier.fillMaxSize())
                Box(Modifier.align(Alignment.Center).size(200.dp).background(Color.Transparent)) {
                    ViewfinderCorners()
                }
                Text(
                    "Point the camera at the pairing QR code",
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(14.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        } else {
            val (icon, title, body) = when (access) {
                CameraAccess.UNAVAILABLE -> Triple(AppIcons.NoPhotography, "No camera", "Paste the pairing link below instead.")
                CameraAccess.PERMANENTLY_DENIED -> Triple(AppIcons.NoPhotography, "Camera access is off", "Allow the camera in Settings, or paste the pairing link below.")
                CameraAccess.DENIED -> Triple(AppIcons.QrCodeScanner, "Scan the QR code", "PlanMeter uses the camera only to read the pairing code.")
                else -> Triple(AppIcons.QrCodeScanner, "Scan the QR code", "Allow camera access to scan the code shown by PlanMeter on your computer.")
            }
            Column(
                Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Box(
                    Modifier.size(72.dp).clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.size(36.dp))
                }
                Spacer(Modifier.height(16.dp))
                Text(title, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                when (access) {
                    CameraAccess.NOT_REQUESTED, CameraAccess.DENIED -> FilledTonalButton(onClick = onRequestCamera) { Text("Allow camera") }
                    CameraAccess.PERMANENTLY_DENIED -> FilledTonalButton(onClick = onOpenAppSettings) { Text("Open settings") }
                    else -> {}
                }
            }
        }
    }
}

@Composable
private fun ViewfinderCorners() {
    val color = Color.White
    val length = 28.dp
    val thickness = 4.dp
    Box(Modifier.fillMaxSize()) {
        for (alignment in listOf(Alignment.TopStart, Alignment.TopEnd, Alignment.BottomStart, Alignment.BottomEnd)) {
            Box(Modifier.align(alignment).size(length)) {
                val horizontal = if (alignment == Alignment.TopStart || alignment == Alignment.TopEnd) Alignment.TopCenter else Alignment.BottomCenter
                val vertical = if (alignment == Alignment.TopStart || alignment == Alignment.BottomStart) Alignment.CenterStart else Alignment.CenterEnd
                Box(Modifier.align(horizontal).fillMaxWidth().height(thickness).clip(RoundedCornerShape(2.dp)).background(color))
                Box(Modifier.align(vertical).width(thickness).fillMaxHeight().clip(RoundedCornerShape(2.dp)).background(color))
            }
        }
    }
}

@Composable
private fun PasteLink(
    link: String,
    onLinkChange: (String) -> Unit,
    state: PairingUiState,
    onPairText: (String) -> Unit,
    readClipboard: () -> String?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Or paste the pairing link", style = MaterialTheme.typography.titleSmall)
        OutlinedTextField(
            value = link,
            onValueChange = onLinkChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("planmeter://pair?…") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
            keyboardActions = KeyboardActions(onGo = { if (link.isNotBlank()) onPairText(link) }),
            trailingIcon = {
                IconButton(onClick = { readClipboard()?.let { onLinkChange(it.trim()) } }) {
                    Icon(AppIcons.ContentPaste, contentDescription = "Paste from clipboard")
                }
            },
            shape = RoundedCornerShape(14.dp),
        )
        Button(
            onClick = { onPairText(link) },
            enabled = link.isNotBlank() && !state.isPairing,
            modifier = Modifier.fillMaxWidth().height(48.dp),
        ) {
            if (state.isPairing) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                Spacer(Modifier.size(10.dp))
                Text("Pairing…")
            } else {
                Text("Pair")
            }
        }
    }
}

@Composable
private fun ErrorCard(error: String?, onDismiss: () -> Unit) {
    if (error == null) return
    Surface(
        Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Assertive },
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
    ) {
        Row(Modifier.padding(start = 14.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(AppIcons.Warning, contentDescription = null, modifier = Modifier.size(20.dp))
            Text(error, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
            TextButton(onClick = onDismiss) { Text("Dismiss", color = MaterialTheme.colorScheme.onErrorContainer) }
        }
    }
}

@Composable
private fun Facts() {
    Surface(shape = RoundedCornerShape(20.dp), color = Surfaces.card, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Fact(AppIcons.Lan, "Install the Tailscale app on this phone and sign in to the same tailnet as your computer.")
            Fact(AppIcons.Schedule, "Pairing codes are single use and expire in 5 minutes.")
            Fact(AppIcons.Key, "This phone's key stays in its secure hardware. Your computer pins it.")
            Fact(AppIcons.Shield, "Every request is end-to-end encrypted and signed, on top of Tailscale's WireGuard.")
        }
    }
}

@Composable
private fun Fact(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
