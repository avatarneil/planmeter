package com.neilgoldader.planmeter.mobile.ui.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.neilgoldader.planmeter.mobile.data.DashboardData
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.ui.Banner
import com.neilgoldader.planmeter.mobile.ui.BannerTone
import com.neilgoldader.planmeter.mobile.ui.CardTitle
import com.neilgoldader.planmeter.mobile.ui.DashboardUiState
import com.neilgoldader.planmeter.mobile.ui.Dot
import com.neilgoldader.planmeter.mobile.ui.Fmt
import com.neilgoldader.planmeter.mobile.ui.Pill
import com.neilgoldader.planmeter.mobile.ui.PlanCard
import com.neilgoldader.planmeter.mobile.ui.ShareBar
import com.neilgoldader.planmeter.mobile.ui.Stat
import com.neilgoldader.planmeter.mobile.ui.theme.CardNumberStyle
import com.neilgoldader.planmeter.mobile.ui.theme.GroupColors
import com.neilgoldader.planmeter.mobile.ui.theme.HeroNumberStyle
import com.neilgoldader.planmeter.mobile.ui.theme.Surfaces
import com.neilgoldader.planmeter.mobile.ui.theme.tabular
import com.neilgoldader.planmeter.protocol.RemoteAccounts
import com.neilgoldader.planmeter.protocol.RemoteGroupUsage
import com.neilgoldader.planmeter.protocol.RemoteLimits
import com.neilgoldader.planmeter.protocol.RemoteModelRow
import com.neilgoldader.planmeter.protocol.RemoteSummary
import com.neilgoldader.planmeter.protocol.RemoteTimeline
import com.neilgoldader.planmeter.protocol.RemoteTotals
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/** Data older than this is called out, even without an error. */
private val STALE_AFTER: Duration = Duration.ofMinutes(5)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    state: DashboardUiState,
    onRefresh: () -> Unit,
    onRangeChange: (MobileRange) -> Unit,
    onGranularityChange: (String) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
    now: Instant = Instant.now(),
    zone: ZoneId = ZoneId.systemDefault(),
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = Surfaces.screen,
        contentWindowInsets = WindowInsets(0),
        topBar = {
            LargeTopAppBar(
                title = { Text("PlanMeter") },
                actions = {
                    if (state.isLoading && !state.isUserRefreshing) {
                        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        }
                    } else {
                        IconButton(onClick = onRefresh) { Icon(Icons.Outlined.Refresh, contentDescription = "Refresh") }
                    }
                    IconButton(onClick = onOpenSettings) { Icon(Icons.Outlined.Settings, contentDescription = "Settings") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Surfaces.screen, scrolledContainerColor = Surfaces.screen),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.isUserRefreshing,
            onRefresh = onRefresh,
            modifier = Modifier.fillMaxSize().padding(top = padding.calculateTopPadding()),
        ) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val expanded = maxWidth >= 840.dp
                val sections = DashboardSections(state, now, zone, onRefresh, onRangeChange, onGranularityChange)
                if (expanded) {
                    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
                        sections.Header(Modifier.widthIn(max = 720.dp).padding(bottom = 12.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                with(sections) { overview() }
                                bottomSpacer()
                            }
                            if (state.data != null) {
                                LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                    with(sections) { details() }
                                    bottomSpacer()
                                }
                            }
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize().align(Alignment.TopCenter).widthIn(max = 680.dp),
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        item { sections.Header() }
                        with(sections) {
                            overview()
                            details()
                        }
                        bottomSpacer()
                    }
                }
            }
        }
    }
}

private fun LazyListScope.bottomSpacer() {
    item { Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars).height(24.dp)) }
}

/** The dashboard's pieces, arranged in one column on phones and two on wide screens. */
private class DashboardSections(
    val state: DashboardUiState,
    val now: Instant,
    val zone: ZoneId,
    val onRefresh: () -> Unit,
    val onRangeChange: (MobileRange) -> Unit,
    val onGranularityChange: (String) -> Unit,
) {
    val data: DashboardData? = state.data
    val colors = AccountColors.of(data?.timeline, data?.summary)

    @Composable
    fun Header(modifier: Modifier = Modifier) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            RangeSelector(state, onRangeChange)
            StatusBanner()
        }
    }

    @Composable
    private fun StatusBanner() {
        val error = state.error
        val updated = state.lastUpdated
        when {
            error != null && data != null -> Banner(
                Icons.Outlined.CloudOff,
                if (updated != null) "$error Showing data from ${Fmt.relative(updated, now)}." else error,
                BannerTone.Warning,
                actionLabel = "Retry",
                onAction = onRefresh,
            )
            error != null -> Banner(Icons.Outlined.WarningAmber, error, BannerTone.Error, actionLabel = "Retry", onAction = onRefresh)
            updated != null && Duration.between(updated, now) > STALE_AFTER -> Banner(
                Icons.Outlined.History,
                "Last updated ${Fmt.relative(updated, now)}.",
                BannerTone.Info,
                actionLabel = "Refresh",
                onAction = onRefresh,
            )
        }
    }

    fun LazyListScope.overview() {
        val data = data
        if (data == null) {
            item { EmptyState(state, onRefresh) }
            return
        }
        item(key = "hero") { HeroCard(data.summary, state.range) }
        for (group in data.summary.groups) {
            item(key = "group-${group.group}") { GroupCard(group, data.summary.total, colors) }
        }
    }

    fun LazyListScope.details() {
        val data = data ?: return
        data.timeline?.let { timeline ->
            item(key = "timeline") { TimelineCard(timeline, state, colors, zone, onGranularityChange) }
        }
        data.limits?.takeIf { it.accounts.isNotEmpty() }?.let { limits ->
            item(key = "limits") { LimitsCard(limits, now) }
        }
        if (data.models.isNotEmpty()) item(key = "models") { ModelsCard(data.models) }
        data.accounts?.let { accounts -> item(key = "accounts") { AccountsCard(accounts, colors, now) } }
        item(key = "footer") { Footer(data.summary, state.lastUpdated, now) }
    }
}

@Composable
private fun RangeSelector(state: DashboardUiState, onRangeChange: (MobileRange) -> Unit) {
    val ranges = state.availableRanges
    val providerDates = state.data?.summary?.usesProviderDates
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        ranges.forEachIndexed { index, range ->
            SegmentedButton(
                selected = range == state.range,
                onClick = { onRangeChange(range) },
                shape = SegmentedButtonDefaults.itemShape(index, ranges.size),
                icon = {},
                modifier = Modifier.semantics { contentDescription = range.longLabel(providerDates) },
            ) {
                Text(range.label(providerDates), maxLines = 1)
            }
        }
    }
}

@Composable
private fun EmptyState(state: DashboardUiState, onRefresh: () -> Unit) {
    val name = state.server?.serverName ?: "your computer"
    Column(
        Modifier.fillMaxWidth().padding(vertical = 56.dp, horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (state.isLoading) {
            CircularProgressIndicator()
            Text("Loading from $name…", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Icon(Icons.Outlined.CloudOff, contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("No data yet", style = MaterialTheme.typography.titleLarge)
            Text(
                "Make sure $name is awake, PlanMeter is running with Remote access on, and this phone is connected to Tailscale.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            FilledTonalButton(onClick = onRefresh) { Text("Try again") }
        }
    }
}

@Composable
private fun HeroCard(summary: RemoteSummary, range: MobileRange) {
    val total = summary.total
    val spoken = "${range.longLabel(summary.usesProviderDates)} spend ${Fmt.usd(total.costUsd)}. Today ${Fmt.usd(summary.todayCostUsd)}."
    PlanCard(Modifier.semantics(mergeDescendants = true) { contentDescription = spoken }) {
        Text(range.longLabel(summary.usesProviderDates), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(Fmt.usd(total.costUsd), style = HeroNumberStyle, modifier = Modifier.weight(1f), maxLines = 1)
            // "Today" already is the window when the host reports provider calendar days.
            if (!(range == MobileRange.DAY && summary.usesProviderDates == true)) {
                Column(horizontalAlignment = Alignment.End) {
                    Text("Today", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(Fmt.usd(summary.todayCostUsd), style = MaterialTheme.typography.titleLarge.tabular())
                }
            }
        }
        GroupShareBar(summary)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Stat("Tokens", Fmt.tokens(total.tokens), Modifier.weight(1f))
            Stat("Cached", Fmt.percent(total.cachedShare), Modifier.weight(1f))
            Stat("Cache savings", Fmt.usd(total.cacheSavingsUsd), Modifier.weight(1.3f))
        }
    }
}

/** Personal / Work / Other as one segmented bar. */
@Composable
private fun GroupShareBar(summary: RemoteSummary) {
    val total = summary.total.costUsd
    val parts = summary.groups.filter { it.totals.costUsd > 0 }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth().height(8.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            if (total <= 0 || parts.isEmpty()) {
                Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), MaterialTheme.shapes.small))
            } else {
                for (group in parts) {
                    Box(
                        Modifier
                            .weight((group.totals.costUsd / total).toFloat().coerceAtLeast(0.01f))
                            .fillMaxSize()
                            .background(GroupColors.of(group.group), MaterialTheme.shapes.small),
                    )
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            for (group in summary.groups) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Dot(GroupColors.of(group.group), 8)
                    Text(
                        "${Fmt.groupName(group.group)} ${Fmt.percent(if (total > 0) group.totals.costUsd / total else 0.0)}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun GroupCard(group: RemoteGroupUsage, total: RemoteTotals, colors: AccountColors) {
    val share = if (total.costUsd > 0) group.totals.costUsd / total.costUsd else 0.0
    val color = GroupColors.of(group.group)
    PlanCard {
        Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Dot(color)
                Text(Fmt.groupName(group.group), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(Fmt.percent(share), style = MaterialTheme.typography.bodyMedium.tabular(), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(Fmt.usd(group.totals.costUsd), style = CardNumberStyle)
                Text(
                    "${Fmt.tokens(group.totals.tokens)} tokens",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            ShareBar(share, color)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Sessions", Fmt.integer(group.totals.sessions), Modifier.weight(1f))
                Stat("Cache savings", Fmt.usd(group.totals.cacheSavingsUsd), Modifier.weight(1.3f))
                Stat("Cached", Fmt.percent(group.totals.cachedShare), Modifier.weight(1f))
            }
        }
        if (group.accounts.isNotEmpty()) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (row in group.accounts) {
                    Row(
                        Modifier.semantics(mergeDescendants = true) {},
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Dot(colors[row.account.id], 8)
                        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(row.account.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                            row.account.plan?.let { Pill(it) }
                        }
                        Text(
                            Fmt.usd(row.totals.costUsd),
                            style = MaterialTheme.typography.bodyMedium.tabular(),
                            color = if (row.totals.tokens == 0L) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TimelineCard(
    timeline: RemoteTimeline,
    state: DashboardUiState,
    colors: AccountColors,
    zone: ZoneId,
    onGranularityChange: (String) -> Unit,
) {
    val options = state.availableGranularities
    PlanCard {
        CardTitle("Cost over time")
        if (options.size > 1) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                options.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = option == state.granularity,
                        onClick = { onGranularityChange(option) },
                        shape = SegmentedButtonDefaults.itemShape(index, options.size),
                        icon = {},
                        modifier = Modifier.semantics { contentDescription = "${MobileRange.granularityLabel(option)} buckets" },
                    ) { Text(MobileRange.granularityLabel(option), style = MaterialTheme.typography.labelMedium, maxLines = 1) }
                }
            }
        }
        if (timeline.points.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                Text("No usage in this range.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            TimelineChart(timeline, colors, zone = zone)
            // Only once the reply to that request has arrived, not while it's loading.
            if (state.data?.requestedGranularity == state.granularity && timeline.resolution != state.granularity) {
                Text(
                    "Showing ${MobileRange.granularityLabel(timeline.resolution).lowercase()} buckets; update PlanMeter on your computer for finer ones.",
                    style = ChartNoteStyle,
                )
            }
            if (ChartModel(timeline, zone).hasBaseline) {
                Text("Lighter bars: workspace credits without timing, spread evenly over the hours the provider reported.", style = ChartNoteStyle)
            }
        }
    }
}

@Composable
private fun LimitsCard(limits: RemoteLimits, now: Instant) {
    PlanCard {
        CardTitle("Codex limits")
        for (entry in limits.accounts) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Dot(GroupColors.of(entry.account.group), 8)
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(entry.account.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        entry.account.plan?.let { Pill(it) }
                    }
                    entry.asOf?.let {
                        Text(Fmt.relative(it, now), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                for (window in entry.windows) {
                    val used = window.usedPercent
                    val color = when {
                        used > 90 -> MaterialTheme.colorScheme.error
                        used > 70 -> Color(0xFFF59E0B)
                        else -> MaterialTheme.colorScheme.primary
                    }
                    val resets = "resets ${Fmt.relative(window.resetsAt, now, midSentence = true)}"
                    Column(
                        Modifier.semantics(mergeDescendants = true) { contentDescription = "${window.label}: ${used.toInt()} percent used, $resets" },
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Row {
                            Text(window.label, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                            Text(
                                "${Fmt.percent(used / 100)} · $resets",
                                style = MaterialTheme.typography.bodySmall.tabular(),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        ShareBar(used / 100, color, height = 8)
                    }
                }
                entry.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
        Text(limits.note, style = ChartNoteStyle)
    }
}

@Composable
private fun ModelsCard(rows: List<RemoteModelRow>) {
    var showAll by rememberSaveable { mutableStateOf(false) }
    PlanCard {
        CardTitle("By model") {
            if (rows.size > 6) {
                TextButton(onClick = { showAll = !showAll }) { Text(if (showAll) "Show less" else "Show all ${rows.size}") }
            }
        }
        for (row in if (showAll) rows else rows.take(6)) {
            Row(
                Modifier.semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Dot(GroupColors.of(row.group), 8)
                Column(Modifier.weight(1f)) {
                    Text(row.model, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                    Text(row.accountName, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(if (row.priced) Fmt.usd(row.totals.costUsd) else "unpriced", style = MaterialTheme.typography.bodyMedium.tabular())
                    Text(Fmt.tokens(row.totals.tokens), style = MaterialTheme.typography.bodySmall.tabular(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun AccountsCard(accounts: RemoteAccounts, colors: AccountColors, now: Instant) {
    PlanCard {
        CardTitle("Accounts & sources") {
            accounts.scannedAt?.let {
                Text("Scanned ${Fmt.relative(it, now)}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        for (account in accounts.accounts) {
            Row(
                Modifier.semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Dot(colors[account.id], 8)
                Column(Modifier.weight(1f)) {
                    Text(account.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val detail = listOfNotNull(account.providerName, account.email).joinToString(" · ")
                    Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                account.plan?.let { Pill(it) }
                Pill(Fmt.groupName(account.group), color = GroupColors.of(account.group), container = GroupColors.of(account.group).copy(alpha = 0.12f))
            }
        }
        if (accounts.sources.isNotEmpty()) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            for (source in accounts.sources) {
                val ok = source.status.equals("ok", ignoreCase = true)
                Row(
                    Modifier.semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(source.provider.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            source.path,
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.MiddleEllipsis,
                        )
                    }
                    val tone = if (ok) Color(0xFF2FB87A) else Color(0xFFF59E0B)
                    Pill(source.status, color = tone, container = tone.copy(alpha = 0.14f))
                }
            }
        }
    }
}

@Composable
private fun Footer(summary: RemoteSummary, lastUpdated: Instant?, now: Instant) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text("From ${summary.serverName}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (lastUpdated != null) {
            Text(
                "Updated ${Fmt.relative(lastUpdated, now)} · data as of ${Fmt.relative(summary.generatedAt, now)}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
            )
        }
        Text(
            "Estimated costs: API-equivalent token prices, or workspace credits where reported.",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
        )
    }
}
