import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  const driver = CbioSensorDriver();

  test('offline driver declares no working sensor capabilities', () {
    expect(driver.driverId, 'cbio');
    const capabilities = CbioSensorDriver.capabilities;
    expect([
      capabilities.supportsDirectBle,
      capabilities.supportsVendorPairing,
      capabilities.supportsAdvertisementGlucose,
      capabilities.supportsHistory,
      capabilities.supportsRawHistory,
      capabilities.supportsCalibration,
      capabilities.supportsDiagnostics,
      capabilities.supportsUnsafeAdmin,
      capabilities.supportsCommunicationInterval,
      capabilities.supportsAutoUpdateControl,
    ], everyElement(false));
    expect(CbioDiscovery.scanServiceUuids, [CbioUuids.service]);
  });

  test('FF30 variants map to unverified candidates with no capabilities', () {
    const discovery = CbioDiscovery();
    for (final uuid in [
      CbioUuids.service,
      CbioUuids.service.toUpperCase(),
      'FF30',
      '0000ff30',
    ]) {
      final candidate = discovery.mapScanResult(
        BleScanResult(
          deviceId: 'synthetic-device',
          deviceName: 'synthetic-private-name',
          rssi: -63,
          serviceUuids: [uuid],
        ),
      );
      expect(candidate, isNotNull);
      expect(candidate!.driverId, 'cbio');
      expect(candidate.deviceId, 'synthetic-device');
      expect(candidate.storageKey, 'synthetic-device');
      expect(candidate.rssi, -63);
      expect(candidate.displayName, 'Cbio / SiSensing candidate');
      expect(candidate.capabilities.supportsDirectBle, isFalse);
      expect(candidate.advertisement, isNull);
      expect(candidate.metadata, {'cgm.cbio.discovery': 'ff30-candidate'});
    }
  });

  test(
    'characteristic UUIDs and malformed services cannot identify a device',
    () {
      const discovery = CbioDiscovery();
      for (final uuid in [
        CbioUuids.receive,
        CbioUuids.command,
        'ff31',
        'ff32',
        '0000ff30-0000-1000-8000-00805f9b34fa',
        '',
      ]) {
        expect(
          discovery.mapScanResult(
            BleScanResult(
              deviceId: 'synthetic-device',
              deviceName: 'Cbio GS1',
              rssi: -50,
              serviceUuids: [uuid],
            ),
          ),
          isNull,
        );
      }
      expect(
        discovery.mapScanResult(
          const BleScanResult(
            deviceId: '',
            deviceName: 'Cbio GS1',
            rssi: -50,
            serviceUuids: [CbioUuids.service],
          ),
        ),
        isNull,
      );
    },
  );

  test('a discovery candidate still cannot open a live session', () async {
    final candidate = const CbioDiscovery().mapScanResult(
      const BleScanResult(
        deviceId: 'synthetic-device',
        deviceName: '',
        rssi: -50,
        serviceUuids: [CbioUuids.service],
      ),
    );
    await expectLater(
      driver.connect(candidate!),
      throwsA(isA<CbioProtocolUnavailableException>()),
    );
  });

  test('names and standard CGM service do not prove GS1 identity', () {
    const discovery = CbioDiscovery();
    for (final name in ['', 'Cbio GS1', 'SIBIONICS GS1', 'GS3', 'SiSensing']) {
      expect(
        discovery.mapScanResult(
          BleScanResult(
            deviceId: 'synthetic-device',
            deviceName: name,
            rssi: -50,
            serviceUuids: const ['0000181f-0000-1000-8000-00805f9b34fb'],
          ),
        ),
        isNull,
      );
    }
  });

  test(
    'scan reports unavailable instead of a successful empty result',
    () async {
      for (final duplicates in [false, true]) {
        await expectLater(
          driver.scan(timeout: Duration.zero, allowDuplicates: duplicates),
          emitsInOrder([
            emitsError(isA<CbioProtocolUnavailableException>()),
            emitsDone,
          ]),
        );
      }
    },
  );

  test('restored or foreign metadata cannot enable a live session', () async {
    for (final driverId in ['cbio', 'foreign']) {
      final sensor = DiscoveredSensor(
        driverId: driverId,
        deviceId: 'synthetic-private-device',
        displayName: 'synthetic-private-name',
        storageKey: 'synthetic-private-storage',
        rssi: -50,
        capabilities: const CgmCapabilities(supportsDirectBle: true),
        metadata: const {cgmAllowSessionActivationMetadataKey: 'true'},
      );
      await expectLater(
        driver.connect(sensor),
        throwsA(
          isA<CbioProtocolUnavailableException>()
              .having(
                (error) => error.diagnosticCode,
                'diagnosticCode',
                'cgm.cbio.protocol-unavailable',
              )
              .having(
                (error) => error.toString(),
                'redacted error',
                isNot(contains('synthetic-private')),
              ),
        ),
      );
    }
  });
}
