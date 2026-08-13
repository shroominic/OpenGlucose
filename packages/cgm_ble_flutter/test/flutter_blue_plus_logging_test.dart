import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_test/flutter_test.dart';
import 'package:cgm_ble_flutter/src/flutter_blue_plus_logging.dart';

void main() {
  test('release policy disables native and Dart plugin logs', () async {
    fbp.LogLevel? configuredLevel;
    bool? configuredColor;
    final policy = FlutterBluePlusLogPrivacyPolicy(
      logSetter: (level, {required color}) async {
        configuredLevel = level;
        configuredColor = color;
      },
    );

    await policy.apply(isReleaseMode: true);

    expect(configuredLevel, fbp.LogLevel.none);
    expect(configuredColor, isFalse);
  });

  test('development policy leaves plugin diagnostics unchanged', () async {
    var calls = 0;
    final policy = FlutterBluePlusLogPrivacyPolicy(
      logSetter: (_, {required color}) async {
        calls += 1;
      },
    );

    await policy.apply(isReleaseMode: false);

    expect(calls, 0);
  });

  test('release policy propagates log suppression failures', () async {
    final policy = FlutterBluePlusLogPrivacyPolicy(
      logSetter: (_, {required color}) async {
        throw StateError('native channel unavailable');
      },
    );

    await expectLater(policy.apply(isReleaseMode: true), throwsStateError);
  });
}
