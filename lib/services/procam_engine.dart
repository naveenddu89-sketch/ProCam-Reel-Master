import 'dart:async';

import 'package:flutter/services.dart';

import '../models/clip.dart';

/// Bridge to the native CameraX engine (`CameraEngine.kt` + `MicRecorder.kt`).
/// All camera work runs on CameraX's own threads; nothing here blocks the UI.
class ProcamEngine {
  static const MethodChannel _ch = MethodChannel('procam/engine');
  static const EventChannel _eventCh = EventChannel('procam/engine_events');

  /// ready / error / recording_started / recording_finalized / audio_devices
  static final Stream<Map<String, dynamic>> events = _eventCh
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));

  Future<bool> ensurePermissions() async =>
      await _ch.invokeMethod<bool>('ensurePermissions') ?? false;

  /// Android 12+ needs BLUETOOTH_CONNECT before routing to a BT mic.
  /// Requested lazily (mic sheet), so denying it never blocks the camera.
  Future<bool> ensureBluetooth() async =>
      await _ch.invokeMethod<bool>('ensureBluetooth') ?? true;

  /// Idempotent: binds the preview + video use cases once a PlatformView exists.
  Future<void> start() => _ch.invokeMethod<void>('start');

  Future<void> pause() => _ch.invokeMethod<void>('pause');

  Future<bool> setAspect(String label) async =>
      await _ch.invokeMethod<bool>('setAspect', label) ?? false;

  Future<bool> setQuality4k(bool enabled) async =>
      await _ch.invokeMethod<bool>('setQuality4k', enabled) ?? false;

  Future<bool> is4k() async => await _ch.invokeMethod<bool>('is4k') ?? false;

  Future<bool> switchCamera() async =>
      await _ch.invokeMethod<bool>('switchCamera') ?? false;

  Future<bool> startRecording() async =>
      await _ch.invokeMethod<bool>('startRecording') ?? false;

  /// Resolves only after CameraX finalizes the MP4 (file flushed to disk).
  Future<RecordingResult?> stopRecording() async {
    // The mic muxer is flushed on a background thread now, so long takes can
    // take a little longer without blocking the UI. Never hang forever.
    final map = await _ch
        .invokeMapMethod<String, dynamic>('stopRecording')
        .timeout(const Duration(seconds: 60), onTimeout: () => null);
    return map == null ? null : RecordingResult.fromMap(map);
  }

  Future<void> setZoom(double ratio) => _ch.invokeMethod('setZoom', ratio);

  Future<void> setTorch(bool on) => _ch.invokeMethod('setTorch', on);

  Future<void> focusAt(double x, double y, {bool lock = false}) =>
      _ch.invokeMethod('focusAt', {'x': x, 'y': y, 'lock': lock});

  Future<void> setExposure(int index) =>
      _ch.invokeMethod('setExposure', index);

  Future<Map<String, int>> exposureRange() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('exposureRange');
    return {
      'min': (m?['min'] as num?)?.toInt() ?? 0,
      'max': (m?['max'] as num?)?.toInt() ?? 0,
    };
  }

  Future<Map<String, String>> mediaDirs() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('mediaDirs');
    return (m ?? {}).map((k, v) => MapEntry(k, v.toString()));
  }

  Future<List<MicDevice>> audioInputs() async {
    final list = await _ch.invokeListMethod<dynamic>('audioInputs') ?? [];
    return list
        .map((e) => MicDevice.fromMap(e as Map))
        .toList(growable: false);
  }

  Future<void> selectAudioInput(int id) =>
      _ch.invokeMethod('selectAudioInput', id);
}

/// Bridge to native gallery/share helpers (`ClipRepository.kt`).
class ClipRepository {
  static const MethodChannel _ch = MethodChannel('procam/files');

  static Future<List<Clip>> list() async {
    final list = await _ch.invokeListMethod<dynamic>('list') ?? [];
    return list.map((e) => Clip.fromMap(e as Map)).toList(growable: false);
  }

  static Future<String?> thumbnail(String path) =>
      _ch.invokeMethod<String>('thumbnail', path);

  static Future<bool> share(String path, ShareTarget target) async =>
      await _ch.invokeMethod<bool>('share', {
        'path': path,
        'target': target.name,
      }) ??
      false;

  static Future<bool> delete(String path) async =>
      await _ch.invokeMethod<bool>('delete', path) ?? false;

  static Future<void> open(String path) => _ch.invokeMethod('open', path);
}
