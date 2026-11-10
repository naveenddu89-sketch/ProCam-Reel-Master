import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme.dart';
import 'screens/record_screen.dart';
import 'services/analytics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
