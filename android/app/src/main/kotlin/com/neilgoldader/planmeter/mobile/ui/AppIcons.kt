package com.neilgoldader.planmeter.mobile.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.vectorResource
import com.neilgoldader.planmeter.mobile.R

/**
 * The few Material Symbols the app uses, as vector drawables (res/drawable/ic_*.xml),
 * instead of the multi-megabyte material-icons-extended library.
 */
object AppIcons {
    val Refresh: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_refresh)
    val Settings: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_settings)
    val CloudOff: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_cloud_off)
    val History: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_history)
    val Warning: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_warning)
    val ContentPaste: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_content_paste)
    val Key: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_key)
    val Lan: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_lan)
    val NoPhotography: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_no_photography)
    val QrCodeScanner: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_qr_code_scanner)
    val Schedule: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_schedule)
    val Shield: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_shield)
    val ArrowBack: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_arrow_back)
    val Dns: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_dns)
    val Fingerprint: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_fingerprint)
    val Info: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_info)
    val LinkOff: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_link_off)
    val Lock: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_lock)
    val Smartphone: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_smartphone)
    val Widgets: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.ic_widgets)
}
