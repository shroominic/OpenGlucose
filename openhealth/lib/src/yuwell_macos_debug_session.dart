import 'dart:async';

import 'package:cgm_core/cgm_core.dart';

/// Outcome of one bounded macOS debug attempt against the Anytime 5P.
final class YuwellMacosDebugOutcome {
  const YuwellMacosDebugOutcome({
    required this.sensorFound,
    this.finalStage,
    this.gotProvisionalReading = false,
    this.provisionalValueMgdl,
    this.error,
  });

  final bool sensorFound;
  final CgmSyncStage? finalStage;
  final bool gotProvisionalReading;
  final double? provisionalValueMgdl;
  final Object? error;

  @override
  String toString() =>
      'YuwellMacosDebugOutcome(sensorFound: $sensorFound, '
      'finalStage: $finalStage, gotProvisionalReading: $gotProvisionalReading, '
      'error: $error)';
}

/// Runs one bounded scan -> connect -> observe -> disconnect attempt against
/// [driver] and reports what happened through [log].
///
/// Always logs the `BLE GRAB` line before touching the radio and the
/// `BLE RELEASE` line afterward — including on error or timeout — per the
/// shared Bluetooth coordination contract for this contest debug harness.
/// [showValue] controls whether the provisional mg/dL number itself is
/// logged; it defaults to false so an interactive run does not echo it
/// unless the operator explicitly opts in. [scanCancelBound] bounds how
/// long this attempt waits for the scan subscription to cancel cleanly —
/// see the cancel block below.
Future<YuwellMacosDebugOutcome> runYuwellMacosDebugAttempt({
  required CgmDriver driver,
  required void Function(String) log,
  Duration scanTimeout = const Duration(seconds: 25),
  Duration observeWindow = const Duration(seconds: 100),
  Duration scanCancelBound = const Duration(seconds: 5),
  bool showValue = false,
}) async {
  log('BLE GRAB @Claude — Anytime 5P');
  try {
    final firstCandidate = Completer<DiscoveredSensor?>();
    final scanSubscription = driver
        .scan(allowDuplicates: false)
        .listen(
          (candidate) {
            if (!firstCandidate.isCompleted) {
              firstCandidate.complete(candidate);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!firstCandidate.isCompleted) {
              firstCandidate.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!firstCandidate.isCompleted) {
              firstCandidate.complete(null);
            }
          },
        );
    final found = await firstCandidate.future.timeout(
      scanTimeout,
      onTimeout: () => null,
    );
    // M3 (CLAUDE_STATUS.md) found that on this Mac, stopping the shared
    // transport's scan — a plain consumer `.cancel()` included — could
    // wedge the merged UI/platform thread forever: the plugin's own
    // internal stop timer and this wrapper's stop both raced for one
    // mutex, and the loser never returned. M5 root-caused and fixed that
    // at the transport (`SingleFlightTeardown` in
    // `flutter_blue_plus_transport.dart`), but that fix is source-grounded,
    // not yet hardware-confirmed. So: cancel for real now — it stops the
    // radio scan instead of leaking it for the rest of the process, and
    // this log line is the live confirmation evidence M5 is still waiting
    // on — but stay bounded. If cancel does not resolve in time this still
    // degrades to the old, hardware-proven-safe behavior of walking away
    // rather than hanging.
    try {
      await scanSubscription.cancel().timeout(scanCancelBound);
      log('scan cancel completed cleanly.');
    } on TimeoutException {
      log(
        'scan cancel did not complete within '
        '${scanCancelBound.inSeconds}s; leaving the platform scan running '
        "for this process's remaining lifetime, as in the M3 finding.",
      );
    } catch (error) {
      log('scan cancel failed: $error');
    }
    if (found == null) {
      log(
        'No Anytime-family advertisement observed within '
        '${scanTimeout.inSeconds}s.',
      );
      return const YuwellMacosDebugOutcome(sensorFound: false);
    }
    log('Candidate observed (driver=${found.driverId}); connecting.');
    final session = await driver.connect(found);
    var lastStage = session.currentSnapshot.stage;
    var gotReading = false;
    double? value;
    final done = Completer<void>();
    final subscription = session.snapshots.listen(
      (snapshot) {
        if (snapshot.stage != lastStage) {
          lastStage = snapshot.stage;
          log('session stage -> ${lastStage.name}');
        }
        final reading = snapshot.latestReading;
        if (reading != null && !gotReading) {
          gotReading = true;
          value = reading.valueMgdl;
          final suffix = showValue
              ? ' (${reading.valueMgdl.toStringAsFixed(0)} mg/dL, provisional)'
              : '';
          log('provisional engineering reading observed$suffix.');
        }
        if ((gotReading || snapshot.stage == CgmSyncStage.error) &&
            !done.isCompleted) {
          done.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) {
          done.completeError(error, stackTrace);
        }
      },
    );
    try {
      await done.future.timeout(observeWindow, onTimeout: () {});
    } finally {
      await subscription.cancel();
      await session.disconnect();
    }
    return YuwellMacosDebugOutcome(
      sensorFound: true,
      finalStage: lastStage,
      gotProvisionalReading: gotReading,
      provisionalValueMgdl: showValue ? value : null,
    );
  } catch (error) {
    log('attempt failed: $error');
    return YuwellMacosDebugOutcome(sensorFound: true, error: error);
  } finally {
    log('BLE RELEASE @Claude');
  }
}
