import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/glanceable_surface.dart';

const _sensor = DiscoveredSensor(
  driverId: 'aidex',
  deviceId: 'sensor-1',
  displayName: 'Demo sensor',
  storageKey: 'aidex:sensor-1',
  rssi: -45,
  capabilities: CgmCapabilities(supportsDirectBle: true),
);

void main() {
  final now = DateTime.utc(2026, 8, 15, 8);

  CgmSessionSnapshot session({
    CgmSyncStage stage = CgmSyncStage.ready,
    CgmReading? latestReading,
    CgmSessionInfo sessionInfo = const CgmSessionInfo(),
    String? lastError,
  }) {
    return CgmSessionSnapshot(
      stage: stage,
      statusText: stage.name,
      sensor: _sensor,
      capabilities: _sensor.capabilities,
      latestReading: latestReading,
      sessionInfo: sessionInfo,
      lastError: lastError,
    );
  }

  test('context summary aggregates selected activity and sleep samples', () {
    final context = GlanceableContextSummary.fromSamples(
      activity: <ActivitySample>[
        ActivitySample(
          start: now.subtract(const Duration(hours: 2)),
          end: now.subtract(const Duration(hours: 1, minutes: 59)),
          type: ActivityType.steps,
          source: DataSource.appleHealth,
          steps: 1200,
          energyKcal: 12.5,
        ),
        ActivitySample(
          start: now.subtract(const Duration(hours: 1)),
          end: now.subtract(const Duration(minutes: 30)),
          type: ActivityType.workout,
          source: DataSource.appleHealth,
          energyKcal: 187,
        ),
      ],
      sleep: <SleepSample>[
        SleepSample(
          start: now.subtract(const Duration(hours: 9)),
          end: now.subtract(const Duration(hours: 2)),
          stage: SleepStage.asleep,
          source: DataSource.appleHealth,
        ),
      ],
    );

    expect(context.steps, 1200);
    expect(context.workoutCount, 1);
    expect(context.activeEnergyKcal, closeTo(199.5, 0.001));
    expect(context.sleepMinutes, 420);
    expect(context.hasData, isTrue);
    expect(
      GlanceableContextSummary.fromMap(context.toMap()).toMap(),
      context.toMap(),
    );
  });

  test('warmup suppresses provisional glucose but preserves countdown', () {
    final provisional = CgmReading(
      valueMgdl: 206,
      source: CgmRecordSource.vendor,
      recordedAt: now.subtract(const Duration(minutes: 2)),
      isDisplayProvisional: true,
    );
    final snapshot = GlanceableSurfaceSnapshot.fromSession(
      snapshot: session(
        latestReading: provisional,
        sessionInfo: CgmSessionInfo(
          sessionStart: now.subtract(const Duration(minutes: 2)),
          warmupMinutes: 60,
        ),
      ),
      now: now,
    );

    expect(snapshot.phase, GlanceablePhase.warming);
    expect(snapshot.freshness, GlanceableFreshness.unavailable);
    expect(snapshot.warmupRemainingMinutes, 58);
    expect(snapshot.glucoseMgdl, isNull);
    expect(snapshot.toMap()['surfaceText'], 'Warming up');
  });

  test(
    'phase and freshness are deterministic for live, stale, error, and absent data',
    () {
      final recent = CgmReading(
        valueMgdl: 111,
        source: CgmRecordSource.vendor,
        recordedAt: now.subtract(const Duration(minutes: 3)),
      );
      final live = GlanceableSurfaceSnapshot.fromSession(
        snapshot: session(
          latestReading: recent,
          sessionInfo: CgmSessionInfo(
            sessionStart: now.subtract(const Duration(hours: 2)),
          ),
        ),
        now: now,
      );
      expect(live.phase, GlanceablePhase.live);
      expect(live.freshness, GlanceableFreshness.fresh);

      final stale = GlanceableSurfaceSnapshot.fromSession(
        snapshot: session(
          latestReading: recent.copyWith(
            recordedAt: now.subtract(const Duration(minutes: 11)),
          ),
          sessionInfo: CgmSessionInfo(
            sessionStart: now.subtract(const Duration(hours: 2)),
          ),
        ),
        now: now,
      );
      expect(stale.phase, GlanceablePhase.stale);
      expect(stale.freshness, GlanceableFreshness.stale);

      final error = GlanceableSurfaceSnapshot.fromSession(
        snapshot: session(stage: CgmSyncStage.error, lastError: 'BLE failed'),
        now: now,
      );
      expect(error.phase, GlanceablePhase.error);

      final absent = GlanceableSurfaceSnapshot.fromSession(
        snapshot: session(stage: CgmSyncStage.disconnected),
        now: now,
      );
      expect(absent.phase, GlanceablePhase.noSession);
      expect(absent.freshness, GlanceableFreshness.unavailable);
    },
  );

  test('redacted serialization omits sensitive values by default', () {
    final snapshot = GlanceableSurfaceSnapshot(
      generatedAt: now,
      phase: GlanceablePhase.live,
      freshness: GlanceableFreshness.fresh,
      unit: GlucoseUnit.mmolL,
      glucoseMgdl: 108,
      recordedAt: now.subtract(const Duration(minutes: 1)),
      sensorLabel: 'Private sensor label',
      context: const GlanceableContextSummary(
        steps: 1200,
        activeEnergyKcal: 85,
      ),
      alert: const GlanceableAlertState(
        kind: GlanceableAlertKind.low,
        severity: GlanceableAlertSeverity.attention,
      ),
    );
    final redacted = serializeGlanceableSurface(snapshot).toMap();
    expect(redacted['mode'], 'redacted');
    expect(redacted['phase'], 'live');
    expect(redacted['alertState'], <String, Object?>{'attention': true});
    expect(redacted, isNot(contains('glucoseMgdl')));
    expect(redacted, isNot(contains('recordedAtIso8601')));
    expect(redacted, isNot(contains('sensorLabel')));
    expect(redacted, isNot(contains('context')));

    final sensitive = serializeGlanceableSurface(
      snapshot,
      includeSensitive: true,
    ).toMap();
    expect(sensitive['mode'], 'sensitive');
    expect(sensitive['glucoseMgdl'], 108);
    expect(sensitive['valueText'], '6.0');
    expect(sensitive['unitText'], 'mmol/L');
    expect(sensitive['sensorLabel'], 'Private sensor label');
    expect(sensitive['context'], isA<Map<String, Object?>>());
    expect(sensitive['alertState'], <String, Object?>{
      'kind': 'low',
      'severity': 'attention',
    });
  });

  test('payload JSON and map order are deterministic and immutable', () {
    final snapshot = GlanceableSurfaceSnapshot(
      generatedAt: now,
      phase: GlanceablePhase.warming,
      freshness: GlanceableFreshness.unavailable,
      unit: GlucoseUnit.mgdl,
      warmupRemainingMinutes: 57,
    );
    final first = serializeGlanceableSurface(snapshot);
    final second = serializeGlanceableSurface(snapshot);
    expect(first.toJson(), second.toJson());
    expect(() => first.values['phase'] = 'live', throwsUnsupportedError);
  });

  test('alert state round-trips and rejects inconsistent values', () {
    const active = GlanceableAlertState(
      kind: GlanceableAlertKind.high,
      severity: GlanceableAlertSeverity.attention,
    );
    expect(
      GlanceableAlertState.fromMap(active.toMap()).toMap(),
      active.toMap(),
    );
    expect(
      () => GlanceableAlertState.fromMap(<String, Object?>{
        'kind': 'none',
        'severity': 'attention',
      }),
      throwsFormatException,
    );
  });
}
