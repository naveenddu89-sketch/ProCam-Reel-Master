package com.procam.reelmaster.camera

import android.content.Context
import android.os.Environment
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
    private val cameraExecutor: ExecutorService = Executors.newFixedThreadPool(2)

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

    // ---------------------------------------------------------------- lifecycle

    fun start() {
        startRequested = true
        val existing = provider
        if (existing != null) {
            rebind()
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                provider = future.get()
                rebind()
            } catch (t: Throwable) {
                error("Camera init failed: ${t.message}")
            }
        }, mainExecutor)
    }

    fun attachPreview(view: PreviewView) {
        previewView = view
        if (startRequested) rebind()
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
            startRequested = false
        }
    }

    fun pause() {
        if (recording != null) return
        try {
            provider?.unbindAll()
        } catch (_: Throwable) {
        }
        camera = null
        bound = false
        startRequested = false
    }

    fun shutdown() {
        if (recording != null) {
            try {
                recording?.stop()
            } catch (_: Throwable) {
            }
        }
        pendingStop = null
        try {
            mic?.stop()
        } catch (_: Throwable) {
        }
        mic = null
        try {
            provider?.unbindAll()
        } catch (_: Throwable) {
        }
        cameraExecutor.shutdown()
    }

    fun onSinkAttached() {
        if (bound) emitEvent(mapOf("type" to "ready"))
    }

    // ------------------------------------------------------------------- binding

    private fun rebind() {
        val pv = previewView ?: return
        val prov = provider ?: return
        if (recording != null) return

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
            emitEvent(mapOf("type" to "ready"))
        } catch (t: Throwable) {
            error("Camera bind failed: ${t.message}")
        }
    }

    // ------------------------------------------------------------------ settings

    fun setAspect(value: String): Boolean {
        if (recording != null) return false
        if (value !in setOf("9:16", "16:9", "1:1", "4:5")) return false
        aspect = value
        if (bound) rebind()
        return true
    }

    fun setQuality4k(enabled: Boolean): Boolean {
        if (recording != null) return false
        use4k = enabled
        if (bound) rebind()
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
        if (bound) rebind()
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

    fun startRecording(): Boolean {
        val capture = videoCapture ?: return false
        if (recording != null) return false

        val dir = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES),
            "ProCam",
        )
        if (!dir.exists() && !dir.mkdirs()) {
            error("Cannot create output folder")
            return false
        }

        // A long take needs room; CameraX deletes failed output on storage
        // errors, so refuse to start instead of losing the recording.
        try {
            val free = StatFs(dir.absolutePath).availableBytes
            if (free < 300L * 1024 * 1024) {
                error("Storage almost full — free at least 300 MB")
                return false
            }
        } catch (_: Throwable) {
        }

        val stamp = System.currentTimeMillis()
        val videoFile = File(dir, "PROCAM_$stamp.mp4")
        val audioFile = File(dir, "PROCAM_${stamp}_audio.m4a")

        val audio = MicRecorder(context, audioFile, audioRoute.selectedDevice)
        return try {
            audio.start()
            mic = audio

            val options = FileOutputOptions.Builder(videoFile).build()
            val pending = capture.output.prepareRecording(context, options)
            // No withAudioEnabled(): CameraX's default mic is bypassed.
            recording = pending.start(mainExecutor) { event ->
                onVideoEvent(event, videoFile, audioFile)
            }
            true
        } catch (t: Throwable) {
            try {
                audio.stop()
            } catch (_: Throwable) {
            }
            mic = null
            error("Record start failed: ${t.message}")
            false
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
                try {
                    micLocal?.stop()
                } catch (_: Throwable) {
                }

                val offsetMs = if (audioStart > 0 && videoStartNs > 0) {
                    ((audioStart - videoStartNs) / 1_000_000L).toInt()
                } else {
                    0
                }
                val durationMs =
                    event.recordingStats.recordedDurationNanos / 1_000_000L
                recording = null

                if (event.hasError()) {
                    error(
                        "Recording error ${event.error}: " +
                            (event.cause?.message ?: "unknown"),
                    )
                    // Keep a playable partial take (storage full, app killed)
                    // instead of throwing away minutes of footage.
                    val keep = videoFile.exists() && videoFile.length() > 100_000
                    if (!keep) {
                        videoFile.delete()
                        audioFile.delete()
                        val cb = pendingStop
                        pendingStop = null
                        cb?.invoke(null)
                        return
                    }
                }

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

            else -> Unit
        }
    }

    private fun error(message: String) {
        emitEvent(mapOf("type" to "error", "message" to message))
    }
}
