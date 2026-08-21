import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/live_activity_payload.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toMap omits an unavailable reading timestamp', () {
    const payload = LiveActivityPayload(
      sensorName: 'Demo sensor',
      stageCode: 'pending',
      stageLabel: 'Connecting',
      valueText: '--',
      unitText: 'mg/dL',
      lastReadingText: '--',
      lifeText: '',
      detailText: 'Waiting for glucose update',
      trendSymbol: '',
      deltaText: '',
      isStale: false,
    );

    expect(payload.toMap(), isNot(contains('recordedAtIso8601')));
  });

  test('buildLiveActivityPayload clamps slightly-future reading times', () {
    final now = DateTime.utc(2026, 4, 13, 6, 58);
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-1',
      displayName: 'LinX-222224SBWM',
      storageKey: 'aidex:sensor-1',
      rssi: -45,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsHistory: true,
      ),
    );
    final latest = CgmReading(
      valueMgdl: 72,
      source: CgmRecordSource.vendor,
      sensorMinute: 123,
      recordedAt: now.add(const Duration(minutes: 1)),
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Live',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: latest,
      history: <CgmReading>[latest],
      sessionInfo: CgmSessionInfo(
        sessionStart: now.subtract(const Duration(days: 6)),
      ),
    );

    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: latest,
      preferences: const DisplayPreferences(),
      now: now,
    );

    expect(payload.stageLabel, 'Connected');
    expect(payload.recordedAtIso8601, now.toIso8601String());
    expect(payload.lastReadingText, '06:58');
  });

  test('buildLiveActivityPayload emits the warmup countdown', () {
    final now = DateTime.utc(2026, 8, 14, 7);
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-warmup',
      displayName: 'AiDEX sensor',
      storageKey: 'aidex:sensor-warmup',
      rssi: -47,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsHistory: true,
      ),
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Warming up',
      sensor: sensor,
      capabilities: sensor.capabilities,
      sessionInfo: CgmSessionInfo(
        sessionStart: now.subtract(const Duration(minutes: 3)),
        warmupMinutes: 60,
      ),
    );

    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: null,
      preferences: const DisplayPreferences(),
      now: now,
    );

    expect(payload.stageCode, 'progress');
    expect(payload.sensorName, liveSurfaceBrandName);
    expect(payload.stageLabel, 'WARMUP');
    expect(payload.valueText, '57');
    expect(payload.unitText, 'min');
    expect(payload.lastReadingText, '--');
    expect(payload.recordedAtIso8601, isNull);
    expect(
      shouldPublishLiveActivity(
        snapshot: snapshot,
        latestReading: null,
        now: now,
      ),
      isTrue,
    );
  });

  test('live activity still requires a recent reading outside warmup', () {
    final now = DateTime.utc(2026, 8, 14, 9);
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-active',
      displayName: 'AiDEX sensor',
      storageKey: 'aidex:sensor-active',
      rssi: -47,
      capabilities: const CgmCapabilities(supportsDirectBle: true),
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      sensor: sensor,
      capabilities: sensor.capabilities,
      sessionInfo: CgmSessionInfo(
        sessionStart: now.subtract(const Duration(hours: 2)),
        warmupMinutes: 60,
      ),
    );

    expect(
      shouldPublishLiveActivity(
        snapshot: snapshot,
        latestReading: null,
        now: now,
      ),
      isFalse,
    );
  });

  test('minute 59 is not published after warmup reaches minute 60', () {
    final boundary = DateTime.utc(2026, 8, 14, 8);
    final sessionStart = boundary.subtract(const Duration(minutes: 60));
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-boundary',
      displayName: 'AiDEX sensor',
      storageKey: 'aidex:sensor-boundary',
      rssi: -47,
      capabilities: const CgmCapabilities(supportsDirectBle: true),
    );
    final minute59 = CgmReading(
      valueMgdl: 171,
      source: CgmRecordSource.vendor,
      sensorMinute: 59,
      recordedAt: boundary.subtract(const Duration(minutes: 1)),
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Warmup complete',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: minute59,
      history: <CgmReading>[minute59],
      sessionInfo: CgmSessionInfo(
        sessionStart: sessionStart,
        warmupMinutes: 60,
      ),
    );

    final waitingPayload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: null,
      preferences: const DisplayPreferences(),
      now: boundary,
    );

    expect(waitingPayload.stageLabel, 'WAITING');
    expect(waitingPayload.valueText, '…');
    expect(waitingPayload.recordedAtIso8601, isNull);
    expect(
      shouldPublishLiveActivity(
        snapshot: snapshot,
        latestReading: null,
        now: boundary,
      ),
      isFalse,
    );

    final minute60 = CgmReading(
      valueMgdl: 112,
      source: CgmRecordSource.vendor,
      sensorMinute: 60,
      recordedAt: boundary,
    );
    expect(
      shouldPublishLiveActivity(
        snapshot: snapshot.copyWith(latestReading: minute60),
        latestReading: minute60,
        now: boundary,
      ),
      isTrue,
    );
  });

  test('buildLiveActivityPayload exposes sync stage and trend delta', () {
    final now = DateTime.utc(2026, 4, 13, 7, 0);
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-2',
      displayName: 'LinX-222224SBWM',
      storageKey: 'aidex:sensor-2',
      rssi: -52,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsHistory: true,
      ),
    );
    final previous = CgmReading(
      valueMgdl: 110,
      source: CgmRecordSource.vendor,
      sensorMinute: 200,
      recordedAt: now.subtract(const Duration(minutes: 5)),
    );
    final latest = CgmReading(
      valueMgdl: 124,
      source: CgmRecordSource.vendor,
      sensorMinute: 205,
      recordedAt: now,
    );
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Syncing history',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: latest,
      history: <CgmReading>[previous, latest],
      historySync: const CgmHistorySyncState(
        inProgress: true,
        storedCount: 3500,
        totalAvailable: 7000,
      ),
      sessionInfo: CgmSessionInfo(
        sessionStart: now.subtract(const Duration(days: 2)),
      ),
    );

    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: latest,
      preferences: const DisplayPreferences(),
      now: now,
    );

    expect(payload.stageCode, 'live');
    expect(payload.sensorName, liveSurfaceBrandName);
    expect(payload.stageLabel, 'Connected');
    expect(payload.trendSymbol, '↑');
    expect(payload.deltaText, '+14');
    expect(payload.detailText, 'Updated ${readingTimeText(latest, now: now)}');
  });

  test('post-warmup live activity starts and updates with fresh glucose', () {
    final now = DateTime.utc(2026, 8, 15, 10);
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'sensor-live-updates',
      displayName: 'AiDEX sensor',
      storageKey: 'aidex:sensor-live-updates',
      rssi: -44,
      capabilities: const CgmCapabilities(supportsDirectBle: true),
    );
    final first = CgmReading(
      valueMgdl: 112,
      source: CgmRecordSource.broadcast,
      sensorMinute: 60,
      recordedAt: now,
    );
    final baseSnapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: first,
      history: <CgmReading>[first],
      sessionInfo: CgmSessionInfo(
        sessionStart: now.subtract(const Duration(minutes: 60)),
      ),
    );

    expect(
      shouldPublishLiveActivity(
        snapshot: baseSnapshot,
        latestReading: first,
        now: now,
      ),
      isTrue,
    );
    final started = buildLiveActivityPayload(
      snapshot: baseSnapshot,
      latestReading: first,
      preferences: const DisplayPreferences(),
      now: now,
    );
    expect(started.stageCode, 'live');
    expect(started.valueText, '112');
    expect(started.unitText, 'mg/dL');

    final nextTime = now.add(const Duration(minutes: 1));
    final next = CgmReading(
      valueMgdl: 118,
      source: CgmRecordSource.broadcast,
      sensorMinute: 61,
      recordedAt: nextTime,
    );
    final updatedSnapshot = baseSnapshot.copyWith(
      latestReading: next,
      history: <CgmReading>[first, next],
    );
    final updated = buildLiveActivityPayload(
      snapshot: updatedSnapshot,
      latestReading: next,
      preferences: const DisplayPreferences(),
      now: nextTime,
    );

    expect(
      shouldPublishLiveActivity(
        snapshot: updatedSnapshot,
        latestReading: next,
        now: nextTime,
      ),
      isTrue,
    );
    expect(updated.valueText, '118');
    expect(updated.lastReadingText, isNot(started.lastReadingText));
    expect(updated.recordedAtIso8601, nextTime.toIso8601String());
  });

  test(
    'stage label drops the sync percent once history is nearly complete',
    () {
      final sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'sensor-3',
        displayName: 'LinX-222224SBWM',
        storageKey: 'aidex:sensor-3',
        rssi: -48,
        capabilities: const CgmCapabilities(
          supportsDirectBle: true,
          supportsHistory: true,
        ),
      );
      final snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Syncing history',
        sensor: sensor,
        capabilities: sensor.capabilities,
        historySync: const CgmHistorySyncState(
          inProgress: true,
          storedCount: 6840,
          totalAvailable: 7000,
        ),
      );

      expect(stageLabelForSnapshot(snapshot), 'Setting up');
    },
  );
}
