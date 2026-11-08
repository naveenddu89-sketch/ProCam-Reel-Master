import 'package:flutter/material.dart';

/// Minimal dark palette. Kept in one place so the whole app stays consistent.
const kBg = Color(0xFF08080A);
const kSurface = Color(0xFF141417);
const kSurfaceHi = Color(0xFF1E1E22);
const kAccent = Color(0xFFFF2D55);
const kLime = Color(0xFFC8FF2E);
const kTextDim = Color(0xFF9A9AA2);

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
  ).copyWith(surface: kBg, primary: Colors.white, secondary: kAccent);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    splashFactory: NoSplash.splashFactory,
    sliderTheme: const SliderThemeData(
      trackHeight: 2,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      activeTrackColor: Colors.white,
      inactiveTrackColor: Color(0xFF3A3A40),
      thumbColor: Colors.white,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kSurfaceHi,
      contentTextStyle: TextStyle(color: Colors.white, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
  );
}

String fmtSize(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  return mb < 1000 ? '${mb.toStringAsFixed(1)} MB' : '${(mb / 1024).toStringAsFixed(2)} GB';
}

String fmtDuration(int ms) {
  final d = Duration(milliseconds: ms);
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}
