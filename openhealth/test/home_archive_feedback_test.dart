import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export.dart';
import 'package:openglucose/src/sensor_lifecycle_card.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
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

  testWidgets(
    'home connects inline and offers model help after empty Bluetooth search',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final driver = _NoSensorDriver();
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
      await tester.pumpAndSettle();
      expect(find.text("Can't find your sensor?"), findsNothing);
      expect(find.text('FreeStyle Libre 2'), findsNothing);
      expect(find.textContaining('NFC'), findsNothing);
      expect(driver.scanCalls, 0);
      await tester.tap(
        find.byKey(const ValueKey<String>('connectSensorButton')),
      );
      await tester.pumpAndSettle();
      expect(driver.scanCalls, 1);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('OpenGlucose'), findsOneWidget);
      expect(find.text("Can't find your sensor?"), findsOneWidget);
      expect(find.text('FreeStyle Libre 2'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('supportedModelCatalog')),
        findsNothing,
      );
      expect(find.textContaining('NFC'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('sensorHelpButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('sensorHelpButton')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Which sensor do you have?'), findsOneWidget);
      expect(find.text('AiDEX / LinX'), findsOneWidget);
      expect(find.textContaining('NFC'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('chooseLibre2Help')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('chooseLibre2Help')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('libre2NfcGuide')),
        findsOneWidget,
      );
      expect(find.textContaining('NFC'), findsWidgets);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('settings connection returns to inline home search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final driver = _NoSensorDriver();
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
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect a sensor').last);
    await tester.pumpAndSettle();
    expect(driver.scanCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('sensorConnectionScreen')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('settingsOverview')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'home keeps only compact expiry while Current sensor owns lifecycle card',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
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
      await _startNearbySensorScan(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const ValueKey<String>('connectButton-1')),
      );
      await _waitForSensorConnectionFlowToClose(tester);

      expect(find.byType(SensorLifecycleCard), findsNothing);
      expect(_compactExpiryText(), findsOneWidget);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();

      expect(find.byType(SensorLifecycleCard), findsOneWidget);
      expect(find.text('Sensor lifecycle'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  for (final raw in [false, true]) {
    testWidgets(
      'archive shows data quality in details without a banner (raw: $raw)',
      (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'openHealth.onboarding.completed': true,
        });
        final preferences = await SharedPreferences.getInstance();
        final fixture = _archivedHistoryFixture(
          provisional: !raw,
          source: raw ? CgmRecordSource.raw : CgmRecordSource.vendor,
        );
        final store = _MemoryHealthStateStore(fixture.values);
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
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sensor archive'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(fixture.session.serial));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('historyQualityNotice')),
          findsNothing,
        );
        expect(
          find.textContaining('Not validated for body glucose'),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('sensorDataQuality')), findsOneWidget);
        expect(find.text('Data quality'), findsOneWidget);
        expect(
          find.text(raw ? 'Raw sensor data' : 'Provisional readings'),
          findsOneWidget,
        );
        expect(find.text('Recap this sensor'), findsNothing);
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(find.text('Export data'), findsOneWidget);
        expect(controller.allHistoricalReadings, isEmpty);
        expect(
          controller.readingsForArchivedSensor(fixture.session),
          hasLength(2),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  testWidgets('archive export offers CSV TXT and XLSX choices', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final fixture = _archivedHistoryFixture(includePostWarmup: false);
    final store = _MemoryHealthStateStore(fixture.values);
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

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sensor archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(fixture.session.serial));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sensorDataQuality')), findsNothing);
    expect(find.text('Data quality'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();

    final exportLabel = find.text('Export data');
    expect(exportLabel, findsOneWidget);
    final exportButton = find.ancestor(
      of: exportLabel,
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(exportButton, findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(exportButton).onPressed, isNotNull);

    await tester.tap(exportLabel);
    await tester.pumpAndSettle();

    expect(find.text('Export archived sensor data'), findsOneWidget);
    expect(find.text('1 stored glucose readings'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('archivedExportWarmupDisclosure')),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 warmup reading is included for a complete export'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('archivedSensorExportFormatPicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('exportFormatCsv')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('exportFormatTxt')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('exportFormatXlsx')),
      findsOneWidget,
    );
    expect(find.text('Included in the file'), findsOneWidget);
    expect(find.textContaining('Sensor serials, device IDs'), findsOneWidget);
    for (final format in const <({String key, String shareLabel})>[
      (key: 'exportFormatCsv', shareLabel: 'Share CSV'),
      (key: 'exportFormatTxt', shareLabel: 'Share TXT'),
      (key: 'exportFormatXlsx', shareLabel: 'Share XLSX'),
    ]) {
      await tester.tap(find.byKey(ValueKey<String>(format.key)));
      await tester.pumpAndSettle();
      expect(find.text(format.shareLabel), findsOneWidget);
    }
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final format in ArchivedSensorExportFormat.values) {
    testWidgets(
      'actual ${format.name} share retains NFC acquisition evidence',
      (
        tester,
      ) async {
        final fixture = _libreArchivedHistoryFixture();
        final harness = await _openArchiveExportHarness(tester, fixture);
        await _openArchiveDetail(tester, fixture.session);
        await _scrollToArchiveExport(tester);
        await tester.tap(find.text('Export data'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('archivedExportAcquisitionDisclosure')),
          findsOneWidget,
        );
        final formatKey = switch (format) {
          ArchivedSensorExportFormat.csv => 'exportFormatCsv',
          ArchivedSensorExportFormat.txt => 'exportFormatTxt',
          ArchivedSensorExportFormat.xlsx => 'exportFormatXlsx',
        };
        await tester.tap(find.byKey(ValueKey(formatKey)));
        await tester.pumpAndSettle();
        await _confirmAndWaitForArchiveShare(tester, harness);
        expect(harness.shareCalls, 1);
        expect(harness.temporaryDirectoryCalls, 1);
        final String contents;
        if (format == ArchivedSensorExportFormat.xlsx) {
          final zip = ZipDecoder().decodeBytes(harness.bytes!);
          contents = utf8.decode(
            zip.find('xl/worksheets/sheet1.xml')!.readBytes()!,
          );
          expect(contents, contains('A1:Q5'));
          for (var row = 2; row <= 5; row++) {
            expect(
              contents,
              contains(
                '<c r="M$row" t="inlineStr"><is><t xml:space="preserve">true</t></is></c>',
              ),
            );
          }
        } else {
          contents = utf8.decode(harness.bytes!);
          final separator = format == ArchivedSensorExportFormat.csv
              ? ','
              : '\t';
          expect(contents.split('\r\n').first.split(separator), hasLength(17));
          final rows = contents
              .split('\r\n')
              .skip(1)
              .where((row) => row.isNotEmpty);
          expect(
            rows.map((row) => row.split(separator)[14]),
            ['legacyUnknown', 'nfcHistory', 'nfcTrend', 'bleLive'],
          );
          expect(rows.first.split(separator)[15], isEmpty);
          expect(
            rows.map((row) => row.split(separator)[12]),
            everyElement('true'),
          );
        }
        for (final field in [
          'export_schema_version',
          'acquisition_origin',
          'first_received_at_utc',
          'timestamp_basis',
          'legacyUnknown',
          'nfcHistory',
          'nfcTrend',
          'bleLive',
          'sensorRelative',
          'phoneReceipt',
          '2026-09-01T12:00:00.000Z',
          'vendor',
        ]) {
          expect(contents, contains(field));
        }
        for (final identity in [
          fixture.session.id,
          fixture.session.historyKey,
          fixture.session.storageKey,
          fixture.session.deviceId,
          fixture.session.serial,
        ]) {
          expect(contents, isNot(contains(identity)));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        harness.controller.dispose();
      },
    );
  }

  testWidgets('actual legacy share keeps the original 13 columns', (
    tester,
  ) async {
    final fixture = _archivedHistoryFixture();
    final harness = await _openArchiveExportHarness(tester, fixture);
    await _openArchiveDetail(tester, fixture.session);
    await _scrollToArchiveExport(tester);
    await tester.tap(find.text('Export data'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('archivedExportAcquisitionDisclosure')),
      findsNothing,
    );
    await _confirmAndWaitForArchiveShare(tester, harness);
    final csv = utf8.decode(harness.bytes!);
    expect(csv.split('\r\n').first, archivedSensorCsvColumns.join(','));
    expect(csv, isNot(contains('acquisition_origin')));
    expect(harness.shareCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    harness.controller.dispose();
  });

  for (final phase in ['list', 'detail', 'confirmation']) {
    testWidgets('corrupt archive at $phase cannot create or share a file', (
      tester,
    ) async {
      final fixture = _libreArchivedHistoryFixture();
      final harness = await _openArchiveExportHarness(tester, fixture);
      Future<void> corrupt() async {
        final value =
            jsonDecode(harness.store.getString(fixture.session.historyKey)!)
                as Map<String, dynamic>;
        value['schemaVersion'] = 900;
        await harness.store.setString(
          fixture.session.historyKey,
          jsonEncode(value),
        );
      }

      if (phase == 'list') await corrupt();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sensor archive'));
      await tester.pumpAndSettle();
      if (phase == 'list') {
        expect(find.textContaining('History unavailable'), findsOneWidget);
      }
      if (phase == 'detail') await corrupt();
      await tester.tap(find.text(fixture.session.serial));
      await tester.pumpAndSettle();
      if (phase == 'confirmation') {
        await _scrollToArchiveExport(tester);
        await tester.tap(find.text('Export data'));
        await tester.pumpAndSettle();
        await corrupt();
        await tester.tap(
          find.byKey(const ValueKey('confirmArchivedSensorExport')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('The archived sensor data could not be exported.'),
          findsOneWidget,
        );
      } else {
        expect(
          find.byKey(const ValueKey('archivedSensorDataUnavailable')),
          findsOneWidget,
        );
        expect(find.text('Export data'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      expect(harness.temporaryDirectoryCalls, 0);
      expect(harness.shareCalls, 0);
      expect(harness.directory.listSync(), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      harness.controller.dispose();
    });
  }

  testWidgets(
    'sample data stays out of the home and is available from Settings',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _MemoryHealthStateStore(const <String, String>{});
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
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('onboardingSkipButton')),
      );
      await tester.pumpAndSettle();

      expect(controller.archivedSensors, isEmpty);
      expect(controller.allHistoricalReadings, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('connectSensorButton')),
        findsOneWidget,
      );
      expect(find.text('Nearby sensors'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('findNearbySensorsButton')),
        findsNothing,
      );
      expect(find.text('Explore sample data'), findsNothing);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Explore sample data'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Explore sample data'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('home keeps sample data secondary when archive is retained', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final fixture = _archivedHistoryFixture();
    final store = _MemoryHealthStateStore(fixture.values);
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

    expect(controller.archivedSensors, hasLength(1));
    expect(controller.allHistoricalReadings, isNotEmpty);
    expect(
      find.byKey(const ValueKey<String>('connectSensorButton')),
      findsOneWidget,
    );
    expect(find.text('Explore sample data'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('historicalOverviewCard')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

Future<void> _startNearbySensorScan(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('connectSensorButton')),
  );
  await tester.pump();
  for (
    var attempt = 0;
    attempt < 30 &&
        find
            .byKey(const ValueKey<String>('nearbyScanProgress'))
            .evaluate()
            .isNotEmpty;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

Future<void> _waitForSensorConnectionFlowToClose(WidgetTester tester) async {
  for (
    var attempt = 0;
    attempt < 30 &&
        find
            .byKey(const ValueKey<String>('sensorConnectionScreen'))
            .evaluate()
            .isNotEmpty;
    attempt += 1
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

Finder _compactExpiryText() => find.byWidgetPredicate((widget) {
  if (widget is! Text) {
    return false;
  }
  final value = widget.data ?? widget.textSpan?.toPlainText() ?? '';
  return RegExp(
    r'\b(?:\d+\s+days?\s+left|expires?)\b',
    caseSensitive: false,
  ).hasMatch(value);
});

({ArchivedSensorSession session, Map<String, String> values})
_archivedHistoryFixture({
  bool includePostWarmup = true,
  bool provisional = false,
  CgmRecordSource source = CgmRecordSource.vendor,
}) {
  final startedAt = DateTime(2026, 7, 1, 8);
  final endedAt = startedAt.add(const Duration(days: 15));
  const historyKey = 'openHealth.history.archive.feedback-session';
  final readings = <CgmReading>[
    CgmReading(
      valueMgdl: 171,
      source: source,
      isDisplayProvisional: provisional,
      sensorMinute: 59,
      recordedAt: startedAt.add(const Duration(minutes: 59)),
    ),
    if (includePostWarmup)
      CgmReading(
        valueMgdl: 112,
        source: source,
        isDisplayProvisional: provisional,
        sensorMinute: 60,
        recordedAt: startedAt.add(const Duration(hours: 1)),
      ),
  ];
  final session = ArchivedSensorSession(
    id: 'feedback-session',
    historyKey: historyKey,
    storageKey: 'aidex:feedback-archive',
    driverId: 'aidex-test',
    deviceId: 'feedback-device',
    displayName: 'Previous AiDEX',
    serial: 'ARCHIVE-CSV-001',
    model: 'AiDEX',
    reason: SensorArchiveReason.expired,
    readingCount: readings.length,
    startedAt: startedAt,
    endedAt: endedAt,
    lastReadingAt: readings.last.recordedAt,
  );
  return (
    session: session,
    values: <String, String>{
      'openHealth.sensorArchive': jsonEncode(<Object?>[session.toJson()]),
      historyKey: jsonEncode(
        readings.map((reading) => reading.toJson()).toList(growable: false),
      ),
    },
  );
}

({ArchivedSensorSession session, Map<String, String> values})
_libreArchivedHistoryFixture() {
  const storageKey = 'libre2-gen1:synthetic-export-bootstrap';
  final id = base64Url
      .encode(utf8.encode('libre2-gen1|$storageKey|1'))
      .replaceAll('=', '');
  final key = 'openHealth.history.archive.$id';
  final receipt = DateTime.utc(2026, 9, 1, 12);
  Map<String, Object?> entry(String origin, int minute, int offset) {
    final at = receipt.add(Duration(minutes: offset));
    return {
      'reading': CgmReading(
        valueMgdl: 100 + minute / 10,
        source: CgmRecordSource.vendor,
        sensorMinute: minute,
        recordedAt: at,
        isDisplayProvisional: true,
      ).toJson(),
      'origin': origin,
      'firstReceivedAt': origin == 'legacyUnknown'
          ? null
          : (origin == 'bleLive' ? at : receipt).toIso8601String(),
      'timestampBasis': switch (origin) {
        'legacyUnknown' => 'legacyUnknown',
        'bleLive' => 'phoneReceipt',
        _ => 'sensorRelative',
      },
    };
  }

  final session = ArchivedSensorSession(
    id: id,
    historyKey: key,
    storageKey: storageKey,
    driverId: 'libre2-gen1',
    deviceId: 'synthetic-export-device',
    displayName: 'Synthetic Libre archive',
    serial: 'SYNTHETIC-EXPORT-SERIAL',
    model: 'Libre 2',
    reason: SensorArchiveReason.disconnected,
    readingCount: 4,
    endedAt: receipt.add(const Duration(minutes: 31)),
    lastReadingAt: receipt.add(const Duration(minutes: 30)),
  );
  return (
    session: session,
    values: {
      'openHealth.sensorArchive': jsonEncode([session.toJson()]),
      key: jsonEncode({
        'schemaVersion': 2,
        'kind': 'libreHistoryArchive',
        'driverId': session.driverId,
        'storageKey': storageKey,
        'sensorBindingDigest': 'a' * 64,
        'readings': [
          entry('nfcHistory', 75, -15),
          entry('bleLive', 120, 30),
          entry('legacyUnknown', 60, -30),
          entry('nfcTrend', 89, -1),
        ],
      }),
    },
  );
}

Future<_ArchiveExportHarness> _openArchiveExportHarness(
  WidgetTester tester,
  ({ArchivedSensorSession session, Map<String, String> values}) fixture,
) async {
  SharedPreferences.setMockInitialValues({
    'openHealth.onboarding.completed': true,
  });
  final preferences = await SharedPreferences.getInstance();
  final store = _MemoryHealthStateStore(fixture.values);
  final controller = CgmAppController(
    preferences: preferences,
    driver: _NoSensorDriver(),
    healthStateStore: store,
  );
  await controller.initialize();
  final harness = _ArchiveExportHarness(
    store: store,
    controller: controller,
    directory: Directory.systemTemp.createTempSync(
      'openglucose-export-ui-test-',
    ),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method != 'getTemporaryDirectory') {
      throw StateError('Unexpected directory request.');
    }
    harness.temporaryDirectoryCalls++;
    return harness.directory.path;
  });
  addTearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await harness.directory.delete(recursive: true);
  });
  await tester.pumpWidget(
    OpenGlucoseApp(
      controller: controller,
      healthExport: HealthExportController(
        preferences: preferences,
        healthStateStore: store,
        writesAllowed: false,
      )..initialize(),
      preferences: preferences,
      archivedSensorShareAction: harness.share,
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openArchiveDetail(
  WidgetTester tester,
  ArchivedSensorSession session,
) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sensor archive'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(session.serial));
  await tester.pumpAndSettle();
}

Future<void> _scrollToArchiveExport(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('exportArchivedSensorData')),
    300,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}

Future<void> _confirmAndWaitForArchiveShare(
  WidgetTester tester,
  _ArchiveExportHarness harness,
) async {
  await tester.tap(find.byKey(const ValueKey('confirmArchivedSensorExport')));
  await tester.pumpAndSettle();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  // Pump both schedulers: real isolate/file I/O and the widget fake clock.
  // Waiting only in runAsync prevents the dialog continuation from draining.
  while (!harness.shared.isCompleted && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    expect(
      find.text('The archived sensor data could not be exported.'),
      findsNothing,
    );
  }
  expect(
    harness.shared.isCompleted,
    isTrue,
    reason: 'The real share callback must complete.',
  );
  await tester.pumpAndSettle();
}

class _ArchiveExportHarness {
  _ArchiveExportHarness({
    required this.store,
    required this.controller,
    required this.directory,
  });
  final _MemoryHealthStateStore store;
  final CgmAppController controller;
  final Directory directory;
  final shared = Completer<void>();
  int temporaryDirectoryCalls = 0;
  int shareCalls = 0;
  List<int>? bytes;

  Future<void> share(ShareParams params) async {
    shareCalls++;
    expect(params.files, hasLength(1));
    expect(params.text, isNull);
    // Read inside the callback: normal export cleanup removes this file after
    // the platform share future completes.
    bytes = await params.files!.single.readAsBytes();
    shared.complete();
  }
}

class _NoSensorDriver implements CgmDriver {
  int scanCalls = 0;
  @override
  String get driverId => 'aidex-test';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    scanCalls++;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    throw StateError('No connection is expected in this fixture.');
  }
}

class _MemoryHealthStateStore implements HealthStateStore {
  _MemoryHealthStateStore(Map<String, String> values)
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
