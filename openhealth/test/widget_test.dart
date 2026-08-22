import 'dart:async';
import 'dart:convert';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('BLE support copy action is private-build gated', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final driver = _PrivateSupportDriver();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
    );
    await controller.initialize();
    await controller.connect(driver.sensor);

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

    final copyButton = find.byKey(
      const ValueKey<String>('copyBleSupportCodeButton'),
    );
    if (kOgPrivateSupport) {
      expect(copyButton, findsOneWidget);
      String? copiedText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(copyButton);
      await tester.pumpAndSettle();
      expect(find.text('Support code copied'), findsOneWidget);
      expect(
        copiedText,
        'OGSUP1 phase=P05 op=subscribe kind=bondRejected '
        'code=fake.subscribe.authentication-required',
      );
    } else {
      expect(copyButton, findsNothing);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('advanced settings route exposes the scenario picker', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // This test exercises the connected dashboard, not first-run setup.
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

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
    await tester.tap(find.text('Find my sensor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.mockScenario, MockScenario.activeNormal);

    // Open settings -> Advanced route.
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('settingsOverview')),
      findsOneWidget,
    );
    expect(find.byType(TabBar), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    // The scenario picker is present (only shown for the mock driver).
    final picker = find.byKey(const ValueKey<String>('mockScenarioPicker'));
    expect(picker, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('advancedCalibrationScale')),
      findsOneWidget,
    );

    // Return to Settings, then prove it reacts to a sensor change that occurs
    // inside a nested destination without requiring the route to be reopened.
    Navigator.of(tester.element(picker)).pop();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Glucose & display'));
    await tester.tap(find.text('Glucose & display'));
    await tester.pumpAndSettle();
    expect(find.text('Calibration scale'), findsNothing);
    expect(find.text('Crop first N samples'), findsNothing);
    expect(find.text('Clear cache'), findsNothing);
    Navigator.of(tester.element(find.text('Display settings'))).pop();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Current sensor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();
    await tester.runAsync(controller.disconnect);
    await tester.pumpAndSettle();
    expect(find.text('This sensor is no longer active'), findsOneWidget);
    await tester.tap(find.text('Back to Settings'));
    await tester.pumpAndSettle();
    expect(controller.snapshot, isNull);
    expect(find.text('No active sensor'), findsOneWidget);
    expect(find.text('Connect a sensor'), findsOneWidget);

    // Unmount the tree so the dashboard's periodic hero-card ticker is
    // disposed before teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('demo driver renders scan results and dashboard', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Bypass first-run onboarding so this test targets the scan/dashboard.
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

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

    expect(find.text('OpenGlucose'), findsOneWidget);
    await tester.tap(find.text('Find my sensor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('OpenGlucose'), findsOneWidget);
    expect(find.text('AiDEX Demo 07A12'), findsNothing);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('DEMO DATA — NOT REAL GLUCOSE'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('warmup hides every history-derived dashboard section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(initialScenario: MockScenario.warmup),
    );
    await controller.initialize();
    await controller.connect(MockScenarioCatalog.sensor);

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

    expect(find.text('Warming up'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('dashboardHistorySection')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dashboardPatternsSection')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dashboardWeeklyRecapSection')),
      findsNothing,
    );

    controller.applyMockScenario(MockScenario.activeNormal);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('dashboardHistorySection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dashboardPatternsSection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dashboardWeeklyRecapSection')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('demo mode never reads or overwrites a real saved sensor', (
    tester,
  ) async {
    final rememberedSensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'physical-aidex-1234',
      displayName: 'Physical AiDEX',
      storageKey: 'aidex:physical-1234',
      rssi: -46,
      capabilities: const CgmCapabilities(
        supportsDirectBle: true,
        supportsVendorPairing: true,
        supportsAdvertisementGlucose: true,
        supportsHistory: true,
        supportsRawHistory: true,
        supportsCalibration: true,
        supportsDiagnostics: true,
        supportsCommunicationInterval: true,
      ),
      advertisement: const CgmAdvertisement(
        payloadHex: '5900DEMO0712',
        counter: 12,
        phaseHex: '21',
        glucoseTriplet: <int>[122, 124, 127],
        qualifiers: <int>[1, 0, 0],
        displayValueMgdl: 124,
      ),
      metadata: const <String, String>{'serial': 'PHYSICAL1234'},
    );
    final rememberedJson = jsonEncode(rememberedSensor.toJson());

    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.lastSensor': rememberedJson,
      // Bypass first-run onboarding so this test targets sensor restore.
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();
    expect(controller.snapshot, isNull);
    expect(preferences.getString('openHealth.lastSensor'), rememberedJson);

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
    expect(find.text('Find my sensor'), findsOneWidget);
    await tester.tap(find.text('Find my sensor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    expect(preferences.getString('openHealth.lastSensor'), rememberedJson);
    expect(preferences.getString('openHealth.history.demo:07A12'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(preferences.getString('openHealth.lastSensor'), rememberedJson);
  });

  testWidgets('Android sensor move locks Disconnect until the transfer ends', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final started = Completer<void>();
    final release = Completer<void>();
    final driver = _TransferWidgetDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.allLe),
      executeStarted: started,
      executeRelease: release,
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
    );
    await controller.initialize();
    await controller.connect(driver.sensor);

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
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Current sensor'));
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('moveSensorToAnotherPhoneButton')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove all sensor phone bonds?'), findsOneWidget);
    expect(find.textContaining('all other phones'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('confirmMoveSensorButton')),
    );
    await tester.pump();
    expect(started.isCompleted, isTrue);
    final disconnectButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('disconnectSensorButton')),
    );
    expect(disconnectButton.onPressed, isNull);
    expect(driver.session.executeCalls, 1);
    expect(driver.session.disconnectCalls, 0);

    await tester.runAsync(() async {
      release.complete();
      for (var attempt = 0; attempt < 40; attempt += 1) {
        if (driver.session.disconnectCalls == 1) {
          return;
        }
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pumpAndSettle();
    expect(driver.session.disconnectCalls, 1);
    expect(controller.snapshot, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'restored accepted move needs explicit Bluetooth acknowledgment',
    (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final driver = _TransferWidgetDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final tombstoneKey =
          'openHealth.bondTransfer.${driver.sensor.storageKey}';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
        'openHealth.lastSensor': jsonEncode(driver.sensor.toJson()),
        tombstoneKey: 'sensor-accepted',
      });
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
      );
      await controller.initialize();

      await controller.disconnect();
      expect(controller.snapshot, isNotNull);
      expect(preferences.getString(tombstoneKey), 'sensor-accepted');

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
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Current sensor'));
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey<String>('reviewSelectedInterruptedMoveButton'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not listed as paired'), findsOneWidget);
      expect(find.textContaining('choose Forget'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('confirmSelectedInterruptedMoveRecovery'),
        ),
      );
      await tester.pumpAndSettle();

      expect(preferences.getString(tombstoneKey), isNull);
      expect(controller.snapshot, isNull);
      expect(driver.connectCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'orphan accepted move requires local confirmation before Connect',
    (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final driver = _TransferWidgetDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final tombstoneKey =
          'openHealth.bondTransfer.${driver.sensor.storageKey}';
      await preferences.setString(tombstoneKey, 'sensor-accepted');
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
      );
      await controller.initialize();

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
      await tester.tap(find.text('Find my sensor'));
      await tester.pumpAndSettle();

      final connectFinder = find.byKey(
        ValueKey<String>('connectButton-${driver.sensor.deviceId}'),
      );
      expect(tester.widget<FilledButton>(connectFinder).onPressed, isNull);
      await tester.tap(
        find.byKey(
          ValueKey<String>('resolveInterruptedMove-${driver.sensor.deviceId}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not listed as paired'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('confirmInterruptedMoveRecovery')),
      );
      await tester.pumpAndSettle();

      expect(preferences.getString(tombstoneKey), isNull);
      expect(driver.connectCalls, 0);
      expect(tester.widget<FilledButton>(connectFinder).onPressed, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('unknown move stays fail closed with support guidance', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final driver = _TransferWidgetDriver(
      plan: const CgmBondTransferPlan(
        CgmBondTransferScope.requestingDeviceLe,
      ),
    );
    final tombstoneKey = 'openHealth.bondTransfer.${driver.sensor.storageKey}';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
      'openHealth.lastSensor': jsonEncode(driver.sensor.toJson()),
      tombstoneKey: 'outcome-unknown',
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
    );
    await controller.initialize();

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
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Current sensor'));
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();

    final blockedAction = tester.widget<FilledButton>(
      find.byKey(
        const ValueKey<String>('reviewSelectedInterruptedMoveButton'),
      ),
    );
    expect(blockedAction.onPressed, isNull);
    expect(find.text('Move needs support'), findsOneWidget);
    expect(find.textContaining('Do not reconnect'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('confirmSelectedInterruptedMoveRecovery'),
      ),
      findsNothing,
    );
    expect(preferences.getString(tombstoneKey), 'outcome-unknown');
    expect(driver.connectCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}

class _TransferWidgetDriver implements CgmDriver {
  _TransferWidgetDriver({
    required this.plan,
    this.executeStarted,
    this.executeRelease,
  }) : session = _TransferWidgetSession(
         sensor: sensorDefinition,
         plan: plan,
         executeStarted: executeStarted,
         executeRelease: executeRelease,
       );

  static const sensorDefinition = DiscoveredSensor(
    driverId: 'transfer-widget-test',
    deviceId: 'transfer-widget-device',
    displayName: 'AiDEX Transfer Test',
    storageKey: 'aidex:transfer-widget-test',
    rssi: -45,
    capabilities: CgmCapabilities(
      supportsDirectBle: true,
      supportsVendorPairing: true,
      supportsHistory: true,
    ),
    metadata: <String, String>{'serial': 'TRANSFERTEST'},
  );

  final CgmBondTransferPlan plan;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  final _TransferWidgetSession session;
  int connectCalls = 0;

  DiscoveredSensor get sensor => sensorDefinition;

  @override
  String get driverId => sensor.driverId;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCalls += 1;
    return session;
  }

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    yield sensor;
  }
}

class _TransferWidgetSession implements CgmSession, CgmBondTransferSession {
  _TransferWidgetSession({
    required this.sensor,
    required this.plan,
    this.executeStarted,
    this.executeRelease,
  }) : currentSnapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.ready,
         statusText: 'Connected',
         sensor: sensor,
         capabilities: sensor.capabilities,
         metadata: <String, String>{'serial': sensor.metadata['serial']!},
       );

  @override
  final DiscoveredSensor sensor;
  final CgmBondTransferPlan plan;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  int executeCalls = 0;
  int disconnectCalls = 0;

  @override
  final CgmSessionSnapshot currentSnapshot;

  @override
  Future<CgmBondTransferPlan> inspectBondTransfer() async => plan;

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
    await onSensorAccepted();
  }

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

class _PrivateSupportDriver implements CgmDriver {
  final DiscoveredSensor sensor = const DiscoveredSensor(
    driverId: 'private-support-test',
    deviceId: 'sensitive-device-id',
    displayName: 'Sensitive Sensor Name',
    storageKey: 'sensitive-storage-key',
    rssi: -50,
    capabilities: CgmCapabilities(supportsDirectBle: true),
  );

  @override
  String get driverId => sensor.driverId;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    return _PrivateSupportSession(sensor);
  }

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();
}

class _PrivateSupportSession implements CgmSession {
  _PrivateSupportSession(this.sensor)
    : currentSnapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        sensor: sensor,
        capabilities: sensor.capabilities,
        metadata: <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.subscribe,
          ...BleFailure(
            kind: BleFailureKind.bondRejected,
            operation: BleOperation.subscribe,
            diagnosticCode: 'fake.subscribe.authentication-required',
          ).toMetadata(),
          'deviceId': sensor.deviceId,
        },
        lastError: 'Bluetooth setup could not be completed.',
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
