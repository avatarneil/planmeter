package com.neilgoldader.planmeter.mobile.ui

import android.text.format.DateUtils
import java.text.NumberFormat
import java.time.Instant
import java.util.Currency
import java.util.Locale

/** Number, currency, and date formatting, matching the iPhone's Fmt but locale-aware. */
object Fmt {
    private val usd: Currency = Currency.getInstance("USD")

    fun usd(value: Double, locale: Locale = Locale.getDefault()): String {
        if (value == 0.0) return currency(0.0, 2, locale)
        if (value > 0 && value < 0.005) return "<" + currency(0.01, 2, locale)
        return currency(value, if (kotlin.math.abs(value) >= 1000) 0 else 2, locale)
    }

    /** Short amounts for the widget: $4.6, $46, $1.2K, $12K. */
    fun compactUsd(value: Double, locale: Locale = Locale.getDefault()): String = when {
        value >= 10_000 -> currency(value / 1000, 0, locale) + "K"
        value >= 1000 -> currency(value / 1000, 1, locale) + "K"
        value >= 10 -> currency(value, 0, locale)
        value == 0.0 -> currency(0.0, 0, locale)
        else -> currency(value, 2, locale)
    }

    private fun currency(value: Double, fraction: Int, locale: Locale): String {
        val format = NumberFormat.getCurrencyInstance(locale)
        format.currency = usd
        format.minimumFractionDigits = fraction
        format.maximumFractionDigits = fraction
        return format.format(value)
    }

    fun tokens(value: Long, locale: Locale = Locale.getDefault()): String {
        val v = value.toDouble()
        return when {
            v >= 1_000_000_000 -> String.format(locale, "%.2fB", v / 1_000_000_000)
            v >= 1_000_000 -> String.format(locale, "%.1fM", v / 1_000_000)
            v >= 10_000 -> String.format(locale, "%.0fK", v / 1_000)
            v >= 1_000 -> String.format(locale, "%.1fK", v / 1_000)
            else -> NumberFormat.getIntegerInstance(locale).format(value)
        }
    }

    fun integer(value: Long, locale: Locale = Locale.getDefault()): String = NumberFormat.getIntegerInstance(locale).format(value)

    fun percent(fraction: Double, locale: Locale = Locale.getDefault()): String {
        if (!fraction.isFinite()) return "–"
        return NumberFormat.getPercentInstance(locale).apply { maximumFractionDigits = 0 }.format(fraction)
    }

    /** "5 min. ago", "in 2 hr." in the user's language. */
    fun relative(instant: Instant, now: Instant = Instant.now(), midSentence: Boolean = false): String {
        val delta = kotlin.math.abs(now.toEpochMilli() - instant.toEpochMilli())
        if (delta < DateUtils.MINUTE_IN_MILLIS) return "just now"
        val text = DateUtils.getRelativeTimeSpanString(instant.toEpochMilli(), now.toEpochMilli(), DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()
        // English capitalizes "In 2 hr."; other languages keep their own casing.
        val locale = Locale.getDefault()
        return if (midSentence && locale.language == "en") text.replaceFirstChar { it.lowercase(locale) } else text
    }

    fun groupName(raw: String): String = when (raw) {
        "personal" -> "Personal"
        "work" -> "Work"
        else -> "Other"
    }
}
