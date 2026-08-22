import 'dart:async';
import 'dart:convert';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/messaging/message_context_builder.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'live-notification glucose consent stays explicit and reversible',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ProductionTestDriver(),
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();

      expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
      expect(
        await controller.updateSensitiveLiveActivityContent(enabled: true),
        isTrue,
      );
      expect(controller.sensitiveLiveActivityContentEnabled, isTrue);
      expect(
        await controller.updateSensitiveLiveActivityContent(enabled: false),
        isTrue,
      );
      expect(controller.sensitiveLiveActivityContentEnabled, isFalse);

      controller.dispose();
    },
  );

  test('failed live-notification publish rolls consent back closed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final nativeWrites = <bool>[];
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        nativeWrites.add(enabled);
      },
      liveActivityPrivacyRefresh: () async {
        throw StateError('simulated publish failure');
      },
    );

    await controller.initialize();

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isFalse,
    );
    expect(nativeWrites, <bool>[true, false]);
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
    expect(controller.liveActivityPrivacyUpdateInFlight, isFalse);
    expect(controller.lastError, contains('Updating lock-screen privacy'));

    controller.dispose();
  });

  test('failed redacted refresh keeps withdrawn consent disabled', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final nativeWrites = <bool>[];
    var failRefresh = false;
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        nativeWrites.add(enabled);
      },
      liveActivityPrivacyRefresh: () async {
        if (failRefresh) {
          throw StateError('simulated redacted refresh failure');
        }
      },
    );

    await controller.initialize();
    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isTrue,
    );
    failRefresh = true;

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: false),
      isFalse,
    );
    expect(nativeWrites, <bool>[true, false]);
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);

    controller.dispose();
  });

  test('failed native withdrawal still fails closed in Flutter', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    var nativeEnabled = false;
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        if (!enabled) {
          throw StateError('simulated withdrawal persistence failure');
        }
        nativeEnabled = enabled;
      },
      liveActivityPrivacyRefresh: () async {},
    );

    await controller.initialize();
    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isTrue,
    );
    expect(nativeEnabled, isTrue);
    expect(controller.sensitiveLiveActivityContentEnabled, isTrue);

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: false),
      isFalse,
    );
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
    expect(controller.liveActivityPrivacyUpdateInFlight, isFalse);

    controller.dispose();
  });

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

  test(
    'user-action BLE failure does not auto-retry or archive an unverified sensor',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
        reconnectDelay: Duration.zero,
      );
      final failure = BleFailure(
        kind: BleFailureKind.sensorPossiblyInUse,
        operation: BleOperation.bond,
        diagnosticCode: 'fbp.android.bond.busy',
      );

      await controller.initialize();
      await controller.connect(sensor);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          metadata: failure.toMetadata(),
          lastError: 'Bluetooth setup could not be completed.',
        ),
      );
      await _drainEventQueue();

      expect(controller.connectionRequiresUserAction, isTrue);
      expect(controller.lastError, contains('another phone'));
      expect(driver.connectedSensors, hasLength(1));

      await controller.chooseAnotherSensor();
      expect(controller.snapshot, isNull);
      expect(controller.archivedSensors, isEmpty);

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'terminal P02 snapshot survives forced freshness during listener attachment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final failure = BleFailure(
        kind: BleFailureKind.bondRejected,
        operation: BleOperation.bond,
        diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
      );
      final terminalSnapshot = _testSnapshot(
        sensor,
        stage: CgmSyncStage.error,
        metadata: <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
          ...failure.toMetadata(),
        },
        lastError: 'Bluetooth setup could not be completed.',
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
        snapshotOnSnapshotsAccess: terminalSnapshot,
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
        reconnectDelay: Duration.zero,
      );

      await controller.initialize();
      await controller
          .connect(sensor)
          .timeout(const Duration(milliseconds: 100));

      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(
        controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.bond,
      );
      expect(
        BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
        'aidex.bond.sensor-paired-os-unbonded',
      );
      expect(controller.connectionRequiresUserAction, isTrue);
      expect(controller.lastError, isNotNull);
      expect(driver.connectedSensors, hasLength(1));

      await controller.ensureFreshData(force: true);

      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(
        controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.bond,
      );
      expect(
        BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
        'aidex.bond.sensor-paired-os-unbonded',
      );
      expect(session.refreshLiveDataCalls, 0);
      expect(session.syncHistoryCalls, 0);

      controller.dispose();
      await driver.close();
    },
  );

  test('attached terminal P02 snapshot blocks forced freshness', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final failure = BleFailure(
      kind: BleFailureKind.bondRejected,
      operation: BleOperation.bond,
      diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
    );
    final terminalSnapshot = _testSnapshot(
      sensor,
      stage: CgmSyncStage.error,
      metadata: <String, String>{
        aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
        ...failure.toMetadata(),
      },
      lastError: 'Bluetooth setup could not be completed.',
    );
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(terminalSnapshot);
    await _drainEventQueue();
    await controller.ensureFreshData(force: true);

    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(
      controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
      AidexSetupPhase.bond,
    );
    expect(
      BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
      'aidex.bond.sensor-paired-os-unbonded',
    );
    expect(session.refreshLiveDataCalls, 0);
    expect(session.syncHistoryCalls, 0);

    controller.dispose();
    await driver.close();
  });

  test('refresh transition to P02 error cannot start history sync', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final failure = BleFailure(
      kind: BleFailureKind.bondRejected,
      operation: BleOperation.bond,
      diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
    );
    final terminalSnapshot = _testSnapshot(
      sensor,
      stage: CgmSyncStage.error,
      metadata: <String, String>{
        aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
        ...failure.toMetadata(),
      },
      lastError: 'Bluetooth setup could not be completed.',
    );
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.ready),
      snapshotOnRefreshLiveData: terminalSnapshot,
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );

    await controller.initialize();
    await controller.connect(sensor);
    await _drainEventQueue();
    await controller.ensureFreshData(force: true);

    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(
      controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
      AidexSetupPhase.bond,
    );
    expect(
      BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
      'aidex.bond.sensor-paired-os-unbonded',
    );
    expect(session.refreshLiveDataCalls, 1);
    expect(session.syncHistoryCalls, 0);

    await _drainEventQueue();
    controller.dispose();
    await driver.close();
  });

  test('unclassified initial BLE setup failure does not auto-retry', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );
    await controller.initialize();
    await controller.connect(sensor);
    session.emit(
      _testSnapshot(
        sensor,
        stage: CgmSyncStage.error,
        lastError: 'initializing session failed (StateError)',
      ),
    );
    await _drainEventQueue();

    expect(controller.connectionRequiresUserAction, isFalse);
    expect(driver.connectedSensors, hasLength(1));

    controller.dispose();
    await driver.close();
  });

  testWidgets('unverified disconnect exposes manual BLE recovery actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );
    final failure = BleFailure(
      kind: BleFailureKind.deviceDisconnected,
      operation: BleOperation.connect,
      diagnosticCode: 'aidex.connection.disconnected',
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(
      _testSnapshot(
        sensor,
        stage: CgmSyncStage.disconnected,
        metadata: failure.toMetadata(),
        lastError: 'BLE connection lost',
      ),
    );

    expect(controller.connectionRequiresUserAction, isTrue);
    expect(driver.connectedSensors, hasLength(1));

    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(
          preferences: preferences,
          writesAllowed: false,
        )..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('retryBleSetupButton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chooseAnotherSensorButton')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
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
        jsonDecode(store.getString('openHealth.lastSensor')!)
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
        history.where((reading) => reading.source == CgmRecordSource.broadcast),
        hasLength(1),
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'minute 59 stays out of presentation at the minute 60 boundary',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final boundary = DateTime.now();
      final sessionStart = boundary.subtract(const Duration(minutes: 60));
      final minute59 = _reading(
        valueMgdl: 171,
        sensorMinute: 59,
        recordedAt: sessionStart.add(const Duration(minutes: 59)),
      );
      final minute60 = _reading(
        valueMgdl: 112,
        sensorMinute: 60,
        recordedAt: boundary,
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[minute59],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();
      await controller.connect(sensor);
      await _drainEventQueue();

      expect(controller.latestReading?.sensorMinute, 59);
      expect(controller.displayLatestReading, isNull);
      final waitingContext = buildMessageContext(controller, now: boundary);
      expect(waitingContext.isWarmingUp, isFalse);
      expect(waitingContext.hasReadings, isFalse);

      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[minute59, minute60],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      await _drainEventQueue();

      expect(controller.displayLatestReading?.sensorMinute, 60);
      expect(
        buildMessageContext(controller, now: boundary).hasReadings,
        isTrue,
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'active presentation history excludes the sensor warmup window',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final sessionStart = DateTime.now().subtract(const Duration(hours: 2));
      final history = <CgmReading>[
        for (final minute in <int>[0, 59, 60, 61])
          _reading(
            valueMgdl: 100 + minute.toDouble(),
            sensorMinute: minute,
            recordedAt: sessionStart.add(Duration(minutes: minute)),
          ),
      ];
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: history,
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();
      await controller.connect(sensor);
      await _drainEventQueue();

      expect(controller.snapshot!.history, hasLength(4));
      expect(
        controller.visibleHistory.map((reading) => reading.sensorMinute),
        <int?>[60, 61],
      );
      expect(
        controller.allHistoricalReadings.map((reading) => reading.sensorMinute),
        <int?>[60, 61],
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
        sensorMinute: 30,
        recordedAt: sessionStart.add(const Duration(minutes: 30)),
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
      expect(
        controller
            .displayReadingsForArchivedSensor(archived)
            .map((reading) => reading.valueMgdl),
        <double>[139],
      );
      expect(
        controller.allHistoricalReadings.map((reading) => reading.valueMgdl),
        <double>[139],
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

  test(
    'confirmed sensor transfer uses the capability then clears selection',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(CgmBondTransferScope.allLe),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(controller.canMoveSensorToAnotherPhone, isTrue);
      final plan = await controller.inspectSensorTransfer();
      expect(plan.removesAllLeBonds, isTrue);
      expect(driver.session!.inspectCalls, 1);

      await controller.moveSensorToAnotherPhone(plan);

      expect(driver.session!.executeCalls, 1);
      expect(driver.session!.normalDisconnectCalls, 1);
      expect(controller.snapshot, isNull);
      expect(controller.canMoveSensorToAnotherPhone, isFalse);
      controller.dispose();
    },
  );

  test(
    'unknown sensor transfer outcome stays selected and is privacy safe',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
        executeFailure: const CgmBondTransferException(
          CgmBondTransferFailureKind.sensorResponseUnknown,
          outcome: CgmBondTransferOutcome.unknown,
        ),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);
      final plan = await controller.inspectSensorTransfer();

      await expectLater(
        controller.moveSensorToAnotherPhone(plan),
        throwsA(isA<CgmBondTransferException>()),
      );

      expect(driver.session!.executeCalls, 1);
      expect(driver.session!.normalDisconnectCalls, 0);
      expect(controller.snapshot, isNotNull);
      expect(controller.lastError, contains('Do not retry'));
      expect(controller.lastError, isNot(contains('device-id-private')));
      await controller.disconnect();
      controller.dispose();
    },
  );

  test('transfer state must persist before the driver can write', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failSetPrefix: 'openHealth.bondTransfer.',
    );
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);
    final plan = await controller.inspectSensorTransfer();

    await expectLater(
      controller.moveSensorToAnotherPhone(plan),
      throwsA(
        isA<CgmBondTransferException>()
            .having(
              (failure) => failure.kind,
              'kind',
              CgmBondTransferFailureKind.statePersistenceFailed,
            )
            .having(
              (failure) => failure.outcome,
              'outcome',
              CgmBondTransferOutcome.notStarted,
            ),
      ),
    );

    expect(driver.session!.executeCalls, 0);
    expect(controller.snapshot, isNotNull);
    expect(controller.lastError, contains('Do not retry'));
    await controller.disconnect();
    controller.dispose();
  });

  test(
    'accepted transfer tombstone blocks reconnect after process death',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
        executeFailureAfterAccepted: const CgmBondTransferException(
          CgmBondTransferFailureKind.disconnectUnconfirmed,
          outcome: CgmBondTransferOutcome.sensorAccepted,
        ),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final sensor = controller.sensors.single;
      await controller.connect(sensor);
      await _drainEventQueue();
      final plan = await controller.inspectSensorTransfer();

      await expectLater(
        controller.moveSensorToAnotherPhone(plan),
        throwsA(isA<CgmBondTransferException>()),
      );

      final tombstoneKey = 'openHealth.bondTransfer.${sensor.storageKey}';
      expect(store.getString(tombstoneKey), 'sensor-accepted');
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      controller.dispose();

      final restoredDriver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final restored = CgmAppController(
        preferences: preferences,
        driver: restoredDriver,
        healthStateStore: store,
        reconnectDelay: Duration.zero,
      );
      await restored.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(restoredDriver.connectCalls, 0);
      expect(restored.snapshot?.stage, CgmSyncStage.error);
      expect(
        restored.snapshot?.metadata[cgmBondTransferStateMetadataKey],
        'sensor-accepted',
      );
      expect(restored.lastError, contains('Do not retry'));

      await restored.disconnect();
      expect(store.getString(tombstoneKey), 'sensor-accepted');
      expect(restored.snapshot, isNotNull);

      await restored.acknowledgeInterruptedSelectedSensorTransfer();
      expect(store.getString(tombstoneKey), isNull);
      expect(restored.snapshot, isNull);
      restored.dispose();
    },
  );

  test('normal disconnect cannot interrupt an executing transfer', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final started = Completer<void>();
    final release = Completer<void>();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.allLe),
      executeStarted: started,
      executeRelease: release,
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);
    final plan = await controller.inspectSensorTransfer();

    final transfer = controller.moveSensorToAnotherPhone(plan);
    await started.future;
    expect(controller.bondTransferInFlight, isTrue);

    await controller.disconnect();

    expect(driver.session!.normalDisconnectCalls, 0);
    expect(controller.snapshot, isNotNull);
    release.complete();
    await transfer;

    expect(driver.session!.normalDisconnectCalls, 1);
    expect(controller.snapshot, isNull);
    controller.dispose();
  });

  test('transfer confirmation cannot target a replacement session', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    final sensor = controller.sensors.single;
    await controller.connect(sensor);
    final inspectedSession = driver.session!;
    final plan = await controller.inspectSensorTransfer();

    await controller.disconnect();
    await controller.connect(sensor);
    final replacementSession = driver.session!;
    expect(replacementSession, isNot(same(inspectedSession)));

    await expectLater(
      controller.moveSensorToAnotherPhone(plan),
      throwsA(
        isA<CgmBondTransferException>().having(
          (failure) => failure.kind,
          'kind',
          CgmBondTransferFailureKind.sessionNotReady,
        ),
      ),
    );

    expect(inspectedSession.executeCalls, 0);
    expect(replacementSession.executeCalls, 0);
    await controller.disconnect();
    controller.dispose();
  });

  test(
    'orphan unknown marker stays fail closed without a clear action',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = 'openHealth.bondTransfer.${sensor.storageKey}';
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{tombstoneKey: 'outcome-unknown'},
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final scannedSensor = controller.sensors.single;

      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isTrue);
      expect(
        controller.canAcknowledgeInterruptedSensorTransfer(scannedSensor),
        isFalse,
      );
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 0);

      await expectLater(
        controller.acknowledgeInterruptedSensorTransfer(scannedSensor),
        throwsA(
          isA<CgmBondTransferException>()
              .having(
                (failure) => failure.kind,
                'kind',
                CgmBondTransferFailureKind.sensorResponseUnknown,
              )
              .having(
                (failure) => failure.outcome,
                'outcome',
                CgmBondTransferOutcome.unknown,
              ),
        ),
      );

      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), 'outcome-unknown');
      controller.dispose();
    },
  );

  test(
    'unknown selected marker cannot use the accepted-state bypass',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = 'openHealth.bondTransfer.${sensor.storageKey}';
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          tombstoneKey: 'outcome-unknown',
        },
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        reconnectDelay: Duration.zero,
      );
      await controller.initialize();

      await controller.disconnect(acknowledgeInterruptedTransfer: true);

      expect(store.getString(tombstoneKey), 'outcome-unknown');
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      expect(controller.snapshot, isNotNull);
      expect(controller.lastError, contains('Do not reconnect'));
      expect(driver.connectCalls, 0);
      await expectLater(
        controller.acknowledgeInterruptedSelectedSensorTransfer(),
        throwsA(
          isA<CgmBondTransferException>().having(
            (failure) => failure.kind,
            'kind',
            CgmBondTransferFailureKind.sensorResponseUnknown,
          ),
        ),
      );
      controller.dispose();
    },
  );

  test(
    'orphan accepted marker requires explicit local acknowledgment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = 'openHealth.bondTransfer.${sensor.storageKey}';
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{tombstoneKey: 'sensor-accepted'},
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final scannedSensor = controller.sensors.single;

      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isTrue);
      expect(
        controller.canAcknowledgeInterruptedSensorTransfer(scannedSensor),
        isTrue,
      );
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), 'sensor-accepted');

      await controller.acknowledgeInterruptedSensorTransfer(scannedSensor);

      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), isNull);
      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isFalse);
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 1);
      await controller.disconnect();
      controller.dispose();
    },
  );

  test('normal disconnect never invokes sensor bond transfer', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    await controller.disconnect();

    expect(driver.session!.inspectCalls, 0);
    expect(driver.session!.executeCalls, 0);
    expect(driver.session!.normalDisconnectCalls, 1);
    controller.dispose();
  });
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
    return _delegate.scan(timeout: timeout, allowDuplicates: allowDuplicates);
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

class _BondTransferDriver extends _ProductionTestDriver {
  _BondTransferDriver({
    required this.plan,
    this.executeFailure,
    this.executeFailureAfterAccepted,
    this.executeStarted,
    this.executeRelease,
  });

  final CgmBondTransferPlan plan;
  final Exception? executeFailure;
  final Exception? executeFailureAfterAccepted;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  _BondTransferSession? session;
  int connectCalls = 0;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCalls += 1;
    return session = _BondTransferSession(
      await super.connect(sensor),
      plan: plan,
      executeFailure: executeFailure,
      executeFailureAfterAccepted: executeFailureAfterAccepted,
      executeStarted: executeStarted,
      executeRelease: executeRelease,
    );
  }
}

class _BondTransferSession implements CgmSession, CgmBondTransferSession {
  _BondTransferSession(
    this._delegate, {
    required this.plan,
    this.executeFailure,
    this.executeFailureAfterAccepted,
    this.executeStarted,
    this.executeRelease,
  });

  final CgmSession _delegate;
  final CgmBondTransferPlan plan;
  final Exception? executeFailure;
  final Exception? executeFailureAfterAccepted;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  int inspectCalls = 0;
  int executeCalls = 0;
  int normalDisconnectCalls = 0;

  @override
  Future<CgmBondTransferPlan> inspectBondTransfer() async {
    inspectCalls += 1;
    return plan;
  }

  @override
  Future<void> executeBondTransfer(
    CgmBondTransferPlan plan, {
    required Future<void> Function() onSensorAccepted,
  }) async {
    executeCalls += 1;
    expect(plan, this.plan);
    final started = executeStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final release = executeRelease;
    if (release != null) {
      await release.future;
    }
    final failure = executeFailure;
    if (failure != null) {
      throw failure;
    }
    await onSensorAccepted();
    final acceptedFailure = executeFailureAfterAccepted;
    if (acceptedFailure != null) {
      throw acceptedFailure;
    }
  }

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
  Future<void> disconnect() async {
    normalDisconnectCalls += 1;
    await _delegate.disconnect();
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() =>
      _delegate.fetchCalibrations();

  @override
  Future<void> refresh() => _delegate.refresh();

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() =>
      _delegate.refreshDiagnostics();

  @override
  Future<void> refreshLiveData() => _delegate.refreshLiveData();

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) => _delegate.submitCalibration(
    glucoseMgdl: glucoseMgdl,
    sensorMinute: sensorMinute,
    recordedAt: recordedAt,
  );

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) => _delegate.syncHistory(
    includeRawHistory: includeRawHistory,
    requestedStartOffset: requestedStartOffset,
  );
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
  _ControllableHealthStateStore({
    this.failSetPrefix,
    this.failRemovePrefix,
    Map<String, String> initialValues = const <String, String>{},
  }) {
    _values.addAll(initialValues);
  }

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
  String? lastError,
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
    lastError: lastError,
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
  _ControlledSession(
    this._current, {
    CgmSessionSnapshot? snapshotOnSnapshotsAccess,
    CgmSessionSnapshot? snapshotOnRefreshLiveData,
  }) : _snapshotOnSnapshotsAccess = snapshotOnSnapshotsAccess,
       _snapshotOnRefreshLiveData = snapshotOnRefreshLiveData;

  CgmSessionSnapshot _current;
  CgmSessionSnapshot? _snapshotOnSnapshotsAccess;
  CgmSessionSnapshot? _snapshotOnRefreshLiveData;
  int refreshLiveDataCalls = 0;
  int syncHistoryCalls = 0;
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
  Stream<CgmSessionSnapshot> get snapshots {
    final racedSnapshot = _snapshotOnSnapshotsAccess;
    if (racedSnapshot != null) {
      _snapshotOnSnapshotsAccess = null;
      emit(racedSnapshot);
    }
    return _snapshots.stream;
  }

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
  Future<void> refreshLiveData() async {
    refreshLiveDataCalls += 1;
    final refreshedSnapshot = _snapshotOnRefreshLiveData;
    if (refreshedSnapshot != null) {
      _snapshotOnRefreshLiveData = null;
      emit(refreshedSnapshot);
    }
  }

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
  }) async {
    syncHistoryCalls += 1;
  }
}
