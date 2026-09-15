import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
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

  testWidgets('home counts retained provisional and raw archive readings', (
    tester,
  ) async {
    final first = _archive('first');
    final second = _archive('second');
    final store = _ArchiveStore(<ArchivedSensorSession, List<CgmReading>>{
      first: <CgmReading>[
        _reading(60, provisional: true),
        _reading(61, provisional: true),
        _reading(62, provisional: true),
      ],
      second: <CgmReading>[
        _reading(70, raw: true),
        _reading(71, raw: true),
      ],
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: _NoSensorDriver(),
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

    expect(find.text('2 saved sessions · 5 stored readings'), findsOneWidget);
    expect(controller.allHistoricalReadings, isEmpty);
    expect(find.text('View weekly recap'), findsNothing);
    expect(
      controller
          .readingsForArchivedSensor(first)
          .every((reading) => reading.isDisplayProvisional),
      isTrue,
    );
    expect(
      controller
          .readingsForArchivedSensor(second)
          .every((reading) => reading.source == CgmRecordSource.raw),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test(
    'Libre cumulative copies count once within each bootstrap only',
    () async {
      final first = _archive(
        'first',
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:shared',
        manifestCount: 2,
      );
      final cumulative = _archive(
        'cumulative',
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:shared',
        manifestCount: 3,
      );
      final other = _archive(
        'other',
        driverId: 'libre2-gen1',
        manifestCount: 1,
      );
      final store = _ArchiveStore({
        first: [_reading(60, provisional: true), _reading(61, raw: true)],
        cumulative: [
          _reading(60, provisional: true),
          _reading(61, raw: true),
          _reading(62, provisional: true),
        ],
        other: [_reading(60, provisional: true)],
      });
      final before = Map<String, String>.of(store.values);
      final controller = await _controller(store);
      expect(controller.archivedReadingCount, 4);
      expect(controller.archivedSensors, hasLength(3));
      expect(controller.allHistoricalReadings, isEmpty);
      for (final key in before.keys) {
        expect(store.values[key], before[key]);
      }
      controller.dispose();
    },
  );

  testWidgets('home reports unavailable count for a malformed Libre archive', (
    tester,
  ) async {
    final archive = _archive('bad', driverId: 'libre2-gen1', manifestCount: 1);
    final store = _ArchiveStore({
      archive: [_reading(60, provisional: true)],
    });
    store.values[archive.historyKey] = '{"unknown":true}';
    final preferences = await SharedPreferences.getInstance();
    final controller = await _controller(store);
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
    expect(controller.archivedReadingCount, isNull);
    expect(
      find.text('Saved sessions unavailable · Stored readings unavailable'),
      findsOneWidget,
    );
    expect(find.text('View weekly recap'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(store.values[archive.historyKey], '{"unknown":true}');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final malformed in <String, String>{
    'invalid JSON': '{',
    'wrong top-level type': '{"futureSchema":true}',
    'invalid entry type': '[null]',
    'wrong known field type': jsonEncode([
      {
        'storageKey': 'synthetic-storage',
        'driverId': 'synthetic-driver',
        'readingCount': 'invalid',
      },
    ]),
    'missing required Libre identity': jsonEncode([
      {
        'storageKey': 'libre2-gen1:synthetic',
        'driverId': 'libre2-gen1',
      },
    ]),
  }.entries) {
    testWidgets('home preserves unavailable manifest: ${malformed.key}', (
      tester,
    ) async {
      final archive = _archive('retained');
      final store = _ArchiveStore({
        archive: [_reading(60, provisional: true)],
      });
      store.values['openHealth.sensorArchive'] = malformed.value;
      final before = Map<String, String>.of(store.values);
      final preferences = await SharedPreferences.getInstance();
      final controller = await _controller(store);

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

      expect(controller.archiveManifestUnavailable, isTrue);
      expect(controller.archivedReadingCount, isNull);
      expect(controller.allHistoricalReadings, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('historicalOverviewCard')),
        findsOneWidget,
      );
      expect(
        find.text('Saved sessions unavailable · Stored readings unavailable'),
        findsOneWidget,
      );
      expect(find.textContaining('0 stored readings'), findsNothing);
      expect(find.text('View weekly recap'), findsNothing);
      expect(tester.takeException(), isNull);
      for (final entry in before.entries) {
        expect(store.values[entry.key], entry.value);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  test(
    'stored count does not change profile warmup or wellness filtering',
    () async {
      final libre = _archive(
        'libre',
        driverId: 'libre2-gen1',
        manifestCount: 3,
      );
      final shortWarmup = _archive('short', warmupMinutes: 17);
      final store = _ArchiveStore(<ArchivedSensorSession, List<CgmReading>>{
        libre: <CgmReading>[
          _reading(59, provisional: true),
          _reading(60, provisional: true),
          _reading(61, raw: true),
        ],
        shortWarmup: <CgmReading>[_reading(16), _reading(17)],
      });
      final before = Map<String, String>.of(store.values);
      final controller = await _controller(store);

      expect(controller.archivedReadingCount, 5);
      expect(
        controller
            .displayReadingsForArchivedSensor(libre)
            .map((reading) => reading.sensorMinute),
        <int>[60, 61],
      );
      expect(
        controller
            .displayReadingsForArchivedSensor(shortWarmup)
            .map((reading) => reading.sensorMinute),
        <int>[17],
      );
      expect(
        controller.allHistoricalReadings.map((reading) => reading.sensorMinute),
        <int>[17],
      );
      expect(controller.readingsForArchivedSensor(libre), hasLength(3));
      expect(controller.readingsForArchivedSensor(shortWarmup), hasLength(2));
      for (final key in before.keys) {
        expect(store.values[key], before[key]);
      }
      controller.dispose();
    },
  );

  test(
    'counts each retained array once without cross-sensor deduplication',
    () async {
      final first = _archive('first');
      final alias = _archive('alias', historyKey: first.historyKey);
      final separate = _archive('separate');
      final store = _ArchiveStore(<ArchivedSensorSession, List<CgmReading>>{
        first: <CgmReading>[_reading(60, provisional: true)],
        alias: <CgmReading>[_reading(60, provisional: true)],
        separate: <CgmReading>[_reading(60, provisional: true)],
      });
      final controller = await _controller(store);

      expect(controller.archivedSensors, hasLength(3));
      expect(controller.archivedReadingCount, 2);
      expect(controller.allHistoricalReadings, isEmpty);
      controller.dispose();
    },
  );

  test(
    'counts actual retained records rather than stale manifest totals',
    () async {
      final present = _archive('present', manifestCount: 99);
      final missing = _archive('missing', manifestCount: 99);
      final store = _ArchiveStore(<ArchivedSensorSession, List<CgmReading>>{
        present: <CgmReading>[_reading(60, provisional: true)],
        missing: const <CgmReading>[],
      });
      store.values.remove(missing.historyKey);
      final controller = await _controller(store);

      expect(controller.archivedReadingCount, 1);
      expect(
        controller.archivedSensors.every((s) => s.readingCount == 99),
        isTrue,
      );
      expect(store.values, isNot(contains(missing.historyKey)));
      controller.dispose();
    },
  );
}

Future<CgmAppController> _controller(_ArchiveStore store) async {
  final controller = CgmAppController(
    preferences: await SharedPreferences.getInstance(),
    driver: _NoSensorDriver(),
    healthStateStore: store,
  );
  await controller.initialize();
  return controller;
}

ArchivedSensorSession _archive(
  String id, {
  String driverId = 'synthetic-driver',
  String? historyKey,
  String? storageKey,
  int? warmupMinutes,
  int manifestCount = 0,
}) {
  final storedKey =
      storageKey ??
      (driverId == 'libre2-gen1'
          ? 'libre2-gen1:synthetic-$id'
          : 'synthetic-storage-$id');
  final archiveId = driverId == 'libre2-gen1'
      ? base64Url
            .encode(utf8.encode('$driverId|$storedKey|${id.hashCode}'))
            .replaceAll('=', '')
      : id;
  return ArchivedSensorSession(
    id: archiveId,
    historyKey:
        historyKey ??
        (driverId == 'libre2-gen1'
            ? 'openHealth.history.archive.$archiveId'
            : 'openHealth.history.archive.synthetic-$id'),
    storageKey: storedKey,
    driverId: driverId,
    deviceId: 'synthetic-device-$id',
    displayName: 'Synthetic sensor',
    reason: SensorArchiveReason.disconnected,
    readingCount: manifestCount,
    warmupMinutes: warmupMinutes,
    endedAt: DateTime.utc(2026, 8, 1, 12),
  );
}

CgmReading _reading(int minute, {bool provisional = false, bool raw = false}) =>
    CgmReading(
      valueMgdl: 123,
      source: raw ? CgmRecordSource.raw : CgmRecordSource.vendor,
      isDisplayProvisional: provisional,
      sensorMinute: minute,
      recordedAt: DateTime.utc(2026, 8, 1).add(Duration(minutes: minute)),
    );

class _ArchiveStore implements HealthStateStore {
  _ArchiveStore(Map<ArchivedSensorSession, List<CgmReading>> archives) {
    values['openHealth.sensorArchive'] = jsonEncode(
      archives.keys.map((session) => session.toJson()).toList(growable: false),
    );
    for (final entry in archives.entries) {
      values[entry.key.historyKey] = jsonEncode(
        entry.value.map((reading) => reading.toJson()).toList(growable: false),
      );
    }
  }

  final values = <String, String>{};

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

class _NoSensorDriver implements CgmDriver {
  @override
  String get driverId => 'synthetic-driver';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) =>
      throw StateError('No connection is expected in this fixture.');
}
