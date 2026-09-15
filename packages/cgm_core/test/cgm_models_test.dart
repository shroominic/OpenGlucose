import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  test('backfill alias follows the original capability and serialized key', () {
    const none = CgmCapabilities();
    expect(none.supportsHistoryBackfill, isFalse);
    final backfill = none.copyWith(supportsHistory: true);
    expect(backfill.supportsHistoryBackfill, isTrue);
    expect(
      backfill.copyWith(supportsHistory: false).supportsHistoryBackfill,
      isFalse,
    );
    final sensor = DiscoveredSensor(
      driverId: 'synthetic',
      deviceId: 'synthetic-device',
      displayName: 'Synthetic',
      storageKey: 'synthetic-storage',
      rssi: -40,
      capabilities: backfill,
    );
    final json = sensor.toJson();
    final capabilities = json['capabilities']! as Map<String, Object?>;
    expect(capabilities['supportsHistory'], isTrue);
    expect(capabilities.containsKey('supportsHistoryBackfill'), isFalse);
    expect(
      DiscoveredSensor.fromJson(json).capabilities.supportsHistoryBackfill,
      isTrue,
    );
  });

  test('mmol conversion uses standard divisor', () {
    expect(GlucoseUnit.mmolL.convertFromMgdl(180), 10);
  });

  test('history sync completeness is derived from counts', () {
    const state = CgmHistorySyncState(
      storedCount: 10,
      totalAvailable: 10,
      latestStoredOffset: 10,
    );
    expect(state.isComplete, isTrue);
  });

  test('session snapshot copyWith can clear lastError', () {
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Error',
      sensor: const DiscoveredSensor(
        driverId: 'demo',
        deviceId: 'sensor-1',
        displayName: 'Demo Sensor',
        storageKey: 'sensor-1',
        rssi: -40,
        capabilities: CgmCapabilities(),
      ),
      capabilities: const CgmCapabilities(),
      lastError: 'stale error',
    );

    final cleared = snapshot.copyWith(
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      clearLastError: true,
    );

    expect(cleared.lastError, isNull);
    expect(cleared.stage, CgmSyncStage.ready);
  });
}
