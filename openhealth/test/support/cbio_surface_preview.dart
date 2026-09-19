// Synthetic, radio-free visual fixture. Never the production entrypoint.
// Example: ?driver=cbio&lang=zh&unit=mmol&state=empty
// Normalized numbers are test inputs, NOT verified GS1 decoding evidence.
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/messaging/message_catalog.dart';
import 'package:openglucose/src/messaging/message_controller.dart';
import 'package:openglucose/src/persistence/sensor_state_identity.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cbio_snapshot_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.ensureSemantics();
  final query = Uri.base.queryParameters;
  final driver = switch (query['driver']) {
    'aidex' => 'aidex',
    'libre2-gen1' => 'libre2-gen1',
    _ => 'cbio',
  };
  final now = DateTime.now();
  final state = query['state'] ?? 'normal';
  final readings = <CgmReading>[
    if (state != 'empty' && state != 'warmup')
      for (var index = 0; index < 30; index++)
        CgmReading(
          valueMgdl: 100.0 + index % 15,
          sensorMinute: 100 + index,
          source: CgmRecordSource.standard,
          recordedAt: now.subtract(
            Duration(
              minutes: 30 - index + (state == 'stale' ? 60 : 0),
            ),
          ),
        ),
  ];
  final snapshot = syntheticSurfaceSnapshot(
    driverId: driver,
    readings: readings,
    stage: state == 'error' ? CgmSyncStage.error : CgmSyncStage.ready,
    lastError: state == 'error' ? 'synthetic.failure' : null,
    sessionInfo: state == 'warmup'
        ? CgmSessionInfo(
            sessionStart: now.subtract(const Duration(minutes: 30)),
            warmupMinutes: 60,
          )
        : const CgmSessionInfo(),
  );
  final archive = ArchivedSensorSession(
    id: 'synthetic-normalized-archive',
    historyKey:
        'openHealth.history.normalized.v1.${encodedSensorStateIdentity(snapshot.sensor)}.archive.synthetic',
    storageKey: snapshot.sensor.storageKey,
    driverId: driver,
    deviceId: snapshot.sensor.deviceId,
    displayName: 'Synthetic sensor archive',
    reason: SensorArchiveReason.disconnected,
    readingCount: readings.length,
    lastReadingAt: readings.isEmpty ? null : readings.last.recordedAt,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
    'openHealth.appLanguage': query['lang'] == 'zh' ? 'zh-Hans' : 'en',
    if (query['archive'] == 'normalized') ...{
      archive.historyKey: jsonEncode(
        readings.map((reading) => reading.toJson()).toList(),
      ),
      'openHealth.sensorArchive': jsonEncode([archive.toJson()]),
    },
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: SyntheticSurfaceDriver(snapshot),
  );
  await controller.initialize();
  if (query['archive'] != 'normalized') {
    await controller.connect(snapshot.sensor);
  }
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
          messageController: MessageController(
            preferences: preferences,
            messages: defaultMessageCatalog,
          ),
        ),
      ),
    ),
  );
}
