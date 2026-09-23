import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/persistence/cbio_history_state.dart';
import 'package:openglucose/src/persistence/cbio_private_state_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fullKey =
    'openHealth.history.cbio.fullRecords.v1.WyJjYmlvIiwic3ludGhldGljIl0';
const _legacyKey = 'openHealth.history.cbio.v1.WyJjYmlvIiwic3ludGhldGljIl0';
const _recoveryKey =
    'openHealth.history.cbio.recovery.v1.WyJjYmlvIiwic3ludGhldGljIl0';
const _nextKey = 'openHealth.history.cbio.fullRecords.v1.WyJjYmlvIiwibmV4dCJd';
const _pointerKey = 'openHealth.lastSensor';
final _credentials = CbioCredentials(
  streamKey: 'CGMTESTKEY000000'.codeUnits,
  authMaterial: 'CGMTESTMATERIAL1'.codeUnits,
  authenticationTrigger: const [0x10, 0x20, 0x30, 0x40, 0x50],
);

DiscoveredSensor _sensor([String key = 'synthetic']) => DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'synthetic-device',
  displayName: 'Synthetic',
  storageKey: key,
  rssi: -50,
  capabilities: CbioSensorDriver.capabilities,
);

CbioSensorDriver _driver(_Store store, _Transport transport) =>
    CbioSensorDriver(
      transport,
      privateStateStore: CbioPrivateStateAdapter(store),
      credentials: CbioStaticCredentialSource(_credentials),
      timing: const CbioSessionTiming(
        authTimeout: Duration(seconds: 1),
        historyWindow: Duration(seconds: 1),
        historyIdleWindow: Duration(milliseconds: 50),
        livePollInterval: Duration(days: 1),
        publishInterval: Duration.zero,
      ),
    );

Future<CgmAppController> _controller(
  _Store store,
  CbioSensorDriver driver,
) async {
  SharedPreferences.setMockInitialValues({});
  final controller = CgmAppController(
    preferences: await SharedPreferences.getInstance(),
    healthStateStore: store,
    driver: driver,
    prepareTarget: driver.prepareTarget,
    flushPrivateState: driver.flushPrivateState,
    historyNamespace: (_) => null,
  );
  await controller.initialize();
  return controller;
}

Map<String, dynamic> _saved(_Store store, [String key = _fullKey]) =>
    jsonDecode(store.values[key]!) as Map<String, dynamic>;

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Synthetic condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

String _legacy() =>
    ' \n${CbioHistoryState(
      sensorKey: 'synthetic',
      checkpoint: const CbioSessionCheckpoint(sensorKey: 'synthetic', index: 1, rawTime: 1000).encode(),
      history: const [CgmReading(valueMgdl: 6.4, rawValue: 64, sensorMinute: 1, source: CgmRecordSource.raw, isDisplayProvisional: true)],
    ).encode()}\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unchanged controller retains terminal session while guarded recovery acquires fresh inputs',
    () async {
      final legacy = _legacy();
      final store = _Store()..values[_legacyKey] = legacy;
      final release = Completer<void>();
      final first = _Link([_row(1, 9000, 315, 0)])..disconnectHold = release;
      final second = _Link([_row(1, 2000, 321, 0)]);
      final transport = _Transport([first, second]);
      final driver = _driver(store, transport);
      final controller = await _controller(store, driver);
      final errors = <CgmSessionSnapshot>[];
      controller.addListener(() {
        final snapshot = controller.snapshot;
        if (snapshot?.stage == CgmSyncStage.error) errors.add(snapshot!);
      });
      try {
        await controller.connect(_sensor());
        await _until(() => controller.snapshot?.stage == CgmSyncStage.error);
        final full = store.values[_fullKey]!;
        expect(
          controller.snapshot?.lastError,
          CbioSessionFailure.counterRestart,
        );
        expect(
          controller
              .snapshot
              ?.metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
        expect(transport.connects, 1);
        expect(store.values[_recoveryKey], isNull);
        store.beforeWrite = (key, value) async {
          if (key == _recoveryKey &&
              ((jsonDecode(value) as Map)['active'] as Map)['state'] ==
                  'pending') {
            expect(first.disconnectCompleted, isTrue);
            expect(transport.connects, 1);
            expect(store.values[_fullKey], full);
          }
        };
        transport.beforeConnect = () {
          expect(first.disconnectCompleted, isTrue);
          expect(
            (_saved(store, _recoveryKey)['active'] as Map)['state'],
            'pending',
          );
        };
        release.complete();
        await _until(() => controller.snapshot?.stage == CgmSyncStage.ready);
        await driver.flushPrivateState();
        expect(transport.connects, 2);
        expect(errors, isNotEmpty);
        expect(second.queries.first, 1);
        expect(controller.snapshot?.latestReading, isNull);
        expect(controller.snapshot?.history, isEmpty);
        expect(controller.snapshot?.rawHistory, isEmpty);
        expect(controller.snapshot?.lastError, isNull);
        expect(store.values[_fullKey], full);
        expect(store.values[_legacyKey], legacy);
        final recovery = _saved(store, _recoveryKey);
        expect(
          recovery['predecessorFullSha256'],
          sha256.convert(utf8.encode(full)).toString(),
        );
        expect(
          recovery['predecessorLegacySha256'],
          sha256.convert(utf8.encode(legacy)).toString(),
        );
        expect((recovery['active'] as Map)['records'], [
          [1, 2000, 0, 321, 7, 64, 5],
        ]);
      } finally {
        if (!release.isCompleted) release.complete();
        await controller.disconnect(clearSelection: false);
        controller.dispose();
      }
      expect(second.disconnectCompleted, isTrue);
    },
  );

  test('read-only prepare cannot adopt or open radio', () async {
    final store = _Store()..values[_legacyKey] = _legacy();
    final before = Map.of(store.values);
    final transport = _Transport([]);
    await _driver(store, transport).prepareTarget(_sensor());
    expect(store.values, before);
    expect(store.writes, isEmpty);
    expect(transport.connects, 0);
  });

  test(
    'old durable drain then in-memory selection then pending commit precede BLE',
    () async {
      final store = _Store();
      final transport = _Transport([
        _Link([_row(1, 1000, 315, 0)]),
        _Link([]),
      ]);
      final driver = _driver(store, transport);
      final controller = await _controller(store, driver);
      final oldEntered = Completer<void>();
      final oldRelease = Completer<void>();
      final pendingEntered = Completer<void>();
      final pendingRelease = Completer<void>();
      Map<String, Object?>? pendingObservation;
      store.beforeWrite = (key, envelope) async {
        if (key == _fullKey &&
            (jsonDecode(envelope) as Map)['state'] == 'observing' &&
            !oldEntered.isCompleted) {
          oldEntered.complete();
          await oldRelease.future;
        }
        if (key == _nextKey) {
          pendingObservation = {
            'drained': oldRelease.isCompleted,
            'oldState': _saved(store)['state'],
            'selected': controller.snapshot?.sensor.storageKey,
            'pointer': store.values[_pointerKey],
          };
          pendingEntered.complete();
          await pendingRelease.future;
        }
      };
      await controller.connect(_sensor());
      await oldEntered.future.timeout(const Duration(seconds: 3));
      final priorPointer = store.values[_pointerKey];
      final connecting = controller.connect(_sensor('next'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(store.values[_nextKey], isNull);
      expect(transport.connects, 1);
      expect(controller.snapshot?.sensor.storageKey, 'synthetic');
      oldRelease.complete();
      await pendingEntered.future.timeout(const Duration(seconds: 3));
      expect(pendingObservation, {
        'drained': true,
        'oldState': 'observing',
        'selected': 'next',
        'pointer': priorPointer,
      });
      expect(store.values[_nextKey], isNull);
      expect(transport.connects, 1);
      pendingRelease.complete();
      await connecting;
      await _until(() => transport.connects == 2);
      expect(_saved(store, _nextKey)['state'], 'pending');
      expect(store.values[_pointerKey], priorPointer);
      expect(store.values['openHealth.sensorArchive'], isNull);
      await controller.disconnect(clearSelection: false);
      controller.dispose();
    },
  );

  test(
    'failed actual old-owner drain prevents new adoption and radio',
    () async {
      final original = _legacy();
      final store = _Store()..values[_legacyKey] = original;
      final transport = _Transport([
        _Link([_row(1, 1000, 315, 0)]),
      ]);
      final driver = _driver(store, transport);
      final controller = await _controller(store, driver);
      store.beforeWrite = (key, envelope) async {
        if (key == _fullKey &&
            (jsonDecode(envelope) as Map)['state'] == 'observing') {
          throw StateError('synthetic write failure');
        }
      };
      await controller.connect(_sensor());
      await _until(() => controller.snapshot?.stage == CgmSyncStage.error);
      await controller.connect(_sensor('next'));
      expect(store.values[_nextKey], isNull);
      expect(transport.connects, 1);
      expect(controller.snapshot?.sensor.storageKey, 'synthetic');
      expect(_saved(store)['state'], 'pending');
      expect(store.values[_legacyKey], original);
      store.beforeWrite = null;
      await controller.disconnect(clearSelection: false);
      controller.dispose();
      expect(_saved(store)['state'], 'observing');
      expect(store.values[_legacyKey], original);
      expect(store.writes, isNot(contains(_legacyKey)));
    },
  );

  test(
    'failed pending commit opens no radio and cannot advance legacy',
    () async {
      final original = _legacy();
      final store = _Store()..values[_legacyKey] = original;
      final transport = _Transport([]);
      store.beforeWrite = (key, _) async {
        if (key == _fullKey) throw StateError('synthetic pending failure');
      };
      final controller = await _controller(store, _driver(store, transport));
      await controller.connect(_sensor());
      await _until(() => controller.snapshot?.stage == CgmSyncStage.error);
      expect(transport.connects, 0);
      expect(store.values[_fullKey], isNull);
      expect(store.values[_legacyKey], original);
      expect(store.values[_pointerKey], isNull);
      store.beforeWrite = null;
      await controller.disconnect(clearSelection: false);
      controller.dispose();
    },
  );

  test(
    'real adapter freezes v1 and resumes full checkpoint with all observed words',
    () async {
      final original = _legacy();
      final store = _Store()..values[_legacyKey] = original;
      final firstLink = _Link([_row(1, 1000, 315, 1), _row(2, 1060, 325, 0)]);
      final first = await _driver(
        store,
        _Transport([firstLink]),
      ).connect(_sensor());
      await _until(
        () =>
            store.values[_fullKey] != null &&
            (_saved(store)['records'] as List).length == 2,
      );
      await first.disconnect();
      final saved = _saved(store);
      expect(saved['records'], [
        [1, 1000, 1, 315, 7, 64, 5],
        [2, 1060, 0, 325, 7, 64, 5],
      ]);
      expect(
        (saved['bootstrap'] as Map)['checkpoint'],
        CbioSessionCheckpoint(
          sensorKey: 'synthetic',
          index: 1,
          rawTime: 1000,
        ).encode(),
      );
      expect(store.values[_legacyKey], original);
      expect(store.writes, isNot(contains(_legacyKey)));
      final captureId = saved['captureId'];
      final secondLink = _Link([_row(2, 1060, 325, 1), _row(3, 1120, 326, 0)]);
      final second = await _driver(
        store,
        _Transport([secondLink]),
      ).connect(_sensor());
      await _until(() => (_saved(store)['records'] as List).length == 3);
      await second.disconnect();
      expect(secondLink.queries.first, 2);
      expect(_saved(store)['captureId'], captureId);
      expect(_saved(store)['records'], [
        [1, 1000, 1, 315, 7, 64, 5],
        [2, 1060, 0, 325, 7, 64, 5],
        [3, 1120, 0, 326, 7, 64, 5],
      ]);
      expect(
        (jsonDecode(_saved(store)['currentCheckpoint'] as String)
            as Map)['index'],
        3,
      );
      expect(store.values[_legacyKey], original);
      expect(second.currentSnapshot.latestReading, isNull);
      expect(second.currentSnapshot.history, isEmpty);
      expect(second.currentSnapshot.rawHistory, isEmpty);
      expect(store.values['openHealth.sensorArchive'], isNull);
      expect(store.values.keys.any((k) => k.contains('.normalized.')), isFalse);
    },
  );

  test(
    'malformed full state fails prepare without falling back to valid v1',
    () async {
      final store = _Store()
        ..values.addAll({_legacyKey: _legacy(), _fullKey: '{malformed'});
      final before = Map.of(store.values);
      final transport = _Transport([]);
      await expectLater(
        _driver(store, transport).prepareTarget(_sensor()),
        throwsException,
      );
      expect(store.values, before);
      expect(store.writes, isEmpty);
      expect(transport.connects, 0);
    },
  );

  test(
    'orphan pending acquisition never supplies another binding bootstrap',
    () async {
      final store = _Store();
      final first = await _driver(
        store,
        _Transport([_Link([])]),
      ).connect(_sensor());
      await _until(() => store.values[_fullKey] != null);
      await first.disconnect();
      final orphan = store.values[_fullKey];
      final nextLink = _Link([]);
      final next = await _driver(
        store,
        _Transport([nextLink]),
      ).connect(_sensor('next'));
      await _until(() => nextLink.queries.isNotEmpty);
      expect(store.values[_fullKey], orphan);
      expect(_saved(store, _nextKey)['bootstrap'], {'kind': 'fresh'});
      expect(
        _saved(store, _nextKey)['captureId'],
        isNot(_saved(store)['captureId']),
      );
      expect(nextLink.queries.first, 1);
      expect(store.values[_pointerKey], isNull);
      await next.disconnect();
    },
  );
}

class _Store implements HealthStateStore {
  final values = <String, String>{};
  final writes = <String>[];
  Future<void> Function(String, String)? beforeWrite;
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async {
    writes.add(key);
    await beforeWrite?.call(key, value);
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

class _Transport implements BleTransport {
  _Transport(this.links);
  final List<_Link> links;
  int connects = 0;
  void Function()? beforeConnect;
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
  }) async {
    beforeConnect?.call();
    return links[connects++];
  }
}

List<int> _row(int index, int time, int temperature, int reindex) {
  final body = [
    0x08,
    1,
    index & 255,
    index >> 8,
    time & 255,
    (time >> 8) & 255,
    (time >> 16) & 255,
    (time >> 24) & 255,
    temperature & 255,
    temperature >> 8,
    7,
    0,
    64,
    0,
    5,
    0,
    reindex & 255,
    reindex >> 8,
  ];
  final head = [body.length + 1, ...body];
  return [...head, (-head.fold<int>(0, (sum, b) => sum + b)) & 255];
}

class _Link implements BleConnection {
  _Link(this.rows);
  final List<List<int>> rows;
  final queries = <int>[];
  Completer<void>? disconnectHold;
  bool disconnectCompleted = false;
  final _states = StreamController<BleConnectionState>.broadcast();
  final _notifications = StreamController<List<int>>.broadcast();
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
      uuid: '180a',
      characteristics: [
        BleCharacteristicRef(
          serviceUuid: '180a',
          characteristicUuid: CbioUuids.serial,
          properties: BleCharacteristicProperties(read: true),
        ),
      ],
    ),
  ];
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
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final plain = unmaskCbioFrame(value, key: _credentials.streamKey);
    if (plain[1] == 1) _emit([4, 1, 1, 0, 0xfa]);
    if (plain[1] == 8) {
      queries.add(plain[2] | (plain[3] << 8));
      rows.forEach(_emit);
    }
  }

  void _emit(List<int> frame) =>
      _notifications.add(maskCbioFrame(frame, key: _credentials.streamKey));
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
  Future<void> disconnect() async {
    await disconnectHold?.future;
    await _states.close();
    await _notifications.close();
    disconnectCompleted = true;
  }
}
