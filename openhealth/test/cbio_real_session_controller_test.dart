import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/healthkit_export.dart';
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
  for (final failure in const [
    ('before-checkpoint', 'GS1-H03A'),
    ('witness-time-mismatch', 'GS1-H03B'),
    ('archive-time-conflict', 'GS1-H03C'),
  ]) {
    testWidgets('real ${failure.$1} guard reaches host and sensor details', (
      tester,
    ) async {
      final result = await tester.runAsync(
        () => _restoreCounterFailure(failure.$1),
      );
      final (controller, preferences, store, historyKey, durableBefore) =
          result!;
      expect(controller.snapshot!.stage, CgmSyncStage.error);
      expect(controller.snapshot!.lastError, CbioSessionFailure.counterRestart);
      expect(
        controller.snapshot!.metadata['cgm.cbio.resume.counterFailureReason'],
        failure.$1,
      );
      expect(
        controller.snapshot!.metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
      expect(controller.snapshot!.history.map((row) => row.rawValue), [
        64,
        80,
        97,
      ]);
      expect(store.getString(historyKey), durableBefore);
      await tester.pumpWidget(
        OpenGlucoseApp(
          controller: controller,
          preferences: preferences,
          healthExport: HealthExportController(
            preferences: preferences,
            writesAllowed: false,
          )..initialize(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('record sequence could not be confirmed'),
        findsOneWidget,
      );
      expect(find.text(failure.$2), findsNothing);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();
      expect(find.text(failure.$2), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => controller.disconnect(clearSelection: false));
      expect(store.getString(historyKey), durableBefore);
      expect(
        store.values.values.any(
          (value) =>
              value.contains('counterFailureReason') ||
              value.contains(failure.$1),
        ),
        isFalse,
      );
      controller.dispose();
      await tester.pump();
    });
  }
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

Future<(CgmAppController, SharedPreferences, _MemoryStore, String, String)>
_restoreCounterFailure(String reason) async {
  SharedPreferences.setMockInitialValues({
    'openHealth.onboarding.completed': true,
    'openHealth.appLanguage': 'en',
  });
  final preferences = await SharedPreferences.getInstance();
  final store = _MemoryStore();
  CgmAppController build(_Radio radio) => CgmAppController(
    preferences: preferences,
    healthStateStore: store,
    driver: CbioSensorDriver(
      _Transport(radio),
      credentials: CbioStaticCredentialSource(_credentials),
      timing: _timing,
    ),
  );
  final first = build(
    _Radio(startIndex: 1, rawTime: 12000, currents: [64, 80, 97]),
  );
  await first.initialize();
  await first.connect(_sensor, allowSessionActivation: false);
  await _until(
    () =>
        first.snapshot?.stage == CgmSyncStage.ready &&
        first.snapshot?.history.length == 3,
  );
  await first.disconnect(clearSelection: false);
  final historyKey = store.values.keys.singleWhere(
    (key) => key.startsWith('openHealth.history.cbio.v1.'),
  );
  final durableBefore = store.getString(historyKey)!;
  first.dispose();
  final radio = _Radio(
    startIndex: reason == 'before-checkpoint' ? 2 : 3,
    rawTime: reason == 'before-checkpoint'
        ? 12060
        : reason == 'witness-time-mismatch'
        ? 90000
        : 12120,
    currents: reason == 'before-checkpoint' ? [80, 97] : [97],
  );
  final second = build(radio);
  await second.initialize();
  await second.connect(_sensor, allowSessionActivation: false);
  if (reason == 'archive-time-conflict') {
    await _until(() => second.snapshot?.stage == CgmSyncStage.ready);
    radio.injectRawResponse(startIndex: 3, rawTime: 90000, currents: [97]);
  }
  await _until(() => second.snapshot?.stage == CgmSyncStage.error);
  return (second, preferences, store, historyKey, durableBefore);
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
