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

    test('returns null once a reading is available', () {
      final now = DateTime.parse('2026-04-17T10:00:00Z');
      final status = computeWarmupStatus(
        snapshotWith(sessionStart: now.subtract(const Duration(minutes: 10))),
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
      expect(warmupUnitText(status), 'min remaining');
      expect(warmupSubtext(status), '12 / 60 min elapsed');
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
      expect(warmupSubtext(status), 'warmup complete, t=63 min');
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
}
