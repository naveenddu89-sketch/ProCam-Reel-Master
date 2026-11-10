package com.procam.reelmaster.camera

import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.view.Surface
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.procam.reelmaster.audio.AudioRouteManager
import com.procam.reelmaster.audio.MicRecorder
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * CameraX VideoCapture engine.
 *
 * - Preview + VideoCapture only (no ImageAnalysis) => low GPU/CPU load.
 * - Hardware H.264 via MediaCodec, bitrate pinned for a high-quality master.
 * - Separate AAC audio track (see MicRecorder) so any mic source can be used.
 * - Rebinds use cases only while idle; never during a take.
 */
class CameraEngine(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val audioRoute: AudioRouteManager,
    private val emitEvent: (Map<String, Any?>) -> Unit,
) {
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cameraExecutor: ExecutorService = Executors.newFixedThreadPool(2)

    // AudioRecord + MediaCodec setup/teardown costs 300-2000 ms. Doing that on
    // the main thread froze the UI every time record started or stopped, so all
    // mic work lives on its own single thread.
    private val audioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var previewView: PreviewView? = null

    private var recording: Recording? = null
    private var mic: MicRecorder? = null
    private var pendingStop: ((Map<String, Any?>?) -> Unit)? = null
    private var videoStartNs = 0L

    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var aspect = "9:16"
    private var use4k = false
    private var startRequested = false
    private var bound = false
    // Which configuration is currently bound. Rebinding with the same values is
    // a no-op: unbind/rebind cycles were freezing the preview on app start.
    private var boundKey: String? = null
    private var rebindScheduled = false

    // ---------------------------------------------------------------- lifecycle

    fun start() {
        startRequested = true
        val existing = provider
        if (existing != null) {
            scheduleRebind()
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                provider = future.get()
                scheduleRebind()
            } catch (t: Throwable) {
                error("Camera init failed: ${t.message}")
            }
        }, mainExecutor)
    }

    fun attachPreview(view: PreviewView) {
        previewView = view
        if (startRequested) scheduleRebind()
    }

    fun detachPreview(view: PreviewView) {
        if (previewView === view) previewView = null
        if (recording == null) {
            try {
                provider?.unbindAll()
            } catch (_: Throwable) {
            }
            camera = null
            bound = false
            boundKey = null
            startRequested = false
        }
    }

    fun pause() {
        if (recording != null) return
        startRequested = false
        try {
            provider?.unbindAll()
        } catch (_: Throwable) {
        }
        camera = null
        bound = false
        boundKey = null
    }

    fun shutdown() {
        startRequested = false
        if (recording != null) {
            try {
                recording?.stop()
            } catch (_: Throwable) {
            }
        }
        pendingStop = null
        val micLocal = mic
        mic = null
        if (micLocal != null) {
            try {
                // Flushing the AAC muxer can take a moment; never on the UI thread.
                audioExecutor.execute {
                    try {
                        micLocal.stop()
                    } catch (_: Throwable) {
                    }
                }
            } catch (_: Throwable) {
            }
        }
        try {
            provider?.unbindAll()
        } catch (_: Throwable) {
        }
        bound = false
        boundKey = null
        try {
            audioExecutor.shutdown()
        } catch (_: Throwable) {
        }
        cameraExecutor.shutdown()
    }

    fun onSinkAttached() {
        if (bound) emitEvent(mapOf("type" to "ready"))
    }

    // ------------------------------------------------------------------- binding

    /**
     * Coalesces start() + attachPreview() + provider-ready into one bind.
     * Binding on every call caused two or three unbind/rebind cycles during
     * launch, which looked like a frozen/black preview on slower phones.
     */
    private fun scheduleRebind() {
        if (rebindScheduled) return
        rebindScheduled = true
        mainHandler.postDelayed({
            rebindScheduled = false
            if (startRequested) rebind()
        }, 60L)
    }

    private fun rebind() {
        val pv = previewView ?: return
        val prov = provider ?: return
        if (recording != null) return

        val key = "$aspect|$use4k|$lensFacing"
        if (bound && boundKey == key) return

        try {
            prov.unbindAll()

            val rotation = pv.display?.rotation ?: Surface.ROTATION_0
            val cxAspect = if (aspect == "9:16" || aspect == "16:9") {
                AspectRatio.RATIO_16_9
            } else {
                AspectRatio.RATIO_4_3
            }

            val previewUseCase = Preview.Builder()
                .setTargetAspectRatio(cxAspect)
                .setTargetRotation(rotation)
                .build()
                .also { it.setSurfaceProvider(pv.surfaceProvider) }

            // FHD resolves to 1920x1080 for 16:9 and 1440x1080 for 4:3, so a
            // single quality covers every aspect ratio without losing detail.
            val quality: Quality
            val fallback: FallbackStrategy
            if (use4k) {
                quality = Quality.UHD
                fallback = FallbackStrategy.higherQualityOrLowerThan(Quality.FHD)
            } else {
                quality = Quality.FHD
                fallback = FallbackStrategy.higherQualityOrLowerThan(Quality.HD)
            }

            val recorder = Recorder.Builder()
                .setQualitySelector(QualitySelector.from(quality, fallback))
                .setAspectRatio(cxAspect)
                .setTargetVideoEncodingBitRate(if (use4k) 45_000_000 else 20_000_000)
                .setExecutor(cameraExecutor)
                .build()

            val capture = VideoCapture.withOutput(recorder)
            val selector = CameraSelector.Builder()
                .requireLensFacing(lensFacing)
                .build()

            camera = prov.bindToLifecycle(
                lifecycleOwner,
                selector,
                previewUseCase,
                capture,
            )
            videoCapture = capture
            bound = true
            boundKey = key
            emitEvent(mapOf("type" to "ready"))
        } catch (t: Throwable) {
            bound = false
            boundKey = null
            error("Camera bind failed: ${t.message}")
        }
    }

    // ------------------------------------------------------------------ settings

    fun setAspect(value: String): Boolean {
        if (recording != null) return false
        if (value !in setOf("9:16", "16:9", "1:1", "4:5")) return false
        aspect = value
        if (startRequested) scheduleRebind()
        return true
    }

    fun setQuality4k(enabled: Boolean): Boolean {
        if (recording != null) return false
        use4k = enabled
        if (startRequested) scheduleRebind()
        return true
    }

    /**
     * Reports the quality actually selected, not what was requested. Some
     * cameras advertise UHD but silently fall back to 1080p.
     */
    fun is4k(): Boolean = videoCapture?.selectedQuality == Quality.UHD

    fun switchCamera(): Boolean {
        if (recording != null) return false
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        // Torch is back-camera only; reset it so the UI stays truthful.
        try {
            camera?.cameraControl?.enableTorch(false)
        } catch (_: Throwable) {
        }
        if (startRequested) scheduleRebind()
        return true
    }

    fun setZoom(ratio: Float) {
        val cam = camera ?: return
        val state = cam.cameraInfo.zoomState.value ?: return
        try {
            cam.cameraControl.setZoomRatio(
                ratio.coerceIn(state.minZoomRatio, state.maxZoomRatio),
            )
        } catch (_: Throwable) {
        }
    }

    fun setTorch(on: Boolean) {
        try {
            camera?.cameraControl?.enableTorch(on)
        } catch (_: Throwable) {
        }
    }

    fun setExposure(index: Int) {
        try {
            camera?.cameraControl?.setExposureCompensationIndex(index)
        } catch (_: Throwable) {
        }
    }

    fun exposureRange(): Map<String, Any> {
        val state = camera?.cameraInfo?.exposureState
            ?: return mapOf("min" to 0, "max" to 0)
        return mapOf(
            "min" to state.exposureCompensationRange.lower,
            "max" to state.exposureCompensationRange.upper,
        )
    }

    fun focusAt(nx: Double, ny: Double, lock: Boolean) {
        val pv = previewView ?: return
        val cam = camera ?: return
        if (pv.width == 0 || pv.height == 0) return

        val point = pv.meteringPointFactory.createPoint(
            (nx.coerceIn(0.0, 1.0) * pv.width).toFloat(),
            (ny.coerceIn(0.0, 1.0) * pv.height).toFloat(),
        )
        var builder = FocusMeteringAction.Builder(
            point,
            FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE,
        )
        if (lock) builder = builder.disableAutoCancel()

        try {
            cam.cameraControl.startFocusAndMetering(builder.build())
        } catch (_: Throwable) {
        }
    }

    // ----------------------------------------------------------------- recording

    /**
     * Async on purpose: opening AudioRecord + MediaCodec blocks for a few
     * hundred milliseconds and used to stall the UI thread on every take.
     * [callback] always runs on the main thread.
     */
    fun startRecording(callback: (Boolean) -> Unit) {
        val capture = videoCapture
        if (capture == null || !bound || recording != null) {
            callback(false)
            return
        }

        val dir = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES),
            "ProCam",
        )
        if (!dir.exists() && !dir.mkdirs()) {
            error("Cannot create output folder")
            callback(false)
            return
        }

        // A long take needs room; CameraX deletes failed output on storage
        // errors, so refuse to start instead of losing the recording.
        try {
            val free = StatFs(dir.absolutePath).availableBytes
            if (free < 300L * 1024 * 1024) {
                error("Storage almost full — free at least 300 MB")
                callback(false)
                return
            }
        } catch (_: Throwable) {
        }

        val stamp = System.currentTimeMillis()
        val videoFile = File(dir, "PROCAM_$stamp.mp4")
        val audioFile = File(dir, "PROCAM_${stamp}_audio.m4a")
        val audio = MicRecorder(context, audioFile, audioRoute.selectedDevice)

        try {
            audioExecutor.execute {
                // Mic first, off the UI thread. If it fails we still record the
                // video instead of refusing the whole take.
                val micOk = try {
                    audio.start()
                    true
                } catch (t: Throwable) {
                    error("Mic unavailable: ${t.message}")
                    false
                }

                mainHandler.post {
                    if (recording != null || !startRequested || !bound) {
                        if (micOk) stopMicAsync(audio)
                        callback(false)
                        return@post
                    }
                    if (micOk) mic = audio
                    try {
                        val options = FileOutputOptions.Builder(videoFile).build()
                        val pending = capture.output.prepareRecording(context, options)
                        // No withAudioEnabled(): CameraX's default mic is bypassed.
                        recording = pending.start(mainExecutor) { event ->
                            onVideoEvent(event, videoFile, audioFile)
                        }
                        callback(true)
                    } catch (t: Throwable) {
                        if (micOk) stopMicAsync(audio)
                        mic = null
                        error("Record start failed: ${t.message}")
                        callback(false)
                    }
                }
            }
        } catch (t: Throwable) {
            // Executor already shut down (activity dying).
            try {
                audio.stop()
            } catch (_: Throwable) {
            }
            error("Record start failed: ${t.message}")
            callback(false)
        }
    }

    fun stopRecording(callback: (Map<String, Any?>?) -> Unit) {
        val active = recording
        if (active == null) {
            callback(null)
            return
        }
        pendingStop = callback
        try {
            active.stop()
        } catch (t: Throwable) {
            pendingStop = null
            callback(null)
        }
    }

    /** Flushes the AAC muxer on the audio thread, then calls [after] on main. */
    private fun stopMicAsync(micRecorder: MicRecorder, after: (() -> Unit)? = null) {
        try {
            audioExecutor.execute {
                try {
                    micRecorder.stop()
                } catch (_: Throwable) {
                }
                if (after != null) mainHandler.post { after() }
            }
        } catch (_: Throwable) {
            if (after != null) mainHandler.post { after() }
        }
    }

    private fun onVideoEvent(
        event: VideoRecordEvent,
        videoFile: File,
        audioFile: File,
    ) {
        when (event) {
            is VideoRecordEvent.Start -> {
                videoStartNs = System.nanoTime()
                emitEvent(
                    mapOf(
                        "type" to "recording_started",
                        "video" to videoFile.absolutePath,
                        "audio" to audioFile.absolutePath,
                    ),
                )
            }

            is VideoRecordEvent.Finalize -> {
                val micLocal = mic
                mic = null
                val audioStart = micLocal?.startNs ?: 0L

                val offsetMs = if (audioStart > 0 && videoStartNs > 0) {
                    ((audioStart - videoStartNs) / 1_000_000L).toInt()
                } else {
                    0
                }
                val durationMs =
                    event.recordingStats.recordedDurationNanos / 1_000_000L
                val hadError = event.hasError()
                recording = null

                if (hadError) {
                    error(
                        "Recording error ${event.error}: " +
                            (event.cause?.message ?: "unknown"),
                    )
                }

                val finish: () -> Unit = {
                    // Keep a playable partial take (storage full, app killed)
                    // instead of throwing away minutes of footage.
                    val keep = videoFile.exists() && videoFile.length() > 100_000
                    if (hadError && !keep) {
                        videoFile.delete()
                        audioFile.delete()
                        val cb = pendingStop
                        pendingStop = null
                        cb?.invoke(null)
                    } else {
                        val payload = mapOf<String, Any?>(
                            "type" to "recording_finalized",
                            "video" to videoFile.absolutePath,
                            "audio" to if (audioFile.exists() &&
                                audioFile.length() > 1024
                            ) {
                                audioFile.absolutePath
                            } else {
                                null
                            },
                            "durationMs" to durationMs,
                            "audioOffsetMs" to offsetMs,
                        )
                        emitEvent(payload)
                        val cb = pendingStop
                        pendingStop = null
                        cb?.invoke(payload)
                    }
                }

                if (micLocal != null) {
                    stopMicAsync(micLocal, finish)
                } else {
                    finish()
                }            }

            else -> Unit
        }
    }

    private fun error(message: String) {
        emitEvent(mapOf("type" to "error", "message" to message))
    }
}
