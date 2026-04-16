import 'dart:convert';

import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('demo driver renders scan results and dashboard', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

    await tester.pumpWidget(OpenGlucoseApp(controller: controller));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('OpenGlucose'), findsOneWidget);
    await tester.tap(find.text('Find my sensor'));
    await tester.pumpAndSettle();
    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('LIVE'), findsOneWidget);
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
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

    await tester.pumpWidget(OpenGlucoseApp(controller: controller));
    await tester.pumpAndSettle(const Duration(milliseconds: 1200));

    expect(find.text('AiDEX Demo 07A12'), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });
}
