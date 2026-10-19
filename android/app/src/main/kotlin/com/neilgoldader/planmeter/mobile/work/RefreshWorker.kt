package com.neilgoldader.planmeter.mobile.work

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.neilgoldader.planmeter.mobile.AppGraph
import com.neilgoldader.planmeter.mobile.data.DashboardLoader
import com.neilgoldader.planmeter.mobile.data.WidgetSnapshot
import com.neilgoldader.planmeter.mobile.widget.SpendWidget
import com.neilgoldader.planmeter.mobile.widget.WidgetExpiry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException

/**
 * Keeps the home-screen widget current: every 15 minutes (the WorkManager
 * minimum; Android may defer it), fetch today's summary and re-render. The
 * widget is re-rendered even when the fetch fails, so it can switch to its
 * stale prompt, and its expiry alarm follows the snapshot it shows. Like the
 * iPhone, background refresh pauses while the app lock is on.
 */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val graph = AppGraph.from(applicationContext)
        val settings = graph.store.current()
        val server = settings.server ?: return Result.success()
        if (!settings.requireBiometrics) {
            try {
                val client = graph.client(server)
                val (summary, timeline) = DashboardLoader { request -> withContext(Dispatchers.IO) { client.call(request) } }.loadWidget()
                graph.store.saveWidgetSnapshot(WidgetSnapshot.from(summary, timeline))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Offline or asleep: keep the last snapshot; the widget shows its age.
            }
        }
        WidgetExpiry.redraw(applicationContext)
        return Result.success()
    }

    companion object {
        private const val NAME = "planmeter-widget-refresh"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }

        /** Schedules the job only while a widget is on the home screen. */
        suspend fun syncWithWidgets(context: Context) {
            val placed = GlanceAppWidgetManager(context).getGlanceIds(SpendWidget::class.java).isNotEmpty()
            if (placed && AppGraph.from(context).store.current().server != null) schedule(context) else cancel(context)
        }
    }
}

/**
 * Widget housekeeping that needs storage, so it can't run inside the widget
 * receiver's onUpdate: after a widget is placed, the phone restarts, or the app
 * updates, match the refresh job to the pairing and set the expiry alarm.
 */
class WidgetUpkeepWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        RefreshWorker.syncWithWidgets(applicationContext)
        WidgetExpiry.schedule(applicationContext, AppGraph.from(applicationContext).store.widgetSnapshot())
        return Result.success()
    }

    companion object {
        internal const val NAME = "planmeter-widget-upkeep"

        fun enqueue(context: Context) {
            WorkManager.getInstance(context)
                .enqueueUniqueWork(NAME, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<WidgetUpkeepWorker>().build())
        }
    }
}
