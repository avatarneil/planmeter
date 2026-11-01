package com.neilgoldader.planmeter.mobile

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import com.neilgoldader.planmeter.mobile.widget.SpendWidgetReceiver
import com.neilgoldader.planmeter.mobile.widget.WidgetExpiry
import com.neilgoldader.planmeter.mobile.work.WidgetUpkeepWorker
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The widget receiver hands storage work to WorkManager instead of a second goAsync(). */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], application = TestApplication::class)
class WidgetReceiverTest {
    private val app: TestApplication = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(app)
    }

    private fun send(intent: Intent) {
        app.sendBroadcast(intent.setClass(app, SpendWidgetReceiver::class.java))
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun updatesAndClockChangesAreHandledOffTheReceiver() {
        send(Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(7)))
        assertEquals(1, WorkManager.getInstance(app).getWorkInfosForUniqueWork(WidgetUpkeepWorker.NAME).get().size)

        // Redraws run in the receiver's own goAsync(); none of these may throw.
        for (action in listOf(Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, WidgetExpiry.ACTION_EXPIRED)) {
            send(Intent(action))
        }
    }
}
