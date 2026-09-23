import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// The vendor's accepted authentication reply, opcode 0x01 result 1.
const List<int> _authAccepted = <int>[0x04, 0x01, 0x01, 0x00, 0xfa];

/// Synthetic vendor material for this suite.
///
/// The package compiles no vendor material, so the fake link and every driver
/// under test share this obviously synthetic set. The bytes are unrelated to
/// the real link.
final CbioCredentials _syntheticCredentials = CbioCredentials(
  streamKey: _ascii('CGMTESTKEY000000'),
  authMaterial: _ascii('CGMTESTMATERIAL1'),
  authenticationTrigger: const <int>[0x10, 0x20, 0x30, 0x40, 0x50],
);

final List<int> _syntheticKey = _syntheticCredentials.streamKey;

final CbioCredentialSource _syntheticSource = CbioStaticCredentialSource(
  _syntheticCredentials,
);

List<int> _ascii(String value) => value.codeUnits;

final class _FakeConnection implements BleConnection {
  _FakeConnection({required this.services, List<int>? streamKey})
    : streamKey = streamKey ?? _syntheticKey;

  final List<BleService> services;
  final List<int> streamKey;
  final StreamController<BleConnectionState> _states =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();

  bool notifyEnabled = false;

  @override
  String get deviceId => 'synthetic-device';

  @override
  Stream<BleConnectionState> get connectionStates => _states.stream;

  @override
  bool get supportsBondLifecycle => false;

  @override
  Future<void> ensureBonded() async {}

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unbonded;

  @override
  Future<void> requestMtu(int mtu) async {}

  @override
  Future<List<BleService>> discoverServices() async => services;

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async =>
      const <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66];

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    if (unmaskCbioFrame(value, key: streamKey).elementAtOrNull(1) == 0x01) {
      _notifications.add(maskCbioFrame(_authAccepted, key: streamKey));
    }
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    notifyEnabled = enabled;
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;

  @override
  Future<void> removeBond() async {}

  @override
  Future<void> disconnect() async {
    await _states.close();
    await _notifications.close();
  }
}

final class _FakeBleTransport implements BleTransport {
  _FakeBleTransport(this.connection);

  final _FakeConnection connection;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {}

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => connection;
}

/// Transport fake that records the service filters each scan pass used.
///
/// Models the device behaviour that blocks this sensor today: a scan with the
/// FF30 service filter completes with no results, while an unfiltered pass
/// still sees the FF30 advertisement.
final class _ScriptedScanTransport implements BleTransport {
  _ScriptedScanTransport({
    required this.filteredResults,
    required this.unfilteredResults,
  });

  final List<BleScanResult> filteredResults;
  final List<BleScanResult> unfilteredResults;
  final List<List<String>?> serviceFilters = <List<String>?>[];
  final List<Duration?> timeouts = <Duration?>[];

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {
    serviceFilters.add(withServices);
    timeouts.add(timeout);
    final results = (withServices == null || withServices.isEmpty)
        ? unfilteredResults
        : filteredResults;
    for (final result in results) {
      yield result;
    }
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => throw UnimplementedError('scan-only fake');
}

/// The FF30 advertisement shape the platform reports for this sensor.
BleScanResult _ff30Advertisement({int rssi = -61}) => BleScanResult(
  deviceId: 'synthetic-ff30-device',
  deviceName: 'Cbio / SiSensing candidate',
  rssi: rssi,
  serviceUuids: const <String>[CbioUuids.service],
);

void main() {
  const discovery = CbioDiscovery();

  DiscoveredSensor candidate() => const DiscoveredSensor(
    driverId: 'cbio',
    deviceId: 'synthetic-device',
    displayName: 'Cbio / SiSensing candidate',
    storageKey: 'synthetic-device',
    rssi: -50,
    capabilities: CbioSensorDriver.capabilities,
  );

  test('FF30 variants map; foreign services and empty ids are rejected', () {
    for (final uuid in <String>[
      CbioUuids.service,
      CbioUuids.service.toUpperCase(),
      'FF30',
      '0000ff30',
    ]) {
      final result = discovery.mapScanResult(
        BleScanResult(
          deviceId: 'synthetic-device',
          deviceName: '',
          rssi: -63,
          serviceUuids: <String>[uuid],
        ),
      );
      expect(result, isNotNull);
      expect(result!.driverId, 'cbio');
      expect(result.capabilities.supportsDirectBle, isTrue);
      expect(result.capabilities.supportsHistory, isFalse);
    }
    for (final uuid in <String>[
      CbioUuids.receive,
      CbioUuids.command,
      'ff31',
      'ff32',
    ]) {
      expect(
        discovery.mapScanResult(
          BleScanResult(
            deviceId: 'synthetic-device',
            deviceName: 'Cbio GS1',
            rssi: -50,
            serviceUuids: <String>[uuid],
          ),
        ),
        isNull,
      );
    }
    expect(
      discovery.mapScanResult(
        const BleScanResult(
          deviceId: '',
          deviceName: '',
          rssi: -50,
          serviceUuids: <String>[CbioUuids.service],
        ),
      ),
      isNull,
    );
  });

  test('locates FF31 when the platform reports short-form UUIDs', () async {
    // Android hands the app short-form UUIDs (`FF30`/`FF31`/`FF32`) rather
    // than the full 128-bit base form the driver declares.
    final connection = _FakeConnection(
      services: <BleService>[
        BleService(
          uuid: 'FF30',
          characteristics: const <BleCharacteristicRef>[
            BleCharacteristicRef(
              serviceUuid: 'FF30',
              characteristicUuid: 'FF31',
              properties: BleCharacteristicProperties(notify: true),
            ),
            BleCharacteristicRef(
              serviceUuid: 'FF30',
              characteristicUuid: 'FF32',
              properties: BleCharacteristicProperties(write: true),
            ),
          ],
        ),
      ],
    );
    final driver = CbioSensorDriver(
      _FakeBleTransport(connection),
      credentials: _syntheticSource,
      timing: const CbioSessionTiming(
        authTimeout: Duration(milliseconds: 200),
        historyWindow: Duration(milliseconds: 60),
        historyIdleWindow: Duration(milliseconds: 30),
        publishInterval: Duration.zero,
      ),
    );
    final session = await driver.connect(candidate());
    expect(session, isA<CbioGlucoseSession>());
    await (session as CbioGlucoseSession).initialize();

    expect(connection.notifyEnabled, isTrue);
    expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
    expect(
      session.currentSnapshot.metadata[cbioPhaseMetadataKey],
      CbioSessionPhase.history,
    );
    await session.disconnect();
  });

  test('a connection without FF32 fails closed before any write', () async {
    final connection = _FakeConnection(
      services: const <BleService>[
        BleService(
          uuid: CbioUuids.service,
          characteristics: <BleCharacteristicRef>[
            BleCharacteristicRef(
              serviceUuid: CbioUuids.service,
              characteristicUuid: CbioUuids.receive,
              properties: BleCharacteristicProperties(notify: true),
            ),
          ],
        ),
      ],
    );
    final driver = CbioSensorDriver(
      _FakeBleTransport(connection),
      credentials: _syntheticSource,
    );
    final session = await driver.connect(candidate()) as CbioGlucoseSession;
    await session.initialize();

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(connection.notifyEnabled, isFalse);
    await session.disconnect();
  });

  test(
    'scan retries unfiltered when the FF30 filter surfaces no candidate',
    () async {
      // The sensor's advertisement reaches this app without the FF30 service
      // UUID on the filterable layer, so a filtered pass alone reports an
      // empty nearby-sensor list on a sensor that is advertising and healthy.
      final transport = _ScriptedScanTransport(
        filteredResults: const <BleScanResult>[],
        unfilteredResults: <BleScanResult>[_ff30Advertisement()],
      );
      final driver = CbioSensorDriver(transport, discovery: discovery);

      final results = await driver
          .scan(timeout: const Duration(seconds: 3))
          .toList();

      expect(results, hasLength(1));
      expect(results.single.deviceId, 'synthetic-ff30-device');
      expect(results.single.driverId, 'cbio');
      expect(transport.serviceFilters, hasLength(2));
      expect(transport.serviceFilters.first, CbioDiscovery.scanServiceUuids);
      expect(transport.serviceFilters.last, isNull);
      expect(transport.timeouts, everyElement(const Duration(seconds: 3)));
    },
  );

  test(
    'scan does not retry unfiltered when the filter finds the sensor',
    () async {
      final transport = _ScriptedScanTransport(
        filteredResults: <BleScanResult>[_ff30Advertisement(rssi: -55)],
        unfilteredResults: <BleScanResult>[_ff30Advertisement(rssi: -90)],
      );
      final driver = CbioSensorDriver(transport, discovery: discovery);

      final results = await driver.scan().toList();

      expect(results, hasLength(1));
      expect(results.single.rssi, -55);
      expect(transport.serviceFilters, hasLength(1));
      expect(transport.serviceFilters.single, CbioDiscovery.scanServiceUuids);
    },
  );

  test('a driver reports whether its build can authenticate at all', () {
    final transport = _ScriptedScanTransport(
      filteredResults: const <BleScanResult>[],
      unfilteredResults: const <BleScanResult>[],
    );
    // No `--dart-define` material in a plain test run, so the default source is
    // unconfigured and a registry can skip the driver instead of surfacing a
    // sensor it could never read.
    expect(CbioSensorDriver(transport).canAuthenticate, isFalse);
    expect(
      CbioSensorDriver(
        transport,
        credentials: _syntheticSource,
      ).canAuthenticate,
      isTrue,
    );
  });

  test('a driver without material fails closed before any write', () async {
    final connection = _FakeConnection(
      services: const <BleService>[
        BleService(
          uuid: CbioUuids.service,
          characteristics: <BleCharacteristicRef>[
            BleCharacteristicRef(
              serviceUuid: CbioUuids.service,
              characteristicUuid: CbioUuids.receive,
              properties: BleCharacteristicProperties(notify: true),
            ),
            BleCharacteristicRef(
              serviceUuid: CbioUuids.service,
              characteristicUuid: CbioUuids.command,
              properties: BleCharacteristicProperties(write: true),
            ),
          ],
        ),
      ],
    );
    final driver = CbioSensorDriver(_FakeBleTransport(connection));
    final session = await driver.connect(candidate()) as CbioGlucoseSession;
    await session.initialize();

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(session.currentSnapshot.lastError, CbioSessionFailure.authMaterial);
    expect(connection.notifyEnabled, isFalse);
    await session.disconnect();
  });

  test('the unfiltered retry still drops non-FF30 advertisers', () async {
    final transport = _ScriptedScanTransport(
      filteredResults: const <BleScanResult>[],
      unfilteredResults: const <BleScanResult>[
        BleScanResult(
          deviceId: 'synthetic-foreign-device',
          deviceName: 'Desk lamp',
          rssi: -70,
          serviceUuids: <String>['0000fff0-0000-1000-8000-00805f9b34fb'],
        ),
      ],
    );
    final driver = CbioSensorDriver(transport, discovery: discovery);

    expect(await driver.scan().toList(), isEmpty);
  });
}
