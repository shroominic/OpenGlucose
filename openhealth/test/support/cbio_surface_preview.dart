// Synthetic, radio-free visual fixture. Never used by the production entrypoint.
import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.ensureSemantics();
  final query = Uri.base.queryParameters;
  final archiveRecovery = query['archive'] == 'recovery';
  const archive = ArchivedSensorSession(
    id: 'cbio-unreconciled:synthetic-preview',
    historyKey: 'openHealth.history.v2.synthetic-preview',
    storageKey: 'synthetic-preview',
    driverId: 'cbio',
    deviceId: 'synthetic-preview',
    displayName: 'Synthetic CBIO archive',
    reason: SensorArchiveReason.disconnected,
    readingCount: 0,
    isUnreconciled: true,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
    'openHealth.appLanguage': query['lang'] == 'zh' ? 'zh-Hans' : 'en',
    if (archiveRecovery) ...{
      archive.historyKey: '{',
      'openHealth.sensorArchive': jsonEncode([archive.toJson()]),
    },
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: _PreviewDriver(stale: query['stale'] == 'true'),
  );
  await controller.initialize();
  if (!archiveRecovery) await controller.connect(_sensor);
  controller.updateDisplayPreferences(
    DisplayPreferences(
      unit: query['unit'] == 'mmol' ? GlucoseUnit.mmolL : GlucoseUnit.mgdl,
    ),
  );
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Banner(
        message: 'SYNTHETIC',
        location: BannerLocation.topStart,
        child: OpenGlucoseApp(
          controller: controller,
          healthExport: HealthExportController(
            preferences: preferences,
            writesAllowed: false,
          )..initialize(),
          preferences: preferences,
        ),
      ),
    ),
  );
}

const _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'synthetic-preview-only',
  displayName: 'SiBio GS1',
  storageKey: 'synthetic-preview-only',
  rssi: -60,
  capabilities: CbioGlucoseSession.capabilities,
);

class _PreviewDriver implements CgmDriver {
  _PreviewDriver({required this.stale});
  final bool stale;
  @override
  String get driverId => 'cbio';
  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream.empty();
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _PreviewSession(stale: stale);
}

class _PreviewSession implements CgmSession {
  _PreviewSession({required bool stale}) {
    final history = <CgmReading>[
      for (var index = 0; index < 3; index++)
        CgmReading(
          valueMgdl: 0,
          rawValue: 57 + index,
          sensorMinute: 100 + index,
          source: CgmRecordSource.raw,
          isDisplayProvisional: true,
        ),
    ];
    currentSnapshot = CgmSessionSnapshot(
      sensor: _sensor,
      capabilities: _sensor.capabilities,
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      latestReading: history.last,
      history: history,
      historySync: CgmHistorySyncState(
        storedCount: history.length,
        lastSyncAt: DateTime.now().subtract(
          Duration(minutes: stale ? 60 : 1),
        ),
      ),
      metadata: const {
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
        cbioPhaseMetadataKey: CbioSessionPhase.live,
      },
    );
  }
  @override
  DiscoveredSensor get sensor => _sensor;
  @override
  late final CgmSessionSnapshot currentSnapshot;
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
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => [];
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async => [];
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
