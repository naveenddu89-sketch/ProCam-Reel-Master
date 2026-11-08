// PLACEHOLDER FILE.
//
// The real values live in the Firebase console. Regenerate this file with:
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=procam-reel-master
//
// `flutterfire configure` overwrites this file and also wires the
// google-services Gradle plugin. Until that happens the app builds and runs
// normally with analytics switched off (see `services/analytics.dart`).

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

class DefaultFirebaseOptions {
  /// Flip to true only when `apiKey`/`appId` below are real values.
  static const bool isConfigured = false;

  static FirebaseOptions get currentPlatform {
    if (!isConfigured) {
      throw UnsupportedError(
        'Firebase is not configured yet. Run: '
        'flutterfire configure --project=procam-reel-master',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'Firebase is not supported on $defaultTargetPlatform',
        );
    }
  }

  // Project: procam-reel-master (295466338839)
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_WITH_ANDROID_API_KEY',
    appId: 'REPLACE_WITH_ANDROID_APP_ID',
    messagingSenderId: '295466338839',
    projectId: 'procam-reel-master',
    storageBucket: 'procam-reel-master.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_WITH_IOS_API_KEY',
    appId: 'REPLACE_WITH_IOS_APP_ID',
    messagingSenderId: '295466338839',
    projectId: 'procam-reel-master',
    storageBucket: 'procam-reel-master.firebasestorage.app',
    iosBundleId: 'com.procam.reelmaster',
  );
}
