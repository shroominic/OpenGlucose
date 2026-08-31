import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/ios_export_share.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_lifecycle_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
      await tester.tap(find.text('Find my sensor'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Connect'));
      await tester.pump(const Duration(milliseconds: 500));

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

  testWidgets(
    'large iOS archive invokes the native share bridge once while guarded',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final temporaryDirectory = Directory.systemTemp.createTempSync(
        'openglucose-large-export-widget-test-',
      );
      addTearDown(() {
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      const shareChannel = MethodChannel(IosExportShare.channelName);
      final shareCompletion = Completer<String>();
      MethodCall? shareCall;
      var shareInvocationCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            expect(call.method, 'getTemporaryDirectory');
            return temporaryDirectory.path;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) {
            shareInvocationCount += 1;
            shareCall = call;
            return shareCompletion.future;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final fixture = _archivedHistoryFixture(readingCount: 5000);
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
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Export data'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('confirmArchivedSensorExport')),
      );
      await tester.pump();

      expect(find.text('Preparing export…'), findsOneWidget);
      await _pumpUntil(
        tester,
        () => shareInvocationCount == 1,
        reason: 'the prepared export should reach the native iOS bridge',
      );

      expect(shareInvocationCount, 1);
      expect(shareCall?.method, 'shareFile');
      expect(find.text('Sharing export…'), findsOneWidget);
      final exportButton = find.byKey(
        const ValueKey<String>('exportArchivedSensorData'),
      );
      expect(tester.widget<OutlinedButton>(exportButton).onPressed, isNull);
      await tester.tap(exportButton);
      await tester.pump();
      expect(shareInvocationCount, 1);

      final shareArguments = Map<String, Object?>.from(
        shareCall?.arguments as Map<Object?, Object?>,
      );
      final filePath = shareArguments['filePath']! as String;
      final file = File(filePath);
      expect(file.existsSync(), isTrue);
      final contents = file.readAsStringSync();
      expect(contents.split('\r\n'), hasLength(5002));

      shareCompletion.complete('dismissed');
      await _pumpUntil(
        tester,
        () => find.text('Export data').evaluate().isNotEmpty,
        reason: 'the export guard should clear after the share sheet closes',
      );

      expect(find.text('Export data'), findsOneWidget);
      expect(file.existsSync(), isFalse);
      expect(shareInvocationCount, 1);

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'failed iOS share clears guarded state and a retry invokes native again',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final temporaryDirectory = Directory.systemTemp.createTempSync(
        'openglucose-retry-export-widget-test-',
      );
      addTearDown(() {
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      });
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      const shareChannel = MethodChannel(IosExportShare.channelName);
      final sharedFilePaths = <String>[];
      var shareInvocationCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            expect(call.method, 'getTemporaryDirectory');
            return temporaryDirectory.path;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            shareInvocationCount += 1;
            final arguments = Map<String, Object?>.from(
              call.arguments as Map<Object?, Object?>,
            );
            sharedFilePaths.add(arguments['filePath']! as String);
            if (shareInvocationCount == 1) {
              throw PlatformException(
                code: 'export_share_failed',
                message: 'Private path: ${sharedFilePaths.single}',
              );
            }
            return 'dismissed';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

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
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sensor archive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fixture.session.serial));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      await _confirmCsvArchiveExport(tester);
      await _pumpUntil(
        tester,
        () =>
            shareInvocationCount == 1 &&
            find.text('Export data').evaluate().isNotEmpty,
        reason: 'a native failure should clear the export guard',
      );

      const supportCode =
          'OGEXP1 phase=P03 op=export kind=platform '
          'code=export_share_failed';
      expect(find.textContaining(supportCode), findsOneWidget);
      expect(sharedFilePaths, hasLength(1));
      expect(File(sharedFilePaths.first).existsSync(), isFalse);

      await _confirmCsvArchiveExport(tester);
      await _pumpUntil(
        tester,
        () => shareInvocationCount == 2,
        reason: 'a retry should reach the native iOS bridge again',
      );
      await _pumpUntil(
        tester,
        () => find.text('Export data').evaluate().isNotEmpty,
        reason: 'the successful retry should clear the export guard',
      );

      expect(shareInvocationCount, 2);
      expect(sharedFilePaths, hasLength(2));
      expect(File(sharedFilePaths.last).existsSync(), isFalse);

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'sample data is offered after first-run onboarding with no history',
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
      expect(find.text('Explore sample data'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('sample data is hidden when archived glucose is retained', (
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
    expect(find.text('Explore sample data'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('historicalOverviewCard')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _confirmCsvArchiveExport(WidgetTester tester) async {
  await tester.tap(find.text('Export data'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const ValueKey<String>('confirmArchivedSensorExport')),
  );
  await tester.pump();
}

({ArchivedSensorSession session, Map<String, String> values})
_archivedHistoryFixture({bool includePostWarmup = true, int? readingCount}) {
  final startedAt = DateTime(2026, 7, 1, 8);
  final endedAt = startedAt.add(const Duration(days: 15));
  const historyKey = 'openHealth.history.archive.feedback-session';
  final readings = readingCount == null
      ? <CgmReading>[
          CgmReading(
            valueMgdl: 171,
            source: CgmRecordSource.vendor,
            sensorMinute: 59,
            recordedAt: startedAt.add(const Duration(minutes: 59)),
          ),
          if (includePostWarmup)
            CgmReading(
              valueMgdl: 112,
              source: CgmRecordSource.vendor,
              sensorMinute: 60,
              recordedAt: startedAt.add(const Duration(hours: 1)),
            ),
        ]
      : List<CgmReading>.generate(
          readingCount,
          (index) => CgmReading(
            valueMgdl: 80 + (index % 60).toDouble(),
            source: CgmRecordSource.vendor,
            sensorMinute: index % 60,
            recordedAt: startedAt.add(Duration(seconds: index)),
          ),
          growable: false,
        );
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

class _NoSensorDriver implements CgmDriver {
  @override
  String get driverId => 'aidex-test';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

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
