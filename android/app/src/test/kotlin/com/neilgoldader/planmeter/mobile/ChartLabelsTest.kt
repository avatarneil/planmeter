package com.neilgoldader.planmeter.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.ui.dashboard.ChartModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Chart labels on Android 13, whose ICU data gives zh-TW (and other regions
 * that prefer day periods) "Bh:mm"-style patterns that its java.time rejects.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [33])
class ChartLabelsTest {
    private val zone = FakeData.zone

    @Test
    fun dayPeriodLocalesFormat() {
        val model = ChartModel(FakeData.timeline(MobileRange.WEEK, "hour"), zone)
        val bar = model.bars.first()
        for (locale in listOf(Locale.TAIWAN, Locale.forLanguageTag("sw-TZ"), Locale.US)) {
            val (step, ticks) = model.xTicks(maxLabels = 6)
            assertTrue(model.tickLabel(ticks.first(), step, locale).isNotBlank())
            assertTrue(model.bucketLabel(bar, locale).contains(" – "))
        }
        val hourly = ChartModel(FakeData.timeline(MobileRange.DAY, "hour"), zone)
        val (step, ticks) = hourly.xTicks(maxLabels = 6)
        assertTrue(hourly.tickLabel(ticks.first(), step, Locale.TAIWAN).isNotBlank())
        assertTrue(hourly.bucketLabel(hourly.bars.first(), Locale.TAIWAN).contains(":"))
    }

    @Test
    fun labelsUseTheChartZone() {
        for (offset in listOf(ZoneOffset.UTC, ZoneOffset.ofHours(13), ZoneOffset.ofHours(-11))) {
            val model = ChartModel(FakeData.timeline(MobileRange.DAY, "hour"), offset)
            val tick = model.domainStart.plusSeconds(3 * 3600)
            assertEquals(offset.id, DateTimeFormatter.ofPattern("MMM d", Locale.US).format(tick.atZone(offset)), model.tickLabel(tick, 1440, Locale.US))
            assertEquals(offset.id, DateTimeFormatter.ofPattern("h a", Locale.US).format(tick.atZone(offset)), model.tickLabel(tick, 60, Locale.US))
        }
    }
}
