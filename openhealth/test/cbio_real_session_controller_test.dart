import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/health_state_store_io.dart';
import 'package:openglucose/src/driver_factory.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:openglucose/src/persistence/cbio_private_state_adapter.dart';
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
  test(
    'native store restart keeps raw bytes private and rechecks exact witness',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp(
        'cbio-private-restart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      FileHealthStateStore store() => FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );
      final firstStore = store();
      final first = await _open(
        firstStore,
        _Radio(startIndex: 1, rawTime: 12000, currents: [64, 80, 97]),
      );
      await first.connect(_sensor, allowSessionActivation: false);
      await _until(() => first.snapshot?.stage == CgmSyncStage.ready);
      await first.disconnect(clearSelection: false);
      final original = await CbioPrivateStateAdapter(
        firstStore,
      ).read(_sensor.storageKey);
      expect(original, isNotNull);
      first.dispose();
      final secondStore = store();
      final radio = _Radio(
        startIndex: 3,
        rawTime: 12120,
        currents: [97],
        deferRawResponse: true,
      );
      final second = await _open(secondStore, radio);
      _expectNoPublicRaw(second);
      await second.connect(_sensor, allowSessionActivation: false);
      await _until(() => radio.rawQueryStarts.isNotEmpty);
      expect(radio.rawQueryStarts.first, 3);
      expect(
        await CbioPrivateStateAdapter(secondStore).read(_sensor.storageKey),
        original,
      );
      radio.releaseRawResponse();
      await _until(() => second.snapshot?.stage == CgmSyncStage.ready);
      _expectNoPublicRaw(second);
      await second.disconnect(clearSelection: false);
      expect(
        await CbioPrivateStateAdapter(secondStore).read(_sensor.storageKey),
        original,
      );
      second.dispose();
    },
  );
  for (final outcome in [
    'confirmed',
    'before-checkpoint',
    'witness-time-mismatch',
    'archive-time-conflict',
    'payload-conflict',
  ]) {
    test('real raw driver remains private through restart: $outcome', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = _MemoryStore();
      final first = await _open(
        store,
        _Radio(startIndex: 1, rawTime: 12000, currents: [64, 80, 97]),
      );
      await first.connect(_sensor, allowSessionActivation: false);
      await _until(() => first.snapshot?.stage == CgmSyncStage.ready);
      _expectNoPublicRaw(first);
      await first.disconnect(clearSelection: false);
      final key = store.values.keys.singleWhere(
        (key) => key.startsWith('openHealth.history.cbio.v1.'),
      );
      final original = store.getString(key)!;
      final saved = jsonDecode(original) as Map;
      expect(
        (saved['history'] as List).map((row) => (row as Map)['rawValue']),
        [64, 80, 97],
      );
      final witness = CbioSessionCheckpoint.decode(
        saved['checkpoint'] as String,
        _sensor.storageKey,
      )!;
      expect(witness.index, 3);
      expect(witness.rawTime, 12120);
      first.dispose();

      final radio = _Radio(
        startIndex: outcome == 'before-checkpoint' ? 1 : 3,
        rawTime: outcome == 'witness-time-mismatch'
            ? 90000
            : outcome == 'before-checkpoint'
            ? 12000
            : 12120,
        currents: outcome == 'confirmed'
            ? [97, 101]
            : outcome == 'payload-conflict'
            ? [99]
            : [97],
        deferRawResponse: true,
      );
      final restored = await _open(store, radio);
      _expectNoPublicRaw(restored);
      await restored.connect(_sensor, allowSessionActivation: false);
      await _until(() => radio.rawQueryStarts.isNotEmpty);
      expect(radio.rawQueryStarts.first, 3);
      expect(store.getString(key), original);
      _expectNoPublicRaw(restored);
      radio.releaseRawResponse();
      if (outcome == 'archive-time-conflict') {
        await _until(() => restored.snapshot?.stage == CgmSyncStage.ready);
        radio.injectRawResponse(startIndex: 3, rawTime: 90000, currents: [97]);
      }
      await _until(
        () =>
            restored.snapshot?.stage ==
            (outcome == 'confirmed' ? CgmSyncStage.ready : CgmSyncStage.error),
      );
      _expectNoPublicRaw(restored);
      if (outcome != 'confirmed') {
        expect(
          restored.snapshot!.metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
      }
      await restored.disconnect(clearSelection: false);
      if (outcome == 'confirmed') {
        final updated = jsonDecode(store.getString(key)!) as Map;
        expect(
          (updated['history'] as List).map((row) => (row as Map)['rawValue']),
          [64, 80, 97, 101],
        );
        expect(
          CbioSessionCheckpoint.decode(
            updated['checkpoint'] as String,
            _sensor.storageKey,
          )!.index,
          4,
        );
      } else {
        expect(store.getString(key), original);
      }
      expect(restored.archivedSensors, isEmpty);
      restored.dispose();
    });
  }
}

void _expectNoPublicRaw(CgmAppController controller) {
  final snapshot = controller.snapshot!;
  expect(snapshot.sessionInfo.sessionStart, isNull);
  expect(snapshot.sessionInfo.elapsedMinutes, isNull);
  expect(computeWarmupStatus(snapshot), isNull);
  expect(computeSensorLifecycle(snapshot).phase, SensorLifecyclePhase.unknown);
  expect(snapshot.latestReading, isNull);
  expect(snapshot.history, isEmpty);
  expect(snapshot.rawHistory, isEmpty);
  expect(snapshot.historySync.storedCount, 0);
  expect(controller.allHistoricalReadings, isEmpty);
  expect(controller.displayLatestReading, isNull);
  expect(
    snapshot.metadata.keys.where(
      (key) => key.contains('checkpoint') || key.contains('clock.'),
    ),
    isEmpty,
  );
}

Future<CgmAppController> _open(HealthStateStore store, _Radio radio) async {
  final preferences = await SharedPreferences.getInstance();
  final adapter = CbioPrivateStateAdapter(store);
  await store.initialize();
  await adapter.migrateLegacyArchives();
  final driver = CbioSensorDriver(
    _Transport(radio),
    credentials: CbioStaticCredentialSource(_credentials),
    timing: _timing,
    privateStateStore: adapter,
  );
  final controller = CgmAppController(
    preferences: preferences,
    healthStateStore: store,
    driver: driver,
    prepareTarget: (sensor) => prepareDefaultDriverTarget(driver, sensor),
    flushPrivateState: () => flushDefaultDriverPrivateState(driver),
    historyNamespace: defaultDriverHistoryNamespace,
  );
  await controller.initialize();
  return controller;
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
  void injectRawResponse({
    required int startIndex,
    required int rawTime,
    required List<int> currents,
  }) {
    final lastIndex = startIndex + currents.length - 1;
    _emit(
      _frame([
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
      ]),
    );
  }

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
