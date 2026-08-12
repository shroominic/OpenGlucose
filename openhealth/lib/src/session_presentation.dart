import 'package:cgm_core/cgm_core.dart';
import 'package:intl/intl.dart';

import 'display_preferences.dart';

DateTime? clampedDisplayRecordedAt(DateTime? recordedAt, {DateTime? now}) {
  if (recordedAt == null) {
    return null;
  }
  final effectiveNow = now ?? DateTime.now();
  final localRecordedAt = recordedAt.toLocal();
  if (localRecordedAt.isAfter(effectiveNow) &&
      localRecordedAt.difference(effectiveNow) <= const Duration(minutes: 2)) {
    return effectiveNow;
  }
  return localRecordedAt;
}

String readingTimeText(CgmReading? reading, {DateTime? now}) {
  final recordedAt = clampedDisplayRecordedAt(reading?.recordedAt, now: now);
  if (recordedAt == null) {
    return '--';
  }
  return DateFormat('HH:mm').format(recordedAt);
}

enum WarmupPhase { warming, waiting }

class WarmupStatus {
  const WarmupStatus({
    required this.phase,
    required this.elapsedMinutes,
    required this.remainingMinutes,
    required this.totalMinutes,
  });

  final WarmupPhase phase;
  final int elapsedMinutes;
  final int remainingMinutes;
  final int totalMinutes;
}

WarmupStatus? computeWarmupStatus(
  CgmSessionSnapshot snapshot, {
  CgmReading? latestReading,
  DateTime? now,
}) {
  final sessionStart = snapshot.sessionInfo.sessionStart;
  if (sessionStart == null) {
    return null;
  }
  final total = snapshot.sessionInfo.warmupMinutes;
  if (total <= 0) {
    return null;
  }
  final effectiveNow = now ?? DateTime.now();
  final elapsed = effectiveNow.difference(sessionStart).inMinutes;
  if (elapsed < 0) {
    return WarmupStatus(
      phase: WarmupPhase.warming,
      elapsedMinutes: 0,
      remainingMinutes: total,
      totalMinutes: total,
    );
  }
  if (elapsed < total) {
    // Inside the warmup window readings are unreliable (sensor noise during
    // equilibration), so the warmup countdown always wins over any value the
    // sensor happens to broadcast.
    return WarmupStatus(
      phase: WarmupPhase.warming,
      elapsedMinutes: elapsed,
      remainingMinutes: total - elapsed,
      totalMinutes: total,
    );
  }
  if (latestReading != null) {
    return null;
  }
  return WarmupStatus(
    phase: WarmupPhase.waiting,
    elapsedMinutes: elapsed,
    remainingMinutes: 0,
    totalMinutes: total,
  );
}

String warmupBigValueText(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => status.remainingMinutes.toString(),
    WarmupPhase.waiting => '…',
  };
}

String warmupUnitText(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'min',
    WarmupPhase.waiting => 'waiting for first reading',
  };
}

String warmupSubtext(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'Warming up',
    WarmupPhase.waiting => 'Warmup complete',
  };
}

String warmupStageLabel(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'Warmup',
    WarmupPhase.waiting => 'Waiting',
  };
}

/// Total wear life of the Aidex X sensor. Single source of truth so the
/// dashboard, lifecycle card, and tests never drift (the device is a 15-day
/// sensor — previously the older 14-day Aidex; see TASK-043).
const Duration kSensorLifeDuration = Duration(days: 15);

/// When less than this remains, the sensor is treated as "expiring soon" and
/// the lifecycle card shows a heads-up to have a replacement ready.
const Duration kSensorExpiringSoonThreshold = Duration(hours: 12);

String sensorLifeText(DateTime? sessionStart, {DateTime? now}) {
  if (sessionStart == null) {
    return 'Life remaining unavailable';
  }
  final effectiveNow = now ?? DateTime.now();
  final remaining = kSensorLifeDuration - effectiveNow.difference(sessionStart);
  if (remaining <= Duration.zero) {
    return 'Sensor expired';
  }
  if (remaining < const Duration(days: 1)) {
    final hours = remaining.inHours <= 0 ? 1 : remaining.inHours;
    return '$hours ${hours == 1 ? 'hour' : 'hours'} left';
  }
  // Round up so a freshly-started 15-day sensor reads "15 days left" rather
  // than "14" (a partial first day still counts as a day of life).
  final days = (remaining.inHours / 24).ceil();
  return '$days ${days == 1 ? 'day' : 'days'} left';
}

/// Lifecycle phase of the sensor derived purely from session timing + health.
enum SensorLifecyclePhase {
  /// No `sessionStart` known yet — can't place the sensor in its life.
  unknown,

  /// Inside the ~1h warmup window after insertion (no reliable readings yet).
  warmup,

  /// Normal in-life operation.
  active,

  /// Within [kSensorExpiringSoonThreshold] of end-of-life — replace soon.
  expiringSoon,

  /// Past 15 days, or the session was stopped / flagged expired by the sensor.
  expired,
}

/// A self-contained, testable view-model for the sensor lifecycle card.
///
/// Derived from the session timing (`sessionStart` / `warmupMinutes`) plus the
/// expiry/stopped health flags. Pure: pass `now` in tests for determinism.
class SensorLifecycle {
  const SensorLifecycle({
    required this.phase,
    required this.lifeUsedFraction,
    required this.age,
    required this.remaining,
    required this.totalLife,
    this.sessionStart,
    this.warmup,
  });

  final SensorLifecyclePhase phase;

  /// Fraction (0.0–1.0) of the 15-day life consumed.
  final double lifeUsedFraction;

  /// Time since the sensor session started (clamped to >= 0).
  final Duration age;

  /// Time left before end-of-life (clamped to >= 0; zero when expired).
  final Duration remaining;

  final Duration totalLife;
  final DateTime? sessionStart;

  /// Non-null only while warming up.
  final WarmupStatus? warmup;

  /// Whole-percent of life used, 0–100.
  int get lifeUsedPercent => (lifeUsedFraction * 100).round().clamp(0, 100);

  bool get isExpired => phase == SensorLifecyclePhase.expired;
  bool get isExpiringSoon => phase == SensorLifecyclePhase.expiringSoon;
  bool get isWarmingUp => phase == SensorLifecyclePhase.warmup;
}

/// Computes the [SensorLifecycle] for [snapshot] as of [now].
SensorLifecycle computeSensorLifecycle(
  CgmSessionSnapshot snapshot, {
  CgmReading? latestReading,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final sessionStart = snapshot.sessionInfo.sessionStart;
  const totalLife = kSensorLifeDuration;

  // A stopped session or an explicit expired health flag means the sensor is
  // done regardless of the exact clock math (covers the mock `expired`
  // scenario where readings froze but the wall clock is just past 15 days).
  final stoppedOrFlagged =
      snapshot.sessionInfo.sessionStopped || snapshot.health.expired;

  if (sessionStart == null) {
    return SensorLifecycle(
      phase: stoppedOrFlagged
          ? SensorLifecyclePhase.expired
          : SensorLifecyclePhase.unknown,
      lifeUsedFraction: stoppedOrFlagged ? 1 : 0,
      age: Duration.zero,
      remaining: Duration.zero,
      totalLife: totalLife,
    );
  }

  final rawAge = effectiveNow.difference(sessionStart);
  final age = rawAge.isNegative ? Duration.zero : rawAge;
  final rawRemaining = totalLife - age;
  final remaining = rawRemaining.isNegative ? Duration.zero : rawRemaining;
  final fraction = (age.inSeconds / totalLife.inSeconds).clamp(0.0, 1.0);

  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: latestReading,
    now: effectiveNow,
  );

  final SensorLifecyclePhase phase;
  if (stoppedOrFlagged || remaining <= Duration.zero) {
    phase = SensorLifecyclePhase.expired;
  } else if (warmup != null && warmup.phase == WarmupPhase.warming) {
    phase = SensorLifecyclePhase.warmup;
  } else if (remaining <= kSensorExpiringSoonThreshold) {
    phase = SensorLifecyclePhase.expiringSoon;
  } else {
    phase = SensorLifecyclePhase.active;
  }

  return SensorLifecycle(
    phase: phase,
    lifeUsedFraction: phase == SensorLifecyclePhase.expired ? 1.0 : fraction,
    age: age,
    remaining: phase == SensorLifecyclePhase.expired
        ? Duration.zero
        : remaining,
    totalLife: totalLife,
    sessionStart: sessionStart,
    warmup: warmup,
  );
}

/// "3d 4h" style compact duration for the lifecycle card.
String compactDurationText(Duration duration) {
  if (duration <= Duration.zero) {
    return '0h';
  }
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  return '${minutes}m';
}

/// "Last synced 2 min ago" style relative text for the most recent reading.
String lastSyncText(DateTime? lastSyncAt, {DateTime? now}) {
  if (lastSyncAt == null) {
    return 'Not synced yet';
  }
  final effectiveNow = now ?? DateTime.now();
  final delta = effectiveNow.difference(lastSyncAt.toLocal());
  if (delta.isNegative || delta < const Duration(seconds: 45)) {
    return 'Synced just now';
  }
  if (delta < const Duration(hours: 1)) {
    final mins = delta.inMinutes;
    return 'Synced $mins min ago';
  }
  if (delta < const Duration(days: 1)) {
    final hours = delta.inHours;
    return 'Synced $hours ${hours == 1 ? 'hour' : 'hours'} ago';
  }
  final days = delta.inDays;
  return 'Synced $days ${days == 1 ? 'day' : 'days'} ago';
}

int? historySyncPercent(CgmHistorySyncState historySync) {
  if (!historySync.inProgress || historySync.totalAvailable <= 0) {
    return null;
  }
  final ratio = historySync.storedCount / historySync.totalAvailable;
  return (ratio * 100).clamp(0, 100).round();
}

String stageLabelForSnapshot(CgmSessionSnapshot snapshot) {
  final hasData = snapshot.latestReading != null || snapshot.history.isNotEmpty;

  if (snapshot.stage == CgmSyncStage.error) {
    return 'Error';
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return hasData ? 'Reconnecting' : 'Disconnected';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    if (snapshot.historySync.inProgress && !hasData) {
      return 'Setting up';
    }
    return 'Connected';
  }
  if (snapshot.stage == CgmSyncStage.connecting ||
      snapshot.stage == CgmSyncStage.bonding ||
      snapshot.stage == CgmSyncStage.pairing ||
      snapshot.stage == CgmSyncStage.activating ||
      snapshot.stage == CgmSyncStage.syncing) {
    return hasData ? 'Connected' : 'Connecting';
  }
  return 'Connecting';
}

String stageCodeForSnapshot(CgmSessionSnapshot snapshot) {
  final hasData = snapshot.latestReading != null || snapshot.history.isNotEmpty;

  if (snapshot.stage == CgmSyncStage.error) {
    return 'error';
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return hasData ? 'progress' : 'error';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    return 'live';
  }
  if (hasData) {
    return 'live';
  }
  return 'progress';
}

bool shouldShowPrimaryError(CgmSessionSnapshot snapshot) {
  if (snapshot.lastError == null || snapshot.lastError!.isEmpty) {
    return false;
  }
  if (snapshot.stage == CgmSyncStage.error) {
    return snapshot.latestReading == null && snapshot.history.isEmpty;
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return snapshot.latestReading == null && snapshot.history.isEmpty;
  }
  return false;
}

class GlucoseTrendSummary {
  const GlucoseTrendSummary({this.symbol = '', this.deltaText = ''});

  final String symbol;
  final String deltaText;

  bool get hasTrend => symbol.isNotEmpty || deltaText.isNotEmpty;
}

GlucoseTrendSummary glucoseTrendSummary(
  List<CgmReading> history,
  DisplayPreferences preferences,
) {
  if (history.length < 2) {
    return const GlucoseTrendSummary();
  }

  final latest = history.last;
  CgmReading? previous;
  for (var index = history.length - 2; index >= 0; index -= 1) {
    final candidate = history[index];
    if (candidate.sensorMinute != latest.sensorMinute ||
        candidate.recordedAt != latest.recordedAt) {
      previous = candidate;
      break;
    }
  }
  if (previous == null) {
    return const GlucoseTrendSummary();
  }

  final deltaMgdl = latest.valueMgdl - previous.valueMgdl;
  final symbol = switch (deltaMgdl) {
    >= 20 => '↑↑',
    >= 8 => '↑',
    > 2 => '↗',
    >= -2 => '→',
    > -8 => '↘',
    > -20 => '↓',
    _ => '↓↓',
  };

  final deltaDisplay = preferences.unit.convertFromMgdl(deltaMgdl);
  final sign = deltaDisplay > 0
      ? '+'
      : deltaDisplay < 0
      ? '-'
      : '';
  final magnitude = deltaDisplay.abs();
  final precision = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
  final deltaText = sign.isEmpty && magnitude == 0
      ? ''
      : '$sign${magnitude.toStringAsFixed(precision)}';

  return GlucoseTrendSummary(symbol: symbol, deltaText: deltaText);
}
