import 'core/theme.dart';

enum ShareTarget { instagram, facebook, youtube, generic }

class Clip {
  final String path;
  final String name;
  final int sizeBytes;
  final int durationMs;
  final int dateMs;
  final String? thumbPath;
  final bool exported;

  const Clip({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.durationMs,
    required this.dateMs,
    required this.thumbPath,
    required this.exported,
  });

  factory Clip.fromMap(Map<dynamic, dynamic> m) => Clip(
        path: m['path'] as String? ?? '',
        name: m['name'] as String? ?? '',
        sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        dateMs: (m['dateMs'] as num?)?.toInt() ?? 0,
        thumbPath: m['thumb'] as String?,
        exported: m['exported'] as bool? ?? false,
      );

  String get sizeLabel => fmtSize(sizeBytes);
  String get durationLabel => fmtDuration(durationMs);

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateMs);
}

class RecordingResult {
  final String videoPath;
  final String? audioPath;
  final int durationMs;
  final int audioOffsetMs;

  const RecordingResult({
    required this.videoPath,
    required this.audioPath,
    required this.durationMs,
    required this.audioOffsetMs,
  });

  factory RecordingResult.fromMap(Map<dynamic, dynamic> m) => RecordingResult(
        videoPath: m['video'] as String,
        audioPath: m['audio'] as String?,
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        audioOffsetMs: (m['audioOffsetMs'] as num?)?.toInt() ?? 0,
      );
}

class MicDevice {
  final int id;
  final String name;
  final bool bluetooth;
  final bool wired;

  const MicDevice({
    required this.id,
    required this.name,
    required this.bluetooth,
    required this.wired,
  });

  factory MicDevice.fromMap(Map<dynamic, dynamic> m) => MicDevice(
        id: (m['id'] as num).toInt(),
        name: m['name'] as String? ?? 'Microphone',
        bluetooth: m['bluetooth'] as bool? ?? false,
        wired: m['wired'] as bool? ?? false,
      );
}
