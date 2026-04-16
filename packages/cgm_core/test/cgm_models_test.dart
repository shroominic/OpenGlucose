import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
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
