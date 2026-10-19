package com.neilgoldader.planmeter.mobile

import com.neilgoldader.planmeter.mobile.data.DashboardData
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.ui.DashboardUiState
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.RemoteAccount
import com.neilgoldader.planmeter.protocol.RemoteAccountLimits
import com.neilgoldader.planmeter.protocol.RemoteAccountUsage
import com.neilgoldader.planmeter.protocol.RemoteAccounts
import com.neilgoldader.planmeter.protocol.RemoteGroupUsage
import com.neilgoldader.planmeter.protocol.RemoteLimitWindow
import com.neilgoldader.planmeter.protocol.RemoteLimits
import com.neilgoldader.planmeter.protocol.RemoteModelRow
import com.neilgoldader.planmeter.protocol.RemoteSource
import com.neilgoldader.planmeter.protocol.RemoteSummary
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import com.neilgoldader.planmeter.protocol.RemoteTimelinePoint
import com.neilgoldader.planmeter.protocol.RemoteTotals
import java.time.Instant
import java.time.ZoneId
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

/** Realistic, deterministic dashboard data for screenshots and tests. */
object FakeData {
    val zone: ZoneId = ZoneId.of("America/Los_Angeles")
    val now: Instant = Instant.parse("2026-10-19T22:30:00Z") // 3:30 PM in Los Angeles

    val codexPersonal = RemoteAccount("codex-personal", "Codex · personal", "codex", "Codex", "personal", email = "neil@example.com", plan = "Pro", accentColorHex = "#10A37F")
    val claudePersonal = RemoteAccount("claude-personal", "Claude · personal", "claude", "Claude", "personal", plan = "Max", accentColorHex = "#D97757")
    val claudeWork = RemoteAccount("claude-work", "Claude Code · Acme", "claude", "Claude", "work", email = "neil@acme.dev", plan = "Team", accentColorHex = "#C06AD9")
    val codexWork = RemoteAccount("codex-work", "Codex · Acme", "codex", "Codex", "work", plan = "Business", accentColorHex = "#4F7CFF")
    val opencode = RemoteAccount("opencode", "OpenCode", "opencode", "OpenCode", "other")
    val accounts = listOf(codexPersonal, claudePersonal, claudeWork, codexWork, opencode)

    val server = PairedServer("devbox.tail1234.ts.net", 7787, "Neil’s MacBook Pro", ByteArray(65) { (it * 7).toByte() }.also { it[0] = 4 }, "Qm9pbmcgNzQ3IGZseWluZw", Instant.parse("2026-09-02T17:04:00Z"))

    private fun totals(cost: Double, tokens: Long, cachedShare: Double = 0.72, sessions: Long = 12) = RemoteTotals(
        costUsd = cost,
        tokens = tokens,
        inputTokens = (tokens * 0.9).toLong(),
        cachedInputTokens = (tokens * 0.9 * cachedShare).toLong(),
        outputTokens = (tokens * 0.1).toLong(),
        sessions = sessions,
        cacheSavingsUsd = cost * 0.41,
    )

    fun summary(range: MobileRange = MobileRange.MONTH): RemoteSummary {
        val scale = when (range) {
            MobileRange.HOUR -> 0.012
            MobileRange.DAY -> 0.05
            MobileRange.WEEK -> 0.27
            MobileRange.MONTH -> 1.0
            MobileRange.QUARTER -> 2.6
        }
        fun usage(account: RemoteAccount, cost: Double, tokens: Long, sessions: Long) =
            RemoteAccountUsage(account, totals(cost * scale, (tokens * scale).toLong(), sessions = max(1, (sessions * scale).toLong())))
        val personal = listOf(usage(codexPersonal, 184.32, 412_000_000, 64), usage(claudePersonal, 96.10, 188_000_000, 41))
        val work = listOf(usage(claudeWork, 412.75, 1_020_000_000, 133), usage(codexWork, 133.40, 301_000_000, 58))
        val other = listOf(RemoteAccountUsage(opencode, totals(0.0, 0, sessions = 0)))
        fun group(name: String, rows: List<RemoteAccountUsage>) = RemoteGroupUsage(
            name,
            RemoteTotals(
                costUsd = rows.sumOf { it.totals.costUsd },
                tokens = rows.sumOf { it.totals.tokens },
                inputTokens = rows.sumOf { it.totals.inputTokens },
                cachedInputTokens = rows.sumOf { it.totals.cachedInputTokens },
                outputTokens = rows.sumOf { it.totals.outputTokens },
                sessions = rows.sumOf { it.totals.sessions },
                cacheSavingsUsd = rows.sumOf { it.totals.cacheSavingsUsd },
            ),
            rows,
        )
        val groups = listOf(group("personal", personal), group("work", work), group("other", other))
        val total = RemoteTotals(
            costUsd = groups.sumOf { it.totals.costUsd },
            tokens = groups.sumOf { it.totals.tokens },
            inputTokens = groups.sumOf { it.totals.inputTokens },
            cachedInputTokens = groups.sumOf { it.totals.cachedInputTokens },
            outputTokens = groups.sumOf { it.totals.outputTokens },
            sessions = groups.sumOf { it.totals.sessions },
            cacheSavingsUsd = groups.sumOf { it.totals.cacheSavingsUsd },
        )
        return RemoteSummary(
            days = range.days,
            from = now.minusSeconds(range.minutes?.let { it * 60L } ?: range.days * 86_400L),
            to = now,
            groups = groups,
            total = total,
            todayCostUsd = todayCost(),
            generatedAt = now.minusSeconds(40),
            serverName = server.serverName,
            pricingSource = "litellm",
            usesProviderDates = true,
            minutes = range.minutes,
        )
    }

    /** Calendar-today cost from the hourly buckets, so the widget split adds up. */
    fun todayCost(): Double {
        val today = now.atZone(zone).toLocalDate()
        return timeline(MobileRange.DAY, "hour").points.filter { it.period.atZone(zone).toLocalDate() == today }.sumOf { it.costUsd }
    }

    /** Daily buckets for 30 days, or hourly for a day, with weekday rhythm and a workspace baseline. */
    fun timeline(range: MobileRange = MobileRange.MONTH, resolution: String = range.defaultGranularity): RemoteTimeline {
        val step = RemoteTimeline.stepSeconds(resolution)
        val periods: List<Instant> = if (step == null) {
            val today = now.atZone(zone).toLocalDate()
            (range.days - 1 downTo 0).map { today.minusDays(it.toLong()).atStartOfDay(zone).toInstant() }
        } else {
            val span = range.minutes?.let { it * 60L } ?: range.days * 86_400L
            val end = now.epochSecond / step * step
            ((end - span + step)..end step step).map { Instant.ofEpochSecond(it) }
        }
        val points = mutableListOf<RemoteTimelinePoint>()
        periods.forEachIndexed { i, period ->
            val local = period.atZone(zone)
            val weekend = local.dayOfWeek.value >= 6
            val daytime = if (step == null) 1.0 else max(0.0, sin((local.hour - 7) / 14.0 * PI))
            val scale = if (step == null) 1.0 else step / 86_400.0 * 2.4
            val wobble = 0.65 + 0.35 * sin(i * 1.7) * sin(i * 0.31)
            fun add(account: RemoteAccount, base: Double, weekendFactor: Double, baseline: Double? = null) {
                val cost = base * wobble * daytime * scale * (if (weekend) weekendFactor else 1.0)
                if (cost > 0.004) {
                    points += RemoteTimelinePoint(period, account.id, cost, (cost * 2_100_000).toLong(), baseline?.let { minOf(cost, it * scale) })
                }
            }
            add(codexPersonal, 6.2, 1.6)
            add(claudePersonal, 3.1, 1.4)
            add(claudeWork, 13.5, 0.1, baseline = if (step == null) 2.2 else null)
            add(codexWork, 4.4, 0.05)
        }
        return RemoteTimeline(range.days, resolution, periods, points, accounts, range.minutes)
    }

    val limits = RemoteLimits(
        accounts = listOf(
            RemoteAccountLimits(
                codexPersonal,
                listOf(
                    RemoteLimitWindow("5-hour window", 38.0, 300, now.plusSeconds(2 * 3600 + 900)),
                    RemoteLimitWindow("Weekly", 76.0, 10_080, now.plusSeconds(3 * 86_400 + 5 * 3600)),
                ),
                asOf = now.minusSeconds(180),
            ),
            RemoteAccountLimits(
                codexWork,
                listOf(
                    RemoteLimitWindow("5-hour window", 94.0, 300, now.plusSeconds(1800)),
                    RemoteLimitWindow("Weekly", 41.0, 10_080, now.plusSeconds(5 * 86_400)),
                ),
                asOf = now.minusSeconds(240),
            ),
        ),
        note = "From the Codex CLI's latest rate-limit headers.",
    )

    val models = listOf(
        RemoteModelRow(claudeWork.id, claudeWork.name, "work", "claude", "claude-opus-4-1-20250805", totals(301.20, 610_000_000), true),
        RemoteModelRow(codexPersonal.id, codexPersonal.name, "personal", "codex", "gpt-5-codex", totals(171.04, 390_000_000), true),
        RemoteModelRow(codexWork.id, codexWork.name, "work", "codex", "gpt-5-codex", totals(120.33, 280_000_000), true),
        RemoteModelRow(claudeWork.id, claudeWork.name, "work", "claude", "claude-sonnet-4-5-20250929", totals(111.55, 410_000_000), true),
        RemoteModelRow(claudePersonal.id, claudePersonal.name, "personal", "claude", "claude-sonnet-4-5-20250929", totals(96.10, 188_000_000), true),
        RemoteModelRow(codexPersonal.id, codexPersonal.name, "personal", "codex", "gpt-5-mini", totals(13.28, 22_000_000), true),
        RemoteModelRow(codexWork.id, codexWork.name, "work", "codex", "gpt-5.1-codex-max", totals(13.07, 21_000_000), true),
        RemoteModelRow(opencode.id, opencode.name, "other", "opencode", "ollama/qwen3-coder:30b", totals(0.0, 4_200_000), false),
    )

    val accountsReply = RemoteAccounts(
        accounts = accounts,
        sources = listOf(
            RemoteSource("codex", "/Users/neil/.codex/sessions", "ok"),
            RemoteSource("claude", "/Users/neil/.claude/projects", "ok"),
            RemoteSource("opencode", "/Users/neil/.local/share/opencode/storage", "not found"),
        ),
        scannedAt = now.minusSeconds(90),
    )

    fun data(range: MobileRange = MobileRange.MONTH, granularity: String = range.defaultGranularity) = DashboardData(
        summary = summary(range),
        timeline = timeline(range, granularity),
        limits = limits,
        models = models,
        accounts = accountsReply,
        requestedGranularity = granularity,
        widgetSummary = summary(MobileRange.DAY),
        widgetTimeline = timeline(MobileRange.DAY, "hour"),
    )

    fun dashboard(range: MobileRange = MobileRange.MONTH, granularity: String = range.defaultGranularity) = DashboardUiState(
        server = server,
        range = range,
        granularity = granularity,
        data = data(range, granularity),
        lastUpdated = now.minusSeconds(20),
    )
}
