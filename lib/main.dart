import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/theme.dart';
import 'screens/record_screen.dart';
import 'services/analytics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: kBg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  // Local, bounded (4 s) and failure-tolerant: off until Firebase is configured.
  await Analytics.instance.init();
  runApp(const ProCamApp());
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
