package com.neilgoldader.planmeter.mobile.ui

import android.app.Application
import androidx.glance.appwidget.updateAll
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.neilgoldader.planmeter.mobile.AppGraph
import com.neilgoldader.planmeter.mobile.data.DashboardData
import com.neilgoldader.planmeter.mobile.data.DashboardLoader
import com.neilgoldader.planmeter.mobile.data.KeyStorage
import com.neilgoldader.planmeter.mobile.data.LoadResult
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.data.UserMessages
import com.neilgoldader.planmeter.mobile.data.WidgetSnapshot
import com.neilgoldader.planmeter.mobile.widget.SpendWidget
import com.neilgoldader.planmeter.mobile.widget.WidgetExpiry
import com.neilgoldader.planmeter.mobile.work.RefreshWorker
import com.neilgoldader.planmeter.protocol.DeviceId
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.PairingInvite
import com.neilgoldader.planmeter.protocol.RemoteClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException

data class DashboardUiState(
    val server: PairedServer? = null,
    val range: MobileRange = MobileRange.MONTH,
    val granularity: String = MobileRange.MONTH.defaultGranularity,
    val directSupportsMinutes: Boolean = true,
    val data: DashboardData? = null,
    val isLoading: Boolean = false,
    /** A pull-to-refresh or explicit refresh is running (automatic refreshes stay quiet). */
    val isUserRefreshing: Boolean = false,
    val error: String? = null,
    val lastUpdated: Instant? = null,
) {
    /** The 1h range needs a host that serves sub-day windows. */
    val availableRanges: List<MobileRange>
        get() = MobileRange.entries.filter { it != MobileRange.HOUR || directSupportsMinutes }

    val availableGranularities: List<String> get() = range.granularities
}

data class PairingUiState(
    val isPairing: Boolean = false,
    val error: String? = null,
    /**
     * A link opened from outside the app, waiting for the user to confirm it.
     * Shown only once settings have loaded and the app is unlocked.
     */
    val pendingInvite: PairingInvite? = null,
)

data class DeviceInfo(val deviceId: String = "…", val keyStorage: KeyStorage = KeyStorage.UNKNOWN)

data class AppUiState(
    val ready: Boolean = false,
    val requireBiometrics: Boolean = false,
    val isLocked: Boolean = false,
    val dashboard: DashboardUiState = DashboardUiState(),
    val pairing: PairingUiState = PairingUiState(),
    val device: DeviceInfo = DeviceInfo(),
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val graph = AppGraph.from(application)
    private val store = graph.store
    private val _state = MutableStateFlow(AppUiState())
    val state: StateFlow<AppUiState> = _state.asStateFlow()

    private var granularities: Map<String, String> = emptyMap()
    private var refreshJob: Job? = null
    private var refreshGeneration = 0

    init {
        viewModelScope.launch {
            val settings = store.current()
            granularities = settings.granularities
            _state.update {
                it.copy(
                    ready = true,
                    requireBiometrics = settings.requireBiometrics,
                    isLocked = settings.requireBiometrics,
                    dashboard = it.dashboard.copy(server = settings.server, range = settings.range, granularity = granularityFor(settings.range)),
                )
            }
            withContext(Dispatchers.Default) { RefreshWorker.syncWithWidgets(getApplication()) }
        }
        viewModelScope.launch(Dispatchers.Default) {
            val info = try {
                val signer = graph.signer
                DeviceInfo(DeviceId.derive(signer.publicKeyRaw), signer.storage)
            } catch (e: Exception) {
                DeviceInfo("unavailable", KeyStorage.UNKNOWN)
            }
            _state.update { state ->
                state.copy(device = info.copy(deviceId = state.dashboard.server?.deviceId ?: info.deviceId))
            }
        }
    }

    /** The chosen bucket size if the range offers it, otherwise the range's default. */
    private fun granularityFor(range: MobileRange): String {
        val chosen = granularities[range.raw.toString()]
        return if (chosen != null && chosen in range.granularities) chosen else range.defaultGranularity
    }

    // Data

    /**
     * Fetches the dashboard. Automatic refreshes are skipped while one is in
     * flight; user actions (pull, range or bucket changes) replace it.
     */
    fun refresh(userInitiated: Boolean = false) {
        val current = _state.value
        val server = current.dashboard.server ?: return
        if (current.isLocked || !current.ready) return
        if (!userInitiated && refreshJob?.isActive == true) return
        refreshJob?.cancel()
        val generation = ++refreshGeneration
        val range = current.dashboard.range
        val granularity = current.dashboard.granularity
        _state.update { it.copy(dashboard = it.dashboard.copy(isLoading = true, isUserRefreshing = userInitiated)) }
        refreshJob = viewModelScope.launch {
            try {
                val client = withContext(Dispatchers.Default) { graph.client(server) }
                val loader = DashboardLoader { request -> withContext(Dispatchers.IO) { client.call(request) } }
                when (val result = loader.load(range, granularity)) {
                    LoadResult.NoSubDayWindows -> {
                        // An older host answered with a whole day; don't label it as an hour.
                        _state.update { it.copy(dashboard = it.dashboard.copy(directSupportsMinutes = false, range = MobileRange.DAY, granularity = granularityFor(MobileRange.DAY))) }
                        viewModelScope.launch { refresh(userInitiated = true) }
                    }
                    is LoadResult.Loaded -> {
                        _state.update {
                            it.copy(dashboard = it.dashboard.copy(data = result.data, error = null, lastUpdated = Instant.now()))
                        }
                        publishWidget(result.data)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation == refreshGeneration) {
                    _state.update { it.copy(dashboard = it.dashboard.copy(error = UserMessages.refresh(e, server))) }
                }
            } finally {
                if (generation == refreshGeneration) {
                    _state.update { it.copy(dashboard = it.dashboard.copy(isLoading = false, isUserRefreshing = false)) }
                }
            }
        }
    }

    private suspend fun publishWidget(data: DashboardData) {
        val summary = data.widgetSummary ?: return
        val snapshot = WidgetSnapshot.from(summary, data.widgetTimeline)
        store.saveWidgetSnapshot(snapshot)
        try {
            SpendWidget().updateAll(getApplication())
            WidgetExpiry.schedule(getApplication(), snapshot)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // No widget placed, or the launcher is busy: nothing to update.
        }
    }

    fun setRange(range: MobileRange) {
        if (range == _state.value.dashboard.range) return
        _state.update { it.copy(dashboard = it.dashboard.copy(range = range, granularity = granularityFor(range))) }
        viewModelScope.launch { store.setRange(range) }
        refresh(userInitiated = true)
    }

    fun setGranularity(granularity: String) {
        val range = _state.value.dashboard.range
        if (granularity !in range.granularities || granularity == _state.value.dashboard.granularity) return
        granularities = granularities + (range.raw.toString() to granularity)
        _state.update { it.copy(dashboard = it.dashboard.copy(granularity = granularity)) }
        viewModelScope.launch { store.setGranularities(granularities) }
        refresh(userInitiated = true)
    }

    // Pairing

    fun pair(text: String) {
        val invite = PairingInvite.parse(text)
        if (invite == null) {
            _state.update { it.copy(pairing = it.pairing.copy(error = UserMessages.unreadableLink(text))) }
            return
        }
        pair(invite)
    }

    /**
     * A `planmeter://pair` link from a QR scan elsewhere or another app. Any
     * web page can open one, so it always waits for the user to confirm, even
     * on a cold start before settings have loaded or while the app is locked.
     */
    fun openPairingLink(link: String) {
        val invite = PairingInvite.parse(link)
        if (invite == null) {
            _state.update { it.copy(pairing = it.pairing.copy(error = UserMessages.unreadableLink(link))) }
            return
        }
        _state.update { it.copy(pairing = it.pairing.copy(pendingInvite = invite)) }
    }

    fun confirmPendingInvite() {
        val current = _state.value
        if (!current.ready || current.isLocked) return
        val invite = current.pairing.pendingInvite ?: return
        _state.update { it.copy(pairing = it.pairing.copy(pendingInvite = null)) }
        pair(invite)
    }

    fun dismissPendingInvite() {
        _state.update { it.copy(pairing = it.pairing.copy(pendingInvite = null)) }
    }

    fun dismissPairingError() {
        _state.update { it.copy(pairing = it.pairing.copy(error = null)) }
    }

    fun pair(invite: PairingInvite) {
        if (_state.value.pairing.isPairing) return
        _state.update { it.copy(pairing = it.pairing.copy(isPairing = true, error = null)) }
        viewModelScope.launch {
            try {
                val paired = withContext(Dispatchers.IO) {
                    RemoteClient.pair(invite, graph.deviceName, graph.platformName, graph.signer, graph.httpSettings)
                }
                store.savePairedServer(paired)
                refreshJob?.cancel()
                _state.update {
                    it.copy(
                        dashboard = DashboardUiState(server = paired, range = it.dashboard.range, granularity = it.dashboard.granularity),
                        device = it.device.copy(deviceId = paired.deviceId),
                    )
                }
                withContext(Dispatchers.Default) { RefreshWorker.syncWithWidgets(getApplication()) }
                refresh(userInitiated = true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(pairing = it.pairing.copy(error = UserMessages.pairing(e, invite))) }
            } finally {
                _state.update { it.copy(pairing = it.pairing.copy(isPairing = false)) }
            }
        }
    }

    fun unpair() {
        refreshJob?.cancel()
        refreshGeneration++
        _state.update { it.copy(dashboard = DashboardUiState(range = it.dashboard.range, granularity = it.dashboard.granularity), pairing = PairingUiState()) }
        viewModelScope.launch {
            store.clearPairing()
            RefreshWorker.cancel(getApplication())
            WidgetExpiry.cancel(getApplication())
            try {
                SpendWidget().updateAll(getApplication())
            } catch (_: Exception) {
            }
        }
    }

    // App lock

    fun setRequireBiometrics(enabled: Boolean) {
        _state.update { it.copy(requireBiometrics = enabled) }
        viewModelScope.launch { store.setRequireBiometrics(enabled) }
    }

    /** Called when the app leaves the foreground. */
    fun lockIfNeeded() {
        if (_state.value.requireBiometrics) _state.update { it.copy(isLocked = true) }
    }

    fun unlocked() {
        _state.update { it.copy(isLocked = false) }
        refresh(userInitiated = false)
    }
}
