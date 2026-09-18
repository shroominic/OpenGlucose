import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/display_awake_gate.dart';
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

  testWidgets('a terminal scan error completes under widget fake async', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: _FailingScanDriver(
        BleFailure(
          kind: BleFailureKind.bluetoothOff,
          operation: BleOperation.scan,
          diagnosticCode: 'test.scan.terminal',
        ),
      ),
      healthStateStore: PreferencesHealthStateStore(preferences),
    );
    await controller.initialize();

    var completed = false;
    final scan = controller.scan().whenComplete(() => completed = true);
    await tester.pump();
    await tester.pump();

    expect(completed, isTrue);
    expect(controller.scanning, isFalse);
    await scan;
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
    await _startNearbySensorScan(tester);
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
    await _startNearbySensorScan(tester);
    await tester.pumpAndSettle();

    expect(find.text('Supported sensor'), findsOneWidget);
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
      expect(controller.sensors.map((sensor) => sensor.displayName), <String>[
        'Sensor new',
      ]);

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

  test('a failed scan replacement is contained and does not rescan', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _CancelFailingScanDriver();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: PreferencesHealthStateStore(preferences),
    );
    await controller.initialize();

    final firstScan = controller.scan();
    await _drainEventQueue();
    expect(driver.scanCalls, 1);

    await controller.scan();

    expect(driver.scanCalls, 1);
    expect(controller.scanning, isFalse);
    expect(controller.scanFailure, isNull);
    expect(
      controller.lastError,
      'Sensor scan could not be completed. Check Bluetooth and try again.',
    );
    await firstScan.timeout(const Duration(seconds: 1));
    controller.dispose();
  });

  test(
    'back-to-back scans start only the newest stream and cancel once',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _CancellationTrackedScanDriver();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
      );
      await controller.initialize();

      final initialScan = controller.scan();
      await _drainEventQueue();
      expect(driver.scans, hasLength(1));

      final firstReplacement = controller.scan();
      final secondReplacement = controller.scan();
      await _drainEventQueue();

      expect(driver.scans, hasLength(2));
      expect(driver.scans.map((scan) => scan.cancellations), <int>[1, 0]);

      controller.dispose();
      await Future.wait(<Future<void>>[
        initialScan,
        firstReplacement,
        secondReplacement,
      ]).timeout(const Duration(seconds: 1));
      await _drainEventQueue();

      expect(driver.scans.map((scan) => scan.cancellations), <int>[1, 1]);
    },
  );

  test(
    'the display is held awake for the scan window and released after',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _ControlledScanDriver();
      final display = _FakeDisplayAwake(interactive: true);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
        displayAwake: display,
      );
      await controller.initialize();

      final scan = controller.scan();
      await _drainEventQueue();

      expect(display.holdCalls, 1);
      expect(
        display.held,
        isTrue,
        reason: 'the window needs the display awake',
      );

      driver.scans.single.add(_sensor('held'));
      await driver.scans.single.close();
      await scan;

      expect(
        display.held,
        isFalse,
        reason: 'the hold must not outlive the scan',
      );
      expect(display.releaseCalls, 1);
      expect(controller.sensors, hasLength(1));
      expect(controller.scanFailure, isNull);

      controller.dispose();
    },
  );

  test(
    'a scan the display switched off is unavailable, not an absent sensor',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _ControlledScanDriver();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
        displayAwake: _FakeDisplayAwake(interactive: false),
      );
      await controller.initialize();

      final scan = controller.scan();
      await _drainEventQueue();
      await driver.scans.single.close();
      await scan;

      expect(controller.scanFailure?.kind, BleFailureKind.scanUnavailable);
      expect(controller.scanFailure?.operation, BleOperation.scan);
      expect(
        controller.scanFailure?.diagnosticCode,
        'cgm.ble.scan.display-off',
      );
      expect(controller.scanning, isFalse);
      final message = controller.lastError ?? '';
      expect(message, contains('screen'));
      expect(
        message,
        isNot(contains('No Bluetooth sensors found')),
        reason: 'a scan we could not perform must never blame the sensor',
      );
      expect(message, isNot(contains('Keep the sensor close')));

      controller.dispose();
    },
  );

  test('an empty scan the platform did run stays an empty scan', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _ControlledScanDriver();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: PreferencesHealthStateStore(preferences),
      displayAwake: _FakeDisplayAwake(interactive: true),
    );
    await controller.initialize();

    final scan = controller.scan();
    await _drainEventQueue();
    await driver.scans.single.close();
    await scan;

    expect(controller.scanFailure, isNull);
    expect(controller.lastError, isNull);

    controller.dispose();
  });

  test('a build with no display bridge never invents a declined scan', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _ControlledScanDriver();
    // No gate injected: the default is the no-op used by platforms without the
    // bridge, and it must never turn an empty scan into a platform refusal.
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: PreferencesHealthStateStore(preferences),
    );
    await controller.initialize();

    final scan = controller.scan();
    await _drainEventQueue();
    await driver.scans.single.close();
    await scan;

    expect(controller.scanFailure, isNull);
    expect(controller.lastError, isNull);

    controller.dispose();
  });

  test(
    'a sensor found while the display is off still reports the sensor',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _ControlledScanDriver();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: PreferencesHealthStateStore(preferences),
        displayAwake: _FakeDisplayAwake(interactive: false),
      );
      await controller.initialize();

      final scan = controller.scan();
      await _drainEventQueue();
      driver.scans.single.add(_sensor('filtered'));
      await driver.scans.single.close();
      await scan;

      expect(controller.sensors, hasLength(1));
      expect(controller.scanFailure, isNull);

      controller.dispose();
    },
  );

  testWidgets('a scan the screen turned off cannot run is not "no sensors"', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final stateStore = PreferencesHealthStateStore(preferences);
    final driver = _ControlledScanDriver();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: stateStore,
      displayAwake: _FakeDisplayAwake(interactive: false),
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

    await tester.tap(find.byKey(const ValueKey<String>('connectSensorButton')));
    await tester.pump();
    await driver.scans.single.close();
    await _pumpUntilScanSettles(tester);

    expect(
      find.byKey(const ValueKey<String>('sensorScanFailureTitle')),
      findsOneWidget,
    );
    expect(find.text('Bluetooth scan could not run'), findsOneWidget);
    expect(find.textContaining('screen is off'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('nearbyNoResults')),
      findsNothing,
      reason: 'a scan we could not perform is not an empty scan',
    );
    expect(find.text('No Bluetooth sensors found'), findsNothing);
    expect(find.textContaining('Keep the sensor close'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('retrySensorScanButton')),
    );
    await tester.pump();
    await driver.scans.last.close();
    await _pumpUntilScanSettles(tester);
    expect(driver.scans, hasLength(2), reason: 'the user can retry');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

/// Pumps until the scan progress card is gone, then settles the result card.
///
/// The scanning card animates, so `pumpAndSettle` alone never returns while a
/// scan is open.
Future<void> _pumpUntilScanSettles(WidgetTester tester) async {
  for (
    var attempt = 0;
    attempt < 30 &&
        find
            .byKey(const ValueKey<String>('nearbyScanProgress'))
            .evaluate()
            .isNotEmpty;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// A display that can be told to look asleep, for the screen-off scan cases.
class _FakeDisplayAwake implements DisplayAwakeGate {
  _FakeDisplayAwake({required this.interactive});

  bool interactive;
  bool held = false;
  int holdCalls = 0;
  int releaseCalls = 0;

  @override
  Future<void> hold() async {
    holdCalls += 1;
    held = true;
  }

  @override
  Future<void> release() async {
    releaseCalls += 1;
    held = false;
  }

  @override
  Future<bool> isInteractive() async => interactive;
}

Future<void> _startNearbySensorScan(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('connectSensorButton')),
  );
  await tester.pump();
  for (
    var attempt = 0;
    attempt < 30 &&
        find
            .byKey(const ValueKey<String>('nearbyScanProgress'))
            .evaluate()
            .isNotEmpty;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
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

class _CancelFailingScanDriver implements CgmDriver {
  int scanCalls = 0;

  @override
  String get driverId => 'cancel-failing-scan';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    scanCalls += 1;
    return StreamController<DiscoveredSensor>(
      onCancel: () => throw StateError('synthetic scan cleanup failure'),
    ).stream;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw UnsupportedError('This driver only exercises scan cancellation.');
  }
}

class _CancellationTrackedScanDriver implements CgmDriver {
  final List<_CancellationTrackedScan> scans = <_CancellationTrackedScan>[];

  @override
  String get driverId => 'cancellation-tracked-scan';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    final scan = _CancellationTrackedScan();
    scans.add(scan);
    return scan.controller.stream;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw UnsupportedError('This driver only exercises scan replacement.');
  }
}

class _CancellationTrackedScan {
  _CancellationTrackedScan() {
    controller = StreamController<DiscoveredSensor>(
      onCancel: () {
        cancellations += 1;
      },
    );
  }

  late final StreamController<DiscoveredSensor> controller;
  int cancellations = 0;
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
