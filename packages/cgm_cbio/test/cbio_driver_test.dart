import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

List<int> _checked(List<int> prefix) => <int>[
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

const List<int> readCommand = <int>[0x06, 0x08, 0x01, 0x00, 0x00, 0x00, 0xf1];

final class _FakeBleConnection implements BleConnection {
  _FakeBleConnection(this.deviceId, {List<BleService>? services})
    : services =
          services ??
          <BleService>[
            BleService(
              uuid: CbioUuids.service,
              characteristics: <BleCharacteristicRef>[
                const BleCharacteristicRef(
                  serviceUuid: CbioUuids.service,
                  characteristicUuid: CbioUuids.receive,
                  properties: BleCharacteristicProperties(notify: true),
                ),
                const BleCharacteristicRef(
                  serviceUuid: CbioUuids.service,
                  characteristicUuid: CbioUuids.command,
                  properties: BleCharacteristicProperties(write: true),
                ),
              ],
            ),
          ];

  @override
  final String deviceId;

  final List<BleService> services;
  final StreamController<BleConnectionState> _states =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();
  final List<(BleCharacteristicRef, List<int>, bool)> writeLog =
      <(BleCharacteristicRef, List<int>, bool)>[];
  bool notifyEnabled = false;

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
  Future<List<int>> read(BleCharacteristicRef characteristic) async => <int>[];

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    writeLog.add((characteristic, value, withoutResponse));
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    if (enabled) {
      notifyEnabled = true;
    }
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;

  void emitNotification(List<int> bytes) {
    _notifications.add(bytes);
  }

  @override
  Future<void> removeBond() async {}

  @override
  Future<void> disconnect() async {
    await _states.close();
    await _notifications.close();
  }
}

final class _FakeBleTransport implements BleTransport {
  _FakeBleTransport({
    this.scanResults = const <BleScanResult>[],
    _FakeBleConnection? connection,
  }) : connection = connection ?? _FakeBleConnection('synthetic-device');

  final List<BleScanResult> scanResults;
  final _FakeBleConnection connection;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {
    for (final result in scanResults) {
      yield result;
    }
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return connection;
  }
}

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
    for (final uuid in [
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
          serviceUuids: [uuid],
        ),
      );
      expect(result, isNotNull);
      expect(result!.driverId, 'cbio');
      expect(result.capabilities.supportsDirectBle, isTrue);
    }
    for (final uuid in [CbioUuids.receive, CbioUuids.command, 'ff31', 'ff32']) {
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
          deviceName: '',
          rssi: -50,
          serviceUuids: [CbioUuids.service],
        ),
      ),
      isNull,
    );
  });

  test('scan surfaces one FF30 candidate', () async {
    final transport = _FakeBleTransport(
      scanResults: <BleScanResult>[
        BleScanResult(
          deviceId: 'synthetic-device',
          deviceName: '',
          rssi: -50,
          serviceUuids: [CbioUuids.service],
        ),
      ],
    );
    final driver = CbioSensorDriver(
      transport,
      passiveWindow: const Duration(days: 1),
    );
    final sensors = await driver
        .scan(timeout: Duration.zero, allowDuplicates: false)
        .toList();
    expect(sensors, hasLength(1));
    expect(sensors.single.driverId, 'cbio');
    expect(sensors.single.deviceId, 'synthetic-device');
  });

  test(
    'session enables notifications and decodes a valid plaintext ACK',
    () async {
      final connection = _FakeBleConnection('synthetic-device');
      final transport = _FakeBleTransport(connection: connection);
      final driver = CbioSensorDriver(
        transport,
        passiveWindow: const Duration(days: 1),
      );
      final session = await driver.connect(candidate()) as CbioSession;
      await session.initialize();
      expect(connection.notifyEnabled, isTrue);

      connection.emitNotification(_checked(<int>[4, 0x01, 0, 0x7e]));
      await Future<void>.delayed(Duration.zero);
      expect(session.currentSnapshot.statusText, contains('0x01'));

      await session.disconnect();
    },
  );

  test('a notification cancels the passive 0x08 read', () async {
    final connection = _FakeBleConnection('synthetic-device');
    final transport = _FakeBleTransport(connection: connection);
    final driver = CbioSensorDriver(
      transport,
      passiveWindow: const Duration(milliseconds: 5),
    );
    final session = await driver.connect(candidate()) as CbioSession;
    await session.initialize();
    connection.emitNotification(_checked(<int>[4, 0x01, 0, 0x7e]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connection.writeLog, isEmpty);
    await session.disconnect();
  });

  test(
    'silence sends exactly one bounded 0x08 read, never another write',
    () async {
      final connection = _FakeBleConnection('synthetic-device');
      final transport = _FakeBleTransport(connection: connection);
      final driver = CbioSensorDriver(
        transport,
        passiveWindow: const Duration(milliseconds: 1),
      );
      final session = await driver.connect(candidate()) as CbioSession;
      await session.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(connection.writeLog, hasLength(1));
      expect(
        connection.writeLog.single.$1.characteristicUuid,
        CbioUuids.command,
      );
      expect(connection.writeLog.single.$2, readCommand);
      expect(connection.writeLog.single.$3, isFalse);
      await session.disconnect();
    },
  );

  test('missing FF31 fails closed without a write', () async {
    final connection = _FakeBleConnection(
      'synthetic-device',
      services: <BleService>[
        BleService(
          uuid: CbioUuids.service,
          characteristics: <BleCharacteristicRef>[
            const BleCharacteristicRef(
              serviceUuid: CbioUuids.service,
              characteristicUuid: CbioUuids.command,
              properties: BleCharacteristicProperties(write: true),
            ),
          ],
        ),
      ],
    );
    final transport = _FakeBleTransport(connection: connection);
    final driver = CbioSensorDriver(transport);
    final session = await driver.connect(candidate()) as CbioSession;
    await session.initialize();
    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(
      session.currentSnapshot.lastError,
      contains('missingNotifyCharacteristic'),
    );
    expect(connection.writeLog, isEmpty);
    await session.disconnect();
  });
}
