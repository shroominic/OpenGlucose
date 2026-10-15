import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';

import 'alerts/glucose_alerts.dart';
import 'session_presentation.dart';

/// Lifecycle phase used by a compact home-screen, notification, or widget
/// surface. This is a presentation contract, not a second sensor state
/// machine.
enum GlanceablePhase {
  noSession,
  connecting,
  warming,
  waiting,
  live,
  stale,
  error,
}

/// Coarse freshness buckets that avoid forcing native surfaces to interpret
/// timestamps independently.
enum GlanceableFreshness { unavailable, fresh, aging, stale }

/// Alert state exposed to a glanceable adapter. Raw glucose and threshold
/// names remain behind the explicit sensitive-content gate.
enum GlanceableAlertKind { none, low, high, stale }

enum GlanceableAlertSeverity { none, attention }

/// Small, source-agnostic context summary for a glanceable surface.
///
/// Values are optional because no-data is a valid state. The summary is
/// intentionally aggregate-only: raw health samples do not cross the native
/// adapter boundary.
class GlanceableContextSummary {
  const GlanceableContextSummary({
    this.steps,
    this.workoutCount,
    this.activeEnergyKcal,
    this.sleepMinutes,
  });

  final int? steps;
  final int? workoutCount;
  final double? activeEnergyKcal;
  final int? sleepMinutes;

  bool get hasData =>
      steps != null ||
      workoutCount != null ||
      activeEnergyKcal != null ||
      sleepMinutes != null;

  /// Builds a deterministic aggregate for a selected window. Samples are
  /// assumed to have already been filtered to that window by the repository.
  factory GlanceableContextSummary.fromSamples({
    Iterable<ActivitySample> activity = const <ActivitySample>[],
    Iterable<SleepSample> sleep = const <SleepSample>[],
  }) {
    var steps = 0;
    var hasSteps = false;
    var workouts = 0;
    var hasEnergy = false;
    var energy = 0.0;
    var sleepMinutes = 0;
    var hasSleep = false;
    for (final sample in activity) {
      if (sample.steps != null) {
        steps += sample.steps!;
        hasSteps = true;
      }
      if (sample.type == ActivityType.workout) workouts += 1;
      if (sample.energyKcal != null) {
        energy += sample.energyKcal!;
        hasEnergy = true;
      }
    }
    for (final sample in sleep) {
      final minutes = sample.duration.inMinutes;
      if (minutes >= 0) {
        sleepMinutes += minutes;
        hasSleep = true;
      }
    }
    return GlanceableContextSummary(
      steps: hasSteps ? steps : null,
      workoutCount: workouts == 0 ? null : workouts,
      activeEnergyKcal: hasEnergy ? energy : null,
      sleepMinutes: hasSleep ? sleepMinutes : null,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'steps': steps,
    'workoutCount': workoutCount,
    'activeEnergyKcal': activeEnergyKcal,
    'sleepMinutes': sleepMinutes,
  };

  factory GlanceableContextSummary.fromMap(Map<String, Object?> map) {
    final steps = _optionalNonNegativeInt(map['steps'], 'steps');
    final workoutCount = _optionalNonNegativeInt(
      map['workoutCount'],
      'workoutCount',
    );
    final activeEnergy = _optionalNonNegativeDouble(
      map['activeEnergyKcal'],
      'activeEnergyKcal',
    );
    final sleepMinutes = _optionalNonNegativeInt(
      map['sleepMinutes'],
      'sleepMinutes',
    );
    return GlanceableContextSummary(
      steps: steps,
      workoutCount: workoutCount,
      activeEnergyKcal: activeEnergy,
      sleepMinutes: sleepMinutes,
    );
  }
}

class GlanceableAlertState {
  const GlanceableAlertState({
    this.kind = GlanceableAlertKind.none,
    this.severity = GlanceableAlertSeverity.none,
  });

  final GlanceableAlertKind kind;
  final GlanceableAlertSeverity severity;

  bool get isActive => kind != GlanceableAlertKind.none;

  factory GlanceableAlertState.fromEvaluation(
    GlucoseAlertEvaluation evaluation,
  ) {
    final kind = switch (evaluation.activeType) {
      GlucoseAlertType.low => GlanceableAlertKind.low,
      GlucoseAlertType.high => GlanceableAlertKind.high,
      GlucoseAlertType.stale => GlanceableAlertKind.stale,
      null => GlanceableAlertKind.none,
    };
    return GlanceableAlertState(
      kind: kind,
      severity: kind == GlanceableAlertKind.none
          ? GlanceableAlertSeverity.none
          : GlanceableAlertSeverity.attention,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'kind': kind.name,
    'severity': severity.name,
  };

  factory GlanceableAlertState.fromMap(Map<String, Object?> map) {
    final kind = _enumFromName(GlanceableAlertKind.values, map['kind'], 'kind');
    final severity = _enumFromName(
      GlanceableAlertSeverity.values,
      map['severity'],
      'severity',
    );
    if (kind == GlanceableAlertKind.none &&
        severity != GlanceableAlertSeverity.none) {
      throw const FormatException('inactive alert must have none severity');
    }
    if (kind != GlanceableAlertKind.none &&
        severity == GlanceableAlertSeverity.none) {
      throw const FormatException('active alert must have attention severity');
    }
    return GlanceableAlertState(kind: kind, severity: severity);
  }
}

/// Local state that can be rendered by a glanceable adapter.
class GlanceableSurfaceSnapshot {
  const GlanceableSurfaceSnapshot({
    required this.generatedAt,
    required this.phase,
    required this.freshness,
    required this.unit,
    this.glucoseMgdl,
    this.recordedAt,
    this.warmupRemainingMinutes,
    this.sensorLabel,
    this.context = const GlanceableContextSummary(),
    this.alert = const GlanceableAlertState(),
  }) : assert(
         glucoseMgdl == null || glucoseMgdl >= 0,
         'glucoseMgdl must be non-negative',
       ),
       assert(
         warmupRemainingMinutes == null || warmupRemainingMinutes >= 0,
         'warmupRemainingMinutes must be non-negative',
       );

  final DateTime generatedAt;
  final GlanceablePhase phase;
  final GlanceableFreshness freshness;
  final GlucoseUnit unit;
  final double? glucoseMgdl;
  final DateTime? recordedAt;
  final int? warmupRemainingMinutes;
  final String? sensorLabel;
  final GlanceableContextSummary context;
  final GlanceableAlertState alert;

  /// Derives a snapshot from the same session presentation primitives used by
  /// the foreground UI. No advertisement fallback is used for current glucose:
  /// a glanceable value must be a timestamped reading.
  factory GlanceableSurfaceSnapshot.fromSession({
    required CgmSessionSnapshot snapshot,
    required DateTime now,
    GlucoseUnit unit = GlucoseUnit.mgdl,
    GlanceableContextSummary context = const GlanceableContextSummary(),
    GlucoseAlertEvaluation? alertEvaluation,
  }) {
    final latest = snapshot.latestReading;
    final warmup = computeWarmupStatus(
      snapshot,
      latestReading: latest,
      now: now,
    );
    // A sensor may broadcast provisional values while it is equilibrating.
    // Keep the countdown, but do not treat those values as current glucose on
    // any glanceable surface (including an explicitly sensitive payload).
    final candidateRecordedAt = latest?.recordedAt?.toUtc();
    final candidateAge = candidateRecordedAt == null
        ? null
        : now.toUtc().difference(candidateRecordedAt);
    final candidateIsUsable =
        latest != null &&
        candidateRecordedAt != null &&
        !candidateAge!.isNegative &&
        latest.valueMgdl.isFinite &&
        latest.valueMgdl > 0;
    final trustedLatest =
        warmup?.phase == WarmupPhase.warming || !candidateIsUsable
        ? null
        : latest;
    final recordedAt = trustedLatest?.recordedAt?.toUtc();
    final age = recordedAt == null ? null : now.toUtc().difference(recordedAt);
    final freshness = _freshness(age);
    final phase = warmup?.phase == WarmupPhase.warming
        ? GlanceablePhase.warming
        : snapshot.lastError != null || snapshot.stage == CgmSyncStage.error
        ? GlanceablePhase.error
        : snapshot.stage == CgmSyncStage.disconnected
        ? GlanceablePhase.noSession
        : snapshot.stage != CgmSyncStage.ready
        ? GlanceablePhase.connecting
        : freshness == GlanceableFreshness.stale
        ? GlanceablePhase.stale
        : trustedLatest == null
        ? GlanceablePhase.waiting
        : GlanceablePhase.live;
    return GlanceableSurfaceSnapshot(
      generatedAt: now.toUtc(),
      phase: phase,
      freshness: freshness,
      unit: unit,
      glucoseMgdl: trustedLatest?.valueMgdl,
      recordedAt: recordedAt,
      warmupRemainingMinutes: warmup?.remainingMinutes,
      sensorLabel: snapshot.sensor.displayName,
      context: context,
      alert: alertEvaluation == null
          ? const GlanceableAlertState()
          : GlanceableAlertState.fromEvaluation(alertEvaluation),
    );
  }

  Map<String, Object?> toMap({bool includeSensitive = false}) {
    final map = <String, Object?>{
      'schemaVersion': 1,
      'surface': 'glanceable',
      'mode': includeSensitive ? 'sensitive' : 'redacted',
      'phase': phase.name,
      'freshness': freshness.name,
      'warmupRemainingMinutes': warmupRemainingMinutes,
      'hasContext': context.hasData,
      // Redacted mode deliberately exposes no numeric glucose, exact reading
      // time, sensor label, context measurements, or alert type.
      'surfaceText': _redactedSurfaceText(),
      'alertState': includeSensitive
          ? alert.toMap()
          : <String, Object?>{'attention': alert.isActive},
    };
    if (includeSensitive) {
      map.addAll(<String, Object?>{
        'sensorLabel': sensorLabel,
        'glucoseMgdl': glucoseMgdl,
        'valueText': glucoseMgdl == null
            ? null
            : unit
                  .convertFromMgdl(glucoseMgdl!)
                  .toStringAsFixed(unit == GlucoseUnit.mgdl ? 0 : 1),
        'unitText': unit.label,
        'recordedAtIso8601': recordedAt?.toUtc().toIso8601String(),
        'generatedAtIso8601': generatedAt.toUtc().toIso8601String(),
        'context': context.toMap(),
      });
    }
    return map;
  }

  String toJson({bool includeSensitive = false}) =>
      jsonEncode(toMap(includeSensitive: includeSensitive));

  String _redactedSurfaceText() => switch (phase) {
    GlanceablePhase.warming => 'Warming up',
    GlanceablePhase.live => 'Glucose available',
    GlanceablePhase.stale => 'Open the app to refresh',
    GlanceablePhase.error => 'Open the app for status',
    GlanceablePhase.waiting => 'Waiting for first reading',
    GlanceablePhase.connecting => 'Connecting',
    GlanceablePhase.noSession => 'No active sensor',
  };
}

/// Serialized payload accepted by native widgets, notifications, and Live
/// Activities. Keeping this as a separate type prevents adapters from being
/// handed a mutable domain snapshot or raw health samples.
class GlanceableSurfacePayload {
  GlanceableSurfacePayload(Map<String, Object?> values)
    : values = Map<String, Object?>.unmodifiable(values);

  final Map<String, Object?> values;

  Map<String, Object?> toMap() => Map<String, Object?>.unmodifiable(values);

  String toJson() => jsonEncode(values);
}

/// Contract for platform adapters. Native implementations belong in a later
/// platform-specific change and must consume [GlanceableSurfacePayload] only.
abstract interface class GlanceableSurfaceAdapter {
  Future<void> publish(GlanceableSurfacePayload payload);

  Future<void> clear();
}

/// Safe default for unsupported platforms and tests.
class NoopGlanceableSurfaceAdapter implements GlanceableSurfaceAdapter {
  const NoopGlanceableSurfaceAdapter();

  @override
  Future<void> publish(GlanceableSurfacePayload payload) async {}

  @override
  Future<void> clear() async {}
}

GlanceableSurfacePayload serializeGlanceableSurface(
  GlanceableSurfaceSnapshot snapshot, {
  bool includeSensitive = false,
}) => GlanceableSurfacePayload(
  snapshot.toMap(includeSensitive: includeSensitive),
);

GlanceableFreshness _freshness(Duration? age) {
  if (age == null || age.isNegative) return GlanceableFreshness.unavailable;
  if (age <= const Duration(minutes: 5)) return GlanceableFreshness.fresh;
  if (age <= const Duration(minutes: 10)) return GlanceableFreshness.aging;
  return GlanceableFreshness.stale;
}

T _enumFromName<T extends Enum>(List<T> values, Object? value, String field) {
  if (value is! String) throw FormatException('$field must be a String');
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('Unsupported $field: $value');
}

int? _optionalNonNegativeInt(Object? value, String field) {
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('$field must be a non-negative integer or null');
  }
  return value;
}

double? _optionalNonNegativeDouble(Object? value, String field) {
  if (value == null) return null;
  if (value is! num || !value.toDouble().isFinite || value < 0) {
    throw FormatException(
      '$field must be a finite non-negative number or null',
    );
  }
  return value.toDouble();
}
