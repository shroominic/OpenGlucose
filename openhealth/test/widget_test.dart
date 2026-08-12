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
  testWidgets('developer tab exposes the scenario picker', (tester) async {
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

    // Open settings -> Developer tab.
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Developer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // The scenario picker is present (only shown for the mock driver).
    final picker = find.byKey(const ValueKey<String>('mockScenarioPicker'));
    expect(picker, findsOneWidget);

    // Dismiss the settings sheet, then unmount the tree so the dashboard's
    // periodic hero-card ticker is disposed before teardown.
    Navigator.of(tester.element(picker)).pop();
    await tester.pump(const Duration(milliseconds: 500));
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
    expect(find.text('History'), findsOneWidget);
    expect(find.text('DEMO DATA — NOT REAL GLUCOSE'), findsOneWidget);
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
