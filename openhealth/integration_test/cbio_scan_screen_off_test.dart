// Screen-off discovery evidence for the GS1 scan window.
//
// Android's ScanManager refuses or starves an *unfiltered* (opportunistic) BLE
// scan while the display is off, so a sleeping phone looks like a sensor that
// is not there: the pass comes back empty, or with a small fraction of the
// advertisers a held pass finds. This harness runs the same unfiltered pass
// twice on one device in one session:
//
//   1. with the display held awake by the app's own gate, exactly as a scan
//      window holds it, and
//   2. after the hold is released and the display has actually slept.
//
// Run it on a physical Android device whose screen timeout is short, so the
// display would sleep inside a scan window if nothing held it:
//
//   adb shell settings put system screen_off_timeout 4000
//   adb shell am force-stop <package>   # a reused instance keeps a stale port
//   flutter test integration_test/cbio_scan_screen_off_test.dart -d <device-id>
//
// A fresh `flutter test -d` install has no BLE runtime grants, and Android then
// answers the scan with a permission prompt instead of a scan. Grant them first:
//
//   adb shell pm grant <package> android.permission.BLUETOOTH_SCAN
//   adb shell pm grant <package> android.permission.BLUETOOTH_CONNECT
//   adb shell pm grant <package> android.permission.ACCESS_FINE_LOCATION
//
// Each pass is bounded, and so is the cancel that follows an abort, so a
// platform that neither answers nor refuses the scan is reported as an aborted
// pass instead of hanging the harness. This file prints counts and closed
// milestones only: no device addresses, no advertisement payloads, no sensor
// values.
//
// What this harness asserts is the *display* condition of each half: held keeps
// the display interactive for the whole window, and the control half starts
// with the display already asleep. The advertiser counts are the evidence, not
// an assertion: on Android 17 an unfiltered pass with the display off was
// starved rather than emptied - a small fraction of the advertisers the held
// half saw - so zero cannot be asserted of the platform.
import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openglucose/src/display_awake_gate.dart';
import 'package:openglucose/src/driver_factory.dart';

/// One bounded unfiltered scan, the pass the app's cbio profile asks for.
const Duration _scanWindow = Duration(seconds: 18);

/// Ceiling on one pass, so a silent platform cannot hang the harness.
///
/// Android resolves an unfiltered start slowly on some builds - the observed
/// refusal path took 80-88 seconds before it answered - so the ceiling is
/// generous on purpose and the abort is reported rather than hidden.
const Duration _passCeiling = Duration(seconds: 150);

/// Ceiling on the cancel that follows an aborted pass.
///
/// The transport's cancel waits for the same platform start call that a silent
/// scan never answered, so cancelling needs a bound of its own: otherwise the
/// abort hangs the harness the pass ceiling was meant to bound.
const Duration _cancelCeiling = Duration(seconds: 10);

/// How long to wait for the display to sleep once nothing holds it.
const Duration _sleepBudget = Duration(seconds: 60);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the scan window survives the display sleeping', (tester) async {
    final display = buildDefaultDisplayAwakeGate();
    final transport = FlutterBluePlusTransport();

    _emit('CBIO-D start interactive=${await display.isInteractive()}');

    // 1. The app's scan window: the hold is taken before the pass starts, and
    //    the display timeout is short, so only the hold keeps it interactive.
    await display.hold();
    final held = await _unfilteredPass(transport, 'held', display);
    await display.release();
    _emit(
      'CBIO-D held advertisers=${held.advertisers} completed=${held.completed} '
      'interactive-at-start=${held.interactiveAtStart} '
      'interactive-throughout=${held.interactiveThroughout}',
    );

    // 2. The same pass with nothing holding the display.
    final slept = await _waitForDisplayToSleep(display);
    final baseline = await _unfilteredPass(transport, 'baseline', display);
    _emit(
      'CBIO-D baseline slept=$slept advertisers=${baseline.advertisers} '
      'completed=${baseline.completed} '
      'interactive-at-start=${baseline.interactiveAtStart} '
      'interactive-throughout=${baseline.interactiveThroughout}',
    );
    _emit(
      'CBIO-D summary held-advertisers=${held.advertisers} '
      'dozing-advertisers=${baseline.advertisers} '
      'held-interactive-throughout=${held.interactiveThroughout} '
      'dozing-interactive-throughout=${baseline.interactiveThroughout}',
    );

    expect(
      held.interactiveAtStart,
      isTrue,
      reason: 'the scan window starts while the display is interactive',
    );
    expect(
      held.interactiveThroughout,
      isTrue,
      reason: 'the app holds the display for its whole scan window',
    );
    expect(
      baseline.interactiveAtStart,
      isFalse,
      reason:
          'the control pass needs the display asleep before it starts: set a '
          'short screen timeout before running this harness',
    );
    // Deliberately no assertion on baseline.advertisers: the platform starves
    // this pass rather than emptying it, so the counts are reported above for
    // the record and the meaningful claim is the display condition itself.
  });
}

/// One unfiltered scan pass, sampled and bounded, with observed advertisers.
class _Pass {
  const _Pass({
    required this.label,
    required this.advertisers,
    required this.completed,
    required this.interactiveAtStart,
    required this.interactiveThroughout,
    required this.nonInteractiveSamples,
  });

  final String label;
  final int advertisers;
  final bool completed;
  final bool interactiveAtStart;
  final bool interactiveThroughout;
  final int nonInteractiveSamples;
}

Future<_Pass> _unfilteredPass(
  BleTransport transport,
  String label,
  DisplayAwakeGate display,
) async {
  final interactiveAtStart = await display.isInteractive();
  final seen = <String, int>{};
  var interactiveThroughout = interactiveAtStart;
  var nonInteractiveSamples = 0;

  final sampler = Timer.periodic(const Duration(seconds: 1), (timer) async {
    if (!await display.isInteractive()) {
      nonInteractiveSamples++;
      interactiveThroughout = false;
    }
  });

  _emit('CBIO-D $label pass-start');
  var completed = false;
  try {
    final subscription = transport
        .scan(
          timeout: _scanWindow,
          allowDuplicates: true,
          withServices: const <String>[],
        )
        .listen(
          (sensor) {
            seen[sensor.deviceId] = (seen[sensor.deviceId] ?? 0) + 1;
          },
          onError: (Object error) {
            _emit('CBIO-D $label pass-error ${error.runtimeType}');
          },
        );
    completed = await subscription
        .asFuture<void>()
        .then((_) => true)
        .timeout(_passCeiling, onTimeout: () => false);
    if (!completed) {
      _emit(
        'CBIO-D $label pass-abort ceiling=${_passCeiling.inSeconds}s '
        'cancel-ceiling=${_cancelCeiling.inSeconds}s',
      );
      try {
        await subscription.cancel().timeout(_cancelCeiling);
      } on Object {
        // A transport that cannot close its own scan must not hold the run.
      }
    }
  } on Object catch (error) {
    _emit('CBIO-D $label pass-threw ${error.runtimeType}');
  } finally {
    sampler.cancel();
  }

  _emit(
    'CBIO-D $label pass-end completed=$completed advertisers=${seen.length} '
    'non-interactive-samples=$nonInteractiveSamples',
  );
  return _Pass(
    label: label,
    advertisers: seen.length,
    completed: completed,
    interactiveAtStart: interactiveAtStart,
    interactiveThroughout: interactiveThroughout,
    nonInteractiveSamples: nonInteractiveSamples,
  );
}

/// Polls until the platform reports the display is no longer interactive.
Future<bool> _waitForDisplayToSleep(DisplayAwakeGate display) async {
  final deadline = DateTime.now().add(_sleepBudget);
  while (DateTime.now().isBefore(deadline)) {
    if (!await display.isInteractive()) {
      return true;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

void _emit(String message) {
  // The harness reports through stdout so the run script can tee it to a file.
  // ignore: avoid_print
  print(message);
}
