import 'dart:io';

/// Writes Flutter/Dart errors to a text file so a frozen or crashed app can
/// be diagnosed without a debugger attached. The log lives in the app's
/// cache directory and is shown in the Gallery (bug icon).
class CrashReporter {
  CrashReporter._();

  static File get _file =>
      File('${Directory.systemTemp.path}/procam_error.log');

  static Future<void> log(String message, [StackTrace? stack]) async {
    try {
      await _file.writeAsString(
        '${DateTime.now().toIso8601String()}  $message\n${stack ?? ''}\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Never let logging itself crash the app.
    }
  }

  static Future<String> readLog() async {
    try {
      if (!await _file.exists()) return 'No errors recorded.';
      final text = await _file.readAsString();
      return text.length > 20000 ? text.substring(text.length - 20000) : text;
    } catch (e) {
      return 'Could not read log: $e';
    }
  }

  static Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
