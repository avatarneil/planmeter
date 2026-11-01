package com.neilgoldader.planmeter.mobile.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
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
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
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
import com.neilgoldader.planmeter.mobile.work.WidgetUpkeepWorker
import kotlinx.coroutines.CoroutineExceptionHandler
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

    // A failed redraw must not take the whole process down with it.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, _ -> })

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        RefreshWorker.schedule(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        RefreshWorker.cancel(context)
        WidgetExpiry.cancel(context)
    }

    override fun onUpdate(context: Context, appWidgetManager: android.appwidget.AppWidgetManager, appWidgetIds: IntArray) {
        // Glance's onUpdate already holds this broadcast's goAsync() while it redraws, and a
        // second goAsync() returns null; the pairing-dependent checks run as work instead.
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        WidgetUpkeepWorker.enqueue(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            // Glance passes these through untouched, so this receiver owns the broadcast.
            WidgetExpiry.ACTION_EXPIRED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> {
                val pending: BroadcastReceiver.PendingResult? = goAsync()
                scope.launch {
                    try {
                        WidgetExpiry.redraw(context)
                    } finally {
                        pending?.finish()
                    }
                }
            }
        }
    }
}

/**
 * The widget's "today" expires 15 minutes after a sync or at midnight, like the
 * iPhone widget's timeline entry. Background refreshes can be deferred for
 * hours, so a non-waking alarm redraws it at that moment (or as soon as the
 * phone is next awake) to switch it to its stale prompt.
 */
object WidgetExpiry {
    const val ACTION_EXPIRED = "com.neilgoldader.planmeter.mobile.action.WIDGET_EXPIRED"

    suspend fun redraw(context: Context) {
        SpendWidget().updateAll(context)
        schedule(context, AppGraph.from(context).store.widgetSnapshot())
    }

    /** Sets the alarm for [snapshot]'s expiry, or clears it when there is nothing left to expire. */
    suspend fun schedule(context: Context, snapshot: WidgetSnapshot?, now: Instant = Instant.now()) {
        val placed = GlanceAppWidgetManager(context).getGlanceIds(SpendWidget::class.java).isNotEmpty()
        if (!placed || snapshot == null || snapshot.isStale(now)) {
            cancel(context)
            return
        }
        context.getSystemService(AlarmManager::class.java)
            ?.set(AlarmManager.RTC, snapshot.expiresAt().toEpochMilli(), pendingIntent(context))
    }

    fun cancel(context: Context) {
        context.getSystemService(AlarmManager::class.java)?.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, SpendWidgetReceiver::class.java).setAction(ACTION_EXPIRED),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
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
