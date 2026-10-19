package com.neilgoldader.planmeter.mobile.ui.dashboard

import android.icu.text.DateFormat as IcuDateFormat
import android.icu.util.TimeZone as IcuTimeZone
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLocale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.neilgoldader.planmeter.mobile.ui.Dot
import com.neilgoldader.planmeter.mobile.ui.Fmt
import com.neilgoldader.planmeter.mobile.ui.theme.tabular
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow

/** One stacked bar: untimed workspace baselines first, then timed usage, in account order. */
data class ChartBar(val start: Instant, val end: Instant, val segments: List<ChartSegment>) {
    val total: Double = segments.sumOf { it.value }
}

data class ChartSegment(val accountId: String, val value: Double, val baseline: Boolean)

/** Bars and axes for a timeline, independent of drawing so it can be unit tested. */
class ChartModel(val timeline: RemoteTimeline, val zone: ZoneId = ZoneId.systemDefault()) {
    val step: Long? = RemoteTimeline.stepSeconds(timeline.resolution)

    fun bucketEnd(start: Instant): Instant =
        step?.let { start.plusSeconds(it) } ?: start.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant()

    val bars: List<ChartBar> = run {
        val order = timeline.accounts.withIndex().associate { it.value.id to it.index }
        timeline.points.groupBy { it.period }.toSortedMap().map { (period, points) ->
            val sorted = points.sortedBy { order[it.accountId] ?: Int.MAX_VALUE }
            val segments = buildList {
                for (baseline in listOf(true, false)) {
                    for (point in sorted) {
                        val base = minOf(point.costUsd, point.baselineCostUsd ?: 0.0)
                        val value = if (baseline) base else point.costUsd - base
                        if (value > 0) add(ChartSegment(point.accountId, value, baseline))
                    }
                }
            }
            ChartBar(period, bucketEnd(period), segments)
        }.filter { it.total > 0 }
    }

    /** The whole window, so a few active buckets don't zoom the axis. */
    val domainStart: Instant = timeline.periods.firstOrNull() ?: bars.firstOrNull()?.start ?: Instant.EPOCH
    val domainEnd: Instant = run {
        val last = timeline.periods.lastOrNull() ?: bars.lastOrNull()?.start ?: domainStart
        val end = bucketEnd(last)
        if (end.isAfter(domainStart.plusSeconds(60))) end else domainStart.plusSeconds(60)
    }

    val maxTotal: Double = bars.maxOfOrNull { it.total } ?: 0.0
    val hasBaseline: Boolean = bars.any { bar -> bar.segments.any { it.baseline } }

    fun fraction(instant: Instant): Float {
        val span = (domainEnd.epochSecond - domainStart.epochSecond).toFloat()
        return ((instant.epochSecond - domainStart.epochSecond) / span)
    }

    /** About [count] round values from zero to at least [maxTotal]. */
    fun yTicks(count: Int = 4): List<Double> {
        if (maxTotal <= 0) return listOf(0.0, 1.0)
        val raw = maxTotal / count
        val magnitude = 10.0.pow(floor(log10(raw)))
        val step = listOf(1.0, 2.0, 2.5, 5.0, 10.0).map { it * magnitude }.first { it >= raw }
        val top = ceil(maxTotal / step) * step
        return generateSequence(0.0) { it + step }.takeWhile { it <= top + step / 2 }.toList()
    }

    /** Round label positions (local wall-clock minutes) at most [maxLabels] apart. */
    fun xTicks(maxLabels: Int): Pair<Long, List<Instant>> {
        val spanMinutes = (domainEnd.epochSecond - domainStart.epochSecond) / 60.0
        val tickMinutes = TICK_STEPS.firstOrNull { spanMinutes / it <= maxLabels.coerceAtLeast(2) } ?: TICK_STEPS.last()
        val ticks = mutableListOf<Instant>()
        val start = domainStart.atZone(zone)
        if (tickMinutes < 1440) {
            val dayStart = start.truncatedTo(ChronoUnit.DAYS)
            var minutes = ceil(ChronoUnit.MINUTES.between(dayStart, start) / tickMinutes.toDouble()).toLong() * tickMinutes
            while (true) {
                val t = dayStart.plusMinutes(minutes).toInstant()
                if (t.isAfter(domainEnd)) break
                if (!t.isBefore(domainStart)) ticks += t
                minutes += tickMinutes
            }
        } else if (tickMinutes == 43_200L) {
            var month = start.toLocalDate().withDayOfMonth(1)
            if (month.atStartOfDay(zone).toInstant().isBefore(domainStart)) month = month.plusMonths(1)
            while (!month.atStartOfDay(zone).toInstant().isAfter(domainEnd)) {
                ticks += month.atStartOfDay(zone).toInstant()
                month = month.plusMonths(1)
            }
        } else {
            val days = tickMinutes / 1440
            var date: LocalDate = start.toLocalDate()
            if (date.atStartOfDay(zone).toInstant().isBefore(domainStart)) date = date.plusDays(1)
            // Keep multi-day ticks on stable dates (every Nth day since the epoch).
            while (date.toEpochDay() % days != 0L) date = date.plusDays(1)
            while (!date.atStartOfDay(zone).toInstant().isAfter(domainEnd)) {
                ticks += date.atStartOfDay(zone).toInstant()
                date = date.plusDays(days)
            }
        }
        return tickMinutes to ticks
    }

    fun tickLabel(instant: Instant, tickMinutes: Long, locale: Locale): String {
        val multiDay = domainEnd.epochSecond - domainStart.epochSecond > 86_400 + 3_600
        val skeleton = when {
            tickMinutes >= 1440 -> "MMMd"
            multiDay -> if (tickMinutes % 60 == 0L) "EEEj" else "EEEjm"
            tickMinutes % 60 == 0L -> "j"
            else -> "jm"
        }
        return format(instant, skeleton, locale)
    }

    /** Spoken and inspector label for one bucket: "Mon, Oct 19, 3:00 PM – 3:15 PM" or "Mon, Oct 19". */
    fun bucketLabel(bar: ChartBar, locale: Locale): String {
        if (step == null) return format(bar.start, "EEEMMMd", locale)
        val start = format(bar.start, if (timeline.days > 1) "EEEMMMdjm" else "jm", locale)
        return "$start – ${format(bar.end, "jm", locale)}"
    }

    private val formats = HashMap<Pair<String, Locale>, IcuDateFormat>()

    /**
     * Formats with ICU rather than java.time: on Android 12 and 13, skeletons
     * like "jm" resolve to day-period patterns ("Bh:mm" in zh-TW) whose "B"
     * that release's java.time cannot parse. Used from the main thread only.
     */
    private fun format(instant: Instant, skeleton: String, locale: Locale): String =
        formats.getOrPut(skeleton to locale) {
            IcuDateFormat.getInstanceForSkeleton(skeleton, locale).apply { timeZone = icuTimeZone(zone) }
        }.format(Date(instant.toEpochMilli()))

    companion object {
        /** Candidate label spacings in minutes; 43200 means the first of each month. */
        val TICK_STEPS = listOf(1L, 2, 5, 10, 15, 30, 60, 120, 180, 360, 720, 1440, 2880, 10_080, 20_160, 43_200)

        /** ICU knows region ids; fixed offsets need its "GMT+hh:mm" form. */
        private fun icuTimeZone(zone: ZoneId): IcuTimeZone = IcuTimeZone.getTimeZone(
            when (zone) {
                is ZoneOffset -> if (zone == ZoneOffset.UTC) "GMT" else "GMT${zone.id}"
                else -> zone.id
            },
        )
    }
}

private class ChartGeometry(size: Size, density: Density, axisWidth: Float) {
    val left = axisWidth + with(density) { 8.dp.toPx() }
    val right = size.width
    val top = with(density) { 6.dp.toPx() }
    val bottom = size.height - with(density) { 22.dp.toPx() }
    private val minBar = with(density) { 1.5.dp.toPx() }
    val width get() = right - left
    val height get() = bottom - top

    fun x(model: ChartModel, instant: Instant) = left + model.fraction(instant) * width

    fun barSpan(model: ChartModel, bar: ChartBar): Pair<Float, Float> {
        val x0 = x(model, bar.start)
        val full = x(model, bar.end) - x0
        return x0 to x0 + max(minBar, full * 0.88f)
    }
}

/**
 * Stacked per-account cost bars drawn on a Canvas, with round axes, a lighter
 * baseline for untimed workspace credits, and tap or drag to inspect a bucket.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TimelineChart(
    timeline: RemoteTimeline,
    colors: AccountColors,
    modifier: Modifier = Modifier,
    zone: ZoneId = ZoneId.systemDefault(),
    initialSelection: Instant? = null,
) {
    val model = remember(timeline, zone) { ChartModel(timeline, zone) }
    var selected by rememberSaveable(timeline) { mutableStateOf(initialSelection?.epochSecond) }
    val selectedBar = model.bars.firstOrNull { it.start.epochSecond == selected }
    val locale = LocalLocale.current.platformLocale
    val names = remember(timeline) { timeline.accounts.associate { it.id to it.name } }

    val textMeasurer = rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelSmall.copy(color = MaterialTheme.colorScheme.onSurfaceVariant).tabular()
    val gridColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    val highlight = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f)
    val density = LocalDensity.current
    val yTicks = remember(model) { model.yTicks() }
    val yLabels = remember(yTicks, locale) { yTicks.map { Fmt.usd(it, locale).replace(Regex("[.,]00$"), "") } }
    val axisWidth = remember(yLabels, labelStyle) { yLabels.maxOf { textMeasurer.measure(it, labelStyle).size.width }.toFloat() }

    val peak = model.bars.maxByOrNull { it.total }
    val summary = buildString {
        append("Cost over time chart, ${model.bars.size} active of ${timeline.periods.size} buckets. ")
        if (peak != null) append("Highest ${Fmt.usd(peak.total, locale)} at ${model.bucketLabel(peak, locale)}. ")
        append("Tap a bar for details.")
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // Inspector: the tapped bucket's total and per-account breakdown.
        Column(
            Modifier.fillMaxWidth().heightIn(min = 40.dp).semantics { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (selectedBar == null) {
                Text("Tap or drag across the bars for details.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(model.bucketLabel(selectedBar, locale), style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    Text(Fmt.usd(selectedBar.total, locale), style = MaterialTheme.typography.titleSmall.tabular())
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    val byAccount = selectedBar.segments.groupBy { it.accountId }.mapValues { (_, s) -> s.sumOf { it.value } }
                    for ((account, value) in byAccount.entries.sortedByDescending { it.value }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            Dot(colors[account], 8)
                            Text("${names[account] ?: account} ${Fmt.usd(value, locale)}", style = MaterialTheme.typography.bodySmall.tabular())
                        }
                    }
                }
            }
        }

        Canvas(
            Modifier
                .fillMaxWidth()
                .height(220.dp)
                .semantics { contentDescription = summary }
                .pointerInput(model, axisWidth) {
                    fun pick(x: Float): Long? {
                        val geometry = ChartGeometry(Size(size.width.toFloat(), size.height.toFloat()), this, axisWidth)
                        val slop = 12.dp.toPx()
                        val hit = model.bars.minByOrNull { bar ->
                            val (x0, x1) = geometry.barSpan(model, bar)
                            when {
                                x < x0 -> x0 - x
                                x > x1 -> x - x1
                                else -> 0f
                            }
                        } ?: return null
                        val (x0, x1) = geometry.barSpan(model, hit)
                        return if (x >= x0 - slop && x <= x1 + slop) hit.start.epochSecond else null
                    }
                    detectTapGestures { offset -> selected = pick(offset.x).takeIf { it != selected } }
                }
                .pointerInput(model, axisWidth) {
                    detectHorizontalDragGestures { change, _ ->
                        val geometry = ChartGeometry(Size(size.width.toFloat(), size.height.toFloat()), this, axisWidth)
                        val x = change.position.x.coerceIn(geometry.left, geometry.right)
                        model.bars.minByOrNull { bar ->
                            val (x0, x1) = geometry.barSpan(model, bar)
                            kotlin.math.abs((x0 + x1) / 2 - x)
                        }?.let { selected = it.start.epochSecond }
                    }
                },
        ) {
            val geometry = ChartGeometry(size, density, axisWidth)
            val top = yTicks.last().coerceAtLeast(1e-9)
            fun y(value: Double) = geometry.bottom - (value / top).toFloat() * geometry.height

            // Horizontal grid and dollar labels.
            yTicks.forEachIndexed { index, tick ->
                val yy = y(tick)
                drawLine(gridColor, Offset(geometry.left, yy), Offset(geometry.right, yy), strokeWidth = 1.dp.toPx())
                val layout = textMeasurer.measure(yLabels[index], labelStyle)
                drawText(layout, topLeft = Offset(axisWidth - layout.size.width, (yy - layout.size.height / 2f).coerceAtLeast(0f)))
            }

            // Time labels on round boundaries.
            val maxLabels = max(2, (geometry.width / 56.dp.toPx()).toInt())
            val (tickMinutes, ticks) = model.xTicks(maxLabels)
            for (tick in ticks) {
                val xx = geometry.x(model, tick)
                drawLine(gridColor, Offset(xx, geometry.top), Offset(xx, geometry.bottom), strokeWidth = 1.dp.toPx())
                val layout = textMeasurer.measure(model.tickLabel(tick, tickMinutes, locale), labelStyle)
                val left = (xx - layout.size.width / 2f).coerceIn(geometry.left - 4.dp.toPx(), size.width - layout.size.width)
                drawText(layout, topLeft = Offset(left, geometry.bottom + 6.dp.toPx()))
            }

            if (selectedBar != null) {
                val (x0, x1) = geometry.barSpan(model, selectedBar)
                val pad = 3.dp.toPx()
                drawRect(highlight, Offset(x0 - pad, geometry.top), Size(x1 - x0 + pad * 2, geometry.height))
            }

            for (bar in model.bars) {
                val (x0, x1) = geometry.barSpan(model, bar)
                val dim = selectedBar != null && bar !== selectedBar
                var running = 0.0
                for (segment in bar.segments) {
                    val y0 = y(running)
                    running += segment.value
                    val y1 = y(running)
                    var alpha = if (segment.baseline) 0.35f else 1f
                    if (dim) alpha *= 0.45f
                    drawRect(colors[segment.accountId].copy(alpha = alpha), Offset(x0, y1), Size(x1 - x0, y0 - y1))
                }
            }

            drawLine(gridColor.copy(alpha = 0.2f), Offset(geometry.left, geometry.bottom), Offset(geometry.right, geometry.bottom), strokeWidth = 1.dp.toPx())
        }

        // Legend: accounts that appear in this window.
        val active = timeline.accounts.filter { account -> model.bars.any { bar -> bar.segments.any { it.accountId == account.id } } }
        if (active.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                for (account in active) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Dot(colors[account.id], 8)
                        Text(account.name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

internal val ChartNoteStyle: TextStyle
    @Composable get() = MaterialTheme.typography.bodySmall.copy(color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Normal, fontSize = 12.sp)
