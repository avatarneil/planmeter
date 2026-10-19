package com.neilgoldader.planmeter.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId

// Wire models mirroring Sources/PlanMeterRemote/RemoteModels.swift. Swift `Int`
// is 64-bit, so counters that can grow large are `Long` here.

typealias WireDate = @Serializable(with = Iso8601InstantSerializer::class) Instant
typealias WireData = @Serializable(with = Base64DataSerializer::class) ByteArray

@Serializable
enum class RemoteMethod {
    @SerialName("summary") SUMMARY,
    @SerialName("models") MODELS,
    @SerialName("timeline") TIMELINE,
    @SerialName("limits") LIMITS,
    @SerialName("accounts") ACCOUNTS,
}

/** What the phone asks for. One RPC shape keeps the encrypted channel simple. */
@Serializable
data class RemoteRequest(
    val method: RemoteMethod,
    val days: Int? = null,
    /** "minute", "5m", "15m", "hour", or "day"; timeline only. Older hosts understand only "hour" and "day". */
    val resolution: String? = null,
    /** Account filter for `models`. */
    val account: String? = null,
    /** A window shorter than a day, in minutes, ending now; overrides `days`. */
    val minutes: Int? = null,
)

@Serializable
data class RemoteTotals(
    val costUsd: Double = 0.0,
    val tokens: Long = 0,
    val inputTokens: Long = 0,
    val cachedInputTokens: Long = 0,
    val outputTokens: Long = 0,
    val sessions: Long = 0,
    val cacheSavingsUsd: Double = 0.0,
) {
    val cachedShare: Double get() = if (inputTokens > 0) cachedInputTokens.toDouble() / inputTokens.toDouble() else 0.0
}

@Serializable
data class RemoteAccount(
    val id: String,
    val name: String,
    val provider: String,
    val providerName: String,
    val group: String,
    val email: String? = null,
    val plan: String? = null,
    val accentColorHex: String? = null,
)

@Serializable
data class RemoteAccountUsage(
    val account: RemoteAccount,
    val totals: RemoteTotals,
) {
    val id: String get() = account.id
}

@Serializable
data class RemoteGroupUsage(
    val group: String,
    val totals: RemoteTotals,
    val accounts: List<RemoteAccountUsage>,
) {
    val id: String get() = group
}

@Serializable
data class RemoteSummary(
    val days: Int,
    val from: WireDate,
    val to: WireDate,
    val groups: List<RemoteGroupUsage>,
    val total: RemoteTotals,
    val todayCostUsd: Double,
    val generatedAt: WireDate,
    val serverName: String,
    val pricingSource: String,
    val usesProviderDates: Boolean? = null,
    /** Set for windows shorter than a day. */
    val minutes: Int? = null,
)

@Serializable
data class RemoteModelRow(
    val accountId: String,
    val accountName: String,
    val group: String,
    val provider: String,
    val model: String,
    val totals: RemoteTotals,
    val priced: Boolean,
) {
    val id: String get() = "$accountId:$model"
}

@Serializable
data class RemoteTimelinePoint(
    val period: WireDate,
    val accountId: String,
    val costUsd: Double,
    val tokens: Long,
    /**
     * The part of [costUsd] from workspace credits without timing, spread evenly
     * over the hours the provider reported. Charts draw it as a lighter baseline.
     */
    val baselineCostUsd: Double? = null,
) {
    val id: String get() = "${period.epochSecond}:$accountId"
}

@Serializable
data class RemoteTimeline(
    val days: Int,
    val resolution: String,
    val periods: List<WireDate>,
    val points: List<RemoteTimelinePoint>,
    val accounts: List<RemoteAccount>,
    /** Set for windows shorter than a day. */
    val minutes: Int? = null,
) {
    /** Cost per period by plan group, with the untimed workspace baseline kept apart. */
    data class GroupBar(val start: Instant, val costs: Map<String, Double>, val baselines: Map<String, Double>)

    /**
     * Re-buckets a fixed-step timeline into a coarser fixed step, e.g. 5m into
     * 15m or hour. Returns null when the target is not a whole multiple.
     */
    fun rebucketed(target: String): RemoteTimeline? {
        if (target == resolution) return this
        val step = stepSeconds(resolution) ?: return null
        val wide = stepSeconds(target) ?: return null
        if (wide <= step || wide % step != 0L) return null
        fun floorTo(instant: Instant) = Instant.ofEpochSecond(Math.floorDiv(instant.epochSecond, wide) * wide)
        val merged = LinkedHashMap<Pair<Instant, String>, RemoteTimelinePoint>()
        for (point in points) {
            val key = floorTo(point.period) to point.accountId
            val value = merged[key] ?: RemoteTimelinePoint(key.first, point.accountId, 0.0, 0)
            merged[key] = value.copy(
                costUsd = value.costUsd + point.costUsd,
                tokens = value.tokens + point.tokens,
                baselineCostUsd = point.baselineCostUsd?.let { (value.baselineCostUsd ?: 0.0) + it } ?: value.baselineCostUsd,
            )
        }
        val newPeriods = ArrayList<Instant>()
        for (period in periods.map(::floorTo)) if (newPeriods.lastOrNull() != period) newPeriods.add(period)
        return RemoteTimeline(
            days = days,
            resolution = target,
            periods = newPeriods,
            points = merged.values.sortedWith(compareBy<RemoteTimelinePoint> { it.period }.thenBy { it.accountId }),
            accounts = accounts,
            minutes = minutes,
        )
    }

    /** Every period (zero-filled), optionally limited to one local calendar day. */
    fun groupBars(onDay: Instant? = null, zone: ZoneId = ZoneId.systemDefault()): List<GroupBar> {
        val groups = accountGroups()
        val costs = LinkedHashMap<Instant, MutableMap<String, Double>>()
        val baselines = LinkedHashMap<Instant, MutableMap<String, Double>>()
        for (period in periods) {
            costs.getOrPut(period) { mutableMapOf() }
            baselines.getOrPut(period) { mutableMapOf() }
        }
        for (point in points) {
            val group = groups[point.accountId] ?: "other"
            val c = costs.getOrPut(point.period) { mutableMapOf() }
            c[group] = (c[group] ?: 0.0) + point.costUsd
            val b = baselines.getOrPut(point.period) { mutableMapOf() }
            point.baselineCostUsd?.let { b[group] = (b[group] ?: 0.0) + it }
        }
        val day = onDay?.atZone(zone)?.toLocalDate()
        return costs.keys
            .filter { day == null || it.atZone(zone).toLocalDate() == day }
            .sorted()
            .map { GroupBar(it, costs.getValue(it), baselines[it].orEmpty()) }
    }

    /** Sum the calendar day's buckets, excluding earlier hours in a rolling 24h report. */
    fun costByGroup(on: Instant, zone: ZoneId = ZoneId.systemDefault()): Map<String, Double> {
        val groups = accountGroups()
        val day = on.atZone(zone).toLocalDate()
        val result = LinkedHashMap<String, Double>()
        for (point in points) {
            if (point.period.atZone(zone).toLocalDate() != day) continue
            val group = groups[point.accountId] ?: "other"
            result[group] = (result[group] ?: 0.0) + point.costUsd
        }
        return result
    }

    private fun accountGroups(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (account in accounts) out.putIfAbsent(account.id, account.group)
        return out
    }

    companion object {
        /** Bucket length in seconds for fixed-step resolutions; null for calendar days. */
        fun stepSeconds(resolution: String): Long? = when (resolution) {
            "minute" -> 60
            "5m" -> 300
            "15m" -> 900
            "hour" -> 3600
            else -> null
        }

        /** Whether a fixed-step timeline can be re-bucketed into [target]. */
        fun coarsens(source: String, target: String): Boolean {
            val step = stepSeconds(source) ?: return false
            val wide = stepSeconds(target) ?: return false
            return wide > step && wide % step == 0L
        }
    }
}

@Serializable
data class RemoteLimitWindow(
    val label: String,
    val usedPercent: Double,
    val windowMinutes: Int,
    val resetsAt: WireDate,
)

@Serializable
data class RemoteAccountLimits(
    val account: RemoteAccount,
    val windows: List<RemoteLimitWindow>,
    val note: String? = null,
    val asOf: WireDate? = null,
) {
    val id: String get() = account.id
}

@Serializable
data class RemoteLimits(
    val accounts: List<RemoteAccountLimits>,
    val note: String,
)

@Serializable
data class RemoteSource(
    val provider: String,
    val path: String,
    val status: String,
) {
    val id: String get() = "$provider:$path"
}

@Serializable
data class RemoteAccounts(
    val accounts: List<RemoteAccount>,
    val sources: List<RemoteSource>,
    val scannedAt: WireDate? = null,
)

/** Union reply: exactly one payload field is set for a successful call. */
@Serializable
data class RemoteReply(
    val summary: RemoteSummary? = null,
    val models: List<RemoteModelRow>? = null,
    val timeline: RemoteTimeline? = null,
    val limits: RemoteLimits? = null,
    val accounts: RemoteAccounts? = null,
    val error: String? = null,
)

/**
 * Unauthenticated `GET /v1/info`: enough for a client to recognize a PlanMeter
 * server, nothing about the data behind it.
 */
@Serializable
data class ServerInfo(
    val app: String = "planmeter",
    val version: String,
    val serverName: String,
    val protocolVersion: Int = SecureChannel.PROTOCOL_VERSION,
)
