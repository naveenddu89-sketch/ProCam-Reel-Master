import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme.dart';
import 'screens/record_screen.dart';
import 'services/analytics.dart';
import 'services/crash_reporter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // A frozen app that shows a blank screen tells us nothing. Capture every
  // Dart error and render a readable message instead.
  FlutterError.onError = (details) {
    CrashReporter.log(
      'FlutterError: ${details.exceptionAsString()}',
      details.stack,
    );
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    CrashReporter.log('Unhandled: $error', stack);
    return true;
  };

  ErrorWidget.builder = (details) => const ColoredBox(
        color: kBg,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Kuch galat ho gaya. ProCam ko band karke phir se kholein.\n\n'
              'Error gallery ke bug icon me dikh jayega.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        ),
      );

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: kBg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const ProCamApp());
  // Fire-and-forget: analytics must never delay the first frame, and it is a
  // no-op until Firebase is configured.
  unawaited(Analytics.instance.init());
}

class ProCamApp extends StatelessWidget {
  const ProCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    final observer = Analytics.instance.observer;
    return MaterialApp(
      title: 'ProCam Reel Master',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      navigatorObservers: [if (observer != null) observer],
      home: const RecordScreen(),
    );
  }
}
