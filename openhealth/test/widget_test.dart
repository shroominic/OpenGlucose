import 'dart:convert';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
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
    expect(find.text('DEMO DATA — NOT REAL GLUCOSE'), findsOneWidget);
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
