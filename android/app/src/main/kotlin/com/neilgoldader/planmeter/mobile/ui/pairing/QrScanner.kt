package com.neilgoldader.planmeter.mobile.ui.pairing

import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executors

/**
 * Camera preview that reports QR payloads, using CameraX and ZXing's core
 * decoder (no Google Play services). The same code is reported at most once
 * every three seconds, as on the iPhone.
 */
@Composable
fun QrScanner(onCode: (String) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnCode by rememberUpdatedState(onCode)
    val executor = remember { Executors.newSingleThreadExecutor() }
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }

    DisposableEffect(lifecycleOwner) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        val analyzer = QrAnalyzer { code -> ContextCompat.getMainExecutor(context).execute { currentOnCode(code) } }
        providerFuture.addListener({
            try {
                val cameraProvider = providerFuture.get()
                provider = cameraProvider
                val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { it.setAnalyzer(executor, analyzer) }
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                Log.w("PlanMeter", "Camera unavailable", e)
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            provider?.unbindAll()
        }
    }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }

    AndroidView(factory = { previewView }, modifier = modifier)
}

private class QrAnalyzer(private val onCode: (String) -> Unit) : ImageAnalysis.Analyzer {
    private val reader = QRCodeReader()
    private val hints = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
    )
    private var lastCode: String? = null
    private var lastTime = 0L

    override fun analyze(image: ImageProxy) {
        image.use {
            // The Y (luminance) plane is all ZXing needs.
            val plane = image.planes[0]
            val buffer = plane.buffer
            val data = ByteArray(buffer.remaining()).also(buffer::get)
            val source = PlanarYUVLuminanceSource(data, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
            val text = try {
                reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
            } catch (_: NotFoundException) {
                null
            } catch (_: ReaderException) {
                null
            } finally {
                reader.reset()
            }
            if (text != null) {
                val now = System.currentTimeMillis()
                if (text != lastCode || now - lastTime > 3_000) {
                    lastCode = text
                    lastTime = now
                    onCode(text)
                }
            }
        }
    }
}
