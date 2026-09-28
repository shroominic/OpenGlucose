import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_context_builder.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cbio_snapshot_fixture.dart';

void main() {
  // Closed and unknown protocol failures use the existing shared safe error,
  // not vendor support references or unbounded status/metadata text.
  const failures = [
    'cbio.connect.failed',
    'cbio.topology.failed',
    'cbio.auth.material',
    'cbio.auth.timeout',
    'cbio.auth.rejected',
    'cbio.write.failed',
    'cbio.disconnected',
    'cbio.resume.invalid',
    'cbio.resume.witness-missing',
    'cbio.counter.restart',
    'cbio.history.restore-invalid',
    'cbio.history.foreign',
    'cbio.history.unconfirmed',
    'cbio.history.conflicting',
    'cbio.history.invalid',
    'cbio.history.unconfirmed\n<script>secret serial raw=59</script>',
  ];
  for (final language in AppLanguage.values) {
    for (final failure in failures) {
      test('shared safe GS1 failure $failure in $language', () {
        final snapshot = syntheticSurfaceSnapshot(
          stage: CgmSyncStage.error,
          lastError: failure,
          historySync: const CgmHistorySyncState(inProgress: true),
          metadata: const {'private': 'secret-records'},
        );
        expect(
          primaryErrorTextForSnapshot(snapshot, language: language),
          language == AppLanguage.english
              ? 'The sensor could not be connected. Check Bluetooth, keep the phone close, and try again.'
              : '无法连接传感器。请检查蓝牙，将手机靠近传感器后重试。',
        );
        expect(
          stageLabelForSnapshot(snapshot, language: language),
          language == AppLanguage.english ? 'Error' : '出错',
        );
      });
    }
  }

  for (final language in ['en', 'zh-Hans']) {
    testWidgets('GS1 empty session has shared unavailable lifecycle in $language', (
      tester,
    ) async {
      final snapshot = syntheticSurfaceSnapshot();
      // Actual-like unknown state: no sessionStart/elapsed, expiry, activation,
      // or warmup evidence. The UI may not invent a countdown or 15-day age.
      expect(snapshot.sessionInfo.sessionStart, isNull);
      expect(snapshot.sessionInfo.sessionStopped, isFalse);
      expect(snapshot.health.expired, isFalse);
      expect(computeWarmupStatus(snapshot), isNull);
      expect(
        computeSensorLifecycle(snapshot).phase,
        SensorLifecyclePhase.unknown,
      );
      final mounted = await _mount(tester, snapshot, language: language);
      final hero = find.byKey(const ValueKey('glucoseHeroCard'));
      expect(
        find.descendant(of: hero, matching: find.text('--')),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('messageCard-tip.tapReading')),
        findsNothing,
      );
      _expectNoPrivatePresentation();
      await _openSensorDetails(tester, language);
      expect(find.byKey(const ValueKey('sensorLifecycleCard')), findsOneWidget);
      if (language == 'en') {
        expect(
          find.text(
            'Life remaining is unavailable while the sensor session is being verified.',
          ),
          findsOneWidget,
        );
      }
      expect(find.textContaining('15 days'), findsNothing);
      expect(find.textContaining('days left'), findsNothing);
      expect(find.textContaining('Warmup'), findsNothing);
      expect(find.byKey(const ValueKey('sensorExpiryIndicator')), findsNothing);
      _expectNoPrivatePresentation();
      await _dispose(tester, mounted.$1);
    });

    testWidgets('GS1 error UI never exposes protocol details in $language', (
      tester,
    ) async {
      final mounted = await _mount(
        tester,
        syntheticSurfaceSnapshot(
          stage: CgmSyncStage.error,
          lastError: 'cbio.history.unconfirmed\nprivate-secret-value',
          historySync: const CgmHistorySyncState(inProgress: true),
          metadata: const {'private': 'secret-records'},
        ),
        language: language,
      );
      expect(find.text(language == 'en' ? 'Error' : '出错'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.textContaining('synthetic-private-status'), findsNothing);
      _expectNoPrivatePresentation();
      await _openSensorDetails(tester, language);
      expect(find.textContaining('secret'), findsNothing);
      _expectNoPrivatePresentation();
      await _dispose(tester, mounted.$1);
    });

    testWidgets(
      'explicit raw records do not enable glucose surfaces in $language',
      (tester) async {
        final mounted = await _mount(
          tester,
          syntheticSurfaceSnapshot(
            readings: [
              CgmReading(
                valueMgdl: 59,
                rawValue: 59,
                source: CgmRecordSource.raw,
                sensorMinute: 120,
                recordedAt: DateTime.now(),
              ),
            ],
          ),
          language: language,
        );
        final hero = find.byKey(const ValueKey('glucoseHeroCard'));
        expect(
          find.descendant(of: hero, matching: find.text('59')),
          findsNothing,
        );
        expect(mounted.$1.allHistoricalReadings, isEmpty);
        expect(buildMessageContext(mounted.$1).hasReadings, isFalse);
        expect(
          find.byKey(const ValueKey('messageCard-tip.tapReading')),
          findsNothing,
        );
        _expectNoPrivatePresentation();
        await _dispose(tester, mounted.$1);
      },
    );
  }

  for (final driver in ['aidex', 'cbio']) {
    for (final provisional in [false, true]) {
      testWidgets(
        '$driver keeps existing chart and dismissal policy provisional=$provisional',
        (tester) async {
          final mounted = await _mount(
            tester,
            syntheticSurfaceSnapshot(
              driverId: driver,
              readings: [
                CgmReading(
                  valueMgdl: 110,
                  source: provisional
                      ? CgmRecordSource.vendor
                      : CgmRecordSource.standard,
                  isDisplayProvisional: provisional,
                  sensorMinute: 120,
                  recordedAt: DateTime.now(),
                ),
              ],
            ),
          );
          expect(
            find.byKey(const ValueKey('messageCard-tip.tapReading')),
            findsOneWidget,
          );
          expect(find.byType(CgmDashboardChart), findsOneWidget);
          expect(
            mounted.$2.getStringList('openHealth.messaging.dismissed'),
            isNull,
          );
          if (provisional) expect(mounted.$1.allHistoricalReadings, isEmpty);
          _expectNoPrivatePresentation();
          await _dispose(tester, mounted.$1);
        },
      );
    }
  }

  test(
    'normalized history progress retains generic fetched-count semantics',
    () {
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
    },
  );
}

void _expectNoPrivatePresentation() {
  for (final key in [
    'cbioStoredRange',
    'cbioClockState',
    'cbioSupportReference',
    'rawSensorHistory',
    'archiveRecoveryNotice',
  ]) {
    expect(find.byKey(ValueKey(key)), findsNothing);
  }
  expect(find.textContaining('GS1-H'), findsNothing);
  expect(find.textContaining('Raw sensor value'), findsNothing);
  expect(find.textContaining('传感器原始值'), findsNothing);
}

Future<(CgmAppController, SharedPreferences)> _mount(
  WidgetTester tester,
  CgmSessionSnapshot snapshot, {
  String language = 'en',
}) async {
  SharedPreferences.setMockInitialValues({
    'openHealth.onboarding.completed': true,
    'openHealth.appLanguage': language,
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: SyntheticSurfaceDriver(snapshot),
  );
  await controller.initialize();
  await controller.connect(snapshot.sensor);
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
  await tester.pump(const Duration(seconds: 1));
  // The in-progress fixture intentionally leaves the shared history spinner
  // animating. Wait for the route frame, not for that animation to terminate.
  if (!snapshot.historySync.inProgress) await tester.pumpAndSettle();
  return (controller, preferences);
}

Future<void> _openSensorDetails(WidgetTester tester, String language) async {
  await tester.tap(find.byIcon(Icons.tune_rounded));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text(language == 'en' ? 'Current sensor' : '当前传感器'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _dispose(WidgetTester tester, CgmAppController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await tester.pump();
}
