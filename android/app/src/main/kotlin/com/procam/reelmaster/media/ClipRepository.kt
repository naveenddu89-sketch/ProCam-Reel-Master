package com.procam.reelmaster.media

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream

/**
 * Lightweight local gallery + share helpers.
 * Clips live in app-scoped external storage, so no media permissions are
 * required and nothing is uploaded anywhere.
 */
class ClipRepository(private val context: Context) {

    // MediaExtractor is expensive on low-end storage; key by path + size so a
    // re-scan only parses new files.
    private val durationCache = HashMap<String, Long>()

    private val movieDir: File
        get() = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES),
            "ProCam",
        )

    private val exportDir: File
        get() = File(movieDir, "Exports")

    fun dirs(): Map<String, String> {
        movieDir.mkdirs()
        exportDir.mkdirs()
        return mapOf(
            "movies" to movieDir.absolutePath,
            "exports" to exportDir.absolutePath,
            "cache" to context.cacheDir.absolutePath,
        )
    }

    fun list(): List<Map<String, Any?>> {
        val sources = movieDir.listFiles()?.filter { isClip(it) } ?: emptyList()
        val exports = exportDir.listFiles()?.filter { isClip(it) } ?: emptyList()

        return (sources + exports)
            .distinctBy { it.absolutePath }
            .sortedByDescending { it.lastModified() }
            .take(80)
            .mapIndexed { index, file ->
                mapOf(
                    "path" to file.absolutePath,
                    "name" to file.name,
                    "size" to file.length(),
                    "durationMs" to durationOf(file),
                    "dateMs" to file.lastModified(),
                    // Newest clip gets a thumb immediately (record button + gallery
                    // header); older ones are generated lazily per visible tile.
                    "thumb" to if (index == 0) {
                        thumbnail(file.absolutePath)
                    } else {
                        cachedThumb(file)?.absolutePath
                    },
                    "exported" to file.parentFile?.name.equals("Exports", true),
                )
            }
    }

    /** Returns a cached JPEG path, generating it on first request. */
    fun thumbnail(path: String): String? {
        val file = File(path)
        if (!file.exists()) return null
        cachedThumb(file)?.let { return it.absolutePath }
        return generateThumb(file)?.absolutePath
    }

    fun share(path: String, target: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        val base = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        val pkg = when (target) {
            "instagram" -> "com.instagram.android"
            "facebook" -> "com.facebook.katana"
            "youtube" -> "com.google.android.youtube"
            else -> null
        }

        return try {
            if (pkg != null && isInstalled(pkg) && handles(base, pkg)) {
                // Direct hand-off: Instagram opens the Reels composer directly.
                context.startActivity(
                    Intent(base).setPackage(pkg)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } else {
                context.startActivity(
                    Intent.createChooser(base, "Share reel")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun open(path: String) {
        val file = File(path)
        if (!file.exists()) return
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "video/mp4")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {
        }
    }

    fun delete(path: String): Boolean {
        val file = File(path)
        val thumb = cachedThumb(file)
        val ok = file.delete()
        // Temp AAC sidecar + thumbnail stay in sync with the clip.
        File(file.parentFile, "${file.nameWithoutExtension}_audio.m4a").delete()
        thumb?.delete()
        return ok
    }

    // ---------------------------------------------------------------- internals

    private fun isClip(f: File): Boolean =
        f.isFile &&
            f.name.endsWith(".mp4", true) &&
            !f.name.contains("_audio") &&
            // Hides partially-written files left by an interrupted export.
            f.length() > 4096

    private fun durationOf(file: File): Long {
        val key = "${file.absolutePath}:${file.length()}"
        durationCache[key]?.let { return it }
        val extractor = MediaExtractor()
        val duration = try {
            extractor.setDataSource(file.absolutePath)
            var best = 0L
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                if (fmt.containsKey(MediaFormat.KEY_DURATION)) {
                    best = maxOf(best, fmt.getLong(MediaFormat.KEY_DURATION))
                }
            }
            best / 1000L
        } catch (_: Throwable) {
            0L
        } finally {
            extractor.release()
        }
        if (duration > 0) {
            if (durationCache.size > 200) durationCache.clear()
            durationCache[key] = duration
        }
        return duration
    }

    private fun thumbDir(): File = File(context.cacheDir, "procam_thumbs").apply {
        mkdirs()
    }

    private fun cachedThumb(file: File): File? {
        val candidate = File(
            thumbDir(),
            "${file.nameWithoutExtension}_${file.length()}.jpg",
        )
        return if (candidate.exists()) candidate else null
    }

    private fun generateThumb(file: File): File? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val frame = retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null

            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0

            val rotated = if (rotation != 0) {
                Bitmap.createBitmap(
                    frame, 0, 0, frame.width, frame.height,
                    Matrix().apply { postRotate(rotation.toFloat()) }, true,
                )
            } else {
                frame
            }

            val targetW = 360
            val targetH = (rotated.height * targetW /
                rotated.width.toFloat()).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(rotated, targetW, targetH, true)

            val out = File(
                thumbDir(),
                "${file.nameWithoutExtension}_${file.length()}.jpg",
            )
            FileOutputStream(out).use {
                scaled.compress(Bitmap.CompressFormat.JPEG, 82, it)
            }

            if (scaled !== rotated) scaled.recycle()
            if (rotated !== frame) rotated.recycle()
            frame.recycle()
            out
        } catch (_: Throwable) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun isInstalled(pkg: String): Boolean = try {
        context.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: Throwable) {
        false
    }

    private fun handles(intent: Intent, pkg: String): Boolean = try {
        Intent(intent).setPackage(pkg)
            .resolveActivity(context.packageManager) != null
    } catch (_: Throwable) {
        false
    }

    @Suppress("unused")
    private fun uriOf(file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
}
