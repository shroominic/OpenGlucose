import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Deliberately synthetic material and identity; never contacts hardware.
final _credentials = CbioCredentials(
  streamKey: List<int>.generate(16, (index) => 0x20 + index),
  authMaterial: List<int>.generate(16, (index) => 0x40 + index),
  authenticationTrigger: const [0x10, 0x20, 0x30, 0x40, 0x50],
);
const _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'synthetic-radio',
  storageKey: 'synthetic-radio',
  displayName: 'Synthetic CBIO',
  rssi: -50,
  capabilities: CbioGlucoseSession.capabilities,
);
const _timing = CbioSessionTiming(
  connectTimeout: Duration(milliseconds: 500),
  discoveryTimeout: Duration(milliseconds: 500),
  writeTimeout: Duration(milliseconds: 300),
  authTimeout: Duration(milliseconds: 200),
  historyWindow: Duration(milliseconds: 120),
  historyIdleWindow: Duration(milliseconds: 30),
  livePollInterval: Duration(hours: 1),
  liveResponseWindow: Duration(milliseconds: 30),
  publishInterval: Duration.zero,
);

void main() {
  for (final witnessMatches in [true, false]) {
    test(
      'real CBIO producer crosses host fresh and resumed proof gates matches=$witnessMatches',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _MemoryStore();
        final firstRadio = _Radio(
          startIndex: 1,
          rawTime: 12000,
          currents: [64, 80, 97],
        );
        final first = CgmAppController(
          preferences: preferences,
          healthStateStore: store,
          driver: CbioSensorDriver(
            _Transport(firstRadio),
            credentials: CbioStaticCredentialSource(_credentials),
            timing: _timing,
          ),
        );
        await first.initialize();
        await first.connect(_sensor, allowSessionActivation: false);
        await _until(
          () =>
              first.snapshot?.stage == CgmSyncStage.ready &&
              first.snapshot?.history.length == 3,
        );
        expect(
          first.snapshot!.metadata[cbioResumeStatusMetadataKey],
          CbioResumeStatus.fresh,
        );
        expect(first.snapshot!.history.map((row) => row.rawValue), [
          64,
          80,
          97,
        ]);
        expect(
          first.snapshot!.history.every(
            (row) =>
                row.isDisplayProvisional && row.source == CgmRecordSource.raw,
          ),
          isTrue,
        );
        expect(first.allHistoricalReadings, isEmpty);
        await first.disconnect(clearSelection: false);
        final historyKey = store.values.keys.singleWhere(
          (key) => key.startsWith('openHealth.history.cbio.v1.'),
        );
        final durableBefore = store.getString(historyKey)!;
        final checkpoint =
            (jsonDecode(durableBefore) as Map)['checkpoint'] as String;
        final decoded = CbioSessionCheckpoint.decode(
          checkpoint,
          _sensor.storageKey,
        )!;
        expect(decoded.index, 3);
        expect(decoded.rawTime, 12120);
        first.dispose();

        final secondRadio = _Radio(
          startIndex: 3,
          rawTime: witnessMatches ? 12120 : 90000,
          currents: [97, 101],
          deferRawResponse: true,
        );
        final second = CgmAppController(
          preferences: preferences,
          healthStateStore: store,
          driver: CbioSensorDriver(
            _Transport(secondRadio),
            credentials: CbioStaticCredentialSource(_credentials),
            timing: _timing,
          ),
        );
        await second.initialize();
        await second.connect(_sensor, allowSessionActivation: false);
        await _until(() => secondRadio.rawQueryStarts.isNotEmpty);
        expect(
          second.snapshot!.metadata[cbioResumeStatusMetadataKey],
          CbioResumeStatus.pending,
        );
        expect(
          second.snapshot!.metadata[cbioConfirmedCheckpointMetadataKey],
          isNull,
        );
        expect(second.snapshot!.history.map((row) => row.rawValue), [
          64,
          80,
          97,
        ]);
        expect(store.getString(historyKey), durableBefore);
        secondRadio.releaseRawResponse();
        await _until(
          () =>
              second.snapshot?.stage ==
              (witnessMatches ? CgmSyncStage.ready : CgmSyncStage.error),
        );
        expect(
          secondRadio.rawQueryStarts.first,
          3,
          reason: 'the real producer must reread the persisted witness',
        );
        if (witnessMatches) {
          expect(
            second.snapshot!.metadata[cbioResumeStatusMetadataKey],
            CbioResumeStatus.confirmed,
          );
          expect(
            second.snapshot!.metadata[cbioConfirmedCheckpointMetadataKey],
            checkpoint,
          );
          expect(second.snapshot!.history.map((row) => row.sensorMinute), [
            1,
            2,
            3,
            4,
          ]);
          expect(second.snapshot!.history.map((row) => row.rawValue), [
            64,
            80,
            97,
            101,
          ]);
          await second.disconnect(clearSelection: false);
          final saved = jsonDecode(store.getString(historyKey)!) as Map;
          expect(saved['history'], hasLength(4));
          expect(
            CbioSessionCheckpoint.decode(
              saved['checkpoint'] as String,
              _sensor.storageKey,
            )!.index,
            4,
          );
        } else {
          expect(second.snapshot!.history.map((row) => row.rawValue), [
            64,
            80,
            97,
          ]);
          await second.disconnect(clearSelection: false);
          expect(store.getString(historyKey), durableBefore);
        }
        expect(second.allHistoricalReadings, isEmpty);
        second.dispose();
      },
    );
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(
    condition(),
    isTrue,
    reason: 'real producer reached expected host state',
  );
}

List<int> _frame(List<int> body) {
  final bytes = [body.length + 1, ...body];
  return [...bytes, (-bytes.fold<int>(0, (sum, byte) => sum + byte)) & 0xff];
}

class _Radio implements BleConnection {
  _Radio({
    required this.startIndex,
    required this.rawTime,
    required this.currents,
    this.deferRawResponse = false,
  });
  final int startIndex;
  final int rawTime;
  final List<int> currents;
  final bool deferRawResponse;
  List<int>? _pendingRawFrame;
  final rawQueryStarts = <int>[];
  final _notifications = StreamController<List<int>>.broadcast();
  bool _closed = false;
  @override
  String get deviceId => _sensor.deviceId;
  @override
  Stream<BleConnectionState> get connectionStates => const Stream.empty();
  @override
  bool get supportsBondLifecycle => false;
  @override
  Future<void> ensureBonded() async {}
  @override
  Future<BleBondState> currentBondState() async => BleBondState.unbonded;
  @override
  Future<void> requestMtu(int mtu) async {}
  @override
  Future<void> removeBond() async {}
  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {}
  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;
  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async => [
    0x11,
    0x22,
    0x33,
    0x44,
    0x55,
    0x66,
  ];
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
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final plain = unmaskCbioFrame(value, key: _credentials.streamKey);
    if (plain[1] == 0x01) {
      _emit(_frame([0x01, 0x01, 0x00]));
    } else if (plain[1] == 0x08) {
      rawQueryStarts.add(plain[2] | (plain[3] << 8));
      final lastIndex = startIndex + currents.length - 1;
      final frame = _frame([
        0x08,
        currents.length,
        startIndex & 0xff,
        startIndex >> 8,
        for (var shift = 0; shift < 32; shift += 8) (rawTime >> shift) & 0xff,
        for (final current in currents) ...[
          0x3b,
          0x01,
          0,
          0,
          current & 0xff,
          current >> 8,
          0,
          0,
        ],
        lastIndex & 0xff,
        lastIndex >> 8,
      ]);
      if (deferRawResponse) {
        _pendingRawFrame = frame;
      } else {
        _emit(frame);
      }
    }
  }

  void _emit(List<int> frame) =>
      _notifications.add(maskCbioFrame(frame, key: _credentials.streamKey));
  void releaseRawResponse() {
    final frame = _pendingRawFrame;
    if (frame == null) {
      throw StateError('Expected a requested witness response');
    }
    _pendingRawFrame = null;
    _emit(frame);
  }

  @override
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    await _notifications.close();
  }
}

class _Transport implements BleTransport {
  _Transport(this.radio);
  final _Radio radio;
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
  }) async => radio;
}

class _MemoryStore implements HealthStateStore {
  final values = <String, String>{};
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}
