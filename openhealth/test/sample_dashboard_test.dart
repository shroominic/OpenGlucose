import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'sample dashboard is explicit and leaves production state untouched',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
        'unrelated.preference': 'keep-me',
      });
      final preferences = await SharedPreferences.getInstance();
      final healthStateStore = _RecordingHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _NoSensorDriver(),
        healthStateStore: healthStateStore,
      );
      await controller.initialize();
      final preferencesBefore = <String, Object?>{
        for (final key in preferences.getKeys()) key: preferences.get(key),
      };
      final restrictedStateBefore = healthStateStore.snapshot;

      await tester.pumpWidget(
        OpenGlucoseApp(
          controller: controller,
          healthExport: HealthExportController(
            preferences: preferences,
            healthStateStore: healthStateStore,
            writesAllowed: false,
          )..initialize(),
          preferences: preferences,
        ),
      );
      await tester.pump();

      expect(controller.snapshot, isNull);
      expect(find.text('Explore sample data'), findsOneWidget);
      await tester.tap(find.text('Explore sample data'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('sampleDashboard')),
        findsOneWidget,
      );
      expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);
      expect(find.textContaining('Connected'), findsNothing);
      expect(controller.snapshot, isNull);
      expect(controller.sensors, isEmpty);
      expect(controller.archivedSensors, isEmpty);
      expect(<String, Object?>{
        for (final key in preferences.getKeys()) key: preferences.get(key),
      }, preferencesBefore);
      expect(healthStateStore.snapshot, restrictedStateBefore);

      await tester.scrollUntilVisible(
        find.text('Open sample weekly recap'),
        500,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('sampleDashboard')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Open sample weekly recap'));
      await tester.pumpAndSettle();

      expect(find.text('Sample weekly recap'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('sampleWeeklyRecapBanner')),
        findsOneWidget,
      );
      expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);
      expect(controller.snapshot, isNull);
      expect(healthStateStore.snapshot, restrictedStateBefore);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

class _NoSensorDriver implements CgmDriver {
  @override
  String get driverId => 'production-test';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw StateError('The sample dashboard must never connect to a sensor.');
  }
}

class _RecordingHealthStateStore implements HealthStateStore {
  final Map<String, String> _values = <String, String>{};

  Map<String, String> get snapshot => Map<String, String>.of(_values);

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
    _values[key] = value;
  }
}
