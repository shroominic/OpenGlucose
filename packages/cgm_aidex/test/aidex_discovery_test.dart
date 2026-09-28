import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:test/test.dart';

void main() {
  const discovery = AidexDiscovery();

  test('maps an AiDEX name without changing the existing storage key', () {
    final sensor = discovery.mapScanResult(
      const BleScanResult(
        deviceId: 'synthetic-device',
        deviceName: 'AiDEX-2222293Q2E',
        rssi: -48,
      ),
    );

    expect(sensor, isNotNull);
    expect(sensor!.driverId, 'aidex');
    expect(sensor.storageKey, 'serial:2222293Q2E');
    expect(sensor.metadata, const <String, String>{'serial': '2222293Q2E'});
  });

  test('maps service and Abbott manufacturer data without a device name', () {
    final sensor = discovery.mapScanResult(
      const BleScanResult(
        deviceId: 'synthetic-device',
        deviceName: '',
        rssi: -52,
        serviceUuids: <String>[AidexUuids.cgmService],
        manufacturerData: <BleManufacturerData>[
          BleManufacturerData(
            companyId: 0x0059,
            bytes: <int>[
              0x01,
              0x00,
              0x08,
              0x02,
              0x00,
              0x55,
              0x88,
              0x00,
              0x56,
              0x80,
              0x00,
              0x57,
              0x84,
            ],
          ),
        ],
      ),
    );

    expect(sensor, isNotNull);
    expect(sensor!.driverId, 'aidex');
    expect(sensor.storageKey, 'synthetic-device');
    expect(sensor.advertisement?.displayValueMgdl, 85);
  });

  test('rejects an unrelated advertisement', () {
    expect(
      discovery.mapScanResult(
        const BleScanResult(
          deviceId: 'synthetic-device',
          deviceName: 'Other sensor',
          rssi: -40,
          serviceUuids: <String>['FDE3'],
        ),
      ),
      isNull,
    );
  });
}
