import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';

void main() {
  test('restores discovery state before starting the shared scan', () async {
    final ready = Completer<void>();
    final transport = _FakeBleTransport();
    var restored = false;
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: [
        CgmDriverRegistration(
          driver: _FakeDriver('restored'),
          scanServiceUuids: const ['FDE3'],
          prepareDiscovery: () async {
            await ready.future;
            restored = true;
          },
          discover: (r) => restored ? _sensor('restored', r.deviceId) : null,
        ),
      ],
    );
    final first = registry.scan().first;
    await _pumpEventQueue();
    expect(transport.scanCalls, 0);
    ready.complete();
    await _pumpEventQueue();
    expect(transport.scanCalls, 1);
    transport.emit(
      const BleScanResult(
        deviceId: 'synthetic',
        deviceName: 'synthetic',
        rssi: -45,
      ),
    );
    expect((await first).driverId, 'restored');
  });

  test(
    'failed restoration does not map stale state or block other drivers',
    () async {
      final transport = _FakeBleTransport();
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: [
          CgmDriverRegistration(
            driver: _FakeDriver('unavailable'),
            scanServiceUuids: const ['FDE3'],
            prepareDiscovery: () async => throw StateError('synthetic failure'),
            discover: (r) => _sensor('unavailable', r.deviceId),
          ),
          CgmDriverRegistration(
            driver: _FakeDriver('available'),
            scanServiceUuids: const ['181F'],
            discover: (r) => _sensor('available', r.deviceId),
          ),
        ],
      );
      final first = registry.scan().first;
      await _pumpEventQueue();
      transport.emit(
        const BleScanResult(
          deviceId: 'synthetic',
          deviceName: 'synthetic',
          rssi: -45,
        ),
      );
      expect((await first).driverId, 'available');
    },
  );

  test('cancel during restoration never starts a physical scan', () async {
    final ready = Completer<void>();
    final transport = _FakeBleTransport();
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: [
        CgmDriverRegistration(
          driver: _FakeDriver('restored'),
          scanServiceUuids: const ['FDE3'],
          prepareDiscovery: () => ready.future,
          discover: (_) => null,
        ),
      ],
    );
    final subscription = registry.scan().listen((_) {});
    await _pumpEventQueue();
    final cancellation = subscription.cancel();
    ready.complete();
    await cancellation;
    expect(transport.scanCalls, 0);
  });

  test('uses one physical scan and keeps vendor identities distinct', () async {
    final transport = _FakeBleTransport();
    final alpha = _FakeDriver('alpha');
    final beta = _FakeDriver('beta');
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: alpha,
          scanServiceUuids: const <String>['181F'],
          discover: (result) => result.deviceName == 'alpha'
              ? _sensor('alpha', result.deviceId)
              : null,
        ),
        CgmDriverRegistration(
          driver: beta,
          scanServiceUuids: const <String>['FDE3', '181f'],
          discover: (result) => result.deviceName == 'beta'
              ? _sensor('beta', result.deviceId)
              : null,
        ),
      ],
    );
    final sensors = <DiscoveredSensor>[];
    final subscription = registry
        .scan(allowDuplicates: false)
        .listen(sensors.add);
    await _pumpEventQueue();

    expect(transport.scanCalls, 1);
    expect(transport.lastServices, const <String>['181F', 'FDE3']);

    transport.emit(
      const BleScanResult(
        deviceId: 'same-platform-id',
        deviceName: 'alpha',
        rssi: -45,
      ),
    );
    transport.emit(
      const BleScanResult(
        deviceId: 'same-platform-id',
        deviceName: 'alpha',
        rssi: -45,
      ),
    );
    transport.emit(
      const BleScanResult(
        deviceId: 'same-platform-id',
        deviceName: 'beta',
        rssi: -45,
      ),
    );
    await _pumpEventQueue();

    expect(
      sensors.map((sensor) => sensor.driverId),
      orderedEquals(<String>['alpha', 'beta']),
    );
    expect(
      sensors.map((sensor) => sensor.deviceId).toSet(),
      const <String>{'same-platform-id'},
    );

    await subscription.cancel();
  });

  test(
    'uses one unfiltered scan when a protocol can omit its service',
    () async {
      final transport = _FakeBleTransport();
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: _FakeDriver('filtered'),
            scanServiceUuids: const <String>['181F'],
            discover: (_) => null,
          ),
          CgmDriverRegistration(
            driver: _FakeDriver('name-only'),
            scanServiceUuids: const <String>['1000'],
            requiresUnfilteredScan: true,
            discover: (result) => result.deviceName == 'name-only'
                ? _sensor('name-only', result.deviceId)
                : null,
          ),
        ],
      );

      final first = registry.scan().first;
      await _pumpEventQueue();

      expect(registry.usesUnfilteredScan, isTrue);
      expect(transport.lastServices, isEmpty);
      transport.emit(
        const BleScanResult(
          deviceId: 'synthetic-device',
          deviceName: 'name-only',
          rssi: -50,
        ),
      );
      expect((await first).driverId, 'name-only');
    },
  );

  test('drops an advertisement claimed by more than one driver', () async {
    final transport = _FakeBleTransport();
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: _FakeDriver('alpha'),
          scanServiceUuids: const <String>['181F'],
          discover: (result) => _sensor('alpha', result.deviceId),
        ),
        CgmDriverRegistration(
          driver: _FakeDriver('beta'),
          scanServiceUuids: const <String>['FDE3'],
          discover: (result) => _sensor('beta', result.deviceId),
        ),
      ],
    );
    final sensors = <DiscoveredSensor>[];
    final subscription = registry.scan().listen(sensors.add);
    await _pumpEventQueue();

    transport.emit(
      const BleScanResult(
        deviceId: 'ambiguous-device',
        deviceName: 'ambiguous',
        rssi: -45,
      ),
    );
    await _pumpEventQueue();

    expect(sensors, isEmpty);
    await subscription.cancel();
  });

  test('isolates a malformed vendor matcher', () async {
    final transport = _FakeBleTransport();
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: _FakeDriver('broken'),
          scanServiceUuids: const <String>['181F'],
          discover: (_) => throw const FormatException('synthetic malformed'),
        ),
        CgmDriverRegistration(
          driver: _FakeDriver('healthy'),
          scanServiceUuids: const <String>['FDE3'],
          discover: (result) => _sensor('healthy', result.deviceId),
        ),
      ],
    );
    final first = registry.scan().first;
    await _pumpEventQueue();
    transport.emit(
      const BleScanResult(
        deviceId: 'synthetic-device',
        deviceName: 'synthetic',
        rssi: -50,
      ),
    );

    expect((await first).driverId, 'healthy');
  });

  test('stops the shared scan before dispatching connect', () async {
    final transport = _FakeBleTransport();
    late final _FakeDriver driver;
    driver = _FakeDriver(
      'libre2',
      beforeConnect: () {
        expect(transport.scanCancelCount, 1);
      },
    );
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: driver,
          scanServiceUuids: const <String>['FDE3'],
          discover: (result) => _sensor('libre2', result.deviceId),
        ),
      ],
    );
    final subscription = registry.scan().listen((_) {});
    await _pumpEventQueue();

    final sensor = _sensor('libre2', 'synthetic-device');
    final session = await registry.connect(sensor);

    expect(session.sensor, same(sensor));
    expect(driver.connectCalls, 1);
    await subscription.cancel();
  });

  test(
    'a failed scan cancellation permanently fails closed',
    () async {
      final transport = _FakeBleTransport()
        ..cancelError = StateError('synthetic cancel failure');
      final driver = _FakeDriver('libre2');
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: driver,
            scanServiceUuids: const <String>['FDE3'],
            discover: (result) => _sensor('libre2', result.deviceId),
          ),
        ],
      );
      final subscription = registry.scan().listen((_) {});
      await _pumpEventQueue();
      final sensor = _sensor('libre2', 'synthetic-device');

      await expectLater(registry.connect(sensor), throwsStateError);
      expect(transport.scanCancelCount, 1);
      expect(driver.connectCalls, 0);

      await expectLater(registry.connect(sensor), throwsStateError);
      expect(transport.scanCancelCount, 1);
      expect(driver.connectCalls, 0);

      await subscription.cancel();
    },
  );

  test(
    'source and cancellation failures do not escape the scan zone',
    () async {
      final uncaught = <Object>[];

      await runZonedGuarded<Future<void>>(
        () async {
          final transport = _FakeBleTransport()
            ..cancelError = StateError('synthetic cancel failure');
          final driver = _FakeDriver('libre2');
          final registry = CgmDriverRegistry(
            transport: transport,
            registrations: <CgmDriverRegistration>[
              CgmDriverRegistration(
                driver: driver,
                scanServiceUuids: const <String>['FDE3'],
                discover: (result) => _sensor('libre2', result.deviceId),
              ),
            ],
          );
          final iterator = StreamIterator<DiscoveredSensor>(registry.scan());
          final next = iterator.moveNext();
          await _pumpEventQueue();
          final sourceFailure = BleFailure(
            kind: BleFailureKind.unexpected,
            operation: BleOperation.scan,
            diagnosticCode: 'test.scan.source-failure',
          );

          transport.emitError(sourceFailure);

          await expectLater(next, throwsA(same(sourceFailure)));
          await _pumpEventQueue();
          await expectLater(
            registry.connect(_sensor('libre2', 'synthetic-device')),
            throwsStateError,
          );
          expect(driver.connectCalls, 0);
        },
        (error, _) => uncaught.add(error),
      );

      expect(uncaught, isEmpty);
    },
  );

  test(
    'a scan completes at its timeout when the transport never closes',
    () async {
      final transport = _FakeBleTransport();
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: _FakeDriver('alpha'),
            scanServiceUuids: const <String>['181F'],
            discover: (result) => _sensor('alpha', result.deviceId),
          ),
        ],
      );

      final sensors = <DiscoveredSensor>[];
      final finished = Completer<void>();
      final subscription = registry
          .scan(timeout: const Duration(milliseconds: 80))
          .listen(
            sensors.add,
            onDone: () {
              if (!finished.isCompleted) finished.complete();
            },
          );
      await _pumpEventQueue();
      expect(transport.scanCalls, 1);
      transport.emit(
        const BleScanResult(
          deviceId: 'synthetic',
          deviceName: 'synthetic',
          rssi: -45,
        ),
      );
      await _pumpEventQueue();
      expect(sensors, hasLength(1));

      await finished.future.timeout(const Duration(seconds: 2));
      expect(transport.scanCancelCount, 1);
      await subscription.cancel();

      final second = registry
          .scan(timeout: const Duration(milliseconds: 80))
          .listen((_) {});
      await _pumpEventQueue();
      expect(transport.scanCalls, 2);
      await second.cancel();
    },
  );

  test(
    'a deadline reached during discovery setup still ends the scan',
    () async {
      final transport = _FakeBleTransport();
      final slowPreparation = Completer<void>();
      final registry = CgmDriverRegistry(
        transport: transport,
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: _FakeDriver('slow'),
            scanServiceUuids: const <String>['181F'],
            prepareDiscovery: () => slowPreparation.future,
            discover: (result) => _sensor('slow', result.deviceId),
          ),
        ],
      );

      final sensors = <DiscoveredSensor>[];
      final completed = Completer<void>();
      registry
          .scan(timeout: const Duration(milliseconds: 60))
          .listen(
            sensors.add,
            onDone: () {
              if (!completed.isCompleted) completed.complete();
            },
          );
      await _pumpEventQueue();
      expect(transport.scanCalls, 0);

      await completed.future.timeout(const Duration(seconds: 2));
      expect(sensors, isEmpty);
      expect(transport.scanCalls, 0);

      // The abandoned preparation must not resurrect a scan later.
      slowPreparation.complete();
      await _pumpEventQueue();
      expect(transport.scanCalls, 0);
    },
  );

  test('a transport that never confirms cancellation stays bounded', () async {
    final transport = _WedgedCancelTransport();
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: _FakeDriver('alpha'),
          scanServiceUuids: const <String>['181F'],
          discover: (result) => _sensor('alpha', result.deviceId),
        ),
      ],
    );

    final finished = Completer<void>();
    registry
        .scan(timeout: const Duration(milliseconds: 60))
        .listen((_) {}, onDone: finished.complete);
    await _pumpEventQueue();
    expect(transport.scanCalls, 1);

    // The configured deadline must not wait on an unconfirmable cancellation.
    await finished.future.timeout(const Duration(seconds: 2));
    expect(transport.cancelCalls, 1);
    expect(transport.scanCalls, 1);

    // A retry in the same session must reach the transport again. The
    // unconfirmed cancellation bounds this scan; it must not disable scanning
    // until the app restarts.
    final finishedAgain = Completer<void>();
    registry
        .scan(timeout: const Duration(milliseconds: 60))
        .listen((_) {}, onDone: finishedAgain.complete);
    await finishedAgain.future.timeout(const Duration(seconds: 6));
    expect(transport.scanCalls, 2);
  });

  test('rejects a registration with a blank driver ID', () {
    expect(
      () => CgmDriverRegistration(
        driver: _FakeDriver('   '),
        scanServiceUuids: const <String>['181F'],
        discover: (_) => null,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a registration with no advertised service', () {
    expect(
      () => CgmDriverRegistration(
        driver: _FakeDriver('no-service'),
        scanServiceUuids: const <String>[],
        discover: (_) => null,
      ),
      throwsArgumentError,
    );
    // Whitespace-only and duplicate-after-normalization entries both
    // collapse to nothing usable -- same rejection, not a silent partial
    // registration.
    expect(
      () => CgmDriverRegistration(
        driver: _FakeDriver('blank-service'),
        scanServiceUuids: const <String>['  ', ''],
        discover: (_) => null,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a registry with no registrations', () {
    expect(
      () => CgmDriverRegistry(
        transport: _FakeBleTransport(),
        registrations: const <CgmDriverRegistration>[],
      ),
      throwsArgumentError,
    );
  });

  test('rejects duplicate and unknown driver IDs', () async {
    final transport = _FakeBleTransport();
    final duplicate = _FakeDriver('duplicate');

    expect(
      () => CgmDriverRegistry(
        transport: transport,
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: duplicate,
            scanServiceUuids: const <String>['181F'],
            discover: (_) => null,
          ),
          CgmDriverRegistration(
            driver: duplicate,
            scanServiceUuids: const <String>['FDE3'],
            discover: (_) => null,
          ),
        ],
      ),
      throwsArgumentError,
    );

    final known = _FakeDriver('known');
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: known,
          scanServiceUuids: const <String>['181F'],
          discover: (_) => null,
        ),
      ],
    );
    expect(registry.containsDriver('known'), isTrue);
    expect(registry.containsDriver('unknown'), isFalse);
    expect(registry.driverFor('known'), same(known));
    expect(registry.driverFor('unknown'), isNull);
    await expectLater(
      registry.connect(_sensor('unknown', 'synthetic-device')),
      throwsArgumentError,
    );
  });
}

DiscoveredSensor _sensor(String driverId, String deviceId) => DiscoveredSensor(
  driverId: driverId,
  deviceId: deviceId,
  displayName: 'Synthetic sensor',
  storageKey: '$driverId:synthetic',
  rssi: -45,
  capabilities: const CgmCapabilities(supportsDirectBle: true),
);

Future<void> _pumpEventQueue() => Future<void>.delayed(Duration.zero);

/// A transport whose scan cancellation never reports completion.
final class _WedgedCancelTransport implements BleTransport {
  int scanCalls = 0;
  int cancelCalls = 0;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanCalls += 1;
    return StreamController<BleScanResult>(
      onCancel: () {
        cancelCalls += 1;
        return Completer<void>().future;
      },
    ).stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();
}

final class _FakeBleTransport implements BleTransport {
  late StreamController<BleScanResult> _scanController;
  int scanCalls = 0;
  int scanCancelCount = 0;
  List<String>? lastServices;
  Error? cancelError;

  void emit(BleScanResult result) => _scanController.add(result);

  void emitError(Object error) => _scanController.addError(error);

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanCalls += 1;
    lastServices = withServices;
    late final StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>(
      onCancel: () {
        scanCancelCount += 1;
        final error = cancelError;
        cancelError = null;
        if (error != null) {
          throw error;
        }
      },
    );
    _scanController = controller;
    return controller.stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();
}

final class _FakeDriver implements CgmDriver {
  _FakeDriver(this.driverId, {this.beforeConnect});

  @override
  final String driverId;
  final void Function()? beforeConnect;
  int connectCalls = 0;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => throw StateError('The registry must own the physical scan.');

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    beforeConnect?.call();
    connectCalls += 1;
    return _FakeSession(sensor);
  }
}

final class _FakeSession implements CgmSession {
  _FakeSession(this.sensor)
    : currentSnapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Ready',
        sensor: sensor,
        capabilities: sensor.capabilities,
      );

  @override
  final DiscoveredSensor sensor;

  @override
  final CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

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
