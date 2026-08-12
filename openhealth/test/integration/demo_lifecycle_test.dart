import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'demo lifecycle scans, connects, refreshes, and disconnects',
    () async {
      var now = DateTime.utc(2026, 6, 1, 12);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final healthStateStore = PreferencesHealthStateStore(preferences);
      final controller = CgmAppController(
        preferences: preferences,
        driver: DemoCgmDriver(clock: () => now),
        healthStateStore: healthStateStore,
      );

      await controller.initialize();
      expect(controller.snapshot, isNull);

      await controller.scan();
      expect(controller.sensors, hasLength(1));
      final sensor = controller.sensors.single;

      await controller.connect(sensor);
      expect(controller.snapshot?.stage, CgmSyncStage.ready);
      expect(controller.visibleHistory, hasLength(48));
      expect(healthStateStore.getString('openHealth.lastSensor'), isNotNull);

      final previousReading = controller.latestReading;
      now = now.add(const Duration(minutes: 5));
      await controller.refresh();
      expect(controller.latestReading?.recordedAt, now);
      expect(
        controller.latestReading?.sensorMinute,
        isNot(previousReading?.sensorMinute),
      );

      await controller.disconnect();
      expect(controller.snapshot, isNull);
      expect(healthStateStore.getString('openHealth.lastSensor'), isNull);
      controller.dispose();
    },
    tags: 'integration',
  );
}
