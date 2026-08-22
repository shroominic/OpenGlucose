import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/weekly_recap/weekly_recap_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'expired persisted sensor is archived instead of restored as active',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _NeverConnectDriver();
      final sensor = DiscoveredSensor(
        driverId: driver.driverId,
        deviceId: 'expired-device',
        displayName: 'Expired AiDEX',
        storageKey: 'aidex:expired-serial',
        rssi: -60,
        capabilities: const CgmCapabilities(supportsHistory: true),
        metadata: const <String, String>{'serial': 'EXPIRED-SERIAL'},
      );
      final reading = CgmReading(
        valueMgdl: 117,
        source: CgmRecordSource.vendor,
        sensorMinute: 120,
        recordedAt: DateTime.now().subtract(const Duration(days: 16)),
      );
      final store = _SeededHealthStateStore(<String, String>{
        'openHealth.lastSensor': jsonEncode(sensor.toJson()),
        'openHealth.history.${sensor.storageKey}': jsonEncode(<Object?>[
          reading.toJson(),
        ]),
      });
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(controller.snapshot, isNull);
      expect(driver.connectCount, 0);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.archivedSensors, hasLength(1));
      final archived = controller.archivedSensors.single;
      expect(archived.storageKey, sensor.storageKey);
      expect(archived.reason, SensorArchiveReason.expired);
      expect(archived.readingCount, 1);
      expect(controller.readingsForArchivedSensor(archived), hasLength(1));
      expect(controller.allHistoricalReadings, hasLength(1));

      controller.dispose();
    },
  );

  test(
    'archive keeps immutable snapshots for two sessions sharing a storage key',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _NeverConnectDriver();
      final sensor = DiscoveredSensor(
        driverId: driver.driverId,
        deviceId: 'reused-transmitter',
        displayName: 'AiDEX transmitter',
        storageKey: 'aidex:shared-hardware-key',
        rssi: -55,
        capabilities: const CgmCapabilities(supportsHistory: true),
        metadata: const <String, String>{'serial': 'SHARED-SERIAL'},
      );
      final reference = DateTime.now();
      final firstStart = reference.subtract(const Duration(days: 40));
      final secondStart = reference.subtract(const Duration(days: 20));
      final firstReading = CgmReading(
        valueMgdl: 101,
        source: CgmRecordSource.vendor,
        sensorMinute: 120,
        recordedAt: firstStart.add(const Duration(minutes: 120)),
      );
      final secondReading = CgmReading(
        valueMgdl: 149,
        source: CgmRecordSource.vendor,
        sensorMinute: 240,
        recordedAt: secondStart.add(const Duration(minutes: 240)),
      );
      final store = _SeededHealthStateStore(<String, String>{});

      Future<CgmAppController> restoreExpired(CgmReading reading) async {
        await store.setString(
          'openHealth.lastSensor',
          jsonEncode(sensor.toJson()),
        );
        await store.setString(
          'openHealth.history.${sensor.storageKey}',
          jsonEncode(<Object?>[reading.toJson()]),
        );
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        await controller.initialize();
        return controller;
      }

      final firstController = await restoreExpired(firstReading);
      expect(firstController.archivedSensors, hasLength(1));
      firstController.dispose();

      final secondController = await restoreExpired(secondReading);
      expect(secondController.snapshot, isNull);
      expect(secondController.archivedSensors, hasLength(2));
      expect(
        secondController.archivedSensors.map((session) => session.id).toSet(),
        hasLength(2),
      );
      expect(
        secondController.archivedSensors
            .map((session) => session.historyKey)
            .toSet(),
        hasLength(2),
      );

      final archivedValues = secondController.archivedSensors
          .map(secondController.readingsForArchivedSensor)
          .map((readings) => readings.single.valueMgdl)
          .toSet();
      expect(archivedValues, <double>{101, 149});

      // The mutable active-history slot may be reused by the next session,
      // but neither archived session may follow that overwrite.
      await store.setString(
        'openHealth.history.${sensor.storageKey}',
        jsonEncode(<Object?>[
          CgmReading(
            valueMgdl: 222,
            source: CgmRecordSource.vendor,
            recordedAt: reference,
          ).toJson(),
        ]),
      );
      expect(
        secondController.archivedSensors
            .map(secondController.readingsForArchivedSensor)
            .map((readings) => readings.single.valueMgdl)
            .toSet(),
        <double>{101, 149},
      );
      expect(driver.connectCount, 0);

      secondController.dispose();
    },
  );

  testWidgets(
    'expired home explains expiry and anchors recap to retained history',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final driver = _NeverConnectDriver();
      final sensor = DiscoveredSensor(
        driverId: driver.driverId,
        deviceId: 'expired-ui-device',
        displayName: 'Expired AiDEX',
        storageKey: 'aidex:expired-ui-serial',
        rssi: -60,
        capabilities: const CgmCapabilities(supportsHistory: true),
        metadata: const <String, String>{'serial': 'EXPIRED-UI-SERIAL'},
      );
      final recordedAt = DateTime.now().subtract(const Duration(days: 16));
      final reading = CgmReading(
        valueMgdl: 117,
        source: CgmRecordSource.vendor,
        sensorMinute: 120,
        recordedAt: recordedAt,
      );
      final store = _SeededHealthStateStore(<String, String>{
        'openHealth.lastSensor': jsonEncode(sensor.toJson()),
        'openHealth.history.${sensor.storageKey}': jsonEncode(<Object?>[
          reading.toJson(),
        ]),
      });
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();

      await tester.pumpWidget(
        OpenGlucoseApp(
          controller: controller,
          healthExport: HealthExportController(
            preferences: preferences,
            healthStateStore: store,
            writesAllowed: false,
          )..initialize(),
          preferences: preferences,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('last sensor expired'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('historicalTimestampSummary')),
        findsOneWidget,
      );
      expect(find.byType(CgmDashboardChart), findsNothing);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View weekly recap'));
      await tester.pumpAndSettle();
      final recap = tester.widget<WeeklyRecapScreen>(
        find.byType(WeeklyRecapScreen),
      );
      expect(recap.now, recordedAt);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

class _NeverConnectDriver implements CgmDriver {
  int connectCount = 0;

  @override
  String get driverId => 'aidex-test';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCount += 1;
    throw StateError('An expired sensor must never reconnect');
  }
}

class _SeededHealthStateStore implements HealthStateStore {
  _SeededHealthStateStore(Map<String, String> values)
    : _values = Map<String, String>.of(values);

  final Map<String, String> _values;

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
