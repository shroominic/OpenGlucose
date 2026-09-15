import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';
import 'package:openglucose/src/libre_gen1_streaming_setup.dart';
import 'package:openglucose/src/sensor_connection_policy.dart';
import 'package:openglucose/src/sensor_connection_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.openglucose/libre2'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.openglucose/libre2'),
          null,
        );
  });

  const savedLibre = DiscoveredSensor(
    driverId: 'libre2-gen1',
    deviceId: 'synthetic-saved-libre',
    displayName: 'synthetic-private-name',
    storageKey: 'synthetic-private-storage',
    rssi: 0,
    capabilities: CgmCapabilities(supportsDirectBle: true),
  );

  CgmSessionSnapshot receivedWithoutCurrent(
    DiscoveredSensor sensor, {
    String timing = 'observed',
    String committed = 'true',
    String phase = 'validatedPacket',
    CgmSyncStage stage = CgmSyncStage.syncing,
    String? error,
  }) => CgmSessionSnapshot(
    stage: stage,
    statusText: 'Synthetic reception',
    sensor: sensor,
    capabilities: sensor.capabilities,
    sessionInfo: const CgmSessionInfo(elapsedMinutes: 600),
    history: [
      CgmReading(
        valueMgdl: 101,
        source: CgmRecordSource.vendor,
        sensorMinute: 585,
        recordedAt: DateTime.utc(2030),
        isDisplayProvisional: true,
      ),
    ],
    metadata: {
      cgmAutomaticReconnectAllowedMetadataKey: 'false',
      'cgm.libre2.observationCommitted': committed,
      'cgm.libre2.phase': phase,
      'cgm.libre2.timing': timing,
      'cgm.libre2.decoder': 'invalidData',
    },
    lastError: error,
  );

  testWidgets(
    'inline Libre setup completes on durable history-only reception once',
    (tester) async {
      final session = _EmittingSession(savedLibre);
      final driver = _ControlledDriver(
        driverId: 'libre2-gen1',
        discoveredSensors: [savedLibre],
        connectSessionBuilder: (_) => session,
      );
      var completed = 0;
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        inline: true,
        onConnected: () => completed++,
      );
      await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
      expect(completed, 0);
      session.emit(receivedWithoutCurrent(savedLibre));
      for (var index = 0; index < 20; index++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(completed, 1);
      expect(controller.snapshot?.stage, CgmSyncStage.syncing);
      expect(controller.displayLatestReading, isNull);
      expect(controller.visibleHistory, hasLength(1));
      session.emit(receivedWithoutCurrent(savedLibre));
      await tester.pump();
      await tester.pump();
      expect(completed, 1);
      await _disposeConnectionScreen(tester, controller);
      await session.close();
    },
  );

  for (final variant in [
    'pending',
    'replayed',
    'stale',
    'restored',
    'failed',
    'cleanup',
    'wrongTarget',
  ]) {
    testWidgets('Libre setup does not finish for $variant history evidence', (
      tester,
    ) async {
      final session = _EmittingSession(savedLibre);
      final driver = _ControlledDriver(
        driverId: 'libre2-gen1',
        discoveredSensors: [savedLibre],
        connectSessionBuilder: (_) => session,
      );
      var completed = 0;
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        inline: true,
        onConnected: () => completed++,
      );
      await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
      const other = DiscoveredSensor(
        driverId: 'libre2-gen1',
        deviceId: 'other-synthetic-target',
        displayName: 'Synthetic other',
        storageKey: 'other-synthetic-target',
        rssi: 0,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      );
      session.emit(
        receivedWithoutCurrent(
          variant == 'wrongTarget' ? other : savedLibre,
          committed: variant == 'pending' ? 'false' : 'true',
          timing: switch (variant) {
            'replayed' => 'repeatedOrRegressed',
            'stale' => 'stale',
            _ => 'observed',
          },
          phase: variant == 'restored' ? 'awaitingPacket' : 'validatedPacket',
          stage: variant == 'cleanup'
              ? CgmSyncStage.error
              : CgmSyncStage.syncing,
          error: switch (variant) {
            'failed' => 'libre2.observationStorageUnavailable',
            'cleanup' => 'libre2.cleanupUnconfirmed',
            _ => null,
          },
        ),
      );
      for (var index = 0; index < 15; index++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(completed, 0);
      expect(controller.displayLatestReading, isNull);
      await _disposeConnectionScreen(tester, controller);
      await session.close();
    });
  }

  testWidgets(
    'modal Libre setup returns after durable history-only reception',
    (tester) async {
      final session = _EmittingSession(savedLibre);
      final driver = _ControlledDriver(
        driverId: 'libre2-gen1',
        discoveredSensors: [savedLibre],
        connectSessionBuilder: (_) => session,
      );
      final controller = await _createController(driver);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    unawaited(showSensorConnectionFlow(context, controller)),
                child: const Text('Open setup'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open setup'));
      await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
      session.emit(receivedWithoutCurrent(savedLibre));
      for (var index = 0; index < 20; index++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(
        find.byKey(const ValueKey('sensorConnectionScreen')),
        findsNothing,
      );
      expect(find.text('Open setup'), findsOneWidget);
      expect(controller.displayLatestReading, isNull);
      await _disposeConnectionScreen(tester, controller);
      await session.close();
    },
  );

  testWidgets(
    'Libre save failure leaves pending progress for closed recovery actions',
    (tester) async {
      final session = _EmittingSession(savedLibre);
      final driver = _ControlledDriver(
        driverId: 'libre2-gen1',
        discoveredSensors: [savedLibre],
        connectSessionBuilder: (_) => session,
      );
      final store = _ReceptionFailureHealthStateStore();
      var completed = 0;
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        inline: true,
        healthStateStore: store,
        onConnected: () => completed++,
      );
      await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
      session.emit(receivedWithoutCurrent(savedLibre));
      for (var index = 0; index < 10; index++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(store.writeStarted, isTrue);
      expect(controller.hasLibreReceptionSetupFailureFor(savedLibre), isFalse);
      expect(find.byKey(const ValueKey('connectionRetryButton')), findsNothing);
      expect(completed, 0);
      store.release.complete();
      for (var index = 0; index < 20; index++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(controller.hasLibreReceptionSetupFailureFor(savedLibre), isTrue);
      expect(controller.snapshot?.stage, CgmSyncStage.syncing);
      expect(controller.displayLatestReading, isNull);
      expect(completed, 0);
      expect(find.text('Could not connect'), findsOneWidget);
      expect(
        find.textContaining('Sensor setup could not finish.'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-private-storage'), findsNothing);
      expect(
        find.byKey(const ValueKey('connectionRetryButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chooseAnotherSensorButton')),
        findsNothing,
      );
      expect(controller.visibleHistory, hasLength(1));
      await _disposeConnectionScreen(tester, controller);
      await session.close();
    },
  );

  testWidgets('blocked saved NFC setup explains review and disables retry', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final driver = _ControlledDriver(driverId: 'protocol_capture_observation');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
    );
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    nfc.emit(
      const Libre2NfcSetupState.failed(Libre2NfcFailureKind.setupBlocked),
    );
    await tester.pump();
    expect(find.text('Sensor setup needs review'), findsOneWidget);
    expect(
      find.text(
        'Saved sensor setup needs review. No sensor changes were made.',
      ),
      findsOneWidget,
    );
    expect(find.text('Try the NFC tap again'), findsNothing);
    final retry = find.byKey(const ValueKey('libre2NfcRetryButton'));
    expect(tester.widget<FilledButton>(retry).onPressed, isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(nfc.startCalls, 1);
    expect(nfc.retryCalls, 0);
    expect(driver.connectedSensors, isEmpty);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('native read-only Libre setup has no streaming authority', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.openglucose/libre2');
    const events = MethodChannel('com.openglucose/libre2_events');
    const codec = StandardMethodCodec();
    final calls = <String>[];
    String? attemptId;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'capabilities') {
        return {
          'schemaVersion': 1,
          'backend': 'readOnly',
          'readAvailable': true,
          'activationAvailable': false,
          'streamingAvailable': false,
          'receiverAvailable': false,
          'rawCapture': false,
        };
      }
      if (call.method == 'startLibre2NfcSetup') {
        attemptId = (call.arguments as Map)['attemptId'] as String;
        return null;
      }
      if (call.method == 'stopLibre2NfcSetup') {
        expect((call.arguments as Map)['attemptId'], attemptId);
        return null;
      }
      fail('Read-only setup must not invoke ${call.method}');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
    );
    await tester.pumpAndSettle();
    expect(calls, ['capabilities']);
    expect(find.textContaining('NFC'), findsNothing);
    await _openLibre2Nfc(tester);
    await tester.pump();
    expect(calls.where((call) => call == 'startLibre2NfcSetup'), hasLength(1));
    expect(find.text('Hold near the sensor'), findsOneWidget);
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope({
        'attemptId': attemptId!,
        'event': 'metadataRead',
        'model': 'libre2',
        'status': 'notActivated',
      }),
      (_) {},
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('libre2NfcSafeResult')), findsOneWidget);
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
    expect(find.textContaining('Activated'), findsNothing);
    expect(driver.connectedSensors, isEmpty);
    expect(
      calls.toSet(),
      {'capabilities', 'startLibre2NfcSetup'},
    );
    await tester.pump(const Duration(seconds: 106));
    expect(find.text('Scan again to check sensor'), findsOneWidget);
    expect(find.textContaining('before connecting'), findsNothing);
    expect(find.text('Scan again to connect'), findsNothing);
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
    expect(calls.toSet(), {'capabilities', 'startLibre2NfcSetup'});
    await _disposeConnectionScreen(tester, controller);
    await tester.pump();
    expect(
      calls.toSet(),
      {'capabilities', 'startLibre2NfcSetup', 'stopLibre2NfcSetup'},
    );
    debugDefaultTargetPlatformOverride = null;
  });

  for (final scenario in [
    (
      driverId: 'aidex',
      stage: CgmSyncStage.syncing,
      phase: 'awaitingPacket',
      expected: 'Syncing sensor history',
      receiving: false,
    ),
    (
      driverId: 'libre2-gen1',
      stage: CgmSyncStage.connecting,
      phase: 'awaitingPacket',
      expected: 'Connecting to FreeStyle Libre 2',
      receiving: false,
    ),
    (
      driverId: 'libre2-gen1',
      stage: CgmSyncStage.syncing,
      phase: 'loggingIn',
      expected: 'Waiting for verified sensor data.',
      receiving: false,
    ),
    (
      driverId: 'libre2-gen1',
      stage: CgmSyncStage.syncing,
      phase: 'awaitingPacket',
      expected: 'Connected. Waiting for sensor data.',
      receiving: true,
    ),
  ]) {
    testWidgets(
      'connection progress validates driver and stage: ${scenario.driverId}/${scenario.stage.name}/${scenario.phase}',
      (tester) async {
        final sensor = DiscoveredSensor(
          driverId: scenario.driverId,
          deviceId: 'synthetic-progress-sensor',
          displayName: 'Synthetic sensor',
          storageKey: 'synthetic-progress-sensor',
          rssi: -40,
          capabilities: const CgmCapabilities(supportsDirectBle: true),
        );
        final driver = _ControlledDriver(
          driverId: scenario.driverId,
          discoveredSensors: [sensor],
          connectSessionBuilder: (sensor) => _StaticSession(
            sensor,
            stage: scenario.stage,
            metadata: {'cgm.libre2.phase': scenario.phase},
          ),
        );
        final controller = await _pumpConnectionScreen(tester, driver);
        await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
        expect(find.text(scenario.expected), findsOneWidget);
        expect(
          find.byIcon(Icons.bluetooth_connected_rounded),
          scenario.receiving ? findsOneWidget : findsNothing,
        );
        expect(driver.connectedSensors, hasLength(1));
        await _disposeConnectionScreen(tester, controller);
      },
    );
  }

  testWidgets('connection progress scrolls on compact large-text screens', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final driver = _ControlledDriver(
      driverId: 'libre2-gen1',
      discoveredSensors: [savedLibre],
      connectSessionBuilder: (sensor) => _StaticSession(
        sensor,
        metadata: {'cgm.libre2.phase': 'awaitingAdvertisement'},
      ),
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      textScaler: const TextScaler.linear(2),
    );
    await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
    await tester.binding.setSurfaceSize(const Size(320, 300));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final guidance = find.text(
      'Keep the phone and sensor close while setup continues.',
    );
    await tester.ensureVisible(guidance);
    expect(guidance.hitTestable(), findsOneWidget);
    expect(driver.connectedSensors, hasLength(1));
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('Libre connection lost title needs current validated packets', (
    tester,
  ) async {
    for (final config in [
      ('libre2-gen1', '6'),
      ('libre2-gen1', '0'),
      ('aidex', '6'),
    ]) {
      final sensor = DiscoveredSensor(
        driverId: config.$1,
        deviceId: 'synthetic-loss-sensor',
        displayName: 'Synthetic sensor',
        storageKey: 'synthetic-loss-sensor',
        rssi: -40,
        capabilities: const CgmCapabilities(supportsDirectBle: true),
      );
      final nfc = _FakeLibre2NfcSetupSession();
      final driver = _ControlledDriver(
        driverId: config.$1,
        discoveredSensors: [sensor],
        connectSessionBuilder: (sensor) => _StaticSession(
          sensor,
          stage: CgmSyncStage.error,
          lastError: 'libre2.disconnected',
          metadata: {
            'cgm.libre2.phase': 'failed',
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
          },
          diagnostics: [
            CgmDiagnosticItem(
              key: 'libre2.gen1.transport',
              title: 'Libre 2 connection',
              summary: 'synthetic-private-summary',
              fields: {'phase': 'failed', 'validatedPackets': config.$2},
            ),
          ],
        ),
      );
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        inline: true,
        libre2NfcSetupSession: nfc,
      );
      await _scanAndConnectFirstResult(tester);
      final lost = config.$1 == 'libre2-gen1' && config.$2 == '6';
      expect(
        find.text('Connection lost'),
        lost ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Could not connect'),
        lost ? findsNothing : findsOneWidget,
      );
      if (lost) {
        expect(
          find.text(
            'The sensor was sending data, then the connection stopped. '
            'Keep it close and try again.',
          ),
          findsOneWidget,
        );
      }
      await tester.pump(const Duration(seconds: 5));
      expect(driver.connectedSensors, hasLength(1));
      expect(nfc.startCalls, 0);
      expect(nfc.retryCalls, 0);
      await _disposeConnectionScreen(tester, controller);
      await tester.pump();
    }
  });

  testWidgets('saved Libre restore is separate and connects only on a tap', (
    tester,
  ) async {
    var restoreCalls = 0;
    final nfc = _FakeLibre2NfcSetupSession();
    final streaming = _FakeLibreStreamingSession();
    final driver = _ControlledDriver(
      driverId: 'libre2-gen1',
      connectSessionBuilder: (sensor) => _StaticSession(
        sensor,
        metadata: {'cgm.libre2.phase': 'awaitingAdvertisement'},
      ),
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libreGen1StreamingEnabled: true,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingSession: streaming,
      prepareLibreGen1Connection: () async {
        restoreCalls++;
        return savedLibre;
      },
    );
    await tester.pumpAndSettle();
    expect(restoreCalls, 1);
    expect(driver.connectedSensors, isEmpty);
    expect(controller.sensors, isEmpty);
    expect(find.text('Saved Libre 2'), findsOneWidget);
    expect(find.text('No Bluetooth sensors found'), findsOneWidget);
    expect(find.textContaining('synthetic-private'), findsNothing);
    final card = find.byKey(const ValueKey('savedLibreReceiver'));
    expect(
      find.descendant(of: card, matching: find.textContaining('signal')),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('nearby')),
      findsNothing,
    );
    expect(nfc.startCalls, 0);
    expect(streaming.startCalls, 0);
    await tester.tap(find.byKey(const ValueKey('connectSavedLibreReceiver')));
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(driver.connectedSensors, hasLength(1));
    expect(driver.connectedSensors.single.deviceId, savedLibre.deviceId);
    expect(driver.connectedSensors.single.storageKey, savedLibre.storageKey);
    expect(
      driver
          .connectedSensors
          .single
          .metadata[cgmAllowSessionActivationMetadataKey],
      'false',
    );
    expect(find.text('Looking for your Libre 2 sensor'), findsOneWidget);
    expect(controller.snapshot?.stage, CgmSyncStage.connecting);
    expect(find.byIcon(Icons.bluetooth_connected_rounded), findsNothing);
    expect(nfc.startCalls, 0);
    expect(nfc.retryCalls, 0);
    expect(streaming.startCalls, 0);
    expect(restoreCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('nearby Libre selection never grants session activation', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final streaming = _FakeLibreStreamingSession();
    final driver = _ControlledDriver(
      driverId: 'libre2-gen1',
      discoveredSensors: const [savedLibre],
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingSession: streaming,
    );
    await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
    expect(driver.connectedSensors, hasLength(1));
    expect(
      driver
          .connectedSensors
          .single
          .metadata[cgmAllowSessionActivationMetadataKey],
      'false',
    );
    expect(nfc.startCalls, 0);
    expect(nfc.retryCalls, 0);
    expect(streaming.startCalls, 0);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('saved Libre restore requires both enabled flag and driver', (
    tester,
  ) async {
    for (final config in [(false, 'libre2-gen1'), (true, 'aidex')]) {
      var calls = 0;
      final driver = _ControlledDriver(driverId: config.$2);
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        inline: true,
        libreGen1StreamingEnabled: config.$1,
        prepareLibreGen1Connection: () async {
          calls++;
          return savedLibre;
        },
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.byKey(const ValueKey('savedLibreReceiver')), findsNothing);
      expect(driver.scanCalls, 1);
      expect(driver.connectedSensors, isEmpty);
      await _disposeConnectionScreen(tester, controller);
      await tester.pump();
    }
  });

  testWidgets(
    'missing or unreadable saved setup does not block normal search',
    (
      tester,
    ) async {
      for (final mode in ['absent', 'error', 'wrongDriver']) {
        final driver = _ControlledDriver(driverId: 'libre2-gen1');
        final controller = await _pumpConnectionScreen(
          tester,
          driver,
          inline: true,
          libreGen1StreamingEnabled: true,
          prepareLibreGen1Connection: () async {
            if (mode == 'error') {
              throw StateError('synthetic-private-store-error');
            }
            if (mode == 'wrongDriver') {
              return const DiscoveredSensor(
                driverId: 'aidex',
                deviceId: 'synthetic-other',
                displayName: 'synthetic-private-name',
                storageKey: 'synthetic-other',
                rssi: -40,
                capabilities: CgmCapabilities(supportsDirectBle: true),
              );
            }
            return null;
          },
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('savedLibreReceiver')), findsNothing);
        expect(find.textContaining('synthetic-private'), findsNothing);
        expect(find.text("Can't find your sensor?"), findsOneWidget);
        expect(driver.scanCalls, 1);
        expect(driver.connectedSensors, isEmpty);
        if (mode != 'absent') {
          expect(
            find.byKey(const ValueKey('savedLibreRestoreUnavailable')),
            findsOneWidget,
          );
        }
        await _disposeConnectionScreen(tester, controller);
        await tester.pump();
      }
    },
  );

  testWidgets('receiver restore does not grant NFC streaming setup', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final driver = _ControlledDriver(driverId: 'libre2-gen1');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingEnabled: false,
      libreGen1ReceiverRestoreEnabled: true,
      prepareLibreGen1Connection: () async => savedLibre,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('savedLibreReceiver')), findsOneWidget);
    expect(driver.connectedSensors, isEmpty);
    await tester.tap(find.text("Can't find your sensor?"));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chooseLibre2Help')));
    await tester.pumpAndSettle();
    nfc.emit(
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
    expect(driver.connectedSensors, isEmpty);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('saved setup read timeout never revives from a late response', (
    tester,
  ) async {
    final result = Completer<DiscoveredSensor?>();
    final driver = _ControlledDriver(driverId: 'libre2-gen1');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libreGen1StreamingEnabled: true,
      prepareLibreGen1Connection: () => result.future,
    );
    await tester.pumpAndSettle();
    expect(driver.scanCalls, 1);
    expect(find.text('No Bluetooth sensors found'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(
      find.byKey(const ValueKey('savedLibreRestoreUnavailable')),
      findsOneWidget,
    );
    result.complete(savedLibre);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('savedLibreReceiver')), findsNothing);
    expect(driver.connectedSensors, isEmpty);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('saved setup read ignores replaced and disposed completions', (
    tester,
  ) async {
    final first = Completer<DiscoveredSensor?>();
    final second = Completer<DiscoveredSensor?>();
    var calls = 0;
    final driver = _ControlledDriver(driverId: 'libre2-gen1');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libreGen1StreamingEnabled: true,
      prepareLibreGen1Connection: () =>
          ++calls == 1 ? first.future : second.future,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    second.complete(null);
    await tester.pumpAndSettle();
    first.complete(savedLibre);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('savedLibreReceiver')), findsNothing);
    final afterClose = Completer<DiscoveredSensor?>();
    await _disposeConnectionScreen(tester, controller);
    final reopened = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libreGen1StreamingEnabled: true,
      prepareLibreGen1Connection: () => afterClose.future,
    );
    await tester.pumpAndSettle();
    await _disposeConnectionScreen(tester, reopened);
    afterClose.complete(savedLibre);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(driver.connectedSensors, isEmpty);
  });

  testWidgets('inline search hides model help and NFC while scanning', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final controller = await _pumpConnectionScreen(
      tester,
      _BlockingScanDriver(),
      inline: true,
      libre2NfcSetupSession: nfc,
    );
    await tester.pump();
    expect(controller.scanning, isTrue);
    expect(find.text("Can't find your sensor?"), findsNothing);
    expect(find.text('AiDEX / LinX'), findsNothing);
    expect(find.text('FreeStyle Libre 2'), findsNothing);
    expect(find.textContaining('NFC'), findsNothing);
    expect(nfc.startCalls, 0);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('inline model help keeps AiDEX retry on Bluetooth', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      inline: true,
      libre2NfcSetupSession: nfc,
    );
    await tester.pumpAndSettle();
    expect(find.text("Can't find your sensor?"), findsOneWidget);
    expect(find.text('AiDEX / LinX'), findsNothing);
    expect(find.text('FreeStyle Libre 2'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(find.text('Check the name on the sensor box.'), findsOneWidget);
    expect(find.text('Not sure? Check the name on the box.'), findsOneWidget);
    expect(find.textContaining('NFC'), findsNothing);
    expect(nfc.startCalls, 0);
    await tester.tap(find.byKey(const ValueKey('chooseAidexHelp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aidexConnectionHelp')), findsOneWidget);
    expect(find.textContaining('NFC'), findsNothing);
    expect(nfc.startCalls, 0);
    final scanDone = Completer<void>();
    driver.scanBarrier = scanDone.future;
    await tester.tap(find.byKey(const ValueKey('aidexHelpScanAgain')));
    await tester.pump();
    expect(driver.scanCalls, 2);
    expect(controller.scanning, isTrue);
    expect(find.text('AiDEX / LinX'), findsNothing);
    expect(find.text('FreeStyle Libre 2'), findsNothing);
    expect(find.text("Can't find your sensor?"), findsNothing);
    expect(nfc.startCalls, 0);
    scanDone.complete();
    await tester.pumpAndSettle();
    expect(find.text("Can't find your sensor?"), findsOneWidget);
    expect(find.text('Which sensor do you have?'), findsNothing);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('only the Libre model starts NFC and back returns one level', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    var closeCalls = 0;
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(driverId: 'protocol_capture_observation'),
      inline: true,
      onClose: () => closeCalls++,
      libre2NfcSetupSession: nfc,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chooseAidexHelp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorSetupBack')));
    await tester.pumpAndSettle();
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(closeCalls, 0);
    await tester.tap(find.byKey(const ValueKey('chooseLibre2Help')));
    await tester.pump();
    await tester.pump();
    expect(nfc.startCalls, 1);
    expect(find.byKey(const ValueKey('libre2NfcGuide')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Hold near the sensor'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sensorSetupBack')));
    await tester.pumpAndSettle();
    expect(nfc.stopCalls, 1);
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(find.byKey(const ValueKey('libre2NfcGuide')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sensorSetupBack')));
    await tester.pumpAndSettle();
    expect(find.text("Can't find your sensor?"), findsOneWidget);
    expect(find.text('Which sensor do you have?'), findsNothing);
    expect(closeCalls, 0);
    await tester.tap(find.byTooltip('Close sensor setup'));
    expect(closeCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('model help remains reachable after Bluetooth access failures', (
    tester,
  ) async {
    for (final kind in [
      BleFailureKind.bluetoothOff,
      BleFailureKind.permissionRequired,
    ]) {
      final nfc = _FakeLibre2NfcSetupSession();
      final controller = await _pumpConnectionScreen(
        tester,
        _ControlledDriver(
          driverId: 'protocol_capture_observation',
          scanError: BleFailure(
            kind: kind,
            operation: BleOperation.scan,
            diagnosticCode: 'synthetic.scan.failure',
          ),
        ),
        inline: true,
        libre2NfcSetupSession: nfc,
      );
      await tester.pumpAndSettle();
      expect(controller.scanFailure?.kind, kind);
      await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
      await tester.pumpAndSettle();
      expect(find.text('AiDEX / LinX'), findsOneWidget);
      expect(find.text('FreeStyle Libre 2'), findsOneWidget);
      expect(nfc.startCalls, 0);
      await tester.tap(find.byKey(const ValueKey('chooseLibre2Help')));
      await tester.pump();
      await tester.pump();
      expect(nfc.startCalls, 1);
      await _disposeConnectionScreen(tester, controller);
      await tester.pump();
    }
  });

  testWidgets('Libre advertisement wait does not claim a connection', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'libre2-gen1',
      deviceId: 'synthetic-libre',
      displayName: 'FreeStyle Libre 2',
      storageKey: 'synthetic-libre',
      rssi: -40,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(
        driverId: sensor.driverId,
        discoveredSensors: [sensor],
        connectSessionBuilder: (sensor) => _StaticSession(
          sensor,
          stage: CgmSyncStage.connecting,
          metadata: {'cgm.libre2.phase': 'awaitingAdvertisement'},
        ),
      ),
      inline: true,
    );
    await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
    expect(find.text('Looking for your Libre 2 sensor'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_connected_rounded), findsNothing);
    expect(find.textContaining('Connected.'), findsNothing);
    expect(controller.snapshot?.stage, CgmSyncStage.connecting);
    expect(controller.snapshot?.latestReading, isNull);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('Libre errors use closed text and hide unknown raw strings', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'libre2-gen1',
      deviceId: 'synthetic-libre',
      displayName: 'FreeStyle Libre 2',
      storageKey: 'synthetic-libre',
      rssi: -40,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    for (final entry in <(String, String)>[
      (
        'libre2.connectionFailed',
        'Could not connect to your Libre 2 sensor. Keep it close and try again.',
      ),
      (
        'libre2.advertisementUnavailable',
        'Your Libre 2 sensor was not found. Keep it close and try again.',
      ),
      (
        'libre2.oneShotUnavailable',
        'This sensor connection is not supported by this build.',
      ),
      (
        'libre2.connectionFailed synthetic-native-detail',
        'OpenGlucose could not connect to your Libre 2 sensor.',
      ),
      (
        'synthetic-native-detail',
        'OpenGlucose could not connect to your Libre 2 sensor.',
      ),
    ]) {
      final controller = await _pumpConnectionScreen(
        tester,
        _ControlledDriver(
          driverId: sensor.driverId,
          discoveredSensors: [sensor],
          connectSessionBuilder: (sensor) => _StaticSession(
            sensor,
            stage: CgmSyncStage.error,
            lastError: entry.$1,
          ),
        ),
        inline: true,
      );
      await _scanAndConnectFirstResult(tester);
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.textContaining('libre2.'), findsNothing);
      expect(find.textContaining('synthetic-native-detail'), findsNothing);
      expect(controller.snapshot?.stage, CgmSyncStage.error);
      await _disposeConnectionScreen(tester, controller);
      await tester.pump();
    }
  });

  testWidgets(
    'Libre connected transport stays syncing with its closed data status',
    (tester) async {
      const sensor = DiscoveredSensor(
        driverId: 'libre2-gen1',
        deviceId: 'synthetic-libre',
        displayName: 'FreeStyle Libre 2',
        storageKey: 'synthetic-libre',
        rssi: -40,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      );
      for (final entry in <(String, String)>[
        ('awaitingPacket', 'Connected. Waiting for sensor data.'),
        (
          'validatedPacket',
          'Receiving sensor data. Glucose decoding is not ready.',
        ),
      ]) {
        final driver = _ControlledDriver(
          driverId: 'libre2-gen1',
          discoveredSensors: [sensor],
          connectSessionBuilder: (sensor) => _StaticSession(
            sensor,
            stage: CgmSyncStage.syncing,
            metadata: {'cgm.libre2.phase': entry.$1},
          ),
        );
        final controller = await _pumpConnectionScreen(tester, driver);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<String>('connectButton-1')));
        for (var index = 0; index < 12; index++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(find.text(entry.$2), findsOneWidget);
        expect(
          find.text('No glucose reading is available yet.'),
          findsOneWidget,
        );
        expect(controller.snapshot?.stage, CgmSyncStage.syncing);
        expect(find.byIcon(Icons.bluetooth_connected_rounded), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await _disposeConnectionScreen(tester, controller);
        await tester.pump();
      }
    },
  );

  testWidgets(
    'Libre streaming stops the reader then hands verified setup to BLE once',
    (tester) async {
      final readerStopped = Completer<void>();
      final nfc = _FakeLibre2NfcSetupSession(stopBarrier: readerStopped.future);
      final streaming = _FakeLibreStreamingSession();
      final prepared = Completer<DiscoveredSensor?>();
      var prepareCalls = 0;
      final driver = _ControlledDriver(
        driverId: 'protocol_capture_observation',
      );
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        libre2NfcSetupSession: nfc,
        libreGen1StreamingSession: streaming,
        libreGen1StreamingEnabled: true,
        prepareLibreGen1Connection: () {
          prepareCalls++;
          return prepared.future;
        },
      );
      await tester.pumpAndSettle();
      await _openLibre2Nfc(tester);
      await tester.pump();
      nfc.emit(
        const Libre2NfcSetupState.metadataRead(
          model: Libre2SensorModel.libre2,
          sensorStatus: Libre2SensorStatus.warmingUp,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('connectLibre2Sensor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('connectLibre2Sensor')),
      );
      await tester.pump();
      expect(nfc.stopCalls, 1);
      expect(streaming.startCalls, 0);
      readerStopped.complete();
      await tester.pump();
      await tester.pump();
      expect(streaming.startCalls, 1);
      expect(find.text('Tap your sensor again'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('libre2NfcScanAnimation')),
        findsOneWidget,
      );
      streaming.emit(
        const LibreGen1StreamingState(
          LibreGen1StreamingPhase.enablingStreaming,
        ),
      );
      await tester.pump();
      expect(find.text('Setting up Bluetooth'), findsOneWidget);
      expect(driver.connectedSensors, isEmpty);
      streaming.emit(
        const LibreGen1StreamingState(
          LibreGen1StreamingPhase.streamingEnabled,
          lifecycle: Libre2SensorStatus.warmingUp,
        ),
      );
      await tester.pump();
      expect(find.text('Bluetooth setup complete'), findsOneWidget);
      expect(streaming.stopCalls, 1);
      expect(prepareCalls, 1);
      expect(driver.connectedSensors, isEmpty);
      streaming.emit(
        const LibreGen1StreamingState(
          LibreGen1StreamingPhase.streamingEnabled,
          lifecycle: Libre2SensorStatus.warmingUp,
        ),
      );
      prepared.complete(
        const DiscoveredSensor(
          driverId: 'protocol_capture_observation',
          deviceId: 'synthetic-libre',
          displayName: 'FreeStyle Libre 2',
          storageKey: 'synthetic-libre',
          rssi: -40,
          capabilities: CgmCapabilities(supportsDirectBle: true),
        ),
      );
      for (var index = 0; index < 12; index++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(driver.connectedSensors, hasLength(1));
      expect(prepareCalls, 1);
      expect(controller.snapshot?.stage, CgmSyncStage.connecting);
      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('same-read receiver proof hands off without another NFC setup', (
    tester,
  ) async {
    const channel = MethodChannel('com.openglucose/protocol_capture');
    final nfc = _FakeLibre2NfcSetupSession();
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      expect(nfc.stopCalls, 1);
      expect(nfc.completedReadAttemptId, isNull);
      expect(call.method, 'readLibreGen1ReceiverReuseProof');
      expect(call.arguments, {'attemptId': 'synthetic_completed_read'});
      return {
        'attemptId': 'synthetic_completed_read',
        'event': 'receiverReusable',
        'model': 'libre2',
        'lifecycle': 'active',
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final driver = _ControlledDriver(driverId: 'protocol_capture_observation');
    final prepareGate = Completer<void>();
    var prepareCalls = 0;
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingEnabled: true,
      prepareLibreGen1Connection: () async {
        prepareCalls++;
        await prepareGate.future;
        return const DiscoveredSensor(
          driverId: 'protocol_capture_observation',
          deviceId: 'synthetic-reused-receiver',
          displayName: 'FreeStyle Libre 2',
          storageKey: 'synthetic-reused-receiver',
          rssi: 0,
          capabilities: CgmCapabilities(supportsDirectBle: true),
        );
      },
    );
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    await tester.pump();
    nfc.emit(
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('connectLibre2Sensor')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connectLibre2Sensor')));
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(calls, ['readLibreGen1ReceiverReuseProof']);
    expect(prepareCalls, 1);
    expect(driver.connectedSensors, isEmpty);
    expect(find.text('Using saved Bluetooth setup'), findsOneWidget);
    expect(find.text('Bluetooth setup complete'), findsNothing);
    prepareGate.complete();
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(driver.connectedSensors, hasLength(1));
    expect(find.text('Tap your sensor again'), findsNothing);
    expect(find.text('Setup needs a check'), findsNothing);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('expired read and activation proof require a new read', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final streaming = _FakeLibreStreamingSession();
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(driverId: 'protocol_capture_observation'),
      libre2NfcSetupSession: nfc,
      libreGen1StreamingSession: streaming,
      libreGen1StreamingEnabled: true,
    );
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    for (final state in [
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
        isReadExpired: true,
      ),
      const Libre2NfcSetupState.activationVerified(),
    ]) {
      nfc.emit(state);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
      expect(nfc.completedReadAttemptId, isNull);
      expect(
        find.text(
          state.isReadExpired
              ? 'At last scan: Active'
              : 'At activation: Warming up',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('libre2NfcReadAgainButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('libre2NfcReadAgainButton')));
      await tester.pump();
    }
    expect(nfc.retryCalls, 2);
    expect(streaming.startCalls, 0);
    nfc.emit(
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsOneWidget);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('failed read-only proof can scan again and reuse the receiver', (
    tester,
  ) async {
    const channel = MethodChannel('com.openglucose/protocol_capture');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      expect(call.method, 'readLibreGen1ReceiverReuseProof');
      expect(call.arguments, {'attemptId': 'synthetic_completed_read'});
      if (calls.length == 1) {
        throw PlatformException(code: 'unavailable');
      }
      return {
        'attemptId': 'synthetic_completed_read',
        'event': 'receiverReusable',
        'model': 'libre2',
        'lifecycle': 'active',
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final nfc = _FakeLibre2NfcSetupSession();
    final driver = _ControlledDriver(driverId: 'protocol_capture_observation');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingEnabled: true,
      prepareLibreGen1Connection: () async => const DiscoveredSensor(
        driverId: 'protocol_capture_observation',
        deviceId: 'synthetic-reused-receiver',
        displayName: 'FreeStyle Libre 2',
        storageKey: 'synthetic-reused-receiver',
        rssi: 0,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      ),
    );
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      nfc.emit(
        const Libre2NfcSetupState.metadataRead(
          model: Libre2SensorModel.libre2,
          sensorStatus: Libre2SensorStatus.active,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('connectLibre2Sensor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('connectLibre2Sensor')));
      for (var index = 0; index < 12; index++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      if (attempt == 0) {
        expect(find.text('Check the sensor again'), findsOneWidget);
        expect(driver.connectedSensors, isEmpty);
        await tester.ensureVisible(
          find.byKey(const ValueKey('retryLibreReadOnlyCheck')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('retryLibreReadOnlyCheck')));
        await tester.pump();
        await tester.pump();
        expect(nfc.retryCalls, 1);
        expect(find.byKey(const ValueKey('libre2NfcGuide')), findsOneWidget);
      }
    }
    expect(calls, List.filled(2, 'readLibreGen1ReceiverReuseProof'));
    expect(driver.connectedSensors, hasLength(1));
    expect(nfc.startCalls, 1);
    expect(nfc.retryCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('unknown setup outcome remains blocked after close and reopen', (
    tester,
  ) async {
    final nfc = _FakeLibre2NfcSetupSession();
    final streaming = _FakeLibreStreamingSession();
    final driver = _ControlledDriver(driverId: 'protocol_capture_observation');
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
      libreGen1StreamingSession: streaming,
      libreGen1StreamingEnabled: true,
    );
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    nfc.emit(
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('connectLibre2Sensor')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connectLibre2Sensor')));
    await tester.pump();
    streaming.emit(
      const LibreGen1StreamingState(
        LibreGen1StreamingPhase.failed,
        failure: LibreGen1StreamingFailure.outcomeUnknown,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Setup needs a check'), findsOneWidget);
    expect(find.byKey(const ValueKey('retryLibreReadOnlyCheck')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('closeLibreStreaming')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('closeLibreStreaming')));
    await tester.pumpAndSettle();
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    await _openLibre2Nfc(tester);
    await tester.pumpAndSettle();
    expect(find.text('Setup needs a check'), findsOneWidget);
    expect(find.byKey(const ValueKey('retryLibreReadOnlyCheck')), findsNothing);
    expect(find.byKey(const ValueKey('connectLibre2Sensor')), findsNothing);
    expect(nfc.startCalls, 1);
    expect(nfc.retryCalls, 0);
    expect(streaming.startCalls, 1);
    expect(driver.connectedSensors, isEmpty);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets(
    'Libre streaming is gated and requires a verified started Libre 2',
    (tester) async {
      for (final enabled in [false, true]) {
        final nfc = _FakeLibre2NfcSetupSession();
        final controller = await _pumpConnectionScreen(
          tester,
          _ControlledDriver(driverId: 'protocol_capture_observation'),
          libre2NfcSetupSession: nfc,
          libreGen1StreamingEnabled: enabled,
        );
        await tester.pumpAndSettle();
        await _openLibre2Nfc(tester);
        await tester.pump();
        for (final status in Libre2SensorStatus.values) {
          nfc.emit(
            Libre2NfcSetupState.metadataRead(
              model: Libre2SensorModel.libre2,
              sensorStatus: status,
            ),
          );
          await tester.pump();
          final allowed =
              enabled &&
              (status == Libre2SensorStatus.warmingUp ||
                  status == Libre2SensorStatus.active);
          expect(
            find.byKey(const ValueKey<String>('connectLibre2Sensor')),
            allowed ? findsOneWidget : findsNothing,
          );
        }
        nfc.emit(
          const Libre2NfcSetupState.metadataRead(
            model: Libre2SensorModel.libre2Plus,
            sensorStatus: Libre2SensorStatus.active,
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('connectLibre2Sensor')),
          findsNothing,
        );
        await _disposeConnectionScreen(tester, controller);
        await tester.pump();
      }
    },
  );

  testWidgets(
    'uncertain streaming cleanup blocks handoff and another NFC start',
    (tester) async {
      final nfc = _FakeLibre2NfcSetupSession();
      final streaming = _FakeLibreStreamingSession(failStop: true);
      var prepareCalls = 0;
      final driver = _ControlledDriver(
        driverId: 'protocol_capture_observation',
      );
      final controller = await _pumpConnectionScreen(
        tester,
        driver,
        libre2NfcSetupSession: nfc,
        libreGen1StreamingSession: streaming,
        libreGen1StreamingEnabled: true,
        prepareLibreGen1Connection: () async {
          prepareCalls++;
          return null;
        },
      );
      await tester.pumpAndSettle();
      await _openLibre2Nfc(tester);
      await tester.pump();
      nfc.emit(
        const Libre2NfcSetupState.metadataRead(
          model: Libre2SensorModel.libre2,
          sensorStatus: Libre2SensorStatus.active,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('connectLibre2Sensor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('connectLibre2Sensor')),
      );
      await tester.pump();
      streaming.emit(
        const LibreGen1StreamingState(
          LibreGen1StreamingPhase.streamingEnabled,
          lifecycle: Libre2SensorStatus.active,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup needs a check'), findsOneWidget);
      expect(prepareCalls, 0);
      expect(driver.connectedSensors, isEmpty);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('closeLibreStreaming')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('closeLibreStreaming')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup needs a check'), findsOneWidget);
      expect(streaming.startCalls, 1);
      expect(nfc.retryCalls, 0);
      expect(
        find.byKey(const ValueKey<String>('connectLibre2Sensor')),
        findsNothing,
      );
      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('showSensorConnectionFlow opens one modal without a second CTA', (
    tester,
  ) async {
    final driver = _ControlledDriver();
    final controller = await _createController(driver);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              key: const ValueKey<String>('openSetup'),
              onPressed: () => unawaited(
                showSensorConnectionFlow(context, controller),
              ),
              child: const Text('Open setup'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('openSetup')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Find nearby sensors'), findsNothing);
    expect(driver.scanCalls, 1);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    controller.dispose();
  });

  testWidgets('opening scans first and model help is only shown on request', (
    tester,
  ) async {
    final driver = _ControlledDriver();
    final nfc = _FakeLibre2NfcSetupSession();
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfc,
    );
    await tester.pumpAndSettle();
    expect(driver.scanCalls, 1);
    expect(find.text('Nearby sensors'), findsOneWidget);
    expect(find.byKey(const ValueKey('chooseLibre2Help')), findsNothing);
    expect(find.byKey(const ValueKey('chooseAidexHelp')), findsNothing);
    expect(find.byKey(const ValueKey('supportedModelCatalog')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(find.text('AiDEX / LinX'), findsOneWidget);
    expect(find.text('FreeStyle Libre 2'), findsOneWidget);
    expect(find.text('Not sure? Check the name on the box.'), findsOneWidget);
    expect(nfc.startCalls, 0);
    expect(driver.scanCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('Libre 2 NFC flow presents each redacted native state', (
    tester,
  ) async {
    final nfcSession = _FakeLibre2NfcSetupSession();
    final driver = _ControlledDriver(
      driverId: 'protocol_capture_observation',
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      libre2NfcSetupSession: nfcSession,
    );
    await tester.pumpAndSettle();
    final scanCallsBeforeGuide = driver.scanCalls;

    await _openLibre2Nfc(tester);
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Check sensor'), findsNothing);
    expect(find.text('FreeStyle Libre 2 · NFC'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('libre2NfcGuide')),
      findsOneWidget,
    );
    expect(find.text('Connect a sensor'), findsOneWidget);
    expect(find.text('Nearby sensors'), findsNothing);
    expect(nfcSession.startCalls, 1);
    expect(find.text('Hold near the sensor'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('libre2NfcCollapseButton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('libre2NfcScanAnimation')),
      findsOneWidget,
    );
    _expectLiveRegion(
      tester,
      find.byKey(const ValueKey<String>('libre2NfcSetupTitle')),
    );

    nfcSession.emit(
      const Libre2NfcSetupState.tagDetected(
        model: Libre2SensorModel.libre2,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Sensor detected'), findsOneWidget);
    expect(find.text('NFC tag detected'), findsNothing);
    expect(find.textContaining('Keep the phone still'), findsOneWidget);

    nfcSession.emit(
      const Libre2NfcSetupState.reading(model: Libre2SensorModel.libre2),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Checking sensor'), findsOneWidget);

    nfcSession.emit(
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.active,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Libre 2 identified'), findsOneWidget);
    expect(find.text('FreeStyle Libre 2'), findsWidgets);
    expect(find.text('Sensor state: Active'), findsOneWidget);
    expect(
      find.text('Sensor data verified. Current state: Active.'),
      findsOneWidget,
    );
    expect(find.textContaining('connected'), findsNothing);
    expect(find.text('Scan again'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('libre2NfcSafeResult')),
      findsOneWidget,
    );
    expect(driver.scanCalls, scanCallsBeforeGuide);
    expect(driver.connectedSensors, isEmpty);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('libre2NfcCollapseButton')),
      160,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('libre2NfcCollapseButton')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('libre2NfcCollapseButton')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('libre2NfcGuide')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsOneWidget,
    );
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(driver.scanCalls, scanCallsBeforeGuide);
    expect(nfcSession.stopCalls, 1);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('Libre 2 NFC failure is identifier-free and retryable', (
    tester,
  ) async {
    final nfcSession = _FakeLibre2NfcSetupSession();
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(driverId: 'protocol_capture_observation'),
      libre2NfcSetupSession: nfcSession,
    );
    await tester.pumpAndSettle();

    await _openLibre2Nfc(tester);
    await tester.pump(const Duration(milliseconds: 16));

    nfcSession.emitError(
      StateError('private-tag-e007 private-serial-1234'),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Try the NFC tap again'), findsOneWidget);
    expect(find.textContaining('private-tag'), findsNothing);
    expect(find.textContaining('private-serial'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('libre2NfcRetryButton')),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(nfcSession.retryCalls, 1);
    expect(find.text('Hold near the sensor'), findsOneWidget);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets(
    'Libre 2 shows every verified lifecycle without a connection claim',
    (
      tester,
    ) async {
      final nfcSession = _FakeLibre2NfcSetupSession();
      final controller = await _pumpConnectionScreen(
        tester,
        _ControlledDriver(driverId: 'protocol_capture_observation'),
        libre2NfcSetupSession: nfcSession,
      );
      await tester.pumpAndSettle();
      await _openLibre2Nfc(tester);
      await tester.pump(const Duration(milliseconds: 16));

      for (final status in Libre2SensorStatus.values) {
        nfcSession.emit(
          Libre2NfcSetupState.metadataRead(
            model: Libre2SensorModel.libre2,
            sensorStatus: status,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final label = libre2SensorStatusLabel(status);
        expect(find.text('Sensor state: $label'), findsOneWidget);
        expect(find.textContaining('Current state: $label.'), findsOneWidget);
        expect(find.textContaining('connected'), findsNothing);
      }

      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('Libre 2 NFC states do not overflow at 320px and 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nfcSession = _FakeLibre2NfcSetupSession();
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(driverId: 'protocol_capture_observation'),
      textScaler: const TextScaler.linear(2),
      libre2NfcSetupSession: nfcSession,
    );
    await tester.pumpAndSettle();

    await _openLibre2Nfc(tester);
    await tester.pump(const Duration(milliseconds: 16));
    expect(nfcSession.startCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('libre2NfcGuide')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    for (final state in <Libre2NfcSetupState>[
      const Libre2NfcSetupState.tagDetected(),
      const Libre2NfcSetupState.reading(),
      const Libre2NfcSetupState.metadataRead(
        model: Libre2SensorModel.libre2,
        sensorStatus: Libre2SensorStatus.unknown,
      ),
      const Libre2NfcSetupState.failed(Libre2NfcFailureKind.tagMoved),
    ]) {
      nfcSession.emit(state);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
    }

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('Libre 2 NFC scan honors reduced motion', (tester) async {
    final nfcSession = _FakeLibre2NfcSetupSession();
    final controller = await _pumpConnectionScreen(
      tester,
      _ControlledDriver(driverId: 'protocol_capture_observation'),
      disableAnimations: true,
      libre2NfcSetupSession: nfcSession,
    );
    await tester.pumpAndSettle();

    await _openLibre2Nfc(tester);
    await tester.pumpAndSettle();

    expect(nfcSession.startCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('libre2NfcScanAnimation')),
      findsOneWidget,
    );
    expect(tester.hasRunningAnimations, isFalse);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('unsupported future models are not offered as setup choices', (
    tester,
  ) async {
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(tester, driver);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    for (final label in [
      'Libre 2 Plus',
      'FreeStyle Libre 3',
      'Dexcom',
      'Medtronic',
      'Eversense',
      'Planned',
    ]) {
      expect(find.textContaining(label), findsNothing);
    }
    expect(find.byKey(const ValueKey('chooseAidexHelp')), findsOneWidget);
    expect(find.byKey(const ValueKey('chooseLibre2Help')), findsOneWidget);
    expect(driver.connectedSensors, isEmpty);
    expect(driver.scanCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets(
    'nearby result is public and connects its exact discovered value',
    (
      tester,
    ) async {
      const sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'private-device-identifier',
        displayName: 'Private transmitter display name',
        storageKey: 'private-storage-key',
        rssi: -54,
        capabilities: CgmCapabilities(supportsDirectBle: true),
        metadata: <String, String>{'serial': 'private-serial-number'},
      );
      const otherSensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'other-private-device-identifier',
        displayName: 'Other private transmitter name',
        storageKey: 'other-private-storage-key',
        rssi: -82,
        capabilities: CgmCapabilities(supportsDirectBle: true),
        metadata: <String, String>{'serial': 'other-private-serial-number'},
      );
      final driver = _ControlledDriver(
        discoveredSensors: const <DiscoveredSensor>[
          sensor,
          otherSensor,
        ],
      );
      final controller = await _pumpConnectionScreen(tester, driver);
      await tester.pumpAndSettle();

      expect(driver.scanCalls, 1);
      expect(find.text('AiDEX / LinX sensor 1'), findsOneWidget);
      expect(find.text('AiDEX / LinX sensor 2'), findsOneWidget);
      expect(
        find.textContaining('Numbers are temporary'),
        findsOneWidget,
      );
      expect(find.textContaining(sensor.displayName), findsNothing);
      expect(find.textContaining(sensor.deviceId), findsNothing);
      expect(find.textContaining(sensor.metadata['serial']!), findsNothing);
      expect(find.textContaining(otherSensor.displayName), findsNothing);
      expect(find.textContaining(otherSensor.deviceId), findsNothing);
      expect(
        find.textContaining(otherSensor.metadata['serial']!),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('connectButton-1'),
        ),
      );
      for (
        var attempt = 0;
        attempt < 10 && driver.connectedSensors.isEmpty;
        attempt += 1
      ) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      expect(driver.connectedSensors, hasLength(1));
      final connected = driver.connectedSensors.single;
      expect(connected.driverId, sensor.driverId);
      expect(connected.deviceId, sensor.deviceId);
      expect(connected.storageKey, sensor.storageKey);
      expect(connected.displayName, sensor.displayName);
      expect(connected.rssi, sensor.rssi);
      expect(connected.capabilities, same(sensor.capabilities));
      expect(connected.advertisement, same(sensor.advertisement));
      expect(connected.notes, sensor.notes);
      expect(
        connected.metadata,
        containsPair('serial', 'private-serial-number'),
      );
      expect(
        connected.metadata[cgmAllowSessionActivationMetadataKey],
        'true',
      );
      expect(connected.deviceId, isNot(otherSensor.deviceId));

      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets(
    'Yuwell activation needs a read-only probe and explicit confirmation',
    (tester) async {
      const sensor = DiscoveredSensor(
        driverId: 'yuwell-anytime',
        deviceId: 'private-yuwell-device',
        displayName: 'Private Yuwell sensor name',
        storageKey: 'private-yuwell-storage',
        rssi: -51,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      );
      late final _ControlledDriver driver;
      driver = _ControlledDriver(
        driverId: 'yuwell-anytime',
        discoveredSensors: const <DiscoveredSensor>[sensor],
        connectSessionBuilder: (connected) {
          if (driver.connectedSensors.length == 1) {
            return _StaticSession(
              connected,
              stage: CgmSyncStage.error,
              lastError: 'Activation confirmation is required.',
              metadata: const <String, String>{
                'activationRequired': 'true',
              },
            );
          }
          return _StaticSession(connected, stage: CgmSyncStage.ready);
        },
      );
      final controller = await _pumpConnectionScreen(tester, driver);

      await _scanAndConnectFirstResult(tester);

      expect(driver.connectedSensors, hasLength(1));
      expect(
        driver
            .connectedSensors
            .single
            .metadata[cgmAllowSessionActivationMetadataKey],
        'false',
      );
      expect(
        find.byKey(
          const ValueKey<String>('sensorActivationConfirmation'),
        ),
        findsOneWidget,
      );
      expect(find.text('Start this sensor?'), findsOneWidget);
      expect(find.textContaining('activate the sensor'), findsOneWidget);
      expect(find.textContaining('this app installation'), findsOneWidget);
      expect(find.textContaining('connection credentials'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('confirmSensorActivationButton'),
        ),
      );
      await tester.pumpAndSettle();

      expect(driver.connectedSensors, hasLength(2));
      expect(
        driver
            .connectedSensors
            .last
            .metadata[cgmAllowSessionActivationMetadataKey],
        'true',
      );

      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('Yuwell saved session resumes without an activation prompt', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'yuwell-anytime',
      deviceId: 'saved-yuwell-device',
      displayName: 'Saved Yuwell sensor',
      storageKey: 'saved-yuwell-storage',
      rssi: -49,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final driver = _ControlledDriver(
      driverId: 'yuwell-anytime',
      discoveredSensors: const <DiscoveredSensor>[sensor],
      connectSessionBuilder: (connected) => _StaticSession(
        connected,
        stage: CgmSyncStage.ready,
      ),
    );
    final controller = await _pumpConnectionScreen(tester, driver);

    await _scanAndConnectFirstResult(tester);

    expect(driver.connectedSensors, hasLength(1));
    expect(
      driver
          .connectedSensors
          .single
          .metadata[cgmAllowSessionActivationMetadataKey],
      'false',
    );
    expect(
      find.byKey(const ValueKey<String>('sensorActivationConfirmation')),
      findsNothing,
    );

    await _disposeConnectionScreen(tester, controller);
  });

  for (final policy in <SensorConnectionPolicy?>[
    ...SensorConnectionPolicy.values,
    null,
  ]) {
    testWidgets(
      'synthetic registration uses ${policy?.name ?? 'restrictive default'} '
      'instead of discovery activation metadata',
      (tester) async {
        const sensor = DiscoveredSensor(
          driverId: 'synthetic-future-sensor',
          deviceId: 'synthetic-policy-device',
          displayName: 'Synthetic sensor',
          storageKey: 'synthetic-policy-storage',
          rssi: -50,
          capabilities: CgmCapabilities(supportsDirectBle: true),
          metadata: {
            cgmAllowSessionActivationMetadataKey: 'true',
            'connectionPolicy': 'explicitConnect',
          },
        );
        final driver = _ControlledDriver(
          driverId: sensor.driverId,
          discoveredSensors: const [sensor],
          connectSessionBuilder: (connected) => _StaticSession(
            connected,
            stage: CgmSyncStage.error,
            lastError: 'Activation confirmation is required.',
            metadata: const {'activationRequired': 'true'},
          ),
        );
        final controller = await _pumpConnectionScreen(
          tester,
          _registeredPolicyDriver(driver, policy),
        );
        await _scanAndConnectFirstResult(tester);

        expect(driver.connectedSensors, hasLength(1));
        expect(
          driver
              .connectedSensors
              .single
              .metadata[cgmAllowSessionActivationMetadataKey],
          policy == SensorConnectionPolicy.explicitConnect ? 'true' : 'false',
        );
        expect(
          find.byKey(const ValueKey('sensorActivationConfirmation')),
          policy == SensorConnectionPolicy.separateConfirmation
              ? findsOneWidget
              : findsNothing,
        );
        if (policy != SensorConnectionPolicy.separateConfirmation) {
          expect(find.text('Could not connect'), findsOneWidget);
        }
        await _disposeConnectionScreen(tester, controller);
      },
    );
  }

  testWidgets('synthetic separate policy confirms only the current sensor', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'synthetic-future-sensor',
      deviceId: 'synthetic-first-device',
      displayName: 'Synthetic first sensor',
      storageKey: 'synthetic-first-storage',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    const otherSensor = DiscoveredSensor(
      driverId: 'synthetic-future-sensor',
      deviceId: 'synthetic-second-device',
      displayName: 'Synthetic second sensor',
      storageKey: 'synthetic-second-storage',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    for (final changeSelection in [false, true]) {
      final driver = _ControlledDriver(
        driverId: sensor.driverId,
        discoveredSensors: const [sensor],
        connectSessionBuilder: (connected) => _StaticSession(
          connected,
          stage: CgmSyncStage.error,
          lastError: 'Activation confirmation is required.',
          metadata: const {'activationRequired': 'true'},
        ),
      );
      final controller = await _pumpConnectionScreen(
        tester,
        _registeredPolicyDriver(
          driver,
          SensorConnectionPolicy.separateConfirmation,
        ),
      );
      await _scanAndConnectFirstResult(tester);
      expect(driver.connectedSensors, hasLength(1));
      expect(
        driver
            .connectedSensors
            .single
            .metadata[cgmAllowSessionActivationMetadataKey],
        'false',
      );
      if (changeSelection) {
        var changed = false;
        final changing = controller
            .connect(otherSensor, allowSessionActivation: false)
            .then((_) => changed = true);
        for (var attempt = 0; attempt < 20; attempt++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(changed, isTrue);
        await changing;
        await tester.pumpAndSettle();
      }

      await tester.tap(
        find.byKey(const ValueKey('confirmSensorActivationButton')),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await tester.pumpAndSettle();

      expect(driver.connectedSensors, hasLength(2));
      expect(
        driver
            .connectedSensors
            .last
            .metadata[cgmAllowSessionActivationMetadataKey],
        changeSelection ? 'false' : 'true',
      );
      expect(
        driver.connectedSensors.last.deviceId,
        changeSelection ? otherSensor.deviceId : sensor.deviceId,
      );
      await _disposeConnectionScreen(tester, controller);
    }
  });

  testWidgets('unstructured scan failure renders failure and a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final driver = _ControlledDriver(
      scanError: StateError('private transport detail'),
    );
    final controller = await _pumpConnectionScreen(tester, driver);
    await tester.pumpAndSettle();

    expect(find.text('Could not scan for sensors'), findsOneWidget);
    expect(
      find.text(
        'Sensor scan could not be completed. Check Bluetooth and try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('nearbyNoResults')),
      findsNothing,
    );
    _expectLiveRegion(
      tester,
      find.byKey(const ValueKey<String>('sensorScanFailureTitle')),
    );

    semantics.dispose();
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('terminal no-results state is a live region', (tester) async {
    final semantics = tester.ensureSemantics();
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(tester, driver);
    await tester.pumpAndSettle();

    final noResults = find.byKey(const ValueKey<String>('nearbyNoResults'));
    expect(noResults, findsOneWidget);
    _expectLiveRegion(tester, noResults);

    semantics.dispose();
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets(
    'first connection failure keeps selection until explicit cancellation',
    (
      tester,
    ) async {
      const sensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'first-failure-device',
        displayName: 'First failure sensor',
        storageKey: 'first-failure-storage',
        rssi: -50,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      );
      final driver = _ControlledDriver(
        discoveredSensors: const <DiscoveredSensor>[sensor],
        connectSessionBuilder: (connected) => _StaticSession(
          connected,
          stage: CgmSyncStage.error,
          lastError: 'Synthetic connection failure',
        ),
      );
      final controller = await _pumpConnectionScreen(tester, driver);

      await _scanAndConnectFirstResult(tester);
      expect(find.text('Could not connect'), findsOneWidget);
      expect(controller.archivedSensors, isEmpty);

      expect(find.text('Choose another sensor'), findsNothing);
      await _settleControllerAction(tester, controller.chooseAnotherSensor());
      await tester.pump();

      expect(controller.snapshot, isNull);
      expect(controller.archivedSensors, isEmpty);

      await _disposeConnectionScreen(tester, controller);
    },
  );

  for (final driverId in ['libre2-gen1', 'aidex']) {
    testWidgets('snapshot cleanup guidance is driver-bound ($driverId)', (
      tester,
    ) async {
      final sensor = DiscoveredSensor(
        driverId: driverId,
        deviceId: 'synthetic-cleanup-device',
        displayName: 'Synthetic sensor',
        storageKey: 'synthetic-cleanup-storage',
        rssi: -50,
        capabilities: const CgmCapabilities(supportsDirectBle: true),
      );
      final driver = _ControlledDriver(
        driverId: driverId,
        discoveredSensors: [sensor],
        connectSessionBuilder: (connected) => _StaticSession(
          connected,
          stage: CgmSyncStage.error,
          lastError: 'libre2.cleanupUnconfirmed',
          metadata: {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
        ),
      );
      final controller = await _pumpConnectionScreen(tester, driver);
      await _scanAndConnectFirstResult(tester);
      final requiresRestart = driverId == 'libre2-gen1';
      expect(controller.sensorConnectionCleanupUnconfirmed, requiresRestart);
      expect(
        find.byKey(const ValueKey('connectionRestartRequired')),
        requiresRestart ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('connectionRetryButton')),
        requiresRestart ? findsNothing : findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chooseAnotherSensorButton')),
        findsNothing,
      );
      expect(driver.connectedSensors, hasLength(1));
      await _disposeConnectionScreen(tester, controller);
    });
  }

  testWidgets(
    'unconfirmed Libre cleanup replaces retry with restart guidance',
    (
      tester,
    ) async {
      const sensor = DiscoveredSensor(
        driverId: 'libre2-gen1',
        deviceId: 'synthetic-cleanup-device',
        displayName: 'FreeStyle Libre 2',
        storageKey: 'synthetic-cleanup-storage',
        rssi: -50,
        capabilities: CgmCapabilities(supportsDirectBle: true),
      );
      final driver = _ControlledDriver(
        driverId: 'libre2-gen1',
        discoveredSensors: const [sensor],
        connectSessionBuilder: (connected) => _StaticSession(
          connected,
          stage: CgmSyncStage.error,
          lastError: 'libre2.connectionFailed',
          metadata: {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
          disconnectError: const LibreGen1LiveException(
            LibreGen1LiveFailure.cleanupUnconfirmed,
          ),
        ),
      );
      final controller = await _pumpConnectionScreen(tester, driver);
      await _scanAndConnectFirstResult(tester);
      await _settleControllerAction(tester, controller.disconnect());
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 40; attempt += 1) {
          if (controller.sensorConnectionCleanupUnconfirmed) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();

      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(
        find.byKey(const ValueKey('connectionRestartRequired')),
        findsOneWidget,
      );
      expect(find.textContaining('Do not reset the sensor'), findsOneWidget);
      expect(find.byKey(const ValueKey('connectionRetryButton')), findsNothing);
      expect(
        find.byKey(const ValueKey('chooseAnotherSensorButton')),
        findsNothing,
      );
      expect(driver.connectedSensors, hasLength(1));
      expect(controller.snapshot, isNotNull);
      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('failed pointer cleanup keeps the connection failure visible', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'cleanup-failure-device',
      displayName: 'Cleanup failure sensor',
      storageKey: 'cleanup-failure-storage',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final store = _FailingCleanupHealthStateStore(
      <String, String>{'openHealth.lastSensor': jsonEncode(sensor.toJson())},
    );
    final driver = _ControlledDriver(
      discoveredSensors: const <DiscoveredSensor>[sensor],
      connectSessionBuilder: (connected) => _StaticSession(
        connected,
        stage: CgmSyncStage.error,
        lastError: 'Synthetic connection failure',
      ),
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      healthStateStore: store,
      initializeController: true,
    );

    await _scanAndConnectFirstResult(tester);
    expect(find.text('Could not connect'), findsOneWidget);

    await _settleControllerAction(tester, controller.disconnect());
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (controller.lastError?.contains('Clearing the selected sensor') ??
            false) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    expect(find.text('Could not connect'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('findNearbySensorsButton')),
      findsNothing,
    );
    expect(controller.snapshot, isNotNull);
    expect(controller.lastError, contains('Clearing the selected sensor'));

    await _disposeConnectionScreen(tester, controller);
    await tester.pump(const Duration(milliseconds: 701));
  });

  testWidgets('failure actions stay disabled while Retry is in progress', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'retry-race-device',
      displayName: 'Retry race sensor',
      storageKey: 'retry-race-storage',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final teardown = Completer<void>();
    final firstSession = _DelayedDisconnectSession(sensor, teardown.future);
    final driver = _SequencedConnectionDriver(sensor, firstSession);
    final controller = await _pumpConnectionScreen(tester, driver);

    await _scanAndConnectFirstResult(tester);
    expect(find.text('Could not connect'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pump();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (firstSession.disconnectCalls != 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    final retry = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Try again'),
    );
    expect(retry.onPressed, isNull);
    expect(find.text('Choose another sensor'), findsNothing);
    expect(firstSession.disconnectCalls, 1);
    expect(driver.connectCalls, 1);

    await tester.tap(
      find.widgetWithText(FilledButton, 'Try again'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(firstSession.disconnectCalls, 1);
    expect(controller.snapshot, isNotNull);

    teardown.complete();
    await tester.pumpAndSettle();
    expect(driver.connectCalls, 2);
    expect(controller.archivedSensors, isEmpty);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('failure retry cannot reconnect during explicit disconnect', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'choose-race-device',
      displayName: 'Choose race sensor',
      storageKey: 'choose-race-storage',
      rssi: -50,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final teardown = Completer<void>();
    final firstSession = _DelayedDisconnectSession(
      sensor,
      teardown.future,
      history: const <CgmReading>[
        CgmReading(valueMgdl: 110, source: CgmRecordSource.vendor),
      ],
    );
    final driver = _SequencedConnectionDriver(sensor, firstSession);
    final controller = await _pumpConnectionScreen(tester, driver);

    await _scanAndConnectFirstResult(tester);
    expect(find.text('Could not connect'), findsOneWidget);

    final disconnect = controller.disconnect();
    await tester.pump();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (firstSession.disconnectCalls != 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    expect(find.text('Choose another sensor'), findsNothing);
    expect(firstSession.disconnectCalls, 1);

    await tester.tap(
      find.widgetWithText(FilledButton, 'Try again'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(firstSession.disconnectCalls, 1);
    expect(driver.connectCalls, 1);
    expect(controller.archivedSensors, isEmpty);

    teardown.complete();
    await _settleControllerAction(tester, disconnect);
    expect(firstSession.disconnectCalls, 1);
    expect(driver.connectCalls, 1);
    expect(controller.archivedSensors, hasLength(1));

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('ready connection pops only its sensor route once', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'ready-route-device',
      displayName: 'Ready route sensor',
      storageKey: 'ready-route-storage',
      rssi: -48,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    late _EmittingSession session;
    final driver = _ControlledDriver(
      discoveredSensors: const <DiscoveredSensor>[sensor],
      connectSessionBuilder: (connected) =>
          session = _EmittingSession(connected),
    );
    final controller = await _createController(driver);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('Base route', key: ValueKey<String>('baseRoute')),
        ),
      ),
    );
    final navigator = Navigator.of(
      tester.element(find.byKey(const ValueKey<String>('baseRoute'))),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: Text(
              'Underlying route',
              key: ValueKey<String>('underlyingRoute'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SensorConnectionScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scanAndConnectFirstResult(tester, settleAfterConnect: false);
    expect(driver.connectedSensors, hasLength(1));
    session.emitReady();
    controller.updateDisplayPreferences(controller.displayPreferences);
    controller.updateDisplayPreferences(controller.displayPreferences);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('underlyingRoute')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsNothing,
    );
    controller.updateDisplayPreferences(controller.displayPreferences);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('underlyingRoute')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await session.close();
  });

  testWidgets('back during an active scan cancels and returns to chooser', (
    tester,
  ) async {
    final driver = _BlockingScanDriver();
    final controller = await _createController(driver);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              key: const ValueKey<String>('openBlockingSetup'),
              onPressed: () => unawaited(
                showSensorConnectionFlow(context, controller),
              ),
              child: const Text('Open setup'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('openBlockingSetup')),
    );
    await tester.pump();
    await tester.pump();
    expect(controller.scanning, isTrue);
    expect(
      find.byKey(const ValueKey<String>('nearbyScanProgress')),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (driver.cancelCalls != 0 && !controller.scanning) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    expect(driver.cancelCalls, 1);
    expect(controller.scanning, isFalse);
    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsNothing,
    );

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('system back collapses inline NFC without restarting scan', (
    tester,
  ) async {
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(tester, driver);
    await tester.pumpAndSettle();
    final scanCallsBeforeNfc = driver.scanCalls;

    await _openLibre2Nfc(tester);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('libre2NfcGuide')),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sensorModelHelp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('libre2NfcGuide')),
      findsNothing,
    );
    expect(find.text('Which sensor do you have?'), findsOneWidget);
    expect(find.text('Nearby sensors'), findsNothing);
    expect(driver.scanCalls, scanCallsBeforeNfc);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('sensorConnectionChooser')),
      findsOneWidget,
    );
    expect(find.text('Nearby sensors'), findsOneWidget);
    expect(driver.scanCalls, scanCallsBeforeNfc);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('AiDEX help does not offer unavailable driver actions', (
    tester,
  ) async {
    final driver = _ControlledDriver(driverId: 'other-driver');
    final controller = await _pumpConnectionScreen(tester, driver);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chooseAidexHelp')));
    await tester.pumpAndSettle();
    expect(
      find.text('Bluetooth setup is not supported on this device.'),
      findsOneWidget,
    );
    final action = tester.widget<FilledButton>(
      find.byKey(const ValueKey('aidexHelpScanAgain')),
    );
    expect(action.onPressed, isNull);
    expect(driver.scanCalls, 1);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('macOS help preserves preview status without a support claim', (
    tester,
  ) async {
    final driver = _ControlledDriver();
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      platform: TargetPlatform.macOS,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chooseAidexHelp')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('physical AiDEX use on macOS is not verified'),
      findsOneWidget,
    );
    expect(find.text('Available'), findsNothing);
    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('unsupported desktop discovery cannot bypass the family gate', (
    tester,
  ) async {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'unsupported-desktop-device',
      displayName: 'Unsupported desktop sensor',
      storageKey: 'unsupported-desktop-storage',
      rssi: -52,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final driver = _ControlledDriver(
      discoveredSensors: const <DiscoveredSensor>[sensor],
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      platform: TargetPlatform.windows,
    );
    await tester.pumpAndSettle();

    final connect = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('connectButton-1')),
    );
    expect(connect.onPressed, isNull);
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(driver.connectedSensors, isEmpty);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('connection flow does not overflow at 320px and 2x text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'narrow-device',
      displayName: 'Narrow test sensor',
      storageKey: 'narrow-storage',
      rssi: -67,
      capabilities: CgmCapabilities(supportsDirectBle: true),
    );
    final driver = _ControlledDriver(
      discoveredSensors: const <DiscoveredSensor>[
        sensor,
      ],
    );
    final controller = await _pumpConnectionScreen(
      tester,
      driver,
      textScaler: const TextScaler.linear(2),
    );

    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await _openLibre2Nfc(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('libre2UnavailableButton')),
      240,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('libre2UnavailableButton')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _disposeConnectionScreen(tester, controller);
    final nearbyController = await _pumpConnectionScreen(
      tester,
      driver,
      textScaler: const TextScaler.linear(2),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('AiDEX / LinX sensor'), 240);
    await tester.ensureVisible(find.text('AiDEX / LinX sensor'));
    await tester.pumpAndSettle();
    expect(find.text('AiDEX / LinX sensor'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeConnectionScreen(tester, nearbyController);
  });
}

Future<void> _openLibre2Nfc(WidgetTester tester) async {
  if (find.byKey(const ValueKey('sensorHelpButton')).evaluate().isNotEmpty) {
    await tester.ensureVisible(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sensorHelpButton')));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.byKey(const ValueKey('chooseLibre2Help')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('chooseLibre2Help')));
  await tester.pump();
}

Future<CgmAppController> _pumpConnectionScreen(
  WidgetTester tester,
  CgmDriver driver, {
  TextScaler textScaler = TextScaler.noScaling,
  TargetPlatform platform = TargetPlatform.android,
  HealthStateStore? healthStateStore,
  bool initializeController = false,
  bool disableAnimations = false,
  bool inline = false,
  VoidCallback? onClose,
  VoidCallback? onConnected,
  Libre2NfcSetupSession? libre2NfcSetupSession,
  LibreGen1StreamingSession? libreGen1StreamingSession,
  bool? libreGen1StreamingEnabled,
  bool? libreGen1ReceiverRestoreEnabled,
  Future<DiscoveredSensor?> Function()? prepareLibreGen1Connection,
}) async {
  final controller = await _createController(
    driver,
    healthStateStore: healthStateStore,
    initialize: initializeController,
  );
  final screen = SensorConnectionScreen(
    controller: controller,
    inline: inline,
    onClose: onClose,
    onConnected: onConnected,
    libre2NfcSetupSession: libre2NfcSetupSession,
    libreGen1StreamingSession: libreGen1StreamingSession,
    libreGen1StreamingEnabled: libreGen1StreamingEnabled,
    libreGen1ReceiverRestoreEnabled: libreGen1ReceiverRestoreEnabled,
    prepareLibreGen1Connection: prepareLibreGen1Connection,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: inline
          ? Scaffold(body: SingleChildScrollView(child: screen))
          : screen,
    ),
  );
  await tester.pump();
  return controller;
}

Future<CgmAppController> _createController(
  CgmDriver driver, {
  HealthStateStore? healthStateStore,
  bool initialize = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: driver,
    healthStateStore: healthStateStore,
  );
  if (initialize) {
    await controller.initialize();
  }
  return controller;
}

Future<void> _scanAndConnectFirstResult(
  WidgetTester tester, {
  bool settleAfterConnect = true,
}) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('connectButton-1')));
  if (settleAfterConnect) {
    // Probe teardown crosses secure-storage/platform futures. Drain both
    // zones before waiting for its progress animation to stop.
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
  } else {
    for (var attempt = 0; attempt < 10; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }
}

void _expectLiveRegion(WidgetTester tester, Finder descendant) {
  final liveRegion = find.ancestor(
    of: descendant,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.liveRegion == true,
    ),
  );
  expect(liveRegion, findsOneWidget);
  final data = tester.getSemantics(liveRegion).getSemanticsData();
  expect(data.flagsCollection.isLiveRegion, isTrue);
}

Future<void> _settleControllerAction(
  WidgetTester tester,
  Future<void> action,
) async {
  var complete = false;
  final completion = action.whenComplete(() => complete = true);
  // Teardown crosses root-zone stream cancellation and widget-zone storage.
  for (var attempt = 0; attempt < 40 && !complete; attempt++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(complete, isTrue, reason: 'Controller action did not complete.');
  await completion;
}

Future<void> _disposeConnectionScreen(
  WidgetTester tester,
  CgmAppController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

CgmDriverRegistry _registeredPolicyDriver(
  _ControlledDriver driver,
  SensorConnectionPolicy? policy,
) => CgmDriverRegistry(
  transport: const _SyntheticPolicyTransport(),
  registrations: [
    if (policy == null)
      CgmDriverRegistration(
        driver: driver,
        scanServiceUuids: const ['181F'],
        discover: (_) => driver.discoveredSensors.single,
      )
    else
      CgmDriverRegistration(
        driver: driver,
        scanServiceUuids: const ['181F'],
        discover: (_) => driver.discoveredSensors.single,
        connectionPolicy: policy,
      ),
  ],
);

final class _SyntheticPolicyTransport implements BleTransport {
  const _SyntheticPolicyTransport();

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => Stream.value(
    const BleScanResult(
      deviceId: 'synthetic-policy-advertisement',
      deviceName: 'Synthetic sensor',
      rssi: -50,
    ),
  );

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw StateError('The synthetic driver owns connection.');
}

final class _ControlledDriver implements CgmDriver {
  _ControlledDriver({
    this.discoveredSensors = const <DiscoveredSensor>[],
    this.scanError,
    this.connectSessionBuilder,
    this.driverId = 'aidex',
  });

  final List<DiscoveredSensor> discoveredSensors;
  final Object? scanError;
  Future<void>? scanBarrier;
  final CgmSession Function(DiscoveredSensor sensor)? connectSessionBuilder;
  final List<DiscoveredSensor> connectedSensors = <DiscoveredSensor>[];
  int scanCalls = 0;

  @override
  final String driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    scanCalls += 1;
    await scanBarrier;
    final error = scanError;
    if (error != null) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    yield* Stream<DiscoveredSensor>.fromIterable(discoveredSensors);
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectedSensors.add(sensor);
    return connectSessionBuilder?.call(sensor) ?? _StaticSession(sensor);
  }
}

final class _FakeLibre2NfcSetupSession
    implements Libre2NfcSetupSession, Libre2NfcCompletedReadAttemptProvider {
  _FakeLibre2NfcSetupSession({this.stopBarrier});
  final Future<void>? stopBarrier;
  final StreamController<Libre2NfcSetupState> _states =
      StreamController<Libre2NfcSetupState>.broadcast(sync: true);

  int startCalls = 0;
  int retryCalls = 0;
  int stopCalls = 0;
  bool disposed = false;
  @override
  String? completedReadAttemptId;

  @override
  Stream<Libre2NfcSetupState> get states => _states.stream;

  void emit(Libre2NfcSetupState state) {
    completedReadAttemptId =
        state.phase == Libre2NfcSetupPhase.metadataRead &&
            !state.isReadExpired &&
            !state.isActivationVerified
        ? 'synthetic_completed_read'
        : null;
    _states.add(state);
  }

  void emitError(Object error) => _states.addError(error);

  @override
  Future<void> start() async {
    startCalls += 1;
    emit(const Libre2NfcSetupState.listening());
  }

  @override
  Future<void> retry() async {
    retryCalls += 1;
    emit(const Libre2NfcSetupState.listening());
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    await stopBarrier;
    if (!disposed) {
      emit(const Libre2NfcSetupState.idle());
    }
  }

  @override
  Future<void> dispose() async {
    if (disposed) {
      return;
    }
    disposed = true;
    await _states.close();
  }
}

final class _FakeLibreStreamingSession implements LibreGen1StreamingSession {
  _FakeLibreStreamingSession({this.failStop = false});
  final bool failStop;
  final _states = StreamController<LibreGen1StreamingState>.broadcast(
    sync: true,
  );
  int startCalls = 0;
  int stopCalls = 0;
  @override
  Stream<LibreGen1StreamingState> get states => _states.stream;
  void emit(LibreGen1StreamingState state) => _states.add(state);
  @override
  Future<void> start() async {
    startCalls++;
    emit(const LibreGen1StreamingState(LibreGen1StreamingPhase.listening));
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (failStop) throw StateError('synthetic cleanup failure');
  }

  @override
  Future<void> dispose() => _states.close();
}

final class _StaticSession implements CgmSession {
  _StaticSession(
    this.sensor, {
    CgmSyncStage stage = CgmSyncStage.connecting,
    String? lastError,
    Map<String, String> metadata = const <String, String>{},
    List<CgmDiagnosticItem> diagnostics = const [],
    this.disconnectError,
  }) : currentSnapshot = CgmSessionSnapshot(
         stage: stage,
         statusText: stage == CgmSyncStage.error ? 'Error' : 'Connecting',
         sensor: sensor,
         capabilities: sensor.capabilities,
         lastError: lastError,
         metadata: metadata,
         diagnostics: diagnostics,
       );

  @override
  final DiscoveredSensor sensor;

  @override
  final CgmSessionSnapshot currentSnapshot;

  final Object? disconnectError;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      const Stream<CgmSessionSnapshot>.empty();

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {
    final error = disconnectError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }

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

final class _EmittingSession implements CgmSession {
  _EmittingSession(this.sensor)
    : currentSnapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.connecting,
        statusText: 'Connecting',
        sensor: sensor,
        capabilities: sensor.capabilities,
      );

  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);

  @override
  final DiscoveredSensor sensor;

  @override
  CgmSessionSnapshot currentSnapshot;

  void emitReady() {
    currentSnapshot = currentSnapshot.copyWith(
      stage: CgmSyncStage.ready,
      statusText: 'Ready',
    );
    _snapshots.add(currentSnapshot);
  }

  void emit(CgmSessionSnapshot value) {
    currentSnapshot = value;
    _snapshots.add(value);
  }

  Future<void> close() => _snapshots.close();

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

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

final class _SequencedConnectionDriver implements CgmDriver {
  _SequencedConnectionDriver(this.sensor, this.firstSession);

  final DiscoveredSensor sensor;
  final CgmSession firstSession;
  int connectCalls = 0;

  @override
  String get driverId => 'aidex';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => Stream<DiscoveredSensor>.value(sensor);

  @override
  Future<CgmSession> connect(DiscoveredSensor connectedSensor) async {
    expect(connectedSensor.storageKey, sensor.storageKey);
    connectCalls += 1;
    if (connectCalls == 1) return firstSession;
    return _StaticSession(
      sensor,
      stage: CgmSyncStage.error,
      lastError: 'Synthetic retry failure',
    );
  }
}

final class _DelayedDisconnectSession implements CgmSession {
  _DelayedDisconnectSession(
    this.sensor,
    this._disconnectGate, {
    List<CgmReading> history = const <CgmReading>[],
  }) : currentSnapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.error,
         statusText: 'Error',
         sensor: sensor,
         capabilities: sensor.capabilities,
         lastError: 'Synthetic connection failure',
         history: history,
       );

  final Future<void> _disconnectGate;
  int disconnectCalls = 0;

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
  Future<void> disconnect() async {
    disconnectCalls += 1;
    await _disconnectGate;
  }

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

final class _BlockingScanDriver implements CgmDriver {
  int scanCalls = 0;
  int cancelCalls = 0;

  @override
  String get driverId => 'aidex';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    scanCalls += 1;
    return Stream<DiscoveredSensor>.multi((controller) {
      controller.onCancel = () {
        cancelCalls += 1;
      };
    });
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw StateError('The blocking scan fixture must not connect.');
  }
}

final class _ReceptionFailureHealthStateStore implements HealthStateStore {
  final _values = <String, String>{};
  final release = Completer<void>();
  bool writeStarted = false;

  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => _values[key];
  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'openHealth.lastSensor') {
      writeStarted = true;
      await release.future;
      throw StateError('synthetic-private-storage failure');
    }
    _values[key] = value;
  }
}

final class _FailingCleanupHealthStateStore implements HealthStateStore {
  _FailingCleanupHealthStateStore(Map<String, String> values)
    : _values = Map<String, String>.of(values);

  final Map<String, String> _values;

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> remove(String key) async {
    if (key == 'openHealth.lastSensor') {
      throw StateError('synthetic pointer cleanup failure');
    }
    _values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }
}
