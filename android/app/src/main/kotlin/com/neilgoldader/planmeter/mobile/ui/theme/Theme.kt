package com.neilgoldader.planmeter.mobile.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.glance.material3.ColorProviders

/** Plan-group colors shared with the Mac, iPhone, and web clients. Data colors never follow dynamic color. */
object GroupColors {
    val personal = Color(0xFF0891B2)
    val work = Color(0xFF7C3AED)
    val other = Color(0xFF8B8F98)

    fun of(group: String): Color = when (group) {
        "personal" -> personal
        "work" -> work
        else -> other
    }
}

/** Per-account series colors, the same order as the iPhone's Palette.series. */
object SeriesPalette {
    val colors = listOf(
        Color(0xFF4F7CFF), Color(0xFFF0883E), Color(0xFF2FB87A), Color(0xFFC06AD9),
        Color(0xFFE5484D), Color(0xFF0AA8A7), Color(0xFFD9A400), Color(0xFF8B8F98),
    )

    fun parseHex(hex: String?): Color? {
        val s = hex?.trim()?.removePrefix("#") ?: return null
        if (s.length != 6) return null
        val value = s.toLongOrNull(16) ?: return null
        return Color(0xFF000000 or value)
    }
}

/**
 * Fallback scheme for Android 11 and below: a teal accent near the Mac/iOS Personal color, with
 * neutral teal-grey selection so controls never read as the violet Work group.
 */
val PlanMeterLightColors: ColorScheme = lightColorScheme(
    primary = Color(0xFF0E7490), onPrimary = Color.White,
    primaryContainer = Color(0xFFCCF1F8), onPrimaryContainer = Color(0xFF053F4D),
    secondary = Color(0xFF4A6268), onSecondary = Color.White,
    secondaryContainer = Color(0xFFCDE7ED), onSecondaryContainer = Color(0xFF051F23),
    tertiary = Color(0xFFB45309), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFDECD3), onTertiaryContainer = Color(0xFF4A2304),
    background = Color(0xFFF3F4F6), onBackground = Color(0xFF191C1F),
    surface = Color(0xFFF8F9FA), onSurface = Color(0xFF191C1F),
    surfaceVariant = Color(0xFFDEE3E7), onSurfaceVariant = Color(0xFF42484C),
    outline = Color(0xFF72787C), outlineVariant = Color(0xFFC2C7CB),
    inverseSurface = Color(0xFF2D3134), inverseOnSurface = Color(0xFFEFF1F3), inversePrimary = Color(0xFF67D4EC),
    surfaceDim = Color(0xFFD9DBDE), surfaceBright = Color(0xFFF8F9FA),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF6F7F9),
    surfaceContainer = Color(0xFFF0F2F4), surfaceContainerHigh = Color(0xFFEAECEF),
    surfaceContainerHighest = Color(0xFFE4E6E9),
)

val PlanMeterDarkColors: ColorScheme = darkColorScheme(
    primary = Color(0xFF67D4EC), onPrimary = Color(0xFF003641),
    primaryContainer = Color(0xFF0E5566), onPrimaryContainer = Color(0xFFCCF1F8),
    secondary = Color(0xFFB1CBD1), onSecondary = Color(0xFF1C3438),
    secondaryContainer = Color(0xFF334B50), onSecondaryContainer = Color(0xFFCDE7ED),
    tertiary = Color(0xFFF6B66B), onTertiary = Color(0xFF4A2304),
    tertiaryContainer = Color(0xFF6B3A0A), onTertiaryContainer = Color(0xFFFDECD3),
    background = Color(0xFF111318), onBackground = Color(0xFFE2E3E6),
    surface = Color(0xFF111318), onSurface = Color(0xFFE2E3E6),
    surfaceVariant = Color(0xFF3F4448), onSurfaceVariant = Color(0xFFC0C6CB),
    outline = Color(0xFF8A9095), outlineVariant = Color(0xFF3F4448),
    inverseSurface = Color(0xFFE2E3E6), inverseOnSurface = Color(0xFF2E3035), inversePrimary = Color(0xFF0E7490),
    surfaceDim = Color(0xFF111318), surfaceBright = Color(0xFF37393E),
    surfaceContainerLowest = Color(0xFF0C0E12), surfaceContainerLow = Color(0xFF191B20),
    surfaceContainer = Color(0xFF1D1F24), surfaceContainerHigh = Color(0xFF272A2F),
    surfaceContainerHighest = Color(0xFF32353A),
)

@Composable
fun PlanMeterTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> PlanMeterDarkColors
        else -> PlanMeterLightColors
    }
    MaterialTheme(colorScheme = colors, typography = PlanMeterTypography, content = content)
}

/** Grouped-list look: cards one step lighter than the screen in light mode, raised in dark mode. */
object Surfaces {
    val isDark: Boolean
        @Composable @ReadOnlyComposable get() = MaterialTheme.colorScheme.surface.luminance() < 0.5f

    val screen: Color
        @Composable @ReadOnlyComposable get() = if (isDark) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.surfaceContainer

    val card: Color
        @Composable @ReadOnlyComposable get() = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest
}

object WidgetColors {
    /** Used before Android 12; later versions use the wallpaper-based dynamic colors. */
    val fallback = ColorProviders(light = PlanMeterLightColors, dark = PlanMeterDarkColors)
}
