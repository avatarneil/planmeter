package com.neilgoldader.planmeter.mobile

import android.content.Context
import android.widget.FrameLayout
import android.widget.RemoteViews
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import com.neilgoldader.planmeter.mobile.data.MobileRange
import com.neilgoldader.planmeter.mobile.data.WidgetSnapshot
import com.neilgoldader.planmeter.mobile.widget.SpendWidgetContent
import com.neilgoldader.planmeter.mobile.widget.WidgetTheme
import kotlinx.coroutines.runBlocking
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.Instant
import java.util.TimeZone

/** Renders the Glance widget through real RemoteViews, as a launcher would. */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w411dp-h560dp-normal-long-notround-any-420dpi-keyshidden-nonav")
class WidgetScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val context: Context = ApplicationProvider.getApplicationContext()

    @Before
    fun useFakeDataTimeZone() {
        TimeZone.setDefault(TimeZone.getTimeZone(FakeData.zone))
    }

    private fun render(snapshot: WidgetSnapshot?, size: DpSize, now: Instant): RemoteViews = runBlocking {
        GlanceRemoteViews().compose(context, size) { WidgetTheme { SpendWidgetContent(snapshot, now) } }.remoteViews
    }

    private fun widgets(name: String) {
        val snapshot = WidgetSnapshot.from(FakeData.summary(MobileRange.DAY), FakeData.timeline(MobileRange.DAY, "hour"), FakeData.zone)
        val fresh = snapshot.updatedAt.plusSeconds(120)
        val small = DpSize(170.dp, 170.dp)
        val wide = DpSize(350.dp, 170.dp)
        val views = listOf(
            "Wide, fresh" to (render(snapshot, wide, fresh) to wide),
            "Small, fresh" to (render(snapshot, small, fresh) to small),
            "Small, stale" to (render(snapshot, small, snapshot.updatedAt.plusSeconds(20 * 60)) to small),
            "Not paired" to (render(null, small, fresh) to small),
        )
        compose.setContent {
            Column(
                Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Color(0xFF3B4B6B), Color(0xFF7A5C8F)))).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                val (wideViews, wideSize) = views[0].second
                AndroidView(factory = { ctx -> wideViews.apply(ctx, FrameLayout(ctx)) }, modifier = Modifier.size(wideSize.width, wideSize.height))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    for ((_, pair) in views.drop(1).take(2)) {
                        AndroidView(factory = { ctx -> pair.first.apply(ctx, FrameLayout(ctx)) }, modifier = Modifier.size(pair.second.width, pair.second.height))
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val (unpaired, size) = views[3].second
                    AndroidView(factory = { ctx -> unpaired.apply(ctx, FrameLayout(ctx)) }, modifier = Modifier.size(size.width, size.height))
                    Text("Wide · small · stale (20 min) · not paired", color = Color.White.copy(alpha = 0.8f), modifier = Modifier.padding(8.dp))
                }
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/android-$name.png")
    }

    @Test
    fun widgetLight() = widgets("widget-light")

    @Test
    @Config(qualifiers = "+night")
    fun widgetDark() = widgets("widget-dark")
}
