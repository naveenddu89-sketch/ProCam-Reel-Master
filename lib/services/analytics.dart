import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../firebase_options.dart';

/// Fail-safe wrapper around Firebase Analytics.
///
/// Design rules:
/// * Never blocks or slows down capture/export. Every call is fire-and-forget.
/// * No-op until [init] succeeds, so the app still runs fully offline when
///   Firebase isn't configured (see `lib/firebase_options.dart`).
/// * Never sends file paths, mic names or any media - only coarse counters.
class Analytics {
  Analytics._();

  static final Analytics instance = Analytics._();

  FirebaseAnalytics? _fa;

  /// True only after Firebase actually initialised.
  bool get enabled => _fa != null;

  /// Attach to `MaterialApp.navigatorObservers` for automatic `screen_view`.
  NavigatorObserver? get observer {
    final fa = _fa;
    return fa == null ? null : FirebaseAnalyticsObserver(analytics: fa);
  }

  Future<void> init() async {
    if (_fa != null) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 4));
      final fa = FirebaseAnalytics.instance;
      await fa.setAnalyticsCollectionEnabled(true);
      _fa = fa;
    } catch (e) {
      _fa = null;
      if (kDebugMode) debugPrint('Analytics disabled: $e');
    }
  }

  /// Logs an event, silently dropping anything the SDK would reject.
  Future<void> log(String name, [Map<String, Object?>? params]) async {
    final fa = _fa;
    if (fa == null) return;
    try {
      await fa.logEvent(name: name, parameters: _clean(params));
    } catch (_) {
      // Telemetry failures must never surface to the user.
    }
  }

  Map<String, Object>? _clean(Map<String, Object?>? params) {
    if (params == null || params.isEmpty) return null;
    final out = <String, Object>{};
    params.forEach((key, value) {
      if (value == null) return;
      if (value is int || value is double) {
        out[key] = value;
      } else if (value is bool) {
        out[key] = value ? 1 : 0;
      } else if (value is String) {
        final v = value.trim();
        if (v.isEmpty) return;
        out[key] = v.length > 100 ? v.substring(0, 100) : v;
      }
    });
    return out.isEmpty ? null : out;
  }
}
