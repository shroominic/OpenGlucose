import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('does not persist an unverified sensor selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final store = _ControllableHealthStateStore();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );

    await controller.initialize();
    await controller.connect(sensor);
    await _drainEventQueue();

    expect(store.getString('openHealth.lastSensor'), isNull);
    expect(
      driver
          .connectedSensors
          .single
          .metadata[cgmAllowSessionActivationMetadataKey],
      'true',
    );

    controller.dispose();
    await driver.close();
  });

  test('promotes a ready sensor to the durable selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final store = _ControllableHealthStateStore();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(_testSnapshot(sensor, stage: CgmSyncStage.ready));
    await _drainEventQueue();

    final persisted =
        jsonDecode(
              store.getString('openHealth.lastSensor')!,
            )
            as Map<String, dynamic>;
    expect(persisted['storageKey'], sensor.storageKey);
    expect(
      persisted['metadata'],
      isNot(contains(cgmAllowSessionActivationMetadataKey)),
    );

    controller.dispose();
    await driver.close();
  });

  test(
    'activation-required state clears selection without creating an archive',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      final reading = _reading(
        valueMgdl: 118,
        sensorMinute: 15,
        recordedAt: DateTime.now(),
      );

      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          history: <CgmReading>[reading],
          metadata: const <String, String>{'activationRequired': 'true'},
        ),
      );
      await _drainEventQueue();

      expect(controller.snapshot, isNull);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(store.getString('openHealth.sensorArchive'), isNull);
      expect(
        store.getString('openHealth.history.${sensor.storageKey}'),
        isNull,
      );
      expect(
        store.setAttempts.where(
          (key) => key.startsWith('openHealth.history.archive.'),
        ),
        isEmpty,
      );

      controller.dispose();
      await driver.close();
    },
  );

  for (final failure in <({String label, bool archiveWrite})>[
    (label: 'archive manifest write', archiveWrite: true),
    (label: 'active pointer removal', archiveWrite: false),
  ]) {
    test(
      '${failure.label} failure preserves a retryable disconnected selection',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _testSensor();
        final reading = _reading(
          valueMgdl: 121,
          sensorMinute: 30,
          recordedAt: DateTime.now(),
        );
        final session = _ControlledSession(
          _testSnapshot(
            sensor,
            stage: CgmSyncStage.ready,
            history: <CgmReading>[reading],
            sessionInfo: CgmSessionInfo(
              sessionStart: reading.recordedAt!.subtract(
                const Duration(minutes: 30),
              ),
            ),
          ),
        );
        final driver = _ControlledDriver(<_ControlledSession>[session]);
        final store = _ControllableHealthStateStore();
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );

        await controller.initialize();
        await controller.connect(sensor);
        await _drainEventQueue();
        expect(store.getString('openHealth.lastSensor'), isNotNull);

        if (failure.archiveWrite) {
          store.failSetPrefix = 'openHealth.sensorArchive';
        } else {
          store.failRemovePrefix = 'openHealth.lastSensor';
        }
        await controller.disconnect();

        expect(controller.snapshot?.stage, CgmSyncStage.disconnected);
        expect(
          controller.snapshot?.statusText,
          'Disconnected — could not archive sensor',
        );
        expect(store.getString('openHealth.lastSensor'), isNotNull);
        expect(controller.lastError, contains('Clearing the selected sensor'));

        store.failSetPrefix = null;
        store.failRemovePrefix = null;
        await controller.disconnect();

        expect(controller.snapshot, isNull);
        expect(store.getString('openHealth.lastSensor'), isNull);
        expect(controller.archivedSensors, hasLength(1));
        expect(
          controller.readingsForArchivedSensor(
            controller.archivedSensors.single,
          ),
          hasLength(1),
        );

        controller.dispose();
        await driver.close();
      },
    );
  }

  test(
    'active history dedupes rebased timestamps by source and sensor minute',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final now = DateTime.now();
      final persistedReading = _reading(
        valueMgdl: 111,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 5)),
      );
      final rebasedReading = _reading(
        valueMgdl: 124,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 4)),
      );
      final otherSourceReading = CgmReading(
        valueMgdl: 126,
        source: CgmRecordSource.broadcast,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 4)),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final store = _ControllableHealthStateStore();
      await store.setString(
        'openHealth.lastSensor',
        jsonEncode(sensor.toJson()),
      );
      await store.setString(
        'openHealth.history.${sensor.storageKey}',
        jsonEncode(<Object?>[persistedReading.toJson()]),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[rebasedReading, otherSourceReading],
        ),
      );
      await _drainEventQueue();

      final history = controller.snapshot!.history;
      expect(history, hasLength(2));
      final vendorReadings = history
          .where((reading) => reading.source == CgmRecordSource.vendor)
          .toList(growable: false);
      expect(vendorReadings, hasLength(1));
      expect(vendorReadings.single.valueMgdl, rebasedReading.valueMgdl);
      expect(vendorReadings.single.recordedAt, rebasedReading.recordedAt);
      expect(
        history.where(
          (reading) => reading.source == CgmRecordSource.broadcast,
        ),
        hasLength(1),
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'same-id rearchive merges history and preserves session metadata',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor(metadata: const <String, String>{});
      final sessionStart = DateTime.now().subtract(const Duration(days: 1));
      final firstReading = _reading(
        valueMgdl: 101,
        sensorMinute: 60,
        recordedAt: sessionStart.add(const Duration(minutes: 60)),
      );
      final secondReading = _reading(
        valueMgdl: 139,
        sensorMinute: 120,
        recordedAt: sessionStart.add(const Duration(minutes: 120)),
      );
      final firstSession = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[firstReading],
          sessionInfo: CgmSessionInfo(
            serial: 'SERIAL-ONE',
            model: 'MODEL-ONE',
            firmware: 'FW-ONE',
            sessionStart: sessionStart,
          ),
        ),
      );
      final secondSession = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[secondReading],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[
        firstSession,
        secondSession,
      ]);
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(sensor);
      await controller.disconnect(archiveReason: SensorArchiveReason.replaced);
      await controller.connect(sensor);
      await controller.disconnect();

      expect(controller.archivedSensors, hasLength(1));
      final archived = controller.archivedSensors.single;
      expect(archived.serial, 'SERIAL-ONE');
      expect(archived.model, 'MODEL-ONE');
      expect(archived.firmware, 'FW-ONE');
      expect(archived.reason, SensorArchiveReason.replaced);
      expect(archived.startedAt, sessionStart);
      expect(archived.readingCount, 2);
      expect(
        controller
            .readingsForArchivedSensor(archived)
            .map((reading) => reading.valueMgdl),
        <double>[101, 139],
      );

      controller.dispose();
      await driver.close();
    },
  );

  test('surfaces a debounced history persistence failure', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failSetPrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    await controller.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(controller.lastError, contains('Saving history failed'));
    expect(controller.lastError, contains('StateError'));
    expect(
      controller.logs.any(
        (entry) => entry.message.contains('Saving history failed'),
      ),
      isTrue,
    );

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test('does not report a failed history deletion as successful', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failRemovePrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    final cleared = await controller.clearPersistedHistory();

    expect(cleared, isFalse);
    expect(store.removeAttempts, contains('openHealth.history.demo:07A12'));
    expect(controller.lastError, contains('Clearing stored history failed'));

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test(
    'a history write does not clear an unrelated deletion failure',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore(
        failRemovePrefix: 'openHealth.history.',
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ProductionTestDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(await controller.clearPersistedHistory(), isFalse);
      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
    },
  );

  test(
    'disconnect still clears private state when BLE teardown fails',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _DisconnectFailingDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(store.getString('openHealth.lastSensor'), isNotNull);

      await controller.disconnect();

      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.snapshot, isNull);
      expect(
        controller.lastError,
        contains('Disconnecting sensor session failed'),
      );
      expect(
        controller.logs.any(
          (entry) => entry.message.contains(
            'Disconnecting sensor session failed (StateError)',
          ),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );
}

class _ProductionTestDriver implements CgmDriver {
  final DemoCgmDriver _delegate = DemoCgmDriver();

  @override
  String get driverId => _delegate.driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    return _delegate.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
    );
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    return _delegate.connect(sensor);
  }
}

class _DisconnectFailingDriver extends _ProductionTestDriver {
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    return _DisconnectFailingSession(await super.connect(sensor));
  }
}

class _DisconnectFailingSession implements CgmSession {
  _DisconnectFailingSession(this._delegate);

  final CgmSession _delegate;

  @override
  CgmSessionSnapshot get currentSnapshot => _delegate.currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => _delegate.logs;

  @override
  DiscoveredSensor get sensor => _delegate.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _delegate.snapshots;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => _delegate.unsafeAdmin;

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() {
    return _delegate.fetchCalibrations();
  }

  @override
  Future<void> refresh() => _delegate.refresh();

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() {
    return _delegate.refreshDiagnostics();
  }

  @override
  Future<void> refreshLiveData() => _delegate.refreshLiveData();

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) {
    return _delegate.submitCalibration(
      glucoseMgdl: glucoseMgdl,
      sensorMinute: sensorMinute,
      recordedAt: recordedAt,
    );
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) {
    return _delegate.syncHistory(
      includeRawHistory: includeRawHistory,
      requestedStartOffset: requestedStartOffset,
    );
  }

  @override
  Future<void> disconnect() async {
    await _delegate.disconnect();
    throw StateError('simulated BLE teardown failure');
  }
}

class _ControllableHealthStateStore implements HealthStateStore {
  _ControllableHealthStateStore({this.failSetPrefix, this.failRemovePrefix});

  String? failSetPrefix;
  String? failRemovePrefix;
  final Map<String, String> _values = <String, String>{};
  final List<String> setAttempts = <String>[];
  final List<String> removeAttempts = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    setAttempts.add(key);
    if (failSetPrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state write failure');
    }
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removeAttempts.add(key);
    if (failRemovePrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state delete failure');
    }
    _values.remove(key);
  }
}

DiscoveredSensor _testSensor({
  Map<String, String> metadata = const <String, String>{'serial': 'TEST-1'},
}) {
  return DiscoveredSensor(
    driverId: 'controlled',
    deviceId: 'controlled-device',
    displayName: 'Controlled sensor',
    storageKey: 'controlled:test-1',
    rssi: -45,
    capabilities: const CgmCapabilities(supportsHistory: true),
    metadata: metadata,
  );
}

CgmReading _reading({
  required double valueMgdl,
  required int sensorMinute,
  required DateTime recordedAt,
}) {
  return CgmReading(
    valueMgdl: valueMgdl,
    source: CgmRecordSource.vendor,
    sensorMinute: sensorMinute,
    recordedAt: recordedAt,
  );
}

CgmSessionSnapshot _testSnapshot(
  DiscoveredSensor sensor, {
  required CgmSyncStage stage,
  List<CgmReading> history = const <CgmReading>[],
  CgmSessionInfo sessionInfo = const CgmSessionInfo(),
  Map<String, String> metadata = const <String, String>{},
}) {
  return CgmSessionSnapshot(
    stage: stage,
    statusText: stage.name,
    sensor: sensor,
    capabilities: sensor.capabilities,
    history: history,
    latestReading: history.isEmpty ? null : history.last,
    sessionInfo: sessionInfo,
    metadata: metadata,
  );
}

Future<void> _drainEventQueue() async {
  for (var index = 0; index < 12; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ControlledDriver implements CgmDriver {
  _ControlledDriver(this._sessions);

  final List<_ControlledSession> _sessions;
  final List<DiscoveredSensor> connectedSensors = <DiscoveredSensor>[];
  int _nextSession = 0;

  @override
  String get driverId => 'controlled';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectedSensors.add(sensor);
    return _sessions[_nextSession++];
  }

  Future<void> close() async {
    for (final session in _sessions) {
      await session.close();
    }
  }
}

class _ControlledSession implements CgmSession {
  _ControlledSession(this._current);

  CgmSessionSnapshot _current;
  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);

  void emit(CgmSessionSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  Future<void> close() => _snapshots.close();

  @override
  CgmSessionSnapshot get currentSnapshot => _current;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  DiscoveredSensor get sensor => _current.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}
