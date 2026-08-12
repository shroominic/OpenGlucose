import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sensor = DiscoveredSensor(
    driverId: 'demo',
    deviceId: 'sensor-1',
    displayName: 'Demo Sensor',
    storageKey: 'sensor-1',
    rssi: -50,
    capabilities: CgmCapabilities(),
  );

  test('primary error stays hidden when usable glucose data exists', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Error',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: CgmReading(
        valueMgdl: 112,
        source: CgmRecordSource.vendor,
        recordedAt: DateTime.parse('2026-04-14T08:53:00Z'),
      ),
      history: <CgmReading>[
        CgmReading(
          valueMgdl: 111,
          source: CgmRecordSource.vendor,
          recordedAt: DateTime.parse('2026-04-14T08:52:00Z'),
        ),
      ],
      lastError: 'Timed out after 10s',
    );

    expect(shouldShowPrimaryError(snapshot), isFalse);
  });

  test('primary error remains visible when no glucose data exists', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Error',
      sensor: sensor,
      capabilities: sensor.capabilities,
      lastError: 'Timed out after 10s',
    );

    expect(shouldShowPrimaryError(snapshot), isTrue);
  });

  group('computeWarmupStatus', () {
    CgmSessionSnapshot snapshotWith({
      DateTime? sessionStart,
      int warmupMinutes = 60,
    }) {
      return CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Warming up',
        sensor: sensor,
        capabilities: sensor.capabilities,
        sessionInfo: CgmSessionInfo(
          sessionStart: sessionStart,
          warmupMinutes: warmupMinutes,
        ),
      );
    }

    test('returns null when session start is unknown', () {
      expect(computeWarmupStatus(snapshotWith()), isNull);
    });

    test(
      'keeps warming phase when a reading arrives inside the warmup window',
      () {
        final now = DateTime.parse('2026-04-17T10:00:00Z');
        final status = computeWarmupStatus(
          snapshotWith(sessionStart: now.subtract(const Duration(minutes: 10))),
          latestReading: CgmReading(
            valueMgdl: 157,
            source: CgmRecordSource.broadcast,
            recordedAt: now,
          ),
          now: now,
        );
        expect(status, isNotNull);
        expect(status!.phase, WarmupPhase.warming);
        expect(status.remainingMinutes, 50);
      },
    );

    test('returns null once a reading exists past the warmup window', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 75))),
        latestReading: CgmReading(
          valueMgdl: 112,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(status, isNull);
    });

    test('reports warming phase while elapsed < warmupMinutes', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 12))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 12);
      expect(status.remainingMinutes, 48);
      expect(status.totalMinutes, 60);
      expect(warmupBigValueText(status), '48');
      expect(warmupUnitText(status), 'min');
      expect(warmupSubtext(status), 'Warming up');
      expect(warmupStageLabel(status), 'Warmup');
    });

    test('reports waiting phase once elapsed >= warmupMinutes', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 63))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.waiting);
      expect(status.elapsedMinutes, 63);
      expect(status.remainingMinutes, 0);
      expect(warmupBigValueText(status), '…');
      expect(warmupUnitText(status), 'waiting for first reading');
      expect(warmupSubtext(status), 'Warmup complete');
      expect(warmupStageLabel(status), 'Waiting');
    });

    test('clamps negative elapsed (clock skew) to full warmup window', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.add(const Duration(minutes: 5))),
        now: now,
      );
      expect(status, isNotNull);
      expect(status!.phase, WarmupPhase.warming);
      expect(status.elapsedMinutes, 0);
      expect(status.remainingMinutes, 60);
    });
  });

  group('sensor life constant', () {
    test('Aidex X is a 15-day sensor (TASK-043)', () {
      expect(kSensorLifeDuration, const Duration(days: 15));
    });
  });

  group('computeSensorLifecycle', () {
    final now = DateTime.parse('2026-06-23T12:00:00Z');

    CgmSessionSnapshot snapshotWith({
      DateTime? sessionStart,
      bool sessionStopped = false,
      bool expired = false,
      DateTime? lastSyncAt,
      int warmupMinutes = 60,
    }) {
      return CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: '',
        sensor: sensor,
        capabilities: sensor.capabilities,
        sessionInfo: CgmSessionInfo(
          sessionStart: sessionStart,
          sessionStopped: sessionStopped,
          warmupMinutes: warmupMinutes,
        ),
        health: CgmHealthSnapshot(expired: expired),
        historySync: CgmHistorySyncState(lastSyncAt: lastSyncAt),
      );
    }

    test('unknown when there is no session start', () {
      final lifecycle = computeSensorLifecycle(snapshotWith(), now: now);
      expect(lifecycle.phase, SensorLifecyclePhase.unknown);
    });

    test('warmup phase inside the first hour', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 20))),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.warmup);
      expect(lifecycle.isWarmingUp, isTrue);
      expect(lifecycle.warmup, isNotNull);
      expect(lifecycle.lifeUsedPercent, 0);
    });

    test('active mid-life reports the correct percent used', () {
      // 6 of 15 days used => 40%.
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(const Duration(days: 6)),
          lastSyncAt: now,
        ),
        latestReading: CgmReading(
          valueMgdl: 120,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.active);
      expect(lifecycle.lifeUsedPercent, 40);
      expect(lifecycle.age, const Duration(days: 6));
      expect(lifecycle.remaining, const Duration(days: 9));
    });

    test('expiringSoon within the threshold window', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(
            kSensorLifeDuration - const Duration(hours: 3),
          ),
        ),
        latestReading: CgmReading(
          valueMgdl: 120,
          source: CgmRecordSource.vendor,
          recordedAt: now,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expiringSoon);
      expect(lifecycle.isExpiringSoon, isTrue);
      expect(
        lifecycle.remaining,
        lessThanOrEqualTo(kSensorExpiringSoonThreshold),
      );
    });

    test('expired by elapsed time past 15 days', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(
            kSensorLifeDuration + const Duration(hours: 2),
          ),
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expired);
      expect(lifecycle.isExpired, isTrue);
      expect(lifecycle.lifeUsedPercent, 100);
      expect(lifecycle.remaining, Duration.zero);
    });

    test('expired when the session is stopped even if clock is borderline', () {
      final lifecycle = computeSensorLifecycle(
        snapshotWith(
          sessionStart: now.subtract(const Duration(days: 14, hours: 23)),
          sessionStopped: true,
          expired: true,
        ),
        now: now,
      );
      expect(lifecycle.phase, SensorLifecyclePhase.expired);
      expect(lifecycle.lifeUsedFraction, 1.0);
    });
  });

  group('compactDurationText', () {
    test('formats days, hours, and minutes', () {
      expect(compactDurationText(const Duration(days: 3, hours: 4)), '3d 4h');
      expect(compactDurationText(const Duration(days: 2)), '2d');
      expect(
        compactDurationText(const Duration(hours: 5, minutes: 30)),
        '5h 30m',
      );
      expect(compactDurationText(const Duration(minutes: 45)), '45m');
      expect(compactDurationText(Duration.zero), '0h');
    });
  });

  group('lastSyncText', () {
    final now = DateTime.parse('2026-06-23T12:00:00Z');
    test('handles missing, recent, minutes, hours, and days', () {
      expect(lastSyncText(null, now: now), 'Not synced yet');
      expect(
        lastSyncText(now.subtract(const Duration(seconds: 5)), now: now),
        'Synced just now',
      );
      expect(
        lastSyncText(now.subtract(const Duration(minutes: 8)), now: now),
        'Synced 8 min ago',
      );
      expect(
        lastSyncText(now.subtract(const Duration(hours: 2)), now: now),
        'Synced 2 hours ago',
      );
      expect(
        lastSyncText(now.subtract(const Duration(days: 1)), now: now),
        'Synced 1 day ago',
      );
    });
  });
}
