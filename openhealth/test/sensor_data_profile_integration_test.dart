import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _receiptProfile = CgmSensorDataProfile(
  timestampBasis: CgmReadingTimestampBasis.receivedAt,
  duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
  currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
  retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'registry routes profiles by ID without transport or driver I/O',
    () async {
      const overrideProfile = CgmSensorDataProfile(warmupMinutes: 17);
      final transport = _UnusedTransport();
      final receiptDriver = _ProfileDriver(
        'synthetic-receipt',
        _receiptProfile,
      );
      final overrideDriver = _ProfileDriver('yuwell-anytime', overrideProfile);
      final legacyDriver = _TestDriver('synthetic-legacy');
      final drivers = [receiptDriver, overrideDriver, legacyDriver];
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: [
          for (final driver in drivers)
            CgmDriverRegistration(
              driver: driver,
              scanServiceUuids: const ['181F'],
              discover: (_) => null,
            ),
        ],
      );
      final controller = CgmAppController(
        preferences: await SharedPreferences.getInstance(),
        driver: registry,
        healthStateStore: _MemoryStore(),
      );
      addTearDown(controller.dispose);

      expect(
        registry.sensorDataProfileFor('synthetic-receipt'),
        _receiptProfile,
      );
      expect(registry.sensorDataProfileFor('yuwell-anytime'), overrideProfile);
      expect(registry.sensorDataProfileFor('synthetic-legacy'), isNull);
      expect(registry.sensorDataProfileFor('synthetic-unknown'), isNull);
      expect(
        controller.sensorDataProfileFor('synthetic-receipt'),
        _receiptProfile,
      );
      // An explicit provider wins even when a compatibility catalog entry exists.
      expect(
        controller.sensorDataProfileFor('yuwell-anytime'),
        overrideProfile,
      );
      expect(
        controller.sensorDataProfileFor('synthetic-legacy'),
        CgmSensorDataProfile.legacy,
      );
      expect(
        controller.sensorDataProfileFor('synthetic-unknown'),
        CgmSensorDataProfile.legacy,
      );
      expect(transport.calls, 0);
      expect(drivers.every((driver) => driver.connectCalls == 0), isTrue);
      expect(drivers.every((driver) => driver.scanCalls == 0), isTrue);
    },
  );

  for (final basis in [
    CgmReadingTimestampBasis.receivedAt,
    CgmReadingTimestampBasis.acquisitionRelative,
  ]) {
    final profile = CgmSensorDataProfile(
      timestampBasis: basis,
      duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
      currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
      retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
    );
    test(
      '$basis profile retains first samples without cached current '
      'or inferred lifecycle',
      () async {
        final sensor = _sensor('synthetic-receipt');
        final firstAt = DateTime.now().toUtc().subtract(
          const Duration(days: 20),
        );
        final first = _reading(100, 100, firstAt, provisional: true);
        final second = _reading(
          101,
          101,
          firstAt.add(const Duration(minutes: 1)),
          provisional: true,
        );
        final store = _MemoryStore({
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          _historyKey(sensor): jsonEncode([first.toJson(), second.toJson()]),
        });
        final session = _TestSession(_snapshot(sensor));
        final driver = _ProfileDriver(
          sensor.driverId,
          profile,
          session: session,
        );
        final preferences = await SharedPreferences.getInstance();
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        var controllerDisposed = false;
        addTearDown(() async {
          if (!controllerDisposed) controller.dispose();
          await session.close();
        });

        await controller.initialize();
        expect(controller.snapshot?.stage, CgmSyncStage.connecting);
        expect(controller.snapshot?.sessionInfo.sessionStart, isNull);
        expect(controller.archivedSensors, isEmpty);
        _expectReadings(controller.visibleHistory, [first, second]);
        expect(controller.latestReading, isNull);
        expect(controller.displayLatestReading, isNull);
        await controller.connect(sensor, allowSessionActivation: false);

        final repeated = _reading(
          220,
          101,
          DateTime.now().toUtc(),
          provisional: true,
        );
        final next = _reading(
          102,
          102,
          repeated.recordedAt!.add(const Duration(minutes: 1)),
          provisional: true,
        );
        session.emit(
          _snapshot(
            sensor,
            stage: CgmSyncStage.ready,
            history: [repeated, next],
            latest: repeated,
          ),
        );
        await _drainEvents();
        _expectReadings(controller.visibleHistory, [first, second, next]);
        expect(controller.latestReading?.toJson(), second.toJson());
        expect(controller.latestReading?.recordedAt, second.recordedAt);
        expect(controller.snapshot?.sessionInfo.sessionStart, isNull);
        expect(controller.allHistoricalReadings, isEmpty);

        // A ready stage with history but no live sample is not current data.
        session.emit(_snapshot(sensor, stage: CgmSyncStage.ready));
        _expectReadings(controller.visibleHistory, [first, second, next]);
        expect(controller.latestReading, isNull);
        expect(controller.displayLatestReading, isNull);
        // Nor may a non-ready stage expose a cached latestReading field.
        session.emit(_snapshot(sensor, latest: next));
        expect(controller.latestReading, isNull);
        expect(controller.displayLatestReading, isNull);
        await controller.disconnect(clearSelection: false);
        controller.dispose();
        controllerDisposed = true;

        final restored = CgmAppController(
          preferences: preferences,
          driver: _ProfileDriver(sensor.driverId, profile),
          healthStateStore: store,
        );
        addTearDown(restored.dispose);
        await restored.initialize();
        expect(restored.snapshot?.stage, CgmSyncStage.connecting);
        expect(restored.snapshot?.sessionInfo.sessionStart, isNull);
        _expectReadings(restored.visibleHistory, [first, second, next]);
        expect(restored.latestReading, isNull);
        expect(restored.displayLatestReading, isNull);
        expect(restored.archivedSensors, isEmpty);
        expect(restored.allHistoricalReadings, isEmpty);
        expect(driver.connectCalls, 1);
        expect(session.historySyncCalls, 0);
      },
    );
  }

  test(
    'failed reconnect keeps profile warmup through error and archive',
    () async {
      final sensor = _sensor('synthetic-short-warmup');
      final start = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      final readings = [
        for (final minute in [45, 59])
          _reading(100, minute, start.add(Duration(minutes: minute))),
      ];
      final store = _MemoryStore({
        'openHealth.lastSensor': jsonEncode(sensor.toJson()),
        _historyKey(sensor): jsonEncode([
          for (final reading in readings) reading.toJson(),
        ]),
      });
      // No fake session: connect throws before a live snapshot is available.
      final driver = _ProfileDriver(
        sensor.driverId,
        const CgmSensorDataProfile(warmupMinutes: 45),
      );
      final controller = CgmAppController(
        preferences: await SharedPreferences.getInstance(),
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.snapshot?.sessionInfo.warmupMinutes, 45);
      _expectReadings(controller.visibleHistory, readings);

      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectCalls, 1);
      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(controller.snapshot?.sessionInfo.warmupMinutes, 45);
      _expectReadings(controller.visibleHistory, readings);
      await controller.disconnect();

      final archive = controller.archivedSensors.single;
      expect(archive.warmupMinutes, 45);
      _expectReadings(controller.readingsForArchivedSensor(archive), readings);
      _expectReadings(
        controller.displayReadingsForArchivedSensor(archive),
        readings,
      );
      _expectReadings(controller.allHistoricalReadings, readings);
      expect(store.getString('openHealth.lastSensor'), isNull);
    },
  );

  test(
    'legacy Yuwell archive uses its 45-minute warmup without a driver',
    () async {
      final sensor = _sensor('yuwell-anytime');
      final start = DateTime.utc(2026, 1, 1);
      final readings = [
        for (final minute in [44, 45, 59])
          _reading(
            100 + minute.toDouble(),
            minute,
            start.add(Duration(minutes: minute)),
          ),
      ];
      final archive = ArchivedSensorSession(
        id: 'synthetic-legacy-archive',
        historyKey: 'synthetic-legacy-history',
        storageKey: sensor.storageKey,
        driverId: sensor.driverId,
        deviceId: sensor.deviceId,
        displayName: sensor.displayName,
        reason: SensorArchiveReason.disconnected,
        readingCount: readings.length,
        startedAt: start,
      );
      expect(archive.toJson().containsKey('warmupMinutes'), isFalse);
      final controller = CgmAppController(
        preferences: await SharedPreferences.getInstance(),
        driver: _TestDriver('synthetic-unrelated'),
        healthStateStore: _MemoryStore({
          'openHealth.sensorArchive': jsonEncode([archive.toJson()]),
          archive.historyKey: jsonEncode(
            readings.map((reading) => reading.toJson()).toList(),
          ),
        }),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final restored = controller.archivedSensors.single;
      expect(restored.warmupMinutes, isNull);
      expect(
        controller.sensorDataProfileFor('yuwell-anytime').warmupMinutes,
        45,
      );
      _expectReadings(controller.readingsForArchivedSensor(restored), readings);
      _expectReadings(
        controller.displayReadingsForArchivedSensor(restored),
        readings.skip(1),
      );
      _expectReadings(controller.allHistoricalReadings, readings.skip(1));
      expect(controller.snapshot, isNull);
    },
  );

  test(
    'archive persists reported warmup when its arbitrary driver is absent',
    () async {
      final sensor = _sensor('synthetic-reported-warmup');
      final start = DateTime.now().toUtc().subtract(const Duration(hours: 3));
      final readings = [
        for (final minute in [16, 17, 59])
          _reading(
            100 + minute.toDouble(),
            minute,
            start.add(Duration(minutes: minute)),
          ),
      ];
      final session = _TestSession(
        _snapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: readings,
          latest: readings.last,
          info: CgmSessionInfo(
            sessionStart: start,
            warmupMinutes: 17,
            sensorVariant: const CgmSensorVariant(
              protocolFamily: 'synthetic-family',
              source: CgmSensorVariantSource.deviceInformation,
              model: 'Synthetic model',
              softwareRevision: 'future-release',
            ),
          ),
        ),
      );
      final driver = _ProfileDriver(
        sensor.driverId,
        const CgmSensorDataProfile(warmupMinutes: 90),
        session: session,
      );
      final preferences = await SharedPreferences.getInstance();
      final store = _MemoryStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      var controllerDisposed = false;
      addTearDown(() async {
        if (!controllerDisposed) controller.dispose();
        await session.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEvents();
      _expectReadings(controller.visibleHistory, readings.skip(1));
      await controller.disconnect();
      final archive = controller.archivedSensors.single;
      expect(archive.warmupMinutes, 17);
      expect(archive.sensorVariant?.softwareRevision, 'future-release');
      expect(archive.model, 'Synthetic model');
      expect(archive.sensorVariant?.region, isNull);
      final manifest =
          jsonDecode(store.getString('openHealth.sensorArchive')!) as List;
      expect((manifest.single as Map)['warmupMinutes'], 17);
      expect(store.getString('openHealth.lastSensor'), isNull);
      controller.dispose();
      controllerDisposed = true;

      final unavailableDriver = _TestDriver('synthetic-unrelated');
      final restored = CgmAppController(
        preferences: preferences,
        driver: unavailableDriver,
        healthStateStore: store,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      final restoredArchive = restored.archivedSensors.single;
      // The compatibility fallback is 60; the recorded session's 17 wins.
      expect(restored.sensorDataProfileFor(sensor.driverId).warmupMinutes, 60);
      expect(restoredArchive.warmupMinutes, 17);
      expect(
        restoredArchive.sensorVariant?.toJson(),
        archive.sensorVariant!.toJson(),
      );
      _expectReadings(
        restored.readingsForArchivedSensor(restoredArchive),
        readings,
      );
      _expectReadings(
        restored.displayReadingsForArchivedSensor(restoredArchive),
        readings.skip(1),
      );
      _expectReadings(restored.allHistoricalReadings, readings.skip(1));
      expect(restored.snapshot, isNull);
      expect(unavailableDriver.connectCalls, 0);
    },
  );
}

DiscoveredSensor _sensor(String driverId) => DiscoveredSensor(
  driverId: driverId,
  deviceId: 'synthetic-device',
  displayName: 'Synthetic sensor',
  storageKey: 'synthetic-storage',
  rssi: -45,
  capabilities: const CgmCapabilities(supportsDirectBle: true),
);

CgmReading _reading(
  double value,
  int minute,
  DateTime at, {
  bool provisional = false,
}) => CgmReading(
  valueMgdl: value,
  sensorMinute: minute,
  recordedAt: at,
  source: CgmRecordSource.vendor,
  isDisplayProvisional: provisional,
);

CgmSessionSnapshot _snapshot(
  DiscoveredSensor sensor, {
  CgmSyncStage stage = CgmSyncStage.connecting,
  List<CgmReading> history = const [],
  CgmReading? latest,
  CgmSessionInfo info = const CgmSessionInfo(),
}) => CgmSessionSnapshot(
  stage: stage,
  statusText: stage.name,
  sensor: sensor,
  capabilities: sensor.capabilities,
  history: history,
  latestReading: latest,
  sessionInfo: info,
);

String _historyKey(DiscoveredSensor sensor) {
  final identity = base64Url
      .encode(utf8.encode(jsonEncode([sensor.driverId, sensor.storageKey])))
      .replaceAll('=', '');
  return 'openHealth.history.v2.$identity';
}

void _expectReadings(
  Iterable<CgmReading> actual,
  Iterable<CgmReading> expected,
) {
  expect(
    actual.map((reading) => reading.toJson()),
    expected.map((reading) => reading.toJson()),
  );
}

Future<void> _drainEvents() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _TestDriver implements CgmDriver {
  _TestDriver(this.driverId, {this.session});

  @override
  final String driverId;
  final _TestSession? session;
  int connectCalls = 0;
  int scanCalls = 0;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCalls++;
    return session ?? (throw StateError('Unexpected synthetic connection'));
  }

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    scanCalls++;
    return const Stream.empty();
  }
}

class _ProfileDriver extends _TestDriver
    implements CgmSensorDataProfileProvider {
  _ProfileDriver(super.driverId, this.sensorDataProfile, {super.session});

  @override
  final CgmSensorDataProfile sensorDataProfile;
}

class _TestSession implements CgmSession {
  _TestSession(this._snapshot);

  CgmSessionSnapshot _snapshot;
  final _snapshots = StreamController<CgmSessionSnapshot>.broadcast(sync: true);
  int historySyncCalls = 0;

  void emit(CgmSessionSnapshot next) {
    _snapshot = next;
    _snapshots.add(next);
  }

  Future<void> close() => _snapshots.close();

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;
  @override
  DiscoveredSensor get sensor => _snapshot.sensor;
  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<CgmLogEntry> get logs => const Stream.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async => const [];
  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => const [];
  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) => throw StateError('Unexpected synthetic calibration');
  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    historySyncCalls++;
  }
}

class _MemoryStore implements HealthStateStore {
  _MemoryStore([Map<String, String> seed = const {}]) : _values = {...seed};

  final Map<String, String> _values;
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => _values[key];
  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;
  @override
  Future<void> remove(String key) async => _values.remove(key);
}

class _UnusedTransport implements BleTransport {
  int calls = 0;

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    calls++;
    throw StateError('Unexpected physical connection');
  }

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    calls++;
    throw StateError('Unexpected physical scan');
  }
}
