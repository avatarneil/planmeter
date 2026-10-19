package com.neilgoldader.planmeter.mobile.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.neilgoldader.planmeter.protocol.PairedServer
import com.neilgoldader.planmeter.protocol.RemoteJson
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "planmeter")

data class AppSettings(
    val server: PairedServer? = null,
    val range: MobileRange = MobileRange.MONTH,
    /** Chosen bucket size per range, keyed by [MobileRange.raw]. */
    val granularities: Map<String, String> = emptyMap(),
    val requireBiometrics: Boolean = false,
)

/**
 * Small app state in DataStore: the paired-server record (host, port, name,
 * pinned server key, device id, paired date), view preferences, and the widget
 * snapshot. None of it is secret: the signing key is in the Android Keystore.
 * The app is excluded from backup and device transfer.
 */
class AppStore(context: Context) {
    private val store = context.applicationContext.dataStore

    private object Keys {
        val server = stringPreferencesKey("paired_server")
        val range = intPreferencesKey("range")
        val granularities = stringPreferencesKey("granularities")
        val requireBiometrics = booleanPreferencesKey("require_biometrics")
        val widget = stringPreferencesKey("widget_snapshot")
    }

    private val granularitySerializer = MapSerializer(String.serializer(), String.serializer())

    val settings: Flow<AppSettings> = store.data.map { prefs ->
        AppSettings(
            server = prefs[Keys.server]?.let { decode { RemoteJson.decode(PairedServer.serializer(), it.toByteArray()) } },
            range = prefs[Keys.range]?.let(MobileRange::fromRaw) ?: MobileRange.MONTH,
            granularities = prefs[Keys.granularities]?.let { decode { RemoteJson.json.decodeFromString(granularitySerializer, it) } }.orEmpty(),
            requireBiometrics = prefs[Keys.requireBiometrics] ?: false,
        )
    }

    suspend fun current(): AppSettings = settings.first()

    suspend fun savePairedServer(server: PairedServer) {
        store.edit { it[Keys.server] = RemoteJson.encodeToString(PairedServer.serializer(), server) }
    }

    suspend fun clearPairing() {
        store.edit {
            it.remove(Keys.server)
            it.remove(Keys.widget)
        }
    }

    suspend fun setRange(range: MobileRange) {
        store.edit { it[Keys.range] = range.raw }
    }

    suspend fun setGranularities(value: Map<String, String>) {
        store.edit { it[Keys.granularities] = RemoteJson.json.encodeToString(granularitySerializer, value) }
    }

    suspend fun setRequireBiometrics(enabled: Boolean) {
        store.edit { it[Keys.requireBiometrics] = enabled }
    }

    suspend fun widgetSnapshot(): WidgetSnapshot? =
        store.data.first()[Keys.widget]?.let { decode { RemoteJson.json.decodeFromString(WidgetSnapshot.serializer(), it) } }

    suspend fun saveWidgetSnapshot(snapshot: WidgetSnapshot) {
        store.edit { it[Keys.widget] = RemoteJson.json.encodeToString(WidgetSnapshot.serializer(), snapshot) }
    }

    private inline fun <T> decode(block: () -> T): T? = try {
        block()
    } catch (_: Exception) {
        null
    }
}
