package com.neilgoldader.planmeter.mobile.data

import com.neilgoldader.planmeter.protocol.ChannelError
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.PairingInvite
import com.neilgoldader.planmeter.protocol.RemoteClientException
import com.neilgoldader.planmeter.protocol.RemoteClientException.Transport.Kind

/** Turns protocol failures into sentences a person can act on. */
object UserMessages {
    const val NOT_A_PAIRING_LINK = "That isn't a PlanMeter pairing code. On your computer, open PlanMeter → Remote and create a pairing code."
    const val WEB_PAIRING_LINK = "That's the browser pairing link. Scan the app QR code (planmeter://pair…) or copy the app link instead."

    /** Explains why [text] could not be read as a pairing link. */
    fun unreadableLink(text: String): String {
        val trimmed = text.trim()
        return if (trimmed.startsWith("https://", ignoreCase = true) && trimmed.contains("#k=")) WEB_PAIRING_LINK else NOT_A_PAIRING_LINK
    }

    fun pairing(error: Throwable, invite: PairingInvite): String = when (error) {
        is RemoteClientException.InviteExpired -> "This pairing code has expired. Create a new one in PlanMeter on your computer."
        is RemoteClientException.Transport -> transport(error, invite.serverName, invite.serverHost, invite.port)
        is RemoteClientException.Http -> when {
            error.status == 403 && error.serverMessage == "no active pairing code" ->
                "${invite.serverName} has no active pairing code. Codes are single use and expire after 5 minutes; create a new one."
            error.status == 403 -> "${invite.serverName} rejected this pairing code. Create a new one and try again."
            error.status == 409 -> "That request was already seen. Try again."
            else -> "Pairing failed: ${error.message}"
        }
        is RemoteClientException.Channel -> channel(error.error)
        is RemoteClientException.MalformedReply -> "${invite.serverName} sent an unreadable reply. Is it running PlanMeter?"
        else -> "Pairing failed: ${error.message ?: error.javaClass.simpleName}"
    }

    fun refresh(error: Throwable, server: PairedServer): String = when (error) {
        is RemoteClientException.Transport -> transport(error, server.serverName, server.host, server.port)
        is RemoteClientException.Http -> when (error.status) {
            401 -> "${server.serverName} no longer recognizes this phone. It may have been revoked; unpair in Settings and pair again."
            409 -> "The request was rejected as a replay. It will retry."
            200 -> error.serverMessage
            else -> "${server.serverName} returned an error: ${error.message}"
        }
        is RemoteClientException.Channel -> channel(error.error)
        is RemoteClientException.MalformedReply -> "${server.serverName} sent an unreadable reply. Update PlanMeter on your computer."
        else -> error.message ?: "Something went wrong."
    }

    private fun transport(error: RemoteClientException.Transport, name: String, host: String, port: Int): String = when (error.kind) {
        Kind.NOT_TAILNET -> "$host isn't a Tailscale address. Is Tailscale connected on this phone?"
        Kind.UNREACHABLE -> "Couldn't reach $name ($host:$port). Is Tailscale connected, and is PlanMeter running with Remote access on?"
        Kind.TIMEOUT -> "$name didn't answer in time. Is Tailscale connected, and is the computer awake?"
        Kind.OTHER -> "Couldn't connect to $name: ${error.message}. Is Tailscale connected?"
    }

    private fun channel(error: ChannelError): String = when (error) {
        ChannelError.DECRYPT_FAILED -> "Couldn't decrypt the reply. The host's key may have changed; pair again."
        else -> error.description
    }
}
