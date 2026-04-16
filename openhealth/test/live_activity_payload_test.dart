import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/live_activity_payload.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    expect(payload.stageLabel, 'LIVE');
    expect(payload.recordedAtIso8601, now.toIso8601String());
    expect(payload.lastReadingText, '06:58');
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

    expect(payload.stageCode, 'progress');
    expect(payload.stageLabel, 'SYNC 50%');
    expect(payload.trendSymbol, '↑');
    expect(payload.deltaText, '+14');
    expect(payload.detailText, 'Updated ${readingTimeText(latest, now: now)}');
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

      expect(stageLabelForSnapshot(snapshot), 'SYNCING');
    },
  );
}
