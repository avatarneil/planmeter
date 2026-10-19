package com.neilgoldader.planmeter.mobile.data

/**
 * The ranges the iPhone offers, with the same request parameters: `days`
 * always rides along because hosts that predate `minutes` ignore it.
 */
enum class MobileRange(val raw: Int, val days: Int, val minutes: Int?, val granularities: List<String>, val defaultGranularity: String) {
    HOUR(0, 1, 60, listOf("minute", "5m"), "minute"),
    DAY(1, 1, null, listOf("5m", "15m", "hour"), "hour"),
    WEEK(7, 7, null, listOf("15m", "hour", "day"), "day"),
    MONTH(30, 30, null, listOf("hour", "day"), "day"),
    QUARTER(90, 90, null, listOf("day"), "day"),
    ;

    /** "Today" when the host reports provider calendar days, like the web client. */
    fun label(usesProviderDates: Boolean? = null): String = when (this) {
        HOUR -> "1h"
        DAY -> if (usesProviderDates == true) "Today" else "24h"
        WEEK -> "7d"
        MONTH -> "30d"
        QUARTER -> "90d"
    }

    /** Spoken and long-form label, for TalkBack and the hero card. */
    fun longLabel(usesProviderDates: Boolean? = null): String = when (this) {
        HOUR -> "Last hour"
        DAY -> if (usesProviderDates == true) "Today" else "Last 24 hours"
        WEEK -> "Last 7 days"
        MONTH -> "Last 30 days"
        QUARTER -> "Last 90 days"
    }

    companion object {
        fun fromRaw(raw: Int): MobileRange = entries.firstOrNull { it.raw == raw } ?: MONTH

        fun granularityLabel(granularity: String): String = when (granularity) {
            "minute" -> "1 min"
            "5m" -> "5 min"
            "15m" -> "15 min"
            "hour" -> "1 hour"
            else -> "1 day"
        }
    }
}
