package com.neilgoldader.planmeter.mobile.ui.dashboard

import androidx.compose.ui.graphics.Color
import com.neilgoldader.planmeter.mobile.ui.theme.SeriesPalette
import com.neilgoldader.planmeter.protocol.RemoteAccount
import com.neilgoldader.planmeter.protocol.RemoteSummary
import com.neilgoldader.planmeter.protocol.RemoteTimeline

/**
 * Per-account colors, as MobileModel.color(for:): the account's accent color
 * when no other account shares it, otherwise the series palette by position.
 */
class AccountColors(private val accounts: List<RemoteAccount>) {
    private val colors: Map<String, Color> = accounts.withIndex().associate { (index, account) ->
        val hex = account.accentColorHex
        val unique = hex != null && accounts.count { it.accentColorHex == hex } == 1
        account.id to ((if (unique) SeriesPalette.parseHex(hex) else null) ?: SeriesPalette.colors[index % SeriesPalette.colors.size])
    }

    operator fun get(accountId: String): Color = colors[accountId] ?: SeriesPalette.colors.last()

    companion object {
        fun of(timeline: RemoteTimeline?, summary: RemoteSummary?): AccountColors =
            AccountColors(timeline?.accounts ?: summary?.groups?.flatMap { group -> group.accounts.map { it.account } }.orEmpty())
    }
}
