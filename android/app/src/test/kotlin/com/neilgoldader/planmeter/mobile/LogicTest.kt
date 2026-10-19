package com.neilgoldader.planmeter.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.neilgoldader.planmeter.mobile.data.DashboardLoader
import com.neilgoldader.planmeter.mobile.data.LoadResult
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.data.UserMessages
import com.neilgoldader.planmeter.mobile.data.WidgetSnapshot
import com.neilgoldader.planmeter.mobile.ui.Fmt
import com.neilgoldader.planmeter.mobile.ui.dashboard.AccountColors
import com.neilgoldader.planmeter.mobile.ui.dashboard.ChartModel
import com.neilgoldader.planmeter.mobile.ui.theme.SeriesPalette
import com.neilgoldader.planmeter.protocol.PairingInvite
import com.neilgoldader.planmeter.protocol.RemoteAccount
import com.neilgoldader.planmeter.protocol.RemoteClientException
import com.neilgoldader.planmeter.protocol.RemoteMethod
import com.neilgoldader.planmeter.protocol.RemoteReply
import com.neilgoldader.planmeter.protocol.RemoteRequest
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import com.neilgoldader.planmeter.protocol.RemoteTimelinePoint
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.time.Instant
import java.time.ZoneId
import java.util.Collections
import java.util.Locale

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class LogicTest {
    private val zone = FakeData.zone

    @Test
    fun loaderSendsTheIphoneRequests() = runTest {
        val seen = Collections.synchronizedList(mutableListOf<RemoteRequest>())
        val loader = DashboardLoader { request ->
            seen += request
            reply(request)
        }
        val result = loader.load(MobileRange.WEEK, "hour")
        assertTrue(result is LoadResult.Loaded)
        assertEquals(
            setOf(
                RemoteRequest(RemoteMethod.SUMMARY, days = 7),
                RemoteRequest(RemoteMethod.TIMELINE, days = 7, resolution = "hour"),
                RemoteRequest(RemoteMethod.LIMITS),
                RemoteRequest(RemoteMethod.MODELS, days = 7),
                RemoteRequest(RemoteMethod.ACCOUNTS),
            ),
            seen.toSet(),
        )
        val loaded = (result as LoadResult.Loaded).data
        assertEquals("hour", loaded.requestedGranularity)
        assertEquals(loaded.summary, loaded.widgetSummary)
    }

    @Test
    fun loaderAsksForADayAlongsideTheLastHour() = runTest {
        val seen = Collections.synchronizedList(mutableListOf<RemoteRequest>())
        val result = DashboardLoader { request -> seen += request; reply(request) }.load(MobileRange.HOUR, "minute")
        assertTrue(seen.contains(RemoteRequest(RemoteMethod.SUMMARY, days = 1, minutes = 60)))
        assertTrue(seen.contains(RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "minute", minutes = 60)))
        assertTrue(seen.contains(RemoteRequest(RemoteMethod.SUMMARY, days = 1)))
        assertTrue(seen.contains(RemoteRequest(RemoteMethod.TIMELINE, days = 1, resolution = "hour")))
        val data = (result as LoadResult.Loaded).data
        assertEquals(null, data.widgetSummary?.minutes)
    }

    @Test
    fun olderHostsWithoutSubDayWindowsAreDetected() = runTest {
        val result = DashboardLoader { request ->
            // An older host ignores `minutes` and answers with a whole day.
            reply(request.copy(minutes = null))
        }.load(MobileRange.HOUR, "minute")
        assertEquals(LoadResult.NoSubDayWindows, result)
    }

    @Test
    fun optionalRequestsTolerateFailures() = runTest {
        val result = DashboardLoader { request ->
            if (request.method == RemoteMethod.ACCOUNTS) throw RemoteClientException.Http(200, "unknown method")
            reply(request)
        }.load(MobileRange.MONTH, "day")
        assertNull((result as LoadResult.Loaded).data.accounts)
    }

    private fun reply(request: RemoteRequest): RemoteReply = FakeData.reply(request)

    @Test
    fun widgetSnapshotStaleness() {
        val summary = FakeData.summary(MobileRange.DAY)
        val snapshot = WidgetSnapshot.from(summary, FakeData.timeline(MobileRange.DAY, "hour"), zone)
        val updated = snapshot.updatedAt
        assertFalse(snapshot.isStale(updated.plusSeconds(14 * 60), zone))
        assertTrue(snapshot.isStale(updated.plusSeconds(15 * 60), zone))
        // Past local midnight, "today" is yesterday's number even if it is fresh.
        val midnight = updated.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant()
        val lateSnapshot = snapshot.copy(updatedAt = midnight.minusSeconds(60))
        assertFalse(lateSnapshot.isStale(midnight.minusSeconds(1), zone))
        assertTrue(lateSnapshot.isStale(midnight.plusSeconds(60), zone))
        // The widget's expiry alarm: when isStale turns true, whichever comes first.
        assertEquals(updated.plusSeconds(15 * 60), snapshot.expiresAt(zone))
        assertEquals(midnight, lateSnapshot.expiresAt(zone))
        for (s in listOf(snapshot, lateSnapshot)) {
            assertFalse(s.isStale(s.expiresAt(zone).minusSeconds(1), zone))
            assertTrue(s.isStale(s.expiresAt(zone), zone))
        }
    }

    @Test
    fun widgetSplitUsesCalendarToday() {
        val summary = FakeData.summary(MobileRange.DAY)
        val timeline = FakeData.timeline(MobileRange.DAY, "hour")
        val snapshot = WidgetSnapshot.from(summary, timeline, zone)
        val today = summary.generatedAt.atZone(zone).toLocalDate()
        val expected = timeline.points.filter { it.period.atZone(zone).toLocalDate() == today }
            .filter { it.accountId in setOf(FakeData.codexPersonal.id, FakeData.claudePersonal.id) }.sumOf { it.costUsd }
        assertEquals(expected, snapshot.today("personal"), 1e-9)
        assertTrue(snapshot.hasCalendarSplit)
        // Without a timeline, fall back to the summary's group totals.
        val fallback = WidgetSnapshot.from(summary, null, zone)
        assertEquals(summary.groups.first { it.group == "work" }.totals.costUsd, fallback.today("work"), 1e-9)
    }

    @Test
    fun chartStacksBaselinesFirstAndRoundsAxes() {
        val accounts = listOf(RemoteAccount("a", "A", "codex", "Codex", "personal"), RemoteAccount("b", "B", "claude", "Claude", "work"))
        val start = Instant.parse("2026-10-19T00:00:00Z")
        val timeline = RemoteTimeline(
            days = 1, resolution = "hour",
            periods = (0 until 24).map { start.plusSeconds(it * 3600L) },
            points = listOf(
                RemoteTimelinePoint(start.plusSeconds(3600), "b", 3.0, 10, baselineCostUsd = 1.0),
                RemoteTimelinePoint(start.plusSeconds(3600), "a", 2.0, 10),
                RemoteTimelinePoint(start.plusSeconds(7200), "a", 0.0, 0),
            ),
            accounts = accounts,
        )
        val model = ChartModel(timeline, ZoneId.of("UTC"))
        assertEquals(1, model.bars.size) // Zero buckets are dropped.
        val bar = model.bars.single()
        assertEquals(listOf("b" to true, "a" to false, "b" to false), bar.segments.map { it.accountId to it.baseline })
        assertEquals(5.0, bar.total, 1e-9)
        assertEquals(listOf(0.0, 2.0, 4.0, 6.0), model.yTicks())
        assertEquals(start, model.domainStart)
        assertEquals(start.plusSeconds(86_400), model.domainEnd)
        val (step, ticks) = model.xTicks(maxLabels = 5)
        assertEquals(360L, step)
        assertEquals(listOf(0, 6, 12, 18, 24).map { start.plusSeconds(it * 3600L) }, ticks)
        assertEquals("6 AM", model.tickLabel(start.plusSeconds(6 * 3600), step, Locale.US))
        assertTrue(model.hasBaseline)
    }

    @Test
    fun dailyChartTicksLandOnDates() {
        val model = ChartModel(FakeData.timeline(MobileRange.MONTH), zone)
        val (step, ticks) = model.xTicks(maxLabels = 5)
        assertTrue(step >= 1440)
        assertTrue(ticks.all { it.atZone(zone).toLocalTime().toSecondOfDay() == 0 })
        assertTrue(model.tickLabel(ticks.first(), step, Locale.US).matches(Regex("[A-Z][a-z]{2} \\d{1,2}")))
    }

    @Test
    fun accountColorsPreferUniqueAccents() {
        val accounts = listOf(
            RemoteAccount("a", "A", "codex", "Codex", "personal", accentColorHex = "#112233"),
            RemoteAccount("b", "B", "codex", "Codex", "work", accentColorHex = "#445566"),
            RemoteAccount("c", "C", "codex", "Codex", "work", accentColorHex = "#445566"),
        )
        val colors = AccountColors(accounts)
        assertEquals(SeriesPalette.parseHex("#112233"), colors["a"])
        assertEquals(SeriesPalette.colors[1], colors["b"]) // Shared accent: palette by position.
        assertEquals(SeriesPalette.colors[2], colors["c"])
        assertEquals(SeriesPalette.colors.last(), colors["missing"])
    }

    @Test
    fun formatting() {
        val us = Locale.US
        assertEquals("$0.00", Fmt.usd(0.0, us))
        assertEquals("<$0.01", Fmt.usd(0.004, us))
        assertEquals("$12.35", Fmt.usd(12.345, us))
        assertEquals("$1,235", Fmt.usd(1234.6, us))
        assertTrue(Fmt.usd(1.23, Locale.GERMANY).contains("1,23"))
        assertEquals("3.40B", Fmt.tokens(3_400_000_000, us))
        assertEquals("21.0M", Fmt.tokens(21_000_000, us))
        assertEquals("12K", Fmt.tokens(12_345, us))
        assertEquals("1.2K", Fmt.tokens(1_234, us))
        assertEquals("999", Fmt.tokens(999, us))
        assertEquals("72%", Fmt.percent(0.72, us))
        assertEquals("$4.60", Fmt.compactUsd(4.6, us))
        assertEquals("$46", Fmt.compactUsd(46.2, us))
        assertEquals("$1.2K", Fmt.compactUsd(1234.0, us))
    }

    @Test
    fun userMessages() {
        val invite = PairingInvite("devbox.tail1234.ts.net", 7787, "Mac", ByteArray(65), "t", Instant.EPOCH)
        assertTrue(UserMessages.pairing(RemoteClientException.InviteExpired(), invite).contains("expired"))
        val unreachable = RemoteClientException.Transport(RemoteClientException.Transport.Kind.UNREACHABLE, "x")
        assertTrue(UserMessages.pairing(unreachable, invite).contains("Is Tailscale connected"))
        assertTrue(UserMessages.pairing(RemoteClientException.Http(403, "pairing rejected"), invite).contains("rejected"))
        assertTrue(UserMessages.pairing(RemoteClientException.Http(403, "no active pairing code"), invite).contains("single use"))
        assertEquals(UserMessages.WEB_PAIRING_LINK, UserMessages.unreadableLink("https://devbox.tail1234.ts.net/#k=abc&t=def"))
        assertEquals(UserMessages.NOT_A_PAIRING_LINK, UserMessages.unreadableLink("hello"))
        val revoked = UserMessages.refresh(RemoteClientException.Http(401, "unknown device"), FakeData.server)
        assertTrue(revoked.contains("no longer recognizes"))
    }
}
