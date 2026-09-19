import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/sensor_connection_screen.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cbio_snapshot_fixture.dart';

const DiscoveredSensor _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'AA:BB:CC:DD:EE:FF',
  displayName: 'Cbio / SiSensing candidate',
  storageKey: 'AA:BB:CC:DD:EE:FF',
  rssi: -60,
  capabilities: CbioGlucoseSession.capabilities,
);

List<CgmReading> _readings(int count) => <CgmReading>[
  for (var index = 0; index < count; index++)
    CgmReading(
      valueMgdl: (55 + index) / 10,
      source: CgmRecordSource.raw,
      sensorMinute: 9970 + index,
      recordedAt: DateTime.now().subtract(Duration(minutes: count - index)),
      rawValue: 55 + index,
      isDisplayProvisional: true,
    ),
];

CgmSessionSnapshot _snapshot({
  required CgmSyncStage stage,
  required String statusText,
  required List<CgmReading> history,
  required CgmHistorySyncState historySync,
}) => CgmSessionSnapshot(
  stage: stage,
  statusText: statusText,
  sensor: _sensor,
  capabilities: _sensor.capabilities,
  sessionInfo: const CgmSessionInfo(warmupMinutes: 0),
  latestReading: history.isEmpty ? null : history.last,
  history: history,
  historySync: historySync,
  metadata: <String, String>{
    ...syntheticCbioFreshMetadata(_sensor, history),
    cgmAutomaticReconnectAllowedMetadataKey: 'false',
    cbioPhaseMetadataKey: CbioSessionPhase.live,
  },
);

Future<(CgmAppController, SharedPreferences)> _controllerFor(
  CgmSessionSnapshot Function() build, {
  String language = 'en',
  DiscoveredSensor sensor = _sensor,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
    'openHealth.appLanguage': language,
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: _SurfaceDriver(build, driverId: sensor.driverId),
  );
  await controller.initialize();
  await controller.connect(sensor);
  return (controller, preferences);
}

Future<void> _pumpApp(
  WidgetTester tester,
  CgmAppController controller,
  SharedPreferences preferences,
) async {
  await tester.pumpWidget(
    OpenGlucoseApp(
      controller: controller,
      healthExport: HealthExportController(
        preferences: preferences,
        writesAllowed: false,
      )..initialize(),
      preferences: preferences,
      messageController: MessageController(
        preferences: preferences,
        messages: defaultMessageCatalog,
      ),
    ),
  );
  await tester.pump();
  // The messaging bridge runs post-frame and its host animates in. A second
  // zero-duration pump can assert before the eligible tip is rendered.
  await tester.pumpAndSettle();
}

void main() {
  test(
    'counter support reference never uses missing unknown or stale reasons',
    () {
      final error = _snapshot(
        stage: CgmSyncStage.error,
        statusText: 'ignored',
        history: [],
        historySync: const CgmHistorySyncState(),
      ).copyWith(lastError: CbioSessionFailure.counterRestart);
      for (final reason in [null, 'secret=59', 'before-checkpoint\nprivate']) {
        final snapshot = error.copyWith(
          metadata: {'cgm.cbio.resume.counterFailureReason': ?reason},
        );
        expect(cbioSupportReferenceForSnapshot(snapshot), 'GS1-H03');
      }
      final stale = error.copyWith(
        stage: CgmSyncStage.disconnected,
        metadata: {'cgm.cbio.resume.counterFailureReason': 'before-checkpoint'},
      );
      expect(cbioSupportReferenceForSnapshot(stale), 'GS1-H03');
      expect(
        cbioSupportReferenceForSnapshot(
          stale.copyWith(stage: CgmSyncStage.ready),
        ),
        isNull,
      );
    },
  );
  const failures = [
    (CbioSessionFailure.connect, 'Could not reach', '无法连接', 'GS1-L01'),
    (CbioSessionFailure.topology, 'does not present', '不支持', 'GS1-L02'),
    (CbioSessionFailure.authMaterial, 'could not read', '无法读取', 'GS1-L03'),
    (CbioSessionFailure.authTimeout, 'did not answer', '未回应', 'GS1-L04'),
    (CbioSessionFailure.authRejected, 'refused', '拒绝', 'GS1-L05'),
    (CbioSessionFailure.write, 'refused a command', '拒绝了手机的指令', 'GS1-L06'),
    (CbioSessionFailure.disconnected, 'disconnected', '已断开连接', 'GS1-L07'),
    (
      CbioSessionFailure.invalidResume,
      'resume saved history',
      '继续读取已保存的历史记录',
      'GS1-H01',
    ),
    (
      CbioSessionFailure.missingWitness,
      'confirm this sensor',
      '确认此传感器',
      'GS1-H02',
    ),
    (
      CbioSessionFailure.counterRestart,
      'record sequence could not be confirmed',
      '无法确认传感器记录序列',
      'GS1-H03',
    ),
    (
      'cbio.history.restore-invalid',
      'Saved sensor history could not be read',
      '无法读取已保存的传感器历史记录',
      'GS1-H04',
    ),
    ('cbio.history.foreign', 'different sensor', '不同的传感器', 'GS1-H05'),
    ('cbio.history.unconfirmed', 'not confirmed', '尚未确认', 'GS1-H06'),
    ('cbio.history.conflicting', 'conflict', '冲突', 'GS1-H07'),
    ('cbio.history.invalid', 'could not be verified', '无法验证', 'GS1-H08'),
    (
      automaticReconnectExhaustedCode,
      'Automatic reconnect stopped',
      '自动重连已停止',
      'GS1-L08',
    ),
    (
      sensorSyncStalledMessage,
      'did not receive a readable sensor result during sync',
      '同步期间未收到可读取的传感器结果',
      'GS1-H09',
    ),
  ];
  for (final language in ['en', 'zh-Hans']) {
    for (final width in [320.0, 412.0]) {
      testWidgets(
        'support reference stays separated at $width pixels in $language',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final (controller, preferences) = await _controllerFor(
            () => _snapshot(
              stage: CgmSyncStage.error,
              statusText: 'Synthetic failure',
              history: _readings(3),
              historySync: const CgmHistorySyncState(),
            ).copyWith(lastError: 'cbio.history.unconfirmed'),
            language: language,
          );
          await _pumpApp(tester, controller, preferences);
          await tester.tap(find.byIcon(Icons.tune_rounded));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(language == 'en' ? 'Current sensor' : '当前传感器'),
          );
          await tester.pumpAndSettle();
          final label = tester.getRect(
            find.text(language == 'en' ? 'Support reference' : '支持参考编号'),
          );
          final value = tester.getRect(find.text('GS1-H06'));
          expect(value.left - label.right, greaterThanOrEqualTo(12));
          expect(value.right, lessThanOrEqualTo(width - 20));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          await tester.pump();
        },
      );
    }
    for (final failure in failures) {
      testWidgets('CBIO ${failure.$4} error overrides progress in $language', (
        tester,
      ) async {
        final (controller, preferences) = await _controllerFor(
          () {
            final base = _snapshot(
              stage: CgmSyncStage.error,
              statusText: '<private-status> serial=secret',
              history: _readings(3),
              historySync: const CgmHistorySyncState(
                inProgress: true,
                storedCount: 3,
                totalAvailable: 5,
              ),
            );
            return base.copyWith(
              lastError: failure.$1,
              metadata: {
                ...base.metadata,
                ...BleFailure(
                  kind: BleFailureKind.unexpected,
                  operation: BleOperation.connect,
                  diagnosticCode: 'secret-radio-detail',
                ).toMetadata(),
                cbioPhaseMetadataKey: CbioSessionPhase.history,
                cgmSessionSyncStalledMetadataKey: 'true',
                'private': 'secret-records',
              },
            );
          },
          language: language,
        );
        await _pumpApp(tester, controller, preferences);
        expect(controller.snapshot!.historySync.inProgress, isTrue);
        expect(controller.snapshot!.lastError, failure.$1);
        final expected = language == 'en' ? failure.$2 : failure.$3;
        expect(find.textContaining(expected), findsOneWidget);
        expect(find.text(failure.$4), findsNothing);
        expect(find.textContaining('secret'), findsNothing);
        expect(cbioProgressTextForSnapshot(controller.snapshot!), isNull);
        await tester.tap(find.byIcon(Icons.tune_rounded));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(language == 'en' ? 'Current sensor' : '当前传感器'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(expected), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('cbioSupportReference')),
          180,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text(failure.$4), findsOneWidget);
        expect(
          find.text(language == 'en' ? 'Support reference' : '支持参考编号'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('historySyncProgress')), findsNothing);
        expect(find.textContaining('secret'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.pump();
      });
    }
    testWidgets('unknown CBIO failure stays generic and private in $language', (
      tester,
    ) async {
      final (controller, preferences) = await _controllerFor(
        () =>
            _snapshot(
              stage: CgmSyncStage.error,
              statusText: 'private-status',
              history: _readings(3),
              historySync: const CgmHistorySyncState(inProgress: true),
            ).copyWith(
              lastError:
                  'cbio.history.unconfirmed\n<script>secret serial raw=59</script>',
            ),
        language: language,
      );
      await _pumpApp(tester, controller, preferences);
      expect(controller.snapshot!.historySync.inProgress, isTrue);
      final expected = language == 'en'
          ? 'could not continue this sensor session'
          : '无法继续此传感器会话';
      expect(find.textContaining(expected), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(language == 'en' ? 'Current sensor' : '当前传感器'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(expected), findsOneWidget);
      expect(find.byKey(const ValueKey('cbioSupportReference')), findsNothing);
      expect(find.byKey(const ValueKey('historySyncProgress')), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    });
  }
  test('CBIO history code does not change non-CBIO error copy', () {
    const sensor = DiscoveredSensor(
      driverId: 'aidex',
      deviceId: 'synthetic',
      displayName: 'AiDEX',
      storageKey: 'synthetic',
      rssi: -60,
      capabilities: CgmCapabilities(),
    );
    final snapshot = CgmSessionSnapshot(
      sensor: sensor,
      capabilities: sensor.capabilities,
      stage: CgmSyncStage.error,
      statusText: 'private',
      lastError: 'cbio.history.unconfirmed',
    );
    for (final language in AppLanguage.values) {
      expect(
        primaryErrorTextForSnapshot(snapshot, language: language),
        safeOperationFailureText('Connection', language: language),
      );
      expect(cbioProgressTextForSnapshot(snapshot), isNull);
    }
  });
  test('direct CBIO presentation remains raw-only without quality flags', () {
    const row = CgmReading(
      valueMgdl: 5.9,
      source: CgmRecordSource.vendor,
      rawValue: 59,
      sensorMinute: 120,
    );
    final value = _snapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Synthetic',
      history: [row],
      historySync: const CgmHistorySyncState(),
    );
    expect(cbioProvisionalValueText(row), '59');
    expect(
      provisionalReadingNoticeForSnapshot(value),
      cbioProvisionalUnitNotice,
    );
    expect(
      historyProvisionalNoticeForSnapshot(value),
      cbioProvisionalUnitNotice,
    );
    // The host rejects malformed quality; this separate direct-presentation
    // check prevents safety from depending only on that rejection. CSV/XLSX
    // missing-flags containment is covered in sensor_archive_export_test.dart.
  });

  test('CBIO disconnected history does not promise a reconnect', () {
    final snapshot = _snapshot(
      stage: CgmSyncStage.disconnected,
      statusText: 'Disconnected',
      history: _readings(3),
      historySync: const CgmHistorySyncState(),
    );
    expect(stageLabelForSnapshot(snapshot), 'Disconnected');
  });
  testWidgets('CBIO stale data stays visibly stale on the primary screen', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live',
        history: [
          CgmReading(
            valueMgdl: 5.9,
            rawValue: 59,
            sensorMinute: 1,
            source: CgmRecordSource.raw,
            isDisplayProvisional: true,
            recordedAt: DateTime.now().subtract(const Duration(hours: 1)),
          ),
        ],
        historySync: const CgmHistorySyncState(storedCount: 1),
      ),
    );
    await _pumpApp(tester, controller, preferences);
    expect(find.text('No recent sensor data'), findsOneWidget);
    expect(find.text('59'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  for (final language in ['en', 'zh-Hans']) {
    testWidgets('CBIO primary UI is simple and honest in $language', (
      tester,
    ) async {
      final (controller, preferences) = await _controllerFor(
        () => _snapshot(
          stage: CgmSyncStage.ready,
          statusText: 'Live',
          history: _readings(3),
          historySync: CgmHistorySyncState(
            storedCount: 1,
            lastSyncAt: DateTime.now(),
          ),
        ),
        language: language,
      );
      await _pumpApp(tester, controller, preferences);
      expect(
        find.text(language == 'en' ? 'Raw sensor value' : '传感器原始值'),
        findsOneWidget,
      );
      expect(
        find.text(
          language == 'en' ? 'Not a verified glucose reading.' : '并非经过验证的血糖读数。',
        ),
        findsOneWidget,
      );
      expect(find.text(language == 'en' ? 'Connected' : '已连接'), findsOneWidget);
      expect(find.byKey(const ValueKey('cbioStoredRange')), findsNothing);
      expect(find.byKey(const ValueKey('cbioClockState')), findsNothing);
      expect(find.byKey(const ValueKey('historyQualityNotice')), findsNothing);
      expect(find.byKey(const ValueKey('historySyncComplete')), findsNothing);
      expect(find.byKey(const ValueKey('sensorExpiryIndicator')), findsNothing);
      expect(find.textContaining('index'), findsNothing);
      expect(find.textContaining('Tap a point on the chart'), findsNothing);
      expect(
        find.byKey(const ValueKey('messageCard-tip.tapReading')),
        findsNothing,
      );
      expect(find.byType(CgmDashboardChart), findsNothing);
      expect(
        preferences.getStringList('openHealth.messaging.dismissed'),
        isNull,
      );
      expect(find.textContaining('mg/dL'), findsNothing);
      expect(find.textContaining('mmol/L'), findsNothing);
      expect(controller.snapshot!.history, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    });
  }

  for (final provisional in [false, true]) {
    testWidgets(
      'AiDEX chart retains its undismissed chart tip provisional=$provisional',
      (tester) async {
        const sensor = DiscoveredSensor(
          driverId: 'aidex',
          deviceId: 'synthetic-aidex-tip',
          displayName: 'Synthetic AiDEX',
          storageKey: 'synthetic-aidex-tip',
          rssi: -60,
          capabilities: CgmCapabilities(supportsHistory: true),
        );
        final history = [
          CgmReading(
            valueMgdl: 110,
            source: provisional
                ? CgmRecordSource.vendor
                : CgmRecordSource.standard,
            rawValue: 110,
            isDisplayProvisional: provisional,
            sensorMinute: 120,
            recordedAt: DateTime.now(),
          ),
        ];
        final (controller, preferences) = await _controllerFor(
          () => CgmSessionSnapshot(
            sensor: sensor,
            capabilities: sensor.capabilities,
            stage: CgmSyncStage.ready,
            statusText: 'Connected',
            latestReading: history.last,
            history: history,
          ),
          sensor: sensor,
        );
        await _pumpApp(tester, controller, preferences);
        expect(
          find.byKey(const ValueKey('messageCard-tip.tapReading')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byType(CgmDashboardChart),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(CgmDashboardChart), findsOneWidget);
        expect(
          preferences.getStringList('openHealth.messaging.dismissed'),
          isNull,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets('CBIO missing flags cannot enable glucose or wellness surfaces', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live',
        history: [
          CgmReading(
            valueMgdl: 5.9,
            source: CgmRecordSource.vendor,
            sensorMinute: 120,
            rawValue: 59,
            recordedAt: DateTime.now(),
          ),
        ],
        historySync: const CgmHistorySyncState(storedCount: 1),
      ),
    );
    await _pumpApp(tester, controller, preferences);
    expect(controller.allHistoricalReadings, isEmpty);
    expect(controller.snapshot!.stage, CgmSyncStage.error);
    expect(controller.snapshot!.history, isEmpty);
    expect(controller.snapshot!.latestReading, isNull);
    // This key is the static settings hint, not a chart or admitted raw rows.
    expect(find.byKey(const ValueKey('rawSensorHistory')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('messageCard-tip.tapReading')),
      findsNothing,
    );
    expect(find.text('59'), findsNothing);
    expect(find.textContaining('mg/dL'), findsNothing);
    expect(find.textContaining('mmol/L'), findsNothing);
    expect(
      find.byKey(const ValueKey('dashboardPatternsSection')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('provisionalReadingNotice')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.disconnect(clearSelection: true));
    for (final archive in controller.archivedSensors) {
      expect(archive.readingCount, 0);
      expect(controller.readingsForArchivedSensor(archive), isEmpty);
    }
    expect(controller.allHistoricalReadings, isEmpty);
    controller.dispose();
    await tester.pump();
  });

  test('the CBio unit marker is the provisional-unit notice', () {
    final snapshot = _snapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Live. Reading every minute.',
      history: _readings(2),
      historySync: const CgmHistorySyncState(
        storedCount: 2,
        totalAvailable: 2,
        latestStoredOffset: 9971,
      ),
    );
    expect(
      provisionalReadingNoticeForSnapshot(snapshot),
      cbioProvisionalUnitNotice,
    );
    expect(
      historyProvisionalNoticeForSnapshot(snapshot),
      cbioProvisionalUnitNotice,
    );
    expect(stageLabelForSnapshot(snapshot), 'Connected');
  });

  test('a closed CBio failure reaches the user as a sentence', () {
    for (final code in <String>[
      CbioSessionFailure.connect,
      CbioSessionFailure.topology,
      CbioSessionFailure.authMaterial,
      CbioSessionFailure.authTimeout,
      CbioSessionFailure.authRejected,
      CbioSessionFailure.write,
      CbioSessionFailure.disconnected,
    ]) {
      final snapshot = _snapshot(
        stage: CgmSyncStage.error,
        statusText: 'Connection failed',
        history: const <CgmReading>[],
        historySync: const CgmHistorySyncState(),
      ).copyWith(lastError: code);
      final message = primaryErrorTextForSnapshot(snapshot);
      expect(message, isNotNull, reason: '$code must reach the failure card');
      expect(
        message,
        isNot(contains('cbio.')),
        reason: '$code is a support code, not a sentence',
      );
    }
  });

  test('the stored range names a hole instead of printing an envelope', () {
    List<CgmReading> readingsAt(List<int> positions) => <CgmReading>[
      for (final position in positions)
        CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.raw,
          sensorMinute: position,
          rawValue: 55,
          isDisplayProvisional: true,
        ),
    ];

    expect(
      cbioStoredRangeText(readingsAt(<int>[1, 2, 3])),
      '3 readings stored · sensor minutes 1–3',
    );
    expect(
      cbioStoredRangeText(readingsAt(<int>[1, 2, 3, 6, 7])),
      '5 readings stored · sensor minutes 1–7 · 2 positions not received',
      reason: '1-7 is an envelope, not what the app stored',
    );
    expect(
      cbioStoredRangeText(readingsAt(<int>[4])),
      '1 readings stored · sensor minutes 4–4',
    );
  });

  testWidgets('sensor details retain holes without cluttering the dashboard', (
    tester,
  ) async {
    final readings = <CgmReading>[
      for (final position in <int>[10, 11, 12, 15, 16])
        CgmReading(
          valueMgdl: 100 + position.toDouble(),
          source: CgmRecordSource.raw,
          sensorMinute: position,
          recordedAt: null,
          rawValue: 55,
          isDisplayProvisional: true,
        ),
    ];
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: readings,
        historySync: const CgmHistorySyncState(
          storedCount: 5,
          totalAvailable: 16,
          latestStoredOffset: 16,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    expect(find.byKey(const ValueKey('cbioStoredRange')), findsNothing);
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('cbioStoredRange')))
          .data,
      '5 readings stored · sensor minutes 10–16 · 2 positions not received',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  test('history progress wording reports the fetched count', () {
    expect(
      historySyncProgressText(
        const CgmHistorySyncState(
          inProgress: true,
          storedCount: 1200,
          totalAvailable: 1520,
        ),
      ),
      'Fetching sensor history: 1200 of 1520 records',
    );
  });

  test(
    'the progress card copy comes from the closed phase, never the driver',
    () {
      // A syncing snapshot with no closed phase must fall through to the generic
      // stage label. The driver's status text is an internal, unbounded string.
      expect(
        cbioProgressTextForSnapshot(
          CgmSessionSnapshot(
            stage: CgmSyncStage.syncing,
            statusText: 'Listening for notifications',
            sensor: _sensor,
            capabilities: _sensor.capabilities,
          ),
        ),
        isNull,
      );
      expect(
        cbioProgressTextForSnapshot(
          CgmSessionSnapshot(
            stage: CgmSyncStage.syncing,
            statusText: 'anything at all',
            sensor: _sensor,
            capabilities: _sensor.capabilities,
            metadata: const <String, String>{
              cbioPhaseMetadataKey: CbioSessionPhase.authenticating,
            },
          ),
        ),
        'Checking the sensor link',
      );
      expect(
        cbioProgressTextForSnapshot(
          _snapshot(
            stage: CgmSyncStage.syncing,
            statusText: 'whatever',
            history: const <CgmReading>[],
            historySync: const CgmHistorySyncState(),
          ),
        ),
        isNot(contains('whatever')),
      );
    },
  );

  testWidgets(
    'a syncing cbio session shows the bounded-sync stage label, not the driver text',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ScanningCbioDriver(
          CgmSessionSnapshot(
            stage: CgmSyncStage.syncing,
            statusText: 'Listening for notifications',
            sensor: _sensor,
            capabilities: _sensor.capabilities,
          ),
        ),
        healthStateStore: PreferencesHealthStateStore(preferences),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SensorConnectionScreen(
                controller: controller,
                inline: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('connectButton-1')));
      for (var attempt = 0; attempt < 12; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      // The bounded-failure contract asserts this stage label while a session
      // has connected but not yet decoded anything.
      expect(find.text('Syncing sensor history'), findsOneWidget);
      expect(find.text('Listening for notifications'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('the dashboard shows the live value with its provisional unit', (
    tester,
  ) async {
    final readings = _readings(3);
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: readings,
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
          lastSyncAt: null,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    expect(
      find.byKey(const ValueKey<String>('provisionalReadingNotice')),
      findsOneWidget,
    );
    expect(
      find.text('Not a verified glucose reading.'),
      findsOneWidget,
    );
    expect(find.text('3 readings'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'sensor details retain fetched-history progress while ingesting',
    (
      tester,
    ) async {
      final (controller, preferences) = await _controllerFor(
        () => _snapshot(
          stage: CgmSyncStage.syncing,
          statusText: 'Fetching sensor history',
          history: _readings(1200),
          historySync: const CgmHistorySyncState(
            inProgress: true,
            storedCount: 1200,
            totalAvailable: 1520,
            latestStoredOffset: 11169,
          ),
        ),
      );
      await _pumpApp(tester, controller, preferences);
      expect(find.byKey(const ValueKey('historySyncProgress')), findsNothing);
      expect(find.text('Fetching history'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();

      expect(
        find.text('Fetching sensor history: 1200 of 1520 records'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('historySyncProgress')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('the cbio value renders the raw integer without a unit', (
    tester,
  ) async {
    // Preserve the unscaled raw field. It is not a verified glucose value.
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: _readings(3),
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    final hero = find.byKey(const ValueKey<String>('glucoseHeroCard'));
    expect(hero, findsOneWidget);
    expect(
      find.descendant(of: hero, matching: find.text('57')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hero, matching: find.textContaining('mg/dL')),
      findsNothing,
    );
    expect(
      find.descendant(of: hero, matching: find.textContaining('mmol')),
      findsNothing,
    );
    controller.updateDisplayPreferences(
      const DisplayPreferences(unit: GlucoseUnit.mmolL),
    );
    await tester.pump();
    expect(
      find.descendant(of: hero, matching: find.text('57')),
      findsOneWidget,
    );
    expect(find.textContaining('mmol/L'), findsNothing);
    expect(find.byKey(const ValueKey('rawSensorHistory')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('the cbio details report stored count and sensor range', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: _readings(3),
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);
    expect(find.byKey(const ValueKey('cbioStoredRange')), findsNothing);
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('cbioStoredRange')),
      findsOneWidget,
    );
    expect(
      find.text('3 readings stored · sensor minutes 9970–9972'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });
}

final class _SurfaceDriver implements CgmDriver {
  _SurfaceDriver(this.build, {required this.driverId});

  final CgmSessionSnapshot Function() build;

  @override
  final String driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _CbioSurfaceSession(sensor: sensor, build: build);
}

final class _CbioSurfaceSession implements CgmSession {
  _CbioSurfaceSession({required this.sensor, required this.build})
    : currentSnapshot = build();

  final CgmSessionSnapshot Function() build;

  @override
  final DiscoveredSensor sensor;

  @override
  final CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      const Stream<CgmSessionSnapshot>.empty();

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}

/// A driver that advertises one CBio sensor, so the connection screen can be
/// driven through its real connect button and reach the progress card.
final class _ScanningCbioDriver implements CgmDriver {
  _ScanningCbioDriver(this.snapshot);

  final CgmSessionSnapshot snapshot;

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    yield _sensor;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _FrozenCbioSession(sensor: sensor, snapshot: snapshot);
}

/// A session frozen on one snapshot; it never emits anything else.
final class _FrozenCbioSession implements CgmSession {
  _FrozenCbioSession({required this.sensor, required this.snapshot})
    : currentSnapshot = snapshot;

  final CgmSessionSnapshot snapshot;

  @override
  final DiscoveredSensor sensor;

  @override
  CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots => const Stream.empty();

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}
