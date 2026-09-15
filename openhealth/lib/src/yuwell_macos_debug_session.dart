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
/// unless the operator explicitly opts in.
Future<YuwellMacosDebugOutcome> runYuwellMacosDebugAttempt({
  required CgmDriver driver,
  required void Function(String) log,
  Duration scanTimeout = const Duration(seconds: 25),
  Duration observeWindow = const Duration(seconds: 100),
  bool showValue = false,
}) async {
  log('BLE GRAB @Claude — Anytime 5P');
  try {
    // Observed on this Mac: letting the transport's own `timeout` elapse
    // (or cancelling this subscription ourselves) drives it into a native
    // `stopScan` call that wedges the merged UI/platform thread — nothing
    // Dart-side runs again afterward, not even an independent Dart Timer,
    // because the whole isolate's event loop is what's stuck. So: no
    // `timeout:` here, and no `.cancel()` below. We only ever walk away
    // from a "not found" scan; we never ask it to stop. That leaves the
    // physical scan running for the remaining life of this process, which
    // is acceptable because this single-attempt debug process is always
    // torn down externally right after this function returns. See the
    // "M3" entry in CLAUDE_STATUS.md for the full finding.
    final firstCandidate = Completer<DiscoveredSensor?>();
    driver
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
