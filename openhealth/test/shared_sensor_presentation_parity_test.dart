import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/live_activity_payload.dart';
import 'package:openglucose/src/messaging/message_context_builder.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic normalized contract fixtures, NOT evidence of GS1 decoding.
// The transport alone is doubled; controller, dashboard, chart, messaging and
// live-surface policy are the real production consumers.
void main() {
  for (final driver in ['aidex', 'libre2-gen1', 'cbio']) {
    for (final language in ['en', 'zh-Hans']) {
      for (final unit in GlucoseUnit.values) {
        for (final width in [375.0, 390.0]) {
          testWidgets(
            '$driver normalized hero/chart/actions $language ${unit.name} $width',
            (tester) async {
              tester.view.physicalSize = Size(width, 844);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              SharedPreferences.setMockInitialValues({
                'openHealth.onboarding.completed': true,
                'openHealth.appLanguage': language,
                'openHealth.displayPreferences': jsonEncode(
                  DisplayPreferences(unit: unit).toJson(),
                ),
              });
              final preferences = await SharedPreferences.getInstance();
              final snapshot = _snapshot(driver, now: DateTime.now());
              final controller = CgmAppController(
                preferences: preferences,
                driver: _FixtureDriver(snapshot),
              );
              await controller.initialize();
              await controller.connect(snapshot.sensor);
              final healthExport = HealthExportController(
                preferences: preferences,
                writesAllowed: false,
              )..initialize();
              await tester.pumpWidget(
                OpenGlucoseApp(
                  controller: controller,
                  healthExport: healthExport,
                  preferences: preferences,
                ),
              );
              await tester.pump(const Duration(seconds: 1));
              addTearDown(() async {
                await tester.pumpWidget(const SizedBox.shrink());
                controller.dispose();
                healthExport.dispose();
                await tester.pump();
              });

              final hero = find.byKey(const ValueKey('glucoseHeroCard'));
              expect(hero, findsOneWidget);
              expect(
                find.descendant(
                  of: hero,
                  matching: find.text(
                    unit == GlucoseUnit.mgdl ? '108' : '6.0',
                  ),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(of: hero, matching: find.text(unit.label)),
                findsOneWidget,
              );
              expect(find.byType(CgmDashboardChart), findsOneWidget);
              expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
              expect(
                find.byKey(const ValueKey('rawSensorHistory')),
                findsNothing,
              );
              expect(
                find.byKey(const ValueKey('provisionalReadingNotice')),
                findsNothing,
              );
              expect(find.textContaining('GS1-H'), findsNothing);
              expect(find.textContaining('Raw sensor'), findsNothing);
              expect(find.textContaining('原始传感器'), findsNothing);
              expect(find.textContaining('Support reference'), findsNothing);
              expect(find.textContaining('Recovery needed'), findsNothing);
              expect(tester.takeException(), isNull);
              expect(buildMessageContext(controller).hasReadings, isTrue);
            },
          );
        }
      }
    }
  }

  final now = DateTime.utc(2026, 9, 19, 12);
  for (final driver in ['aidex', 'libre2-gen1', 'cbio']) {
    test('$driver verified normalized readings qualify for live surfaces', () {
      final snapshot = _snapshot(driver, now: now);
      expect(
        shouldPublishLiveActivity(
          snapshot: snapshot,
          latestReading: snapshot.latestReading,
          now: now,
        ),
        isTrue,
      );
      final payload = buildLiveActivityPayload(
        snapshot: snapshot,
        latestReading: snapshot.latestReading,
        preferences: const DisplayPreferences(),
        now: now,
      );
      expect(payload.valueText, '108');
      expect(payload.unitText, 'mg/dL');
      expect(payload.isStale, isFalse);
      expect(provisionalReadingNoticeForSnapshot(snapshot), isNull);
      expect(stageCodeForSnapshot(snapshot), 'live');
    });

    test(
      '$driver raw and provisional values never qualify for live surfaces',
      () {
        for (final reading in [
          CgmReading(
            valueMgdl: 59,
            source: CgmRecordSource.raw,
            recordedAt: now,
          ),
          CgmReading(
            valueMgdl: 59,
            source: CgmRecordSource.vendor,
            recordedAt: now,
            isDisplayProvisional: true,
          ),
        ]) {
          final snapshot = _snapshot(driver, now: now).copyWith(
            latestReading: reading,
            history: [reading],
          );
          expect(
            shouldPublishLiveActivity(
              snapshot: snapshot,
              latestReading: reading,
              now: now,
            ),
            isFalse,
          );
        }
      },
    );
  }

  for (final language in AppLanguage.values) {
    test(
      'GS1 reconnecting normalized session uses shared state in $language',
      () {
        final snapshot = _snapshot('cbio', now: now).copyWith(
          stage: CgmSyncStage.disconnected,
        );
        expect(
          stageLabelForSnapshot(snapshot, language: language),
          language == AppLanguage.english ? 'Reconnecting' : '正在重新连接',
        );
        expect(stageCodeForSnapshot(snapshot), 'progress');
      },
    );
  }
}

CgmSessionSnapshot _snapshot(String driver, {required DateTime now}) {
  final sensor = DiscoveredSensor(
    driverId: driver,
    deviceId: 'fixture-device',
    storageKey: 'fixture-storage',
    displayName: 'Fixture Sensor',
    rssi: -40,
    capabilities: const CgmCapabilities(
      supportsDirectBle: true,
      supportsHistory: true,
    ),
  );
  final readings = [
    for (var i = 0; i < 3; i++)
      CgmReading(
        valueMgdl: 106.0 + i,
        source: CgmRecordSource.standard,
        sensorMinute: 100 + i,
        recordedAt: now.subtract(Duration(minutes: 3 - i)),
      ),
  ];
  return CgmSessionSnapshot(
    stage: CgmSyncStage.ready,
    statusText: 'Ready',
    sensor: sensor,
    capabilities: sensor.capabilities,
    latestReading: readings.last,
    history: readings,
    metadata: const {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
  );
}

class _FixtureDriver implements CgmDriver {
  _FixtureDriver(this.snapshot);
  final CgmSessionSnapshot snapshot;
  @override
  String get driverId => snapshot.sensor.driverId;
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _FixtureSession(snapshot);
  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream.empty();
}

class _FixtureSession implements CgmSession {
  _FixtureSession(this.currentSnapshot);
  @override
  final CgmSessionSnapshot currentSnapshot;
  @override
  DiscoveredSensor get sensor => currentSnapshot.sensor;
  @override
  Stream<CgmLogEntry> get logs => const Stream.empty();
  @override
  Stream<CgmSessionSnapshot> get snapshots => const Stream.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async => [];
  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => [];
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
