import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/session.dart';

/// Instagram Reels delivery spec (do not change casually):
/// 1080x1920 · 30/60 CFR · H.264 High · 18 Mbps avg (15–20) · AAC-LC 48 kHz
/// Rec.709 primaries/transfer/matrix · faststart for instant IG upload preview.
class ExportSettings {
  static const width = 1080;
  static const height = 1920;
  static const targetBitrate = '18M';
  static const maxBitrate = '20M';
  static const bufSize = '36M';
  static const audioBitrate = '192k';
  static const audioRate = 48000;
}

class ExportException implements Exception {
  final String message;
  const ExportException(this.message);
  @override
  String toString() => message;
}

class VideoExporter {
  /// [onProgress] emits 0..100 (throttled by the caller if needed).
  /// [audioPath] may be null when the mic failed — the clip is then exported
  /// video-only instead of with a silent track.
  static Future<void> export({
    required String videoPath,
    required String? audioPath,
    required String outputPath,
    required int fps,
    required int durationMs,
    int audioOffsetMs = 0,
    void Function(int percent)? onProgress,
  }) async {
    if (!File(videoPath).existsSync()) {
      throw const ExportException('Source video missing');
    }

    final hasAudio = audioPath != null &&
        audioPath.isNotEmpty &&
        File(audioPath).existsSync() &&
        File(audioPath).lengthSync() > 1024;

    final totalMs = durationMs > 0 ? durationMs : await _probeMs(videoPath);
    final audioArgs = <String>[];

    if (hasAudio) {
      // Positive offset => audio began AFTER video: delay it.
      // Negative offset => audio has extra head: trim it so lip-sync stays locked.
      if (audioOffsetMs < -50) {
        audioArgs.addAll(['-ss', _sec(audioOffsetMs.abs()), '-i', _q(audioPath)]);
      } else {
        audioArgs.addAll(['-i', _q(audioPath)]);
      }
    }

    final delayFilter = (hasAudio && audioOffsetMs > 50)
        ? 'adelay=${audioOffsetMs}:all=1,'
        : '';

    final audioChain = hasAudio
        ? '[1:a]${delayFilter}'
            'afftdn=nr=12:nf=-35:tn=1,' // FFT denoise, tracks the noise floor
            'highpass=f=90,lowpass=f=12000,'
            'loudnorm=I=-14:TP=-1.5:LRA=11,' // IG-safe loudness
            'apad,' // pad silence so -shortest never cuts the video tail
            'aresample=${ExportSettings.audioRate}[a]'
        : null;

    final filter =
        '[0:v]scale=${ExportSettings.width}:${ExportSettings.height}:'
        'force_original_aspect_ratio=increase:flags=bicubic,'
        'crop=${ExportSettings.width}:${ExportSettings.height},'
        'setsar=1,fps=$fps,format=yuv420p[v]'
        '${audioChain != null ? ';$audioChain' : ''}';

    final cmd = StringBuffer()
      ..write('-y -hide_banner ')
      ..write('-i ${_q(videoPath)} ')
      ..write(hasAudio ? '${audioArgs.join(' ')} ' : '')
      ..write('-filter_complex ${_q(filter)} ')
      ..write('-map [v] ')
      ..write(hasAudio ? '-map [a] ' : '')
      ..write('-c:v libx264 -preset veryfast -profile:v high -level 4.2 ')
      ..write('-pix_fmt yuv420p ')
      ..write('-b:v ${ExportSettings.targetBitrate} '
          '-maxrate ${ExportSettings.maxBitrate} '
          '-bufsize ${ExportSettings.bufSize} ')
      ..write('-g ${fps * 2} -keyint_min ${fps * 2} -sc_threshold 0 ')
      ..write('-color_primaries bt709 -color_trc bt709 -colorspace bt709 '
          '-color_range tv ')
      ..write('-x264-params colorprim=bt709:transfer=bt709:colormatrix=bt709 ')
      ..write('-threads 4 ') // caps RAM on 3GB devices
      ..write(hasAudio
          ? '-c:a aac -b:a ${ExportSettings.audioBitrate} '
              '-ar ${ExportSettings.audioRate} -ac 1 '
          : '-an ')
      ..write('-movflags +faststart -shortest ${_q(outputPath)}');

    final done = Completer<bool>();
    await FFmpegKit.executeAsync(
      cmd.toString(),
      (Session session) async {
        if (done.isCompleted) return;
        final rc = await session.getReturnCode();
        done.complete(ReturnCode.isSuccess(rc));
      },
      null,
      (stats) {
        if (totalMs <= 0) return;
        final ms = (stats.getTime() as num).toDouble();
        final pct = (ms / totalMs * 100).clamp(0, 99).round();
        onProgress?.call(pct);
      },
    );

    final ok = await done.future.timeout(
      // Long takes re-encode slower than real time on phones; 15 min was too
      // tight once clips pass a few minutes.
      const Duration(minutes: 60),
      onTimeout: () {
        FFmpegKit.cancel();
        return false;
      },
    );
    if (!ok) {
      throw const ExportException('Export failed. Try 30 FPS or free up RAM.');
    }
    if (!File(outputPath).existsSync()) {
      throw const ExportException('Export finished but file is missing');
    }
    onProgress?.call(100);
  }

  static Future<int> _probeMs(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = await session.getMediaInformation();
      final seconds = double.tryParse(info?.getDuration() ?? '') ?? 0;
      return (seconds * 1000).round();
    } catch (_) {
      return 0;
    }
  }

  static String _q(String p) => '"${p.replaceAll('"', '\\"')}"';
  static String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
}
