package com.procam.reelmaster.audio

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import java.io.File

/**
 * Records AAC-LC 48 kHz mono from an explicitly chosen input device.
 *
 * Why not CameraX's built-in audio? CameraX always captures from the default
 * mic, which makes Bluetooth/wired selection impossible. Recording audio
 * separately also lets us mux it at export time (afftdn denoise) without
 * touching the video stream.
 *
 * Memory: one 4 KB PCM buffer + one MediaCodec instance. No allocations in
 * the loop, so GC never interrupts capture on 3 GB devices.
 */
class MicRecorder(
    context: Context,
    private val outFile: File,
    private val device: AudioDeviceInfo?,
) {
    private val sampleRate = 48_000
    private val channelCount = 1
    private val bitRate = 192_000

    @Volatile
    private var running = false

    private var record: AudioRecord? = null
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var track = -1
    private var thread: Thread? = null
    private var totalBytes = 0L
    private var released = false

    var startNs: Long = 0L
        private set
    var failure: String? = null
        private set

    fun start() {
        outFile.parentFile?.mkdirs()

        val source = if (device?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
            MediaRecorder.AudioSource.VOICE_COMMUNICATION
        } else {
            MediaRecorder.AudioSource.MIC
        }

        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufferSize = maxOf(minBuf * 2, 8192)

        val rec = AudioRecord(
            source,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("Microphone unavailable")
        }

        try {
            if (device != null) rec.setPreferredDevice(device)
        } catch (_: Throwable) {
        }

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            sampleRate,
            channelCount,
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }

        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()

        record = rec
        encoder = enc
        totalBytes = 0
        running = true
        startNs = System.nanoTime()

        rec.startRecording()
        thread = Thread({ runLoop() }, "procam-mic").also { it.start() }
    }

    fun stop() {
        if (!running) {
            releaseAll()
            return
        }
        running = false
        try {
            record?.stop()
        } catch (_: Throwable) {
        }
        try {
            thread?.join(2000)
        } catch (_: InterruptedException) {
        }
        thread = null
        releaseAll()
    }

    private fun runLoop() {
        val pcm = ByteArray(4096)
        try {
            while (running) {
                val n = record?.read(pcm, 0, pcm.size) ?: -1
                if (n > 0) {
                    feed(pcm, n)
                } else if (n == AudioRecord.ERROR_DEAD_OBJECT ||
                    n == AudioRecord.ERROR_INVALID_OPERATION ||
                    n == AudioRecord.ERROR_BAD_VALUE
                ) {
                    break
                }
                drain(false)
            }
            feedEos()
            drain(true)
        } catch (t: Throwable) {
            failure = t.message
        }
    }

    private fun feed(data: ByteArray, size: Int) {
        var offset = 0
        while (offset < size && running) {
            val enc = encoder ?: return
            val index = enc.dequeueInputBuffer(10_000)
            if (index < 0) return
            val buffer = enc.getInputBuffer(index) ?: return
            buffer.clear()
            val len = minOf(buffer.remaining(), size - offset)
            buffer.put(data, offset, len)
            val ptsUs = totalBytes * 1_000_000L / (sampleRate * 2L)
            enc.queueInputBuffer(index, 0, len, ptsUs, 0)
            totalBytes += len
            offset += len
        }
    }

    private fun feedEos() {
        val enc = encoder ?: return
        val index = enc.dequeueInputBuffer(50_000)
        if (index >= 0) {
            val ptsUs = totalBytes * 1_000_000L / (sampleRate * 2L)
            enc.queueInputBuffer(
                index,
                0,
                0,
                ptsUs,
                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
            )
        }
    }

    private fun drain(endOfStream: Boolean) {
        val enc = encoder ?: return
        val info = MediaCodec.BufferInfo()
        var guard = 0

        while (guard++ < 400) {
            val index = enc.dequeueOutputBuffer(info, if (endOfStream) 20_000 else 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (muxer == null) {
                        val m = MediaMuxer(
                            outFile.absolutePath,
                            MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
                        )
                        track = m.addTrack(enc.outputFormat)
                        m.start()
                        muxer = m
                    }
                }

                index >= 0 -> {
                    val buffer = enc.getOutputBuffer(index)
                    if (buffer != null && info.size > 0 &&
                        track >= 0 && muxer != null
                    ) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer?.writeSampleData(track, buffer, info)
                    }
                    enc.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }

                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
            }
        }
    }

    @Synchronized
    private fun releaseAll() {
        if (released) return
        released = true
        try {
            encoder?.stop()
        } catch (_: Throwable) {
        }
        try {
            encoder?.release()
        } catch (_: Throwable) {
        }
        try {
            muxer?.stop()
        } catch (_: Throwable) {
        }
        try {
            muxer?.release()
        } catch (_: Throwable) {
        }
        try {
            record?.release()
        } catch (_: Throwable) {
        }
        encoder = null
        muxer = null
        record = null
    }
}
