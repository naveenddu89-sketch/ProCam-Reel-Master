package com.procam.reelmaster

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.procam.reelmaster.audio.AudioRouteManager
import com.procam.reelmaster.camera.CameraEngine
import com.procam.reelmaster.camera.CameraPlatformViewFactory
import com.procam.reelmaster.media.ClipRepository
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private lateinit var engine: CameraEngine
    private lateinit var audioRoute: AudioRouteManager
    private lateinit var clips: ClipRepository

    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    // File scans + JPEG thumbnails never run on the UI thread.
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioRoute = AudioRouteManager(this)
        clips = ClipRepository(this)
        engine = CameraEngine(this, this, audioRoute) { payload ->
            runOnUiThread {
                // Long takes: never let the screen sleep mid-recording, and
                // clear the flag when CameraX finalizes on its own.
                if (payload["type"] == "recording_finalized") setKeepScreenOn(false)
                eventSink?.success(payload)
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "procam/engine_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                engine.onSinkAttached()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "procam/camera_preview",
            CameraPlatformViewFactory(engine),
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "procam/engine",
        ).setMethodCallHandler(::handleEngineCall)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "procam/files",
        ).setMethodCallHandler(::handleFileCall)
    }

    private fun handleEngineCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> ensurePermissions(result)
            "ensureBluetooth" -> ensureBluetoothPermission(result)
            "start" -> {
                engine.start()
                result.success(null)
            }

            "pause" -> {
                engine.pause()
                result.success(null)
            }

            "setAspect" ->
                result.success(engine.setAspect(call.arguments as? String ?: ""))

            "setQuality4k" ->
                result.success(engine.setQuality4k(call.arguments as? Boolean ?: false))

            "is4k" -> result.success(engine.is4k())
            "switchCamera" -> result.success(engine.switchCamera())
            "startRecording" -> {
                // Mic + encoder setup runs off the UI thread; the reply lands
                // on the main thread when the take has actually started.
                engine.startRecording { ok ->
                    runOnUiThread {
                        setKeepScreenOn(ok)
                        result.success(ok)
                    }
                }
            }

            "stopRecording" -> {
                setKeepScreenOn(false)
                engine.stopRecording { payload ->
                    runOnUiThread {
                        setKeepScreenOn(false)
                        result.success(payload)
                    }
                }
            }

            "setZoom" -> {
                engine.setZoom((call.arguments as? Number)?.toFloat() ?: 1f)
                result.success(null)
            }

            "setTorch" -> {
                engine.setTorch(call.arguments as? Boolean ?: false)
                result.success(null)
            }

            "setExposure" -> {
                engine.setExposure((call.arguments as? Number)?.toInt() ?: 0)
                result.success(null)
            }

            "focusAt" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                engine.focusAt(
                    (args["x"] as? Number)?.toDouble() ?: 0.5,
                    (args["y"] as? Number)?.toDouble() ?: 0.5,
                    args["lock"] as? Boolean ?: false,
                )
                result.success(null)
            }

            "exposureRange" -> result.success(engine.exposureRange())
            "mediaDirs" -> result.success(clips.dirs())
            "audioInputs" -> result.success(audioRoute.devices())

            "selectAudioInput" -> {
                audioRoute.select((call.arguments as? Number)?.toInt())
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleFileCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> ioExecutor.execute {
                val data = clips.list()
                runOnUiThread { result.success(data) }
            }

            "thumbnail" -> {
                val path = call.arguments as? String ?: ""
                ioExecutor.execute {
                    val thumb = clips.thumbnail(path)
                    runOnUiThread { result.success(thumb) }
                }
            }

            "share" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val path = args["path"] as? String ?: ""
                val target = args["target"] as? String ?: "generic"
                // Package-manager lookups + FileProvider can take a moment;
                // never do them on the UI thread.
                ioExecutor.execute {
                    val ok = clips.share(path, target)
                    runOnUiThread { result.success(ok) }
                }
            }

            "delete" -> {
                val path = call.arguments as? String ?: ""
                ioExecutor.execute {
                    val ok = clips.delete(path)
                    runOnUiThread { result.success(ok) }
                }
            }

            "open" -> {
                val path = call.arguments as? String ?: ""
                ioExecutor.execute {
                    clips.open(path)
                    runOnUiThread { result.success(null) }
                }
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- permissions

    /** Long recordings must not be interrupted by the screen timing out. */
    private fun setKeepScreenOn(on: Boolean) {
        runOnUiThread {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun requiredPermissions(): Array<String> = arrayOf(
        Manifest.permission.CAMERA,
        Manifest.permission.RECORD_AUDIO,
    )

    /** Bluetooth mic routing needs BLUETOOTH_CONNECT on Android 12+. */
    private fun ensureBluetoothPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        requestMissing(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), result)
    }

    private fun ensurePermissions(result: MethodChannel.Result) {
        requestMissing(requiredPermissions(), result)
    }

    private fun requestMissing(
        permissions: Array<String>,
        result: MethodChannel.Result,
    ) {
        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) !=
                PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        // One request at a time; a second call supersedes the first.
        pendingPermissionResult?.success(false)
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERM_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERM_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    override fun onDestroy() {
        setKeepScreenOn(false)
        try {
            engine.shutdown()
        } catch (_: Throwable) {
        }
        try {
            audioRoute.release()
        } catch (_: Throwable) {
        }
        ioExecutor.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val PERM_REQUEST = 4201
    }
}
