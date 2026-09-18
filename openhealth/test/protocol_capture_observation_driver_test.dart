import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/protocol_capture_observation_driver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const driver = ProtocolCaptureObservationDriver();

  test('uses a non-production identity and never discovers a sensor', () async {
    expect(driver.driverId, isNot('aidex'));
    expect(await driver.scan().toList(), isEmpty);
  });

  test('rejects connection without a transport operation', () async {
    final sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'test-device',
      displayName: 'Test sensor',
      storageKey: 'test-storage',
      rssi: -50,
      capabilities: const CgmCapabilities(),
    );

    await expectLater(
      driver.connect(sensor),
      throwsA(isA<UnsupportedCapabilityException>()),
    );
  });

  testWidgets(
    'does not restore or reconnect a persisted production sensor',
    (tester) async {
      final persistedSensor = DiscoveredSensor(
        driverId: 'aidex',
        deviceId: 'persisted-device',
        displayName: 'Persisted sensor',
        storageKey: 'aidex:persisted-device',
        rssi: -50,
        capabilities: const CgmCapabilities(),
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.lastSensor': jsonEncode(persistedSensor.toJson()),
      });
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
      );

      await controller.initialize();
      await tester.pump(const Duration(milliseconds: 701));

      expect(controller.snapshot, isNull);
      expect(controller.sensors, isEmpty);
      expect(controller.lastError, isNull);

      controller.dispose();
    },
  );
}
