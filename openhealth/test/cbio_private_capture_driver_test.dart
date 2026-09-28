import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/cbio_private_capture_support.dart';

final _credentials = CbioCredentials(
  streamKey: 'CGMTESTKEY000000'.codeUnits,
  authMaterial: 'CGMTESTMATERIAL1'.codeUnits,
  authenticationTrigger: const [0x10, 0x20, 0x30, 0x40, 0x50],
);
const _deviceId = 'AA:BB:CC:DD:EE:FF';
const _serial = <int>[0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa];
const _runId = '0123456789abcdef0123456789abcdef';

void main() {
  test(
    'capture cutoff drains fragmented FF31 into the same seven private fields',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cbio-private-driver-test.',
      );
      addTearDown(() => root.delete(recursive: true));
      await CaptureHandshake(
        runDirectory: Directory('${root.path}/$_runId'),
        context: CaptureRunContext.fromValues({
          'CBIO_CAPTURE_RUN_ID': _runId,
          'CBIO_CAPTURE_APP_PACKAGE': 'com.openglucose.app.debug',
          'CBIO_CAPTURE_START_NONCE': 'a' * 32,
          'CBIO_CAPTURE_ACK_NONCE': 'b' * 32,
          'CBIO_TARGET_DEVICE_ID': _deviceId,
          'CBIO_EXPECTED_SERIAL_HEX': 'ffeeddccbbaa',
          'CBIO_LABEL_SHA256': 'c' * 64,
          'CBIO_REPLAY_CONTEXT': 'V1.1.6A',
          'CBIO_RAW_START_INDEX': '1',
          'CBIO_SOURCE_REVISION': 'd' * 40,
        }),
      ).prepare();
      final store = CaptureFullRecordStore(
        root: root,
        runId: _runId,
      );
      final connection = _FragmentedConnection();
      final allowed = <List<int>>[
        buildMaskedCbioAuthentication(
          _serial,
          key: _credentials.streamKey,
          material: _credentials.authMaterial,
        ),
        buildMaskedCbioGlucoseQuery(0, key: _credentials.streamKey),
        buildMaskedCbioRawQuery(1, key: _credentials.streamKey),
      ];
      final transport = ExactCaptureTransport(
        delegate: _SingleAttemptTransport(connection),
        expectedDeviceId: _deviceId,
        expectedSerial: _serial,
        allowedWrites: allowed,
      );
      final driver = CbioSensorDriver(
        transport,
        credentials: CbioStaticCredentialSource(_credentials),
        privateStateStore: store,
        timing: const CbioSessionTiming(
          connectTimeout: Duration(milliseconds: 300),
          discoveryTimeout: Duration(milliseconds: 300),
          writeTimeout: Duration(milliseconds: 300),
          authTimeout: Duration(milliseconds: 300),
          historyWindow: Duration(seconds: 5),
          historyIdleWindow: Duration(seconds: 5),
          livePollInterval: Duration(minutes: 10),
          publishInterval: Duration.zero,
          maxReadsPerSession: 2,
        ),
      );
      final sensor = DiscoveredSensor(
        driverId: 'cbio',
        deviceId: _deviceId,
        displayName: 'Private capture target',
        storageKey: _deviceId,
        rssi: 0,
        capabilities: CbioSensorDriver.capabilities,
      );

      final session = await driver.connect(sensor);
      await _waitUntil(() async {
        final envelope = await store.readFullRecords(sensor.storageKey);
        return envelope != null && envelope.contains('"state":"observing"');
      });
      expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
      await session.disconnect();

      final envelope = await store.readFullRecords(sensor.storageKey);
      final state = CbioFullRecordState.decode(
        envelope!,
        sensorKey: sensor.storageKey,
      );
      expect(
        state.records
            .map(
              (row) => [
                row.index,
                row.rawTime,
                row.reindex,
                row.rawTemperature,
                row.rawDump,
                row.rawPayload,
                row.rawProcessed,
              ],
            )
            .toList(),
        [
          [1, 2000, 1, 321, 0, 74, 0],
          [2, 2060, 0, 321, 0, 80, 0],
        ],
      );
      final summary = inspectCaptureEnvelope(
        envelope,
        sensorKey: sensor.storageKey,
        historyWindowClosed: false,
        authenticatedRawQuery: true,
      );
      expect(
        summary.captureCompleteness,
        CaptureCompleteness.contiguousPrefixCutOff,
      );
      expect(transport.commandSequenceComplete, isTrue);
      expect(connection.fragmentCount, 2);
    },
  );
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not satisfied');
}

List<int> _framed(List<int> body) {
  final head = <int>[body.length + 1, ...body];
  return [...head, (-head.fold<int>(0, (sum, byte) => sum + byte)) & 0xff];
}

List<int> _rawBatch() {
  const currents = <int>[74, 80];
  return _framed(<int>[
    0x08,
    currents.length,
    0x01,
    0x00,
    0xd0,
    0x07,
    0x00,
    0x00,
    for (final current in currents) ...<int>[
      0x41,
      0x01,
      0x00,
      0x00,
      current,
      0x00,
      0x00,
      0x00,
    ],
    0x00,
    0x00,
  ]);
}

final class _SingleAttemptTransport
    implements BleTransport, BleSingleAttemptTransport {
  _SingleAttemptTransport(this.connection);

  final _FragmentedConnection connection;
  int connects = 0;

  @override
  bool get supportsSingleAttemptConnect => true;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => const Stream.empty();

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw StateError('normal connect must not be used');

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connects++;
    return connection;
  }
}

final class _FragmentedConnection implements BleConnection {
  final _notifications = StreamController<List<int>>.broadcast();
  int fragmentCount = 0;

  @override
  String get deviceId => _deviceId;

  @override
  Stream<BleConnectionState> get connectionStates =>
      Stream.value(BleConnectionState.connected);

  @override
  bool get supportsBondLifecycle => false;

  @override
  Future<void> ensureBonded() async {}

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unbonded;

  @override
  Future<void> requestMtu(int mtu) async {}

  @override
  Future<List<BleService>> discoverServices() async => const [
    BleService(
      uuid: CbioUuids.service,
      characteristics: [
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
    BleService(
      uuid: '0000180a-0000-1000-8000-00805f9b34fb',
      characteristics: [
        BleCharacteristicRef(
          serviceUuid: '0000180a-0000-1000-8000-00805f9b34fb',
          characteristicUuid: CbioUuids.serial,
          properties: BleCharacteristicProperties(read: true),
        ),
      ],
    ),
  ];

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async => _serial;

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final plaintext = unmaskCbioFrame(value, key: _credentials.streamKey);
    switch (plaintext[1]) {
      case 0x01:
        _emitPlaintext(const [0x04, 0x01, 0x01, 0x00, 0xfa]);
      case 0x08:
        final masked = maskCbioFrame(_rawBatch(), key: _credentials.streamKey);
        fragmentCount = 2;
        _notifications.add(masked.sublist(0, 7));
        _notifications.add(masked.sublist(7));
    }
  }

  void _emitPlaintext(List<int> value) =>
      _notifications.add(maskCbioFrame(value, key: _credentials.streamKey));

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {}

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;

  @override
  Future<void> removeBond() async {}

  @override
  Future<void> disconnect() => _notifications.close();
}
