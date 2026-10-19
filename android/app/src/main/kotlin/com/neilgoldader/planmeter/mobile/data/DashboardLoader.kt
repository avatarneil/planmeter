package com.neilgoldader.planmeter.mobile.data

import com.neilgoldader.planmeter.protocol.RemoteAccounts
import com.neilgoldader.planmeter.protocol.RemoteLimits
import com.neilgoldader.planmeter.protocol.RemoteMethod
import com.neilgoldader.planmeter.protocol.RemoteModelRow
import com.neilgoldader.planmeter.protocol.RemoteReply
import com.neilgoldader.planmeter.protocol.RemoteRequest
import com.neilgoldader.planmeter.protocol.RemoteSummary
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlin.coroutines.cancellation.CancellationException

/** Everything the dashboard shows for one range. */
data class DashboardData(
    val summary: RemoteSummary,
    val timeline: RemoteTimeline?,
    val limits: RemoteLimits?,
    val models: List<RemoteModelRow>,
    val accounts: RemoteAccounts?,
    /** The bucket size the timeline was requested at; a host may answer coarser. */
    val requestedGranularity: String,
    /** A day-or-longer summary and timeline for the widget, even while 1h is shown. */
    val widgetSummary: RemoteSummary?,
    val widgetTimeline: RemoteTimeline?,
)

sealed interface LoadResult {
    data class Loaded(val data: DashboardData) : LoadResult

    /** The host answered a sub-day request with a whole day: it predates `minutes`. */
    data object NoSubDayWindows : LoadResult
}

/**
 * Issues the same requests as the iPhone's MobileModel.refresh in direct mode,
 * concurrently: summary, timeline, limits, and models for the range, plus the
 * accounts list and (for 1h) a one-day summary and hourly timeline for the
 * widget. Optional requests tolerate failures from older hosts.
 */
class DashboardLoader(private val call: suspend (RemoteRequest) -> RemoteReply) {
    suspend fun load(range: MobileRange, granularity: String): LoadResult = coroutineScope {
        val days = range.days
        val minutes = range.minutes
        val summary = async { call(RemoteRequest(RemoteMethod.SUMMARY, days = days, minutes = minutes)) }
        val timeline = async { call(RemoteRequest(RemoteMethod.TIMELINE, days = days, resolution = granularity, minutes = minutes)) }
        val limits = async { call(RemoteRequest(RemoteMethod.LIMITS)) }
        val models = async { call(RemoteRequest(RemoteMethod.MODELS, days = days, minutes = minutes)) }
        val accounts = async { optional(RemoteRequest(RemoteMethod.ACCOUNTS)) }
        val daySummary = async { if (minutes != null) optional(RemoteRequest(RemoteMethod.SUMMARY, days = 1)) else null }
        val dayTimeline = async { if (minutes != null) optional(RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "hour")) else null }

        val s = summary.await().summary ?: throw IllegalStateException("The host sent no summary.")
        val t = timeline.await().timeline
        val l = limits.await().limits
        val m = models.await().models.orEmpty()
        if (minutes != null && s.minutes != minutes) return@coroutineScope LoadResult.NoSubDayWindows
        LoadResult.Loaded(
            DashboardData(
                summary = s,
                timeline = t,
                limits = l,
                models = m,
                accounts = accounts.await()?.accounts,
                requestedGranularity = granularity,
                widgetSummary = if (minutes == null) s else daySummary.await()?.summary,
                widgetTimeline = if (minutes == null) t else dayTimeline.await()?.timeline,
            ),
        )
    }

    /** For the background widget refresh: today's totals and the calendar-day split. */
    suspend fun loadWidget(): Pair<RemoteSummary, RemoteTimeline?> = coroutineScope {
        val summary = async { call(RemoteRequest(RemoteMethod.SUMMARY, days = 1)) }
        val timeline = async { optional(RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "hour")) }
        val s = summary.await().summary ?: throw IllegalStateException("The host sent no summary.")
        s to timeline.await()?.timeline
    }

    private suspend fun optional(request: RemoteRequest): RemoteReply? = try {
        call(request)
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }
}
