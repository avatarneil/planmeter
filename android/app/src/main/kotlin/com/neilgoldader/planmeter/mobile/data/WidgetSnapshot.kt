package com.neilgoldader.planmeter.mobile.data

import com.neilgoldader.planmeter.protocol.RemoteSummary
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import com.neilgoldader.planmeter.protocol.WireDate
import kotlinx.serialization.Serializable
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/** The compact summary the home-screen widget draws, like the iPhone's WatchPayload. */
@Serializable
data class WidgetSnapshot(
    val updatedAt: WireDate,
    val serverName: String,
    val days: Int,
    val usesProviderDates: Boolean? = null,
    val todayCostUsd: Double,
    /** Calendar-today cost per group from timeline buckets; null if the host sent no timeline. */
    val todayCostByGroup: Map<String, Double>? = null,
    val personalCostUsd: Double = 0.0,
    val workCostUsd: Double = 0.0,
    val otherCostUsd: Double = 0.0,
) {
    /** A cached "today" must not silently become tomorrow's: stale after 15 minutes or past midnight. */
    fun isStale(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): Boolean =
        Duration.between(updatedAt, now) >= STALE_AFTER || updatedAt.atZone(zone).toLocalDate() != now.atZone(zone).toLocalDate()

    /** When [isStale] turns true: [STALE_AFTER] past the sync, or the following midnight if that comes first. */
    fun expiresAt(zone: ZoneId = ZoneId.systemDefault()): Instant =
        minOf(updatedAt.plus(STALE_AFTER), updatedAt.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant())

    /** Today's cost for one group, falling back to the one-day totals when there is no timeline. */
    fun today(group: String): Double = todayCostByGroup?.let { it[group] ?: 0.0 } ?: when (group) {
        "personal" -> personalCostUsd
        "work" -> workCostUsd
        else -> otherCostUsd
    }

    /** Whether [today] is the calendar-day split rather than the summary's window. */
    val hasCalendarSplit: Boolean get() = todayCostByGroup != null

    companion object {
        val STALE_AFTER: Duration = Duration.ofMinutes(15)

        fun from(summary: RemoteSummary, timeline: RemoteTimeline?, zone: ZoneId = ZoneId.systemDefault()): WidgetSnapshot {
            fun group(name: String) = summary.groups.firstOrNull { it.group == name }?.totals?.costUsd ?: 0.0
            return WidgetSnapshot(
                updatedAt = summary.generatedAt,
                serverName = summary.serverName,
                days = summary.days,
                usesProviderDates = summary.usesProviderDates,
                todayCostUsd = summary.todayCostUsd,
                // Timeline points are buckets; use calendar today, never the rolling 24-hour totals.
                todayCostByGroup = timeline?.costByGroup(summary.generatedAt, zone),
                personalCostUsd = group("personal"),
                workCostUsd = group("work"),
                otherCostUsd = group("other"),
            )
        }
    }
}
