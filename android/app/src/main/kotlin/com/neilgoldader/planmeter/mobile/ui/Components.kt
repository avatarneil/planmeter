package com.neilgoldader.planmeter.mobile.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.neilgoldader.planmeter.mobile.ui.theme.Surfaces
import com.neilgoldader.planmeter.mobile.ui.theme.tabular

val CardShape = RoundedCornerShape(20.dp)

/** A grouped card, like the iPhone's CardBackground. */
@Composable
fun PlanCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier = modifier.fillMaxWidth(), shape = CardShape, color = Surfaces.card) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

@Composable
fun CardTitle(text: String, modifier: Modifier = Modifier, trailing: @Composable RowScope.() -> Unit = {}) {
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        trailing()
    }
}

@Composable
fun Dot(color: Color, size: Int = 10) {
    Box(Modifier.size(size.dp).clip(CircleShape).background(color))
}

@Composable
fun Stat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(value, style = MaterialTheme.typography.bodyLarge.tabular(), maxLines = 1)
    }
}

/** A thin rounded progress track, used for shares and limits. */
@Composable
fun ShareBar(fraction: Double, color: Color, modifier: Modifier = Modifier, height: Int = 6) {
    val clamped = fraction.coerceIn(0.0, 1.0).toFloat()
    Box(
        modifier
            .fillMaxWidth()
            .height(height.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)),
    ) {
        if (clamped > 0f) {
            Box(Modifier.fillMaxWidth(clamped).height(height.dp).clip(CircleShape).background(color))
        }
    }
}

/** Compact pill, e.g. a plan name. */
@Composable
fun Pill(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, container: Color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f)) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        maxLines = 1,
        modifier = Modifier.clip(CircleShape).background(container).padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

enum class BannerTone { Error, Warning, Info }

@Composable
fun Banner(
    icon: ImageVector,
    text: String,
    tone: BannerTone,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val (container, content) = when (tone) {
        BannerTone.Error -> MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
        BannerTone.Warning -> MaterialTheme.colorScheme.tertiaryContainer to MaterialTheme.colorScheme.onTertiaryContainer
        BannerTone.Info -> MaterialTheme.colorScheme.secondaryContainer to MaterialTheme.colorScheme.onSecondaryContainer
    }
    Surface(modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = container, contentColor = content) {
        Row(Modifier.padding(start = 14.dp, end = 6.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction) { Text(actionLabel, color = content) }
            }
        }
    }
}
