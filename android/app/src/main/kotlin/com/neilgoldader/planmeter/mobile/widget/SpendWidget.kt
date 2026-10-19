package com.neilgoldader.planmeter.mobile.widget

import android.content.Context
import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.neilgoldader.planmeter.mobile.AppGraph
import com.neilgoldader.planmeter.mobile.MainActivity
import com.neilgoldader.planmeter.mobile.R
import com.neilgoldader.planmeter.mobile.data.WidgetSnapshot
import com.neilgoldader.planmeter.mobile.ui.Fmt
import com.neilgoldader.planmeter.mobile.ui.theme.GroupColors
import com.neilgoldader.planmeter.mobile.ui.theme.WidgetColors
import com.neilgoldader.planmeter.mobile.work.RefreshWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.Date

/** Today's spend and the Personal/Work split, like the iPhone's AI Spend widget. */
class SpendWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, WIDE))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = AppGraph.from(context).store.widgetSnapshot()
        provideContent {
            WidgetTheme { SpendWidgetContent(snapshot, Instant.now()) }
        }
    }

    companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val WIDE = DpSize(250.dp, 110.dp)
    }
}

class SpendWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SpendWidget()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        RefreshWorker.schedule(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        RefreshWorker.cancel(context)
    }

    override fun onUpdate(context: Context, appWidgetManager: android.appwidget.AppWidgetManager, appWidgetIds: IntArray) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        val pending = goAsync()
        scope.launch {
            try {
                RefreshWorker.syncWithWidgets(context)
            } finally {
                pending.finish()
            }
        }
    }
}

/** Wallpaper-based dynamic colors on Android 12+, the PlanMeter palette before. */
@Composable
fun WidgetTheme(content: @Composable () -> Unit) {
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) GlanceTheme(content = content)
    else GlanceTheme(colors = WidgetColors.fallback, content = content)
}

@Composable
fun SpendWidgetContent(snapshot: WidgetSnapshot?, now: Instant) {
    val context = LocalContext.current
    val wide = LocalSize.current.width >= SpendWidget.WIDE.width
    val muted = GlanceTheme.colors.onSurfaceVariant
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(GlanceTheme.colors.widgetBackground)
            .cornerRadius(20.dp)
            .padding(14.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Image(provider = ImageProvider(R.drawable.ic_widget_mark), contentDescription = null, modifier = GlanceModifier.size(16.dp))
            Spacer(GlanceModifier.width(6.dp))
            Text("PlanMeter", style = TextStyle(color = GlanceTheme.colors.primary, fontSize = 12.sp, fontWeight = FontWeight.Medium), maxLines = 1)
        }
        Spacer(GlanceModifier.height(8.dp))
        if (snapshot == null) {
            Text("Ready to sync", style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 16.sp, fontWeight = FontWeight.Bold))
            Spacer(GlanceModifier.height(4.dp))
            Text("Open PlanMeter to pair with your computer.", style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 3)
            return@Column
        }
        val stale = snapshot.isStale(now)
        val todayLabel = if (stale) "Today at last sync" else "Today"
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Column(modifier = GlanceModifier.defaultWeight()) {
                Text(todayLabel, style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 1)
                Text(
                    Fmt.usd(snapshot.todayCostUsd),
                    style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 30.sp, fontWeight = FontWeight.Bold),
                    maxLines = 1,
                    modifier = GlanceModifier.semantics { contentDescription = "$todayLabel ${Fmt.usd(snapshot.todayCostUsd)}" },
                )
                if (!wide) {
                    Spacer(GlanceModifier.height(6.dp))
                    SplitRow("Personal", snapshot.today("personal"), GroupColors.personal)
                    SplitRow("Work", snapshot.today("work"), GroupColors.work)
                }
            }
            if (wide) {
                Spacer(GlanceModifier.width(12.dp))
                Column(modifier = GlanceModifier.defaultWeight()) {
                    val splitLabel = if (snapshot.hasCalendarSplit) "Today by plan" else if (snapshot.usesProviderDates == true) "Last day" else "Last 24h"
                    Text(splitLabel, style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 1)
                    Spacer(GlanceModifier.height(4.dp))
                    SplitRow("Personal", snapshot.today("personal"), GroupColors.personal)
                    SplitRow("Work", snapshot.today("work"), GroupColors.work)
                    if (snapshot.today("other") > 0) SplitRow("Other", snapshot.today("other"), GroupColors.other)
                }
            }
        }
        Spacer(GlanceModifier.defaultWeight())
        val footer = if (stale) "Open PlanMeter to refresh" else "Updated ${DateFormat.getTimeFormat(context).format(Date.from(snapshot.updatedAt))}"
        Text(footer, style = TextStyle(color = muted, fontSize = 11.sp), maxLines = 1)
    }
}

@Composable
private fun SplitRow(name: String, cost: Double, color: Color) {
    Row(modifier = GlanceModifier.fillMaxWidth().padding(vertical = 1.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(modifier = GlanceModifier.size(8.dp).cornerRadius(4.dp).background(ColorProvider(color))) {}
        Spacer(GlanceModifier.width(6.dp))
        Text(name, style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp), maxLines = 1, modifier = GlanceModifier.defaultWeight())
        Text(Fmt.compactUsd(cost), style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp, fontWeight = FontWeight.Medium), maxLines = 1)
    }
}
