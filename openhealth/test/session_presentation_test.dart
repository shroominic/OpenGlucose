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
}
