import 'dart:async';
import 'dart:typed_data';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  test('session initializes, pairs, and syncs vendor history', () async {
    final transport = _FakeBleTransport();
    final driver = AidexSensorDriver(
      transport,
      clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
      timingProfile: const AidexTimingProfile(
        gattGap: Duration.zero,
        postStartSession: Duration.zero,
        postSessionStartWrite: Duration.zero,
        vendorPairTimeout: Duration(seconds: 1),
        vendorCommandTimeout: Duration(seconds: 1),
      ),
    );
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'AA:BB:CC:DD:EE:FF',
      displayName: 'AiDEX-2222293Q2E',
      storageKey: 'serial:2222293Q2E',
      rssi: -40,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsVendorPairing: true,
        supportsHistory: true,
        supportsDiagnostics: true,
        supportsCalibration: true,
        supportsAutoUpdateControl: true,
      ),
      metadata: const <String, String>{'serial': '2222293Q2E'},
    );

    final session = await driver.connect(sensor) as AidexSession;
    final logs = <CgmLogEntry>[];
    final logSubscription = session.logs.listen(logs.add);
    await session.initialize();
    final snapshots = <CgmSessionSnapshot>[];
    final snapshotSubscription = session.snapshots.listen(snapshots.add);
    await session.syncHistory();
    final diagnostics = await session.refreshDiagnostics();
    final ready = session.currentSnapshot;

    expect(
      ready.stage,
      CgmSyncStage.ready,
      reason: 'stage=${ready.stage} error=${ready.lastError}',
    );

    expect(ready.sessionInfo.serial, '2222293Q2E');
    expect(ready.history.map((reading) => reading.valueMgdl).toList(), <double>[
      85,
      86,
      87,
    ]);
    expect(
      snapshots.any(
        (snapshot) =>
            snapshot.history.isNotEmpty && snapshot.historySync.inProgress,
      ),
      isTrue,
    );
    expect(transport.lastConnection.requestedHistoryIndices, <int>[1, 3]);
    expect(diagnostics, isNotEmpty);

    final calibrations = await session.fetchCalibrations();
    expect(calibrations.length, 2);
    await session.submitCalibration(
      glucoseMgdl: 123,
      recordedAt: DateTime.parse('2026-04-02T04:20:00Z'),
    );

    final interval = await session.getCommunicationInterval();
    expect(interval.current, 1);

    final autoUpdate = await session.getAutoUpdateStatus();
    expect(autoUpdate, isTrue);

    await Future<void>.delayed(Duration.zero);
    final diagnosticText = logs.map((entry) => entry.message).join('\n');
    expect(diagnosticText, isNot(contains(sensor.displayName)));
    expect(diagnosticText, isNot(contains(sensor.deviceId)));
    expect(diagnosticText, isNot(contains('123 mg/dL')));
    expect(diagnosticText, isNot(contains('2026-04-02')));
    expect(diagnosticText, isNot(contains('caf41e38a00ab44dd1ce341c')));
    expect(diagnosticText, isNot(contains('55805684')));

    await snapshotSubscription.cancel();
    await logSubscription.cancel();
    await session.disconnect();
    expect(transport.lastConnection.didVendorUnpair, isFalse);
    expect(transport.lastConnection.didClearBondViaBms, isFalse);
    expect(transport.lastConnection.didRemoveBond, isFalse);
    expect(
      transport.operations,
      containsAllInOrder(<String>[
        'ensureBonded',
        'disconnect',
        'discoverServices',
        'setNotify:${AidexUuids.f001}',
        'setNotify:${AidexUuids.f003}',
      ]),
    );
  });

  test(
    'session automatically resumes deferred history sync after warmup',
    () async {
      final warmupEndsAt = DateTime.parse('2026-04-02T04:28:10Z');
      final now = warmupEndsAt.subtract(const Duration(minutes: 15));
      final transport = _FakeBleTransport(
        initialSessionStart: warmupEndsAt.subtract(const Duration(minutes: 60)),
        initialElapsedMinutes: 59,
      );
      final driver = AidexSensorDriver(
        transport,
        clock: () => now,
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
          warmupResumePollInterval: Duration(milliseconds: 100),
        ),
      );
      final session =
          await driver.connect(_activationTestSensor()) as AidexSession;
      final syncedSnapshot = session.snapshots.firstWhere(
        (snapshot) => snapshot.historySync.lastSyncAt != null,
      );

      await session.initialize();

      expect(transport.lastConnection.requestedHistoryRangeCount, 0);
      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(session.currentSnapshot.lastError, isNull);
      expect(session.currentSnapshot.historySync.inProgress, isFalse);

      // The first scheduled poll still sees the authoritative minute 59. It
      // must reschedule rather than dropping the deferred catch-up.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(transport.lastConnection.requestedHistoryRangeCount, 0);

      transport.lastConnection.emitMeasurementMinute(60);
      final synced = await syncedSnapshot.timeout(const Duration(seconds: 1));

      expect(transport.lastConnection.requestedHistoryRangeCount, 1);
      expect(synced.history, isNotEmpty);

      await session.disconnect();
    },
  );

  test(
    'automatic post-warmup history failures become safe session errors',
    () async {
      final warmupEndsAt = DateTime.parse('2026-04-02T04:28:10Z');
      final now = warmupEndsAt.subtract(const Duration(minutes: 15));
      final transport = _FakeBleTransport(
        initialSessionStart: warmupEndsAt.subtract(const Duration(minutes: 60)),
        initialElapsedMinutes: 59,
        historyRangePayload: const <int>[],
      );
      final driver = AidexSensorDriver(
        transport,
        clock: () => now,
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
          warmupResumePollInterval: Duration(milliseconds: 100),
        ),
      );
      final session =
          await driver.connect(_activationTestSensor()) as AidexSession;
      final errorSnapshot = session.snapshots.firstWhere(
        (snapshot) => snapshot.stage == CgmSyncStage.error,
      );

      await session.initialize();
      expect(transport.lastConnection.requestedHistoryRangeCount, 0);

      Timer(const Duration(milliseconds: 50), () {
        transport.lastConnection.emitMeasurementMinute(60);
      });
      final failed = await errorSnapshot.timeout(const Duration(seconds: 1));

      expect(transport.lastConnection.requestedHistoryRangeCount, 1);
      expect(failed.lastError, 'syncing history failed (StateError)');

      await session.disconnect();
    },
  );

  test(
    'session enables vendor auto-update when the sensor reports disabled',
    () async {
      final transport = _FakeBleTransport(autoUpdateEnabled: false);
      final driver = AidexSensorDriver(
        transport,
        clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
        ),
      );
      final sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        displayName: 'AiDEX-2222293Q2E',
        storageKey: 'serial:2222293Q2E',
        rssi: -40,
        capabilities: const CgmCapabilities(
          supportsDirectBle: true,
          supportsVendorPairing: true,
          supportsHistory: true,
          supportsDiagnostics: true,
          supportsCalibration: true,
          supportsAutoUpdateControl: true,
        ),
        metadata: const <String, String>{'serial': '2222293Q2E'},
      );

      final session = await driver.connect(sensor) as AidexSession;
      await session.initialize();

      expect(transport.lastConnection.didSetAutoUpdate, isTrue);
      expect(await session.getAutoUpdateStatus(), isTrue);

      await session.disconnect();
    },
  );

  test(
    'session can sync raw vendor history when explicitly requested',
    () async {
      final transport = _FakeBleTransport();
      final driver = AidexSensorDriver(
        transport,
        clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
        ),
      );
      final sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        displayName: 'AiDEX-2222293Q2E',
        storageKey: 'serial:2222293Q2E',
        rssi: -40,
        capabilities: const CgmCapabilities(
          supportsDirectBle: true,
          supportsVendorPairing: true,
          supportsHistory: true,
          supportsDiagnostics: true,
          supportsCalibration: true,
        ),
        metadata: const <String, String>{'serial': '2222293Q2E'},
      );

      final session = await driver.connect(sensor) as AidexSession;
      await session.initialize();
      await session.syncHistory(includeRawHistory: true);

      expect(
        session.currentSnapshot.rawHistory
            .map((reading) => reading.valueMgdl)
            .toList(),
        <double>[101, 102, 103],
      );

      await session.disconnect();
    },
  );

  test('explicit unsafe unpair clears vendor and local bond state', () async {
    final transport = _FakeBleTransport();
    final driver = AidexSensorDriver(
      transport,
      clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
      timingProfile: const AidexTimingProfile(
        gattGap: Duration.zero,
        postStartSession: Duration.zero,
        postSessionStartWrite: Duration.zero,
        vendorPairTimeout: Duration(seconds: 1),
        vendorCommandTimeout: Duration(seconds: 1),
      ),
    );
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'AA:BB:CC:DD:EE:FF',
      displayName: 'AiDEX-2222293Q2E',
      storageKey: 'serial:2222293Q2E',
      rssi: -40,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsVendorPairing: true,
        supportsHistory: true,
        supportsDiagnostics: true,
        supportsCalibration: true,
        supportsAutoUpdateControl: true,
      ),
      metadata: const <String, String>{'serial': '2222293Q2E'},
    );

    final session = await driver.connect(sensor) as AidexSession;
    await session.initialize();

    await session.unsafeAdmin.perform(CgmUnsafeOperation.unpair);

    expect(transport.lastConnection.didVendorUnpair, isTrue);
    expect(transport.lastConnection.didClearBondViaBms, isTrue);
    expect(transport.lastConnection.didRemoveBond, isTrue);

    await session.disconnect();
  });

  test(
    'session can pair using the GATT serial when the BLE name lacks it',
    () async {
      final transport = _FakeBleTransport();
      final driver = AidexSensorDriver(
        transport,
        clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
        ),
      );
      final sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        displayName: 'AiDEX',
        storageKey: 'AA:BB:CC:DD:EE:FF',
        rssi: -40,
        capabilities: const CgmCapabilities(
          supportsDirectBle: true,
          supportsVendorPairing: true,
          supportsHistory: true,
          supportsDiagnostics: true,
          supportsCalibration: true,
        ),
      );

      final session = await driver.connect(sensor) as AidexSession;
      await session.initialize();
      await session.syncHistory();
      expect(
        session.currentSnapshot.sessionInfo.serial,
        '2222293Q2E',
        reason: 'error=${session.currentSnapshot.lastError}',
      );
      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      await session.disconnect();
    },
  );

  test(
    'explicit connection may activate an uninitialised stopped sensor',
    () async {
      final transport = _FakeBleTransport(uninitialized: true);
      final driver = _activationTestDriver(transport);
      final session =
          await driver.connect(
                _activationTestSensor(allowSessionActivation: true),
              )
              as AidexSession;
      final emitted = <CgmSessionSnapshot>[];
      final subscription = session.snapshots.listen(emitted.add);

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(
        emitted.where(
          (snapshot) =>
              snapshot.health.expired || snapshot.sessionInfo.sessionStopped,
        ),
        isEmpty,
        reason:
            'An activation-ready all-zero sensor must never look expired '
            'while its explicit start exchange is still in progress.',
      );
      expect(transport.lastConnection.didRequestStartSession, isTrue);
      expect(transport.lastConnection.didWriteSessionStart, isTrue);

      await subscription.cancel();
      await session.disconnect();
    },
  );

  test(
    'restored connection never activates an uninitialised stopped sensor',
    () async {
      final transport = _FakeBleTransport(uninitialized: true);
      final driver = _activationTestDriver(transport);
      final session =
          await driver.connect(
                _activationTestSensor(allowSessionActivation: false),
              )
              as AidexSession;

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(session.currentSnapshot.sessionInfo.sessionStopped, isFalse);
      expect(session.currentSnapshot.health.expired, isFalse);
      expect(session.currentSnapshot.metadata['activationRequired'], 'true');
      expect(session.currentSnapshot.lastError, contains('Choose this sensor'));
      expect(transport.lastConnection.didRequestStartSession, isFalse);
      expect(transport.lastConnection.didWriteSessionStart, isFalse);

      await session.disconnect();
    },
  );

  test('activation fails closed without explicit intent metadata', () async {
    final transport = _FakeBleTransport(uninitialized: true);
    final session =
        await _activationTestDriver(transport).connect(_activationTestSensor())
            as AidexSession;

    await session.initialize();

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(session.currentSnapshot.health.expired, isFalse);
    expect(session.currentSnapshot.metadata['activationRequired'], 'true');
    expect(transport.lastConnection.didRequestStartSession, isFalse);
    expect(transport.lastConnection.didWriteSessionStart, isFalse);
    await session.disconnect();
  });

  test('malformed session start can never trigger activation', () async {
    final transport = _FakeBleTransport(
      uninitialized: true,
      malformedSessionStart: true,
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;

    await session.initialize();

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(
      session.currentSnapshot.metadata[aidexSetupPhaseMetadataKey],
      AidexSetupPhase.activation,
    );
    expect(transport.lastConnection.didRequestStartSession, isFalse);
    expect(transport.lastConnection.didWriteSessionStart, isFalse);
    await session.disconnect();
  });

  test(
    'ended prior session is never restarted even with explicit activation',
    () async {
      final transport = _FakeBleTransport(
        initialSessionStart: DateTime.parse('2026-03-20T04:28:10Z'),
        initialSessionStopped: true,
      );
      final driver = _activationTestDriver(transport);
      final session =
          await driver.connect(
                _activationTestSensor(allowSessionActivation: true),
              )
              as AidexSession;

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(session.currentSnapshot.sessionInfo.sessionStopped, isTrue);
      expect(session.currentSnapshot.health.expired, isTrue);
      expect(session.currentSnapshot.lastError, contains('ended'));
      expect(transport.lastConnection.didRequestStartSession, isFalse);
      expect(transport.lastConnection.didWriteSessionStart, isFalse);

      await session.disconnect();
    },
  );

  test(
    'initialization failure never removes a local bond automatically',
    () async {
      final transport = _FakeBleTransport(failDiscoverServicesOnce: true);
      final driver = AidexSensorDriver(
        transport,
        clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
        timingProfile: const AidexTimingProfile(
          gattGap: Duration.zero,
          postStartSession: Duration.zero,
          postSessionStartWrite: Duration.zero,
          vendorPairTimeout: Duration(seconds: 1),
          vendorCommandTimeout: Duration(seconds: 1),
        ),
      );
      final sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        displayName: 'AiDEX-2222293Q2E',
        storageKey: 'serial:2222293Q2E',
        rssi: -40,
        capabilities: const CgmCapabilities(
          supportsDirectBle: true,
          supportsVendorPairing: true,
          supportsHistory: true,
          supportsDiagnostics: true,
          supportsCalibration: true,
        ),
        metadata: const <String, String>{'serial': '2222293Q2E'},
      );

      final session = await driver.connect(sensor) as AidexSession;
      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(
        session.currentSnapshot.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.discovery,
      );
      expect(transport.connections, hasLength(2));
      expect(
        transport.connections.every((connection) => !connection.didRemoveBond),
        isTrue,
      );
      expect(
        BleFailure.fromMetadata(
          session.currentSnapshot.metadata,
        )?.allowsAutomaticRetry,
        isFalse,
      );

      await session.disconnect();
    },
  );

  test('session bonds before discovery and refreshes the GATT link', () async {
    final transport = _FakeBleTransport(
      requireBondBeforeDiscovery: true,
      requireBondBeforeNotifications: true,
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;

    await session.initialize();

    final operations = transport.operations;
    expect(session.currentSnapshot.stage, CgmSyncStage.ready);
    expect(transport.connections, hasLength(2));
    expect(
      transport.connections.first.operations,
      isNot(contains('discoverServices')),
      reason: 'The pre-bond GATT link must never perform service discovery.',
    );
    expect(
      operations.indexOf('ensureBonded'),
      lessThan(operations.indexOf('disconnect')),
    );
    expect(
      operations,
      containsAllInOrder(<String>[
        'connect:1',
        'currentBondState',
        'ensureBonded',
        'currentBondState',
        'disconnect',
        'connect:2',
        'currentBondState',
        'discoverServices',
        'setNotify:${AidexUuids.f001}',
      ]),
    );
    expect(
      operations.where((operation) => operation == 'discoverServices'),
      hasLength(1),
      reason: 'Discovery must use only the fresh post-bond GATT connection.',
    );
    await session.disconnect();
  });

  test(
    'a pre-existing Android bond still refreshes GATT before discovery',
    () async {
      final transport = _FakeBleTransport();
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(transport.connections, hasLength(2));
      expect(
        transport.connections.first.operations,
        isNot(contains('discoverServices')),
      );
      expect(
        transport.operations,
        containsAllInOrder(<String>[
          'connect:1',
          'currentBondState',
          'ensureBonded',
          'currentBondState',
          'disconnect',
          'connect:2',
          'currentBondState',
          'discoverServices',
        ]),
      );
      expect(
        transport.connections.where(
          (connection) => connection.didRequestStartSession,
        ),
        isEmpty,
      );
      expect(
        transport.connections.where(
          (connection) => connection.didWriteSessionStart,
        ),
        isEmpty,
      );
      await session.disconnect();
    },
  );

  test('setup emits only the closed phase set at exact boundaries', () async {
    expect(AidexSetupPhase.values, const <String>{
      'P01',
      'P02',
      'P03',
      'P04',
      'P05',
      'P06',
      'P07',
      'P08',
      'P09',
      'P10',
    });
    final transport = _FakeBleTransport(
      requireBondBeforeDiscovery: true,
      requireBondBeforeNotifications: true,
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;
    final observed = <String>{
      if (session.currentSnapshot.metadata[aidexSetupPhaseMetadataKey]
          case final String initialPhase)
        initialPhase,
    };
    final subscription = session.snapshots.listen((snapshot) {
      final phase = snapshot.metadata[aidexSetupPhaseMetadataKey];
      if (phase != null) {
        observed.add(phase);
      }
    });

    await session.initialize();

    expect(observed, AidexSetupPhase.values);
    expect(session.currentSnapshot.stage, CgmSyncStage.ready);
    expect(
      session.currentSnapshot.metadata,
      isNot(contains(aidexSetupPhaseMetadataKey)),
      reason: 'Completed setup phases must not mislabel runtime failures.',
    );
    await subscription.cancel();
    await session.disconnect();
  });

  test(
    'post-bond reconnect failure preserves a non-retryable BLE failure',
    () async {
      final transport = _FakeBleTransport(
        requireBondBeforeDiscovery: true,
        reconnectFailure: BleFailure(
          kind: BleFailureKind.sensorPossiblyInUse,
          operation: BleOperation.connect,
          diagnosticCode: 'fake.reconnect.in-use',
        ),
      );
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;

      await session.initialize();

      final failure = BleFailure.fromMetadata(session.currentSnapshot.metadata);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(failure?.kind, BleFailureKind.sensorPossiblyInUse);
      expect(failure?.operation, BleOperation.connect);
      expect(failure?.diagnosticCode, 'fake.reconnect.in-use');
      expect(failure?.allowsAutomaticRetry, isFalse);
      expect(
        session.currentSnapshot.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.reconnect,
      );
      expect(transport.operations, isNot(contains('discoverServices')));
      expect(transport.connections.single.didRemoveBond, isFalse);
      expect(transport.connections.single.didRequestStartSession, isFalse);

      await session.disconnect();
    },
  );

  test(
    'bond-time disconnect event is ignored until the fresh GATT link',
    () async {
      final transport = _FakeBleTransport(
        requireBondBeforeDiscovery: true,
        disconnectDuringBonding: true,
      );
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(transport.connections, hasLength(2));
      expect(
        BleFailure.fromMetadata(session.currentSnapshot.metadata),
        isNull,
        reason: 'The intentional bond transition is not a lost connection.',
      );
      expect(
        transport.operations,
        containsAllInOrder(<String>[
          'ensureBonded',
          'bondConnectionDropped',
          'disconnect',
          'connect:2',
          'discoverServices',
        ]),
      );

      await session.disconnect();
    },
  );

  test(
    'post-bond reconnect cannot repeat explicit sensor activation',
    () async {
      final transport = _FakeBleTransport(
        requireBondBeforeDiscovery: true,
        uninitialized: true,
      );
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;

      await session.initialize();

      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(transport.connections, hasLength(2));
      expect(
        transport.connections
            .where((connection) => connection.didRequestStartSession)
            .length,
        1,
      );
      expect(
        transport.connections
            .where((connection) => connection.didWriteSessionStart)
            .length,
        1,
      );
      await session.disconnect();
    },
  );

  test('disconnect cancels a pending post-bond reconnect', () async {
    final disconnectStarted = Completer<void>();
    final allowDisconnect = Completer<void>();
    final transport = _FakeBleTransport(
      requireBondBeforeDiscovery: true,
      uninitialized: true,
      firstDisconnectStarted: disconnectStarted,
      firstDisconnectRelease: allowDisconnect,
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;

    await disconnectStarted.future.timeout(const Duration(seconds: 1));
    final disconnectFuture = session.disconnect();
    allowDisconnect.complete();
    await disconnectFuture;

    expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
    expect(transport.connections, hasLength(1));
    expect(transport.operations, isNot(contains('connect:2')));
    expect(transport.operations, isNot(contains('discoverServices')));
    expect(transport.connections.single.didRequestStartSession, isFalse);
    expect(transport.connections.single.didWriteSessionStart, isFalse);
  });

  test(
    'disconnect cancels setup while the initial connection is pending',
    () async {
      final connectStarted = Completer<void>();
      final allowConnect = Completer<void>();
      final transport = _FakeBleTransport(
        initialConnectStarted: connectStarted,
        initialConnectRelease: allowConnect,
      );
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;

      await connectStarted.future.timeout(const Duration(seconds: 1));
      final disconnectFuture = session.disconnect();
      allowConnect.complete();
      await disconnectFuture;

      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
      expect(transport.connections, hasLength(1));
      expect(
        transport.operations,
        containsAllInOrder(<String>['connect:1', 'disconnect']),
      );
      expect(transport.operations, isNot(contains('ensureBonded')));
      expect(transport.operations, isNot(contains('discoverServices')));
      expect(transport.connections.single.didRequestStartSession, isFalse);
      expect(transport.connections.single.didWriteSessionStart, isFalse);
    },
  );

  test('disconnect cancels setup before pairing can start', () async {
    final bondStateReadStarted = Completer<void>();
    final allowBondStateRead = Completer<void>();
    final transport = _FakeBleTransport(
      initialBondStateReadStarted: bondStateReadStarted,
      initialBondStateReadRelease: allowBondStateRead,
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;

    await bondStateReadStarted.future.timeout(const Duration(seconds: 1));
    final disconnectFuture = session.disconnect();
    allowBondStateRead.complete();
    await disconnectFuture;

    expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
    expect(transport.operations, isNot(contains('ensureBonded')));
    expect(transport.operations, isNot(contains('discoverServices')));
    expect(transport.connections.single.didRequestStartSession, isFalse);
    expect(transport.connections.single.didWriteSessionStart, isFalse);
  });

  test('bond failure exposes only safe structured recovery metadata', () async {
    final transport = _FakeBleTransport(
      bondFailure: BleFailure(
        kind: BleFailureKind.sensorPossiblyInUse,
        operation: BleOperation.bond,
        diagnosticCode: 'fbp.android.bond.busy',
      ),
    );
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;
    final logs = <CgmLogEntry>[];
    final subscription = session.logs.listen(logs.add);

    await session.initialize();
    await Future<void>.delayed(Duration.zero);

    final snapshot = session.currentSnapshot;
    final failure = BleFailure.fromMetadata(snapshot.metadata);
    expect(snapshot.stage, CgmSyncStage.error);
    expect(snapshot.lastError, 'Bluetooth setup could not be completed.');
    expect(snapshot.metadata[aidexSetupPhaseMetadataKey], AidexSetupPhase.bond);
    expect(failure?.kind, BleFailureKind.sensorPossiblyInUse);
    expect(failure?.allowsAutomaticRetry, isFalse);
    expect(transport.lastConnection.didRemoveBond, isFalse);
    expect(
      logs.map((entry) => entry.message).join('\n'),
      contains('fbp.android.bond.busy'),
    );
    expect(
      logs.map((entry) => entry.message).join('\n'),
      isNot(contains(session.sensor.deviceId)),
    );

    await subscription.cancel();
    await session.disconnect();
  });

  test('connection-state stream errors become safe session errors', () async {
    final transport = _FakeBleTransport();
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;
    await session.initialize();

    transport.lastConnection.emitConnectionError(
      BleFailure(
        kind: BleFailureKind.deviceDisconnected,
        operation: BleOperation.connect,
        diagnosticCode: 'fake.connection.stream',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(
      BleFailure.fromMetadata(session.currentSnapshot.metadata)?.kind,
      BleFailureKind.deviceDisconnected,
    );
    await session.disconnect();
  });

  test('disconnect events expose safe structured recovery metadata', () async {
    final transport = _FakeBleTransport();
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;
    await session.initialize();

    transport.lastConnection.emitDisconnected();
    await Future<void>.delayed(Duration.zero);

    final snapshot = session.currentSnapshot;
    final failure = BleFailure.fromMetadata(snapshot.metadata);
    expect(snapshot.stage, CgmSyncStage.disconnected);
    expect(snapshot.metadata, isNot(contains(aidexSetupPhaseMetadataKey)));
    expect(failure?.kind, BleFailureKind.deviceDisconnected);
    expect(failure?.operation, BleOperation.connect);
    expect(failure?.diagnosticCode, 'aidex.connection.disconnected');
    expect(snapshot.lastError, isNot(contains(session.sensor.deviceId)));
    await session.disconnect();
  });

  test(
    'disconnect after pairing error preserves non-retryable failure',
    () async {
      final transport = _FakeBleTransport();
      final session =
          await _activationTestDriver(
                transport,
              ).connect(_activationTestSensor(allowSessionActivation: true))
              as AidexSession;
      await session.initialize();
      const diagnosticCode = 'fake.bond.rejected';

      transport.lastConnection.emitConnectionError(
        BleFailure(
          kind: BleFailureKind.bondRejected,
          operation: BleOperation.bond,
          diagnosticCode: diagnosticCode,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      transport.lastConnection.emitDisconnected();
      await Future<void>.delayed(Duration.zero);

      final snapshot = session.currentSnapshot;
      final failure = BleFailure.fromMetadata(snapshot.metadata);
      expect(snapshot.stage, CgmSyncStage.disconnected);
      expect(snapshot.metadata, isNot(contains(aidexSetupPhaseMetadataKey)));
      expect(failure?.kind, BleFailureKind.bondRejected);
      expect(failure?.operation, BleOperation.bond);
      expect(failure?.diagnosticCode, diagnosticCode);
      expect(failure?.allowsAutomaticRetry, isFalse);
      await session.disconnect();
    },
  );

  test('notification stream errors become safe session errors', () async {
    final transport = _FakeBleTransport();
    final session =
        await _activationTestDriver(
              transport,
            ).connect(_activationTestSensor(allowSessionActivation: true))
            as AidexSession;
    await session.initialize();

    transport.lastConnection.emitNotificationError(
      AidexUuids.measurement,
      BleFailure(
        kind: BleFailureKind.bondRejected,
        operation: BleOperation.subscribe,
        diagnosticCode: 'fake.notification.stream',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.currentSnapshot.stage, CgmSyncStage.error);
    expect(
      BleFailure.fromMetadata(session.currentSnapshot.metadata)?.kind,
      BleFailureKind.bondRejected,
    );
    await session.disconnect();
  });
}

AidexSensorDriver _activationTestDriver(_FakeBleTransport transport) {
  return AidexSensorDriver(
    transport,
    clock: () => DateTime.parse('2026-04-02T04:28:10Z'),
    timingProfile: const AidexTimingProfile(
      gattGap: Duration.zero,
      postStartSession: Duration.zero,
      postSessionStartWrite: Duration.zero,
      vendorPairTimeout: Duration(seconds: 1),
      vendorCommandTimeout: Duration(seconds: 1),
    ),
  );
}

DiscoveredSensor _activationTestSensor({bool? allowSessionActivation}) {
  return DiscoveredSensor(
    driverId: 'aidex',
    deviceId: 'AA:BB:CC:DD:EE:FF',
    displayName: 'AiDEX-2222293Q2E',
    storageKey: 'serial:2222293Q2E',
    rssi: -40,
    capabilities: const CgmCapabilities(
      supportsDirectBle: true,
      supportsVendorPairing: true,
      supportsHistory: true,
      supportsDiagnostics: true,
      supportsCalibration: true,
      supportsAutoUpdateControl: true,
    ),
    metadata: <String, String>{
      'serial': '2222293Q2E',
      if (allowSessionActivation != null)
        cgmAllowSessionActivationMetadataKey: allowSessionActivation.toString(),
    },
  );
}

class _FakeBleTransport implements BleTransport {
  _FakeBleTransport({
    this.failDiscoverServicesOnce = false,
    this.autoUpdateEnabled = true,
    this.initialSessionStart,
    this.initialElapsedMinutes,
    this.initialSessionStopped,
    this.uninitialized = false,
    this.malformedSessionStart = false,
    this.requireBondBeforeDiscovery = false,
    this.requireBondBeforeNotifications = false,
    this.disconnectDuringBonding = false,
    this.bondFailure,
    this.historyRangePayload,
    this.reconnectFailure,
    this.initialConnectStarted,
    this.initialConnectRelease,
    this.initialBondStateReadStarted,
    this.initialBondStateReadRelease,
    this.firstDisconnectStarted,
    this.firstDisconnectRelease,
  }) : _isBonded =
           !requireBondBeforeDiscovery &&
           !requireBondBeforeNotifications &&
           bondFailure == null,
       _discoverServicesFailurePending = failDiscoverServicesOnce;

  final bool failDiscoverServicesOnce;
  final bool autoUpdateEnabled;
  final DateTime? initialSessionStart;
  final int? initialElapsedMinutes;
  final bool? initialSessionStopped;
  final bool uninitialized;
  final bool malformedSessionStart;
  final bool requireBondBeforeDiscovery;
  final bool requireBondBeforeNotifications;
  final bool disconnectDuringBonding;
  final BleFailure? bondFailure;
  final List<int>? historyRangePayload;
  final BleFailure? reconnectFailure;
  final Completer<void>? initialConnectStarted;
  final Completer<void>? initialConnectRelease;
  final Completer<void>? initialBondStateReadStarted;
  final Completer<void>? initialBondStateReadRelease;
  final Completer<void>? firstDisconnectStarted;
  final Completer<void>? firstDisconnectRelease;
  final List<_FakeBleConnection> connections = <_FakeBleConnection>[];
  final List<String> operations = <String>[];
  bool _discoverServicesFailurePending;
  bool _isBonded;
  late _FakeBleConnection lastConnection;

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final attempt = connections.length + 1;
    operations.add('connect:$attempt');
    final failure = reconnectFailure;
    if (attempt == 2 && failure != null) {
      throw failure;
    }
    lastConnection = _FakeBleConnection(
      deviceId,
      failDiscoverServices: _discoverServicesFailurePending,
      autoUpdateEnabled: autoUpdateEnabled,
      initialSessionStart: initialSessionStart,
      initialElapsedMinutes: initialElapsedMinutes,
      initialSessionStopped: initialSessionStopped,
      uninitialized: uninitialized,
      malformedSessionStart: malformedSessionStart,
      initiallyBonded: _isBonded,
      requireBondBeforeDiscovery: requireBondBeforeDiscovery,
      requireBondBeforeNotifications: requireBondBeforeNotifications,
      disconnectDuringBonding: disconnectDuringBonding,
      bondFailure: bondFailure,
      historyRangePayload: historyRangePayload,
      sharedOperations: operations,
      onDiscoverServicesFailure: () {
        _discoverServicesFailurePending = false;
      },
      onBonded: () => _isBonded = true,
      disconnectStarted: connections.isEmpty ? firstDisconnectStarted : null,
      disconnectRelease: connections.isEmpty ? firstDisconnectRelease : null,
      bondStateReadStarted: connections.isEmpty
          ? initialBondStateReadStarted
          : null,
      bondStateReadRelease: connections.isEmpty
          ? initialBondStateReadRelease
          : null,
    );
    connections.add(lastConnection);
    if (attempt == 1) {
      final connectStarted = initialConnectStarted;
      if (connectStarted != null && !connectStarted.isCompleted) {
        connectStarted.complete();
      }
      await initialConnectRelease?.future;
    }
    return lastConnection;
  }

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {
    yield const BleScanResult(
      deviceId: 'AA:BB:CC:DD:EE:FF',
      deviceName: 'AiDEX-2222293Q2E',
      rssi: -40,
      serviceUuids: <String>[AidexUuids.cgmService],
      manufacturerData: <BleManufacturerData>[
        BleManufacturerData(
          companyId: 0x0059,
          bytes: <int>[
            0x00,
            0x01,
            0x00,
            0x08,
            0x02,
            0x00,
            0x55,
            0x88,
            0x00,
            0x56,
            0x80,
            0x00,
            0x57,
            0x84,
          ],
        ),
      ],
    );
  }
}

class _FakeBleConnection implements BleConnection {
  _FakeBleConnection(
    this.deviceId, {
    bool failDiscoverServices = false,
    bool autoUpdateEnabled = true,
    DateTime? initialSessionStart,
    int? initialElapsedMinutes,
    bool? initialSessionStopped,
    bool uninitialized = false,
    bool malformedSessionStart = false,
    required bool initiallyBonded,
    bool requireBondBeforeDiscovery = false,
    bool requireBondBeforeNotifications = false,
    bool disconnectDuringBonding = false,
    BleFailure? bondFailure,
    List<int>? historyRangePayload,
    required List<String> sharedOperations,
    required void Function() onDiscoverServicesFailure,
    required void Function() onBonded,
    Completer<void>? disconnectStarted,
    Completer<void>? disconnectRelease,
    Completer<void>? bondStateReadStarted,
    Completer<void>? bondStateReadRelease,
  }) : _failDiscoverServices = failDiscoverServices,
       _autoUpdateEnabled = autoUpdateEnabled,
       _requireBondBeforeDiscovery = requireBondBeforeDiscovery,
       _requireBondBeforeNotifications = requireBondBeforeNotifications,
       _disconnectDuringBonding = disconnectDuringBonding,
       _bondFailure = bondFailure,
       _historyRangePayload = historyRangePayload,
       _sharedOperations = sharedOperations,
       _onDiscoverServicesFailure = onDiscoverServicesFailure,
       _onBonded = onBonded,
       _disconnectStarted = disconnectStarted,
       _disconnectRelease = disconnectRelease,
       _bondStateReadStarted = bondStateReadStarted,
       _bondStateReadRelease = bondStateReadRelease,
       _isBonded = initiallyBonded {
    _services = <BleService>[
      const BleService(
        uuid: AidexUuids.deviceInfoService,
        characteristics: <BleCharacteristicRef>[
          BleCharacteristicRef(
            serviceUuid: AidexUuids.deviceInfoService,
            characteristicUuid: AidexUuids.manufacturerName,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.deviceInfoService,
            characteristicUuid: AidexUuids.modelNumber,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.deviceInfoService,
            characteristicUuid: AidexUuids.serialNumber,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.deviceInfoService,
            characteristicUuid: AidexUuids.softwareRevision,
          ),
        ],
      ),
      const BleService(
        uuid: AidexUuids.cgmService,
        characteristics: <BleCharacteristicRef>[
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.measurement,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.feature,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.status,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.sessionStart,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.sessionRunTime,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.racp,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.specificOps,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.f001,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.f002,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.f003,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.cgmService,
            characteristicUuid: AidexUuids.f005,
          ),
        ],
      ),
      const BleService(
        uuid: AidexUuids.bondManagementService,
        characteristics: <BleCharacteristicRef>[
          BleCharacteristicRef(
            serviceUuid: AidexUuids.bondManagementService,
            characteristicUuid: AidexUuids.bondManagementControlPoint,
          ),
          BleCharacteristicRef(
            serviceUuid: AidexUuids.bondManagementService,
            characteristicUuid: AidexUuids.bondManagementFeature,
          ),
        ],
      ),
    ];

    final crypto = deriveAidexCrypto('2222293Q2E');
    _serialIv = crypto.iv;
    _expectedSecret = crypto.secret;
    _rawSeed = Uint8List.fromList(
      List<int>.generate(16, (index) => index + 16),
    );
    _sessionKey = Uint8List.fromList(List<int>.generate(16, (index) => index));
    final pairPlaintext = Uint8List.fromList(<int>[
      ..._sessionKey,
      vendorCrc8(_sessionKey),
    ]);
    _pairResponse = aesCfb128Encrypt(pairPlaintext, _rawSeed, _serialIv);

    final effectiveInitialStart =
        initialSessionStart ??
        (uninitialized ? null : DateTime.parse('2026-04-02T03:27:10Z'));
    final initialStart = effectiveInitialStart == null
        ? () {
            final zeroStart = Uint8List(9);
            final zeroStartCrc = crc16CcittFalse(zeroStart);
            return Uint8List.fromList(<int>[
              ...zeroStart,
              zeroStartCrc & 0xFF,
              (zeroStartCrc >> 8) & 0xFF,
            ]);
          }()
        : buildAidexSessionStartPayload(effectiveInitialStart);
    final initialElapsedMinute =
        initialElapsedMinutes ?? (effectiveInitialStart == null ? 0 : 61);
    _reads[AidexUuids.manufacturerName] = Uint8List.fromList(
      'Microtech Medical'.codeUnits,
    );
    _reads[AidexUuids.modelNumber] = Uint8List.fromList('GX-01S'.codeUnits);
    _reads[AidexUuids.serialNumber] = Uint8List.fromList(
      '2222293Q2E'.codeUnits,
    );
    _reads[AidexUuids.softwareRevision] = Uint8List.fromList('1.8.1'.codeUnits);
    _reads[AidexUuids.feature] = bytesFromHex('419101590c2b');
    _reads[AidexUuids.status] = _statusPayload(
      initialElapsedMinute,
      sessionStopped: initialSessionStopped,
    );
    _reads[AidexUuids.sessionStart] = initialStart;
    if (malformedSessionStart) {
      _reads[AidexUuids.sessionStart] = Uint8List.fromList(<int>[0x01, 0x02]);
    }
    _reads[AidexUuids.sessionRunTime] = bytesFromHex('6801ad8f');
    _reads[AidexUuids.f002] = _pairResponse;
    _reads[AidexUuids.f005] = Uint8List.fromList(<int>[0x00]);
    _reads[AidexUuids.bondManagementFeature] = Uint8List.fromList(<int>[
      0x00,
      0x04,
      0x00,
    ]);
  }

  @override
  final String deviceId;

  late final List<BleService> _services;
  final StreamController<BleConnectionState> _connectionStates =
      StreamController<BleConnectionState>.broadcast();
  final Map<String, StreamController<List<int>>> _notifications =
      <String, StreamController<List<int>>>{};
  final Map<String, Uint8List> _reads = <String, Uint8List>{};
  late final Uint8List _expectedSecret;
  late final Uint8List _rawSeed;
  late final Uint8List _sessionKey;
  late final Uint8List _serialIv;
  late final Uint8List _pairResponse;
  bool _failDiscoverServices;
  bool _autoUpdateEnabled;
  final bool _requireBondBeforeDiscovery;
  final bool _requireBondBeforeNotifications;
  final bool _disconnectDuringBonding;
  final BleFailure? _bondFailure;
  final List<int>? _historyRangePayload;
  final List<String> _sharedOperations;
  final void Function() _onDiscoverServicesFailure;
  final void Function() _onBonded;
  final Completer<void>? _disconnectStarted;
  final Completer<void>? _disconnectRelease;
  final Completer<void>? _bondStateReadStarted;
  final Completer<void>? _bondStateReadRelease;
  bool _didPauseBondStateRead = false;
  bool _isBonded;
  bool _didInjectInvalidHistoryFrame = false;
  bool didVendorUnpair = false;
  bool didClearBondViaBms = false;
  bool didRemoveBond = false;
  bool didSetAutoUpdate = false;
  bool didRequestStartSession = false;
  bool didWriteSessionStart = false;
  int requestedHistoryRangeCount = 0;
  final List<int> requestedHistoryIndices = <int>[];
  final List<String> operations = <String>[];

  @override
  Stream<BleConnectionState> get connectionStates => _connectionStates.stream;

  void emitConnectionError(Object error) {
    _connectionStates.addError(error, StackTrace.current);
  }

  void emitDisconnected() {
    _connectionStates.add(BleConnectionState.disconnected);
  }

  void emitNotificationError(String uuid, Object error) {
    _notifications[uuid]!.addError(error, StackTrace.current);
  }

  void emitMeasurementMinute(int minute) {
    _notifications[AidexUuids.measurement]!.add(<int>[
      0x07,
      0x00,
      100,
      0x00,
      minute & 0xFF,
      (minute >> 8) & 0xFF,
      0x80,
    ]);
  }

  @override
  bool get supportsBondLifecycle => true;

  @override
  Future<BleBondState> currentBondState() async {
    _recordOperation('currentBondState');
    if (!_didPauseBondStateRead) {
      _didPauseBondStateRead = true;
      final bondStateReadStarted = _bondStateReadStarted;
      if (bondStateReadStarted != null && !bondStateReadStarted.isCompleted) {
        bondStateReadStarted.complete();
      }
      await _bondStateReadRelease?.future;
    }
    return _isBonded ? BleBondState.bonded : BleBondState.unbonded;
  }

  @override
  Future<List<BleService>> discoverServices() async {
    _recordOperation('discoverServices');
    if (_requireBondBeforeDiscovery && !_isBonded) {
      throw StateError('Service discovery attempted before bonding');
    }
    if (_failDiscoverServices) {
      _failDiscoverServices = false;
      _onDiscoverServicesFailure();
      throw StateError('Device is disconnected');
    }
    return _services;
  }

  @override
  Future<void> disconnect() async {
    _recordOperation('disconnect');
    final disconnectStarted = _disconnectStarted;
    if (disconnectStarted != null && !disconnectStarted.isCompleted) {
      disconnectStarted.complete();
    }
    await _disconnectRelease?.future;
    await _connectionStates.close();
    for (final controller in _notifications.values) {
      await controller.close();
    }
  }

  @override
  Future<void> ensureBonded() async {
    _recordOperation('ensureBonded');
    final failure = _bondFailure;
    if (failure != null) {
      throw failure;
    }
    if (_disconnectDuringBonding) {
      _recordOperation('bondConnectionDropped');
      _connectionStates.add(BleConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
    }
    _isBonded = true;
    _onBonded();
  }

  @override
  Future<void> removeBond() async {
    didRemoveBond = true;
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) {
    return _notifications
        .putIfAbsent(
          characteristic.characteristicUuid,
          () => StreamController<List<int>>.broadcast(),
        )
        .stream;
  }

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    return _reads[characteristic.characteristicUuid] ?? Uint8List(0);
  }

  @override
  Future<void> requestMtu(int mtu) async {
    _recordOperation('requestMtu:$mtu');
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    _recordOperation('setNotify:${characteristic.characteristicUuid}');
    if (_requireBondBeforeNotifications && !_isBonded) {
      throw BleFailure(
        kind: BleFailureKind.bondRejected,
        operation: BleOperation.subscribe,
        diagnosticCode: 'fake.subscribe.authentication-required',
      );
    }
    _notifications.putIfAbsent(
      characteristic.characteristicUuid,
      () => StreamController<List<int>>.broadcast(),
    );
  }

  void _recordOperation(String operation) {
    operations.add(operation);
    _sharedOperations.add(operation);
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final uuid = characteristic.characteristicUuid;
    if (uuid == AidexUuids.bondManagementControlPoint) {
      expect(value, <int>[0x06]);
      didClearBondViaBms = true;
      return;
    }
    if (uuid == AidexUuids.f001) {
      expect(value, _expectedSecret);
      scheduleMicrotask(() {
        _notifications[AidexUuids.f001]!.add(_rawSeed);
      });
      return;
    }

    if (uuid == AidexUuids.specificOps) {
      final opcode = value.first;
      if (opcode == 0x1A) {
        didRequestStartSession = true;
        _reads[AidexUuids.sessionStart] = buildAidexSessionStartPayload(
          DateTime.parse('2026-04-02T04:28:10Z'),
        );
        _reads[AidexUuids.status] = _statusPayload(61);
        scheduleMicrotask(() {
          _notifications[AidexUuids.specificOps]!.add(<int>[0x1C, 0x1A, 0x01]);
        });
        return;
      }
      if (opcode == 0x02) {
        scheduleMicrotask(() {
          _notifications[AidexUuids.specificOps]!.add(
            buildSpecificOpsRequest(0x03, payload: const <int>[0x01]),
          );
        });
        return;
      }
      if (opcode == 0x01) {
        scheduleMicrotask(() {
          _notifications[AidexUuids.specificOps]!.add(<int>[
            0x1C,
            0x01,
            0x01,
            value[1],
          ]);
        });
        return;
      }
    }

    if (uuid == AidexUuids.sessionStart) {
      didWriteSessionStart = true;
      _reads[AidexUuids.sessionStart] = Uint8List.fromList(value);
      return;
    }

    if (uuid != AidexUuids.f002) {
      return;
    }

    final request = decryptVendorResponse(
      Uint8List.fromList(value),
      _sessionKey,
      _serialIv,
    )!;
    final opcode = AidexVendorOpcode.fromCode(request.opcode)!;
    final requestIndex = request.payload.length < 2
        ? null
        : request.payload[0] | (request.payload[1] << 8);
    if (opcode == AidexVendorOpcode.getHistories &&
        !_didInjectInvalidHistoryFrame) {
      _didInjectInvalidHistoryFrame = true;
      scheduleMicrotask(() {
        _notifications[AidexUuids.f002]!.add(<int>[0xAA, 0x55, 0x01]);
      });
    }
    if (opcode == AidexVendorOpcode.getHistories && requestIndex != null) {
      requestedHistoryIndices.add(requestIndex);
    }
    if (opcode == AidexVendorOpcode.getHistoryRange) {
      requestedHistoryRangeCount += 1;
    }
    final payload = switch (opcode) {
      AidexVendorOpcode.getHistoryRange =>
        _historyRangePayload == null
            ? bytesFromHex('01010001000300')
            : Uint8List.fromList(_historyRangePayload),
      AidexVendorOpcode.getHistories => _historyPage(request.payload),
      AidexVendorOpcode.getRawHistories => _rawHistoryPage(request.payload),
      AidexVendorOpcode.getDeviceInfo => bytesFromHex('01020304'),
      AidexVendorOpcode.getBroadcastData => bytesFromHex('5500'),
      AidexVendorOpcode.getStartTime => buildAidexDateTimeBody(
        DateTime.parse('2026-04-02T04:28:10Z'),
      ),
      AidexVendorOpcode.getSensorCheck => bytesFromHex('0102aa'),
      AidexVendorOpcode.getAutoUpdateStatus => Uint8List.fromList(<int>[
        0x01,
        _autoUpdateEnabled ? 0x01 : 0x00,
      ]),
      AidexVendorOpcode.setAutoUpdateStatus => () {
        didSetAutoUpdate = true;
        _autoUpdateEnabled =
            request.payload.isNotEmpty && request.payload.first == 0x01;
        return Uint8List.fromList(<int>[
          0x01,
          request.payload.isNotEmpty ? request.payload.first : 0x00,
        ]);
      }(),
      AidexVendorOpcode.setDynamicAdvMode => Uint8List.fromList(<int>[0x01]),
      AidexVendorOpcode.getCalibrationRange => bytesFromHex('01010002000200'),
      AidexVendorOpcode.getCalibration => Uint8List.fromList(<int>[
        0x01,
        ...request.payload,
        0x55,
        0x00,
      ]),
      AidexVendorOpcode.calibration => Uint8List.fromList(<int>[0x01]),
      AidexVendorOpcode.getLogRange => bytesFromHex('01010002000200'),
      AidexVendorOpcode.getLogs => Uint8List.fromList(<int>[
        0x01,
        ...request.payload,
        0xAB,
        0xCD,
      ]),
      AidexVendorOpcode.getErrorLogs => bytesFromHex('beef'),
      AidexVendorOpcode.unpair => () {
        didVendorUnpair = true;
        return Uint8List.fromList(<int>[0x01]);
      }(),
      AidexVendorOpcode.reset ||
      AidexVendorOpcode.shelfMode ||
      AidexVendorOpcode.clearStorage ||
      AidexVendorOpcode.setGcBiasTrimming ||
      AidexVendorOpcode.setGcImeasTrimming ||
      AidexVendorOpcode.newSensor => Uint8List.fromList(<int>[0x01]),
    };
    final response = buildVendorCommand(
      opcode,
      _sessionKey,
      _serialIv,
      payload: payload,
    );
    scheduleMicrotask(() {
      _notifications[AidexUuids.f002]!.add(response);
    });
  }

  Uint8List _historyPage(Uint8List payload) {
    final index = payload[0] | (payload[1] << 8);
    if (index >= 3) {
      return Uint8List.fromList(<int>[0x01, ...payload, 87, 0x80]);
    }
    return Uint8List.fromList(<int>[
      0x01,
      ...payload,
      84 + index,
      0x80,
      85 + index,
      0x84,
    ]);
  }

  Uint8List _rawHistoryPage(Uint8List payload) {
    final index = payload[0] | (payload[1] << 8);
    if (index >= 3) {
      return Uint8List.fromList(<int>[0x01, ...payload, 103, 0x80]);
    }
    return Uint8List.fromList(<int>[
      0x01,
      ...payload,
      100 + index,
      0x80,
      101 + index,
      0x84,
    ]);
  }

  Uint8List _statusPayload(int minute, {bool? sessionStopped}) {
    final body = <int>[
      minute & 0xFF,
      (minute >> 8) & 0xFF,
      (sessionStopped ?? minute == 0) ? 0x01 : 0x00,
      0x02,
      0x00,
    ];
    final crc = crc16CcittFalse(body);
    return Uint8List.fromList(<int>[...body, crc & 0xFF, (crc >> 8) & 0xFF]);
  }
}
