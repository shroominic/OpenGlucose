import 'package:cgm_core/cgm_core.dart';

/// A deterministic, wellness-only description of a recent sharp rise.
///
/// The signal carries only values already present in the local app state. It
/// is deliberately not persisted, notified, or used as a safety alert.
class SharpRiseSignal {
  const SharpRiseSignal({
    required this.changeMgdl,
    required this.durationMinutes,
    required this.tailStart,
  });

  final int changeMgdl;
  final int durationMinutes;
  final DateTime tailStart;

  String get englishChangeText =>
      'Up $changeMgdl mg/dL in $durationMinutes minutes';
}

/// An immutable, side-effect-free snapshot of the app state that message
/// triggers are allowed to read.
///
/// Keeping triggers dependent only on this (rather than on the whole
/// app controller makes message selection a pure function — trivial to
/// unit-test and impossible to accidentally mutate. The controller builds one
/// of these from the live session on every change; tips/info-boxes added later
/// just add fields here if they need new signals.
class MessageContext {
  const MessageContext({
    required this.hasSession,
    required this.isWarmingUp,
    required this.hasReadings,
    required this.now,
    this.sharpRise,
  });

  /// A sensor session is selected/connected (i.e. the dashboard is showing,
  /// not the scan screen).
  final bool hasSession;

  /// The sensor is inside its warmup window (no trustworthy readings yet).
  final bool isWarmingUp;

  /// At least one glucose reading is available to display.
  final bool hasReadings;

  /// Wall-clock time, injected so time-based triggers are testable.
  final DateTime now;

  /// The current safe-to-surface sharp-rise signal, if one can be derived.
  final SharpRiseSignal? sharpRise;

  MessageContext copyWith({
    bool? hasSession,
    bool? isWarmingUp,
    bool? hasReadings,
    DateTime? now,
    SharpRiseSignal? sharpRise,
  }) {
    return MessageContext(
      hasSession: hasSession ?? this.hasSession,
      isWarmingUp: isWarmingUp ?? this.isWarmingUp,
      hasReadings: hasReadings ?? this.hasReadings,
      now: now ?? this.now,
      sharpRise: sharpRise ?? this.sharpRise,
    );
  }
}

/// Detects the bounded, fresh, monotonic rise used by the walk nudge.
///
/// This intentionally fails closed: any unsafe sensor stage, health flag,
/// missing timestamp, provisional value, non-finite value, sparse gap, or
/// out-of-range current reading makes the signal unavailable.
SharpRiseSignal? detectSharpRise({
  required CgmSessionSnapshot snapshot,
  required Iterable<CgmReading> readings,
  required bool isWarmingUp,
  required DateTime now,
}) {
  if (isWarmingUp || snapshot.stage != CgmSyncStage.ready) {
    return null;
  }
  final health = snapshot.health;
  if (health.error ||
      health.malfunction ||
      health.signalLost ||
      health.expired) {
    return null;
  }

  final allReadings = readings.toList(growable: false);
  if (allReadings.length < 3 ||
      allReadings.any(
        (reading) =>
            !reading.valueMgdl.isFinite ||
            reading.recordedAt == null ||
            reading.isDisplayProvisional,
      )) {
    return null;
  }
  final timestamped = allReadings.toList(growable: false)
    ..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
  final latest = timestamped.last;
  final latestAge = now.difference(latest.recordedAt!);
  if (latestAge.isNegative || latestAge > const Duration(minutes: 6)) {
    return null;
  }
  if (latest.valueMgdl < 100 || latest.valueMgdl >= 180) {
    return null;
  }

  final tailStartLimit = latest.recordedAt!.subtract(
    const Duration(minutes: 20),
  );
  final tail = timestamped
      .where((reading) => !reading.recordedAt!.isBefore(tailStartLimit))
      .toList(growable: false);
  if (tail.length < 3) {
    return null;
  }
  final span = latest.recordedAt!.difference(tail.first.recordedAt!);
  if (span < const Duration(minutes: 10) ||
      span > const Duration(minutes: 20)) {
    return null;
  }
  for (var index = 1; index < tail.length; index += 1) {
    final previous = tail[index - 1];
    final current = tail[index];
    final gap = current.recordedAt!.difference(previous.recordedAt!);
    if (gap <= Duration.zero ||
        gap > const Duration(minutes: 10) ||
        current.valueMgdl <= previous.valueMgdl) {
      return null;
    }
  }

  final totalRise = latest.valueMgdl - tail.first.valueMgdl;
  final spanMinutes = span.inSeconds / Duration.secondsPerMinute;
  if (totalRise < 20 || totalRise / spanMinutes < 2) {
    return null;
  }
  return SharpRiseSignal(
    changeMgdl: totalRise.round(),
    durationMinutes: span.inMinutes,
    tailStart: tail.first.recordedAt!,
  );
}
