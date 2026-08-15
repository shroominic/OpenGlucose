import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('scan preserves a structured Bluetooth-off failure safely', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _FailingScanDriver(
      BleFailure(
        kind: BleFailureKind.bluetoothOff,
        operation: BleOperation.adapter,
        diagnosticCode: 'test.adapter.off',
      ),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: PreferencesHealthStateStore(preferences),
    );

    await controller.initialize();
    await controller.scan();

    expect(controller.scanFailure?.kind, BleFailureKind.bluetoothOff);
    expect(controller.scanFailure?.operation, BleOperation.adapter);
    expect(controller.lastError, contains('Bluetooth is off'));
    expect(controller.lastError, isNot(contains('StateError')));
    expect(controller.lastError, isNot(contains('BleFailure')));

    controller.dispose();
  });

  test('unstructured scan failures never expose exception types', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: _FailingScanDriver(
        StateError('native adapter failure with private details'),
      ),
      healthStateStore: PreferencesHealthStateStore(preferences),
    );

    await controller.initialize();
    await controller.scan();

    expect(controller.scanFailure, isNull);
    expect(
      controller.lastError,
      'Sensor scan could not be completed. Check Bluetooth and try again.',
    );
    expect(controller.lastError, isNot(contains('StateError')));
    expect(controller.lastError, isNot(contains('private details')));

    controller.dispose();
  });

  testWidgets('Bluetooth-off scan shows enable guidance and retry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final stateStore = PreferencesHealthStateStore(preferences);
    final driver = _FailingScanDriver(
      BleFailure(
        kind: BleFailureKind.bluetoothOff,
        operation: BleOperation.adapter,
        diagnosticCode: 'test.adapter.off',
      ),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: stateStore,
    );
    await controller.initialize();

    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(
          preferences: preferences,
          healthStateStore: stateStore,
          writesAllowed: false,
        )..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('scanSensorsButton')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sensorScanFailureTitle')),
      findsOneWidget,
    );
    expect(find.text('Bluetooth is off'), findsOneWidget);
    expect(find.textContaining('quick settings or Settings'), findsOneWidget);
    expect(find.textContaining('try scanning again'), findsOneWidget);
    expect(find.textContaining('No sensors found yet'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('BleFailure'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('retrySensorScanButton')),
    );
    await tester.pumpAndSettle();
    expect(driver.scanCalls, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('partial scan results stay visible with an inline failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final stateStore = PreferencesHealthStateStore(preferences);
    final driver = _PartialFailingScanDriver(
      sensor: _sensor('partial'),
      failure: BleFailure(
        kind: BleFailureKind.bluetoothOff,
        operation: BleOperation.scan,
        diagnosticCode: 'test.scan.off',
      ),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: stateStore,
    );
    await controller.initialize();

    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(
          preferences: preferences,
          healthStateStore: stateStore,
          writesAllowed: false,
        )..initialize(),
        preferences: preferences,
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('scanSensorsButton')));
    await tester.pumpAndSettle();

    expect(find.text('Sensor partial'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('sensorScanInlineFailure')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('retryPartialSensorScanButton')),
      findsOneWidget,
    );
    expect(find.textContaining('No sensors found yet'), findsNothing);
    expect(controller.sensors, hasLength(1));
    expect(controller.scanFailure?.kind, BleFailureKind.bluetoothOff);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test(
    'a retry supersedes late results and errors from the old scan',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _ControlledScanDriver();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
      );
      await controller.initialize();

      final firstScan = controller.scan();
      await _drainEventQueue();
      final first = driver.scans.single;
      first.add(_sensor('old'));
      await _drainEventQueue();
      expect(controller.sensors.single.displayName, 'Sensor old');

      final secondScan = controller.scan();
      await _drainEventQueue();
      final second = driver.scans.last;
      expect(controller.sensors, isEmpty);

      first.addError(
        BleFailure(
          kind: BleFailureKind.bluetoothOff,
          operation: BleOperation.scan,
          diagnosticCode: 'test.old.off',
        ),
      );
      await first.close();
      await _drainEventQueue();

      expect(controller.scanning, isTrue);
      expect(controller.scanFailure, isNull);
      expect(controller.sensors, isEmpty);

      second.add(_sensor('new'));
      await second.close();
      await Future.wait(<Future<void>>[firstScan, secondScan]);

      expect(controller.scanning, isFalse);
      expect(controller.scanFailure, isNull);
      expect(
        controller.sensors.map((sensor) => sensor.displayName),
        <String>['Sensor new'],
      );

      controller.dispose();
    },
  );

  test(
    'connecting invalidates a scan before its late failure arrives',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _ControlledScanDriver();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
      );
      await controller.initialize();

      final scan = controller.scan();
      await _drainEventQueue();
      final oldScan = driver.scans.single;
      final connectedSensor = _sensor('connected');
      await controller.connect(connectedSensor);

      oldScan.add(_sensor('late'));
      oldScan.addError(
        BleFailure(
          kind: BleFailureKind.bluetoothOff,
          operation: BleOperation.scan,
          diagnosticCode: 'test.late.off',
        ),
      );
      await oldScan.close();
      await scan;
      await _drainEventQueue();

      expect(controller.snapshot?.sensor.deviceId, connectedSensor.deviceId);
      expect(controller.scanFailure, isNull);
      expect(controller.scanning, isFalse);
      expect(
        controller.sensors.where((sensor) => sensor.deviceId == 'device-late'),
        isEmpty,
      );

      controller.dispose();
    },
  );
}

class _FailingScanDriver implements CgmDriver {
  _FailingScanDriver(this.failure);

  final Object failure;
  int scanCalls = 0;

  @override
  String get driverId => 'failing-scan';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    scanCalls += 1;
    Error.throwWithStackTrace(failure, StackTrace.current);
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw UnsupportedError('This driver only exercises scan failures.');
  }
}

class _PartialFailingScanDriver implements CgmDriver {
  _PartialFailingScanDriver({required this.sensor, required this.failure});

  final DiscoveredSensor sensor;
  final Object failure;

  @override
  String get driverId => 'failing-scan';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    yield sensor;
    Error.throwWithStackTrace(failure, StackTrace.current);
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw UnsupportedError('This driver only exercises scan failures.');
  }
}

class _ControlledScanDriver implements CgmDriver {
  final List<StreamController<DiscoveredSensor>> scans =
      <StreamController<DiscoveredSensor>>[];

  @override
  String get driverId => 'controlled-scan';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    final controller = StreamController<DiscoveredSensor>();
    scans.add(controller);
    return controller.stream;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _StaticSession(sensor);
}

class _StaticSession implements CgmSession {
  _StaticSession(DiscoveredSensor sensor)
    : _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Connected',
        sensor: sensor,
        capabilities: sensor.capabilities,
      );

  final CgmSessionSnapshot _snapshot;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  DiscoveredSensor get sensor => _snapshot.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      const Stream<CgmSessionSnapshot>.empty();

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

DiscoveredSensor _sensor(String id) => DiscoveredSensor(
  driverId: 'controlled-scan',
  deviceId: 'device-$id',
  displayName: 'Sensor $id',
  storageKey: 'sensor:$id',
  rssi: -48,
  capabilities: const CgmCapabilities(supportsDirectBle: true),
);

Future<void> _drainEventQueue() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
