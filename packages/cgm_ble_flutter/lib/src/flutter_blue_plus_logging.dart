import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

typedef FlutterBluePlusLogSetter =
    Future<void> Function(fbp.LogLevel level, {required bool color});

/// Applies the native BLE plugin's production log policy.
///
/// Keep this policy separate from transport operations so the application can
/// apply it at startup, before scanning, restoring, or connecting could put a
/// device identifier or BLE payload into the native log stream.
final class FlutterBluePlusLogPrivacyPolicy {
  const FlutterBluePlusLogPrivacyPolicy({
    FlutterBluePlusLogSetter logSetter = _setPluginLogLevel,
  }) : _logSetter = logSetter;

  final FlutterBluePlusLogSetter _logSetter;

  Future<void> apply({required bool isReleaseMode}) async {
    if (!isReleaseMode) {
      return;
    }
    await _logSetter(fbp.LogLevel.none, color: false);
  }
}

/// Disables Dart and native `flutter_blue_plus` logging.
///
/// OpenGlucose calls this as its first plugin operation in release builds. A
/// failure is intentionally propagated so release startup fails closed rather
/// than continuing with the plugin's native DEBUG default.
Future<void> disableFlutterBluePlusLogs() =>
    const FlutterBluePlusLogPrivacyPolicy().apply(isReleaseMode: true);

Future<void> _setPluginLogLevel(fbp.LogLevel level, {required bool color}) =>
    fbp.FlutterBluePlus.setLogLevel(level, color: color);
