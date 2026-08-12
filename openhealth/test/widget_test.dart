import 'dart:convert';

import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('developer tab scenario picker switches the live dashboard', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(preferences: preferences)
          ..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.text('Find my sensor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(controller.mockScenario, MockScenario.activeNormal);

    // Open settings -> Developer tab.
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Developer'));
    await tester.pumpAndSettle();

    // The scenario picker is present (only shown for the mock driver).
    final picker = find.byKey(const ValueKey<String>('mockScenarioPicker'));
    expect(picker, findsOneWidget);

    // Switch to activeHigh and confirm the controller + snapshot updated.
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Active — high (alert)').last);
    await tester.pumpAndSettle();

    expect(controller.mockScenario, MockScenario.activeHigh);
    expect(
      controller.latestReading!.valueMgdl,
      greaterThan(kMockHighThresholdMgdl),
    );
    expect(
      controller.snapshot!.metadata['scenario'],
      MockScenario.activeHigh.id,
    );

    // Dismiss the settings sheet, then unmount the tree so the dashboard's
    // periodic hero-card ticker is disposed before teardown.
    Navigator.of(tester.element(picker)).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.disconnect();
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
        healthExport: HealthExportController(preferences: preferences)
          ..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('OpenGlucose'), findsOneWidget);
    await tester.tap(find.text('Find my sensor'));
    await tester.pumpAndSettle();
    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('restores the last connected sensor on launch', (tester) async {
    final rememberedSensor = DiscoveredSensor(
      driverId: 'demo-aidex',
      deviceId: 'demo-aidex-07A12',
      displayName: 'AiDEX Demo 07A12',
      storageKey: 'demo:07A12',
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
      metadata: const <String, String>{'serial': '07A12', 'mode': 'demo'},
    );

    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.lastSensor': jsonEncode(rememberedSensor.toJson()),
      // Bypass first-run onboarding so this test targets sensor restore.
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
        healthExport: HealthExportController(preferences: preferences)
          ..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 1200));

    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });
}
