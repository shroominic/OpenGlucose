// Rendering consumes normalized recordedAt only. Private GS1 counter/anchor
// validation remains covered inside the package and real driver-host tests.
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cbio_snapshot_fixture.dart';

void main() {
  final instant = DateTime.utc(2026, 9, 18, 3, 5);
  for (final driver in ['aidex', 'libre2-gen1', 'cbio']) {
    test('$driver renders supplied normalized time in the device zone', () {
      final reading = CgmReading(
        valueMgdl: 108,
        source: CgmRecordSource.standard,
        sensorMinute: 10067,
        recordedAt: instant,
      );
      final local = instant.toLocal();
      expect(
        readingTimeText(reading),
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
      );
      expect(
        liveSurfaceFreshnessAt(
          snapshot: syntheticSurfaceSnapshot(
            driverId: driver,
            readings: [reading],
          ),
          reading: reading,
          now: instant.add(const Duration(minutes: 1)),
        ),
        local,
      );
    });

    test(
      '$driver never derives a normalized time from private clock metadata',
      () {
        const reading = CgmReading(
          valueMgdl: 108,
          source: CgmRecordSource.standard,
          sensorMinute: 10067,
        );
        final snapshot = syntheticSurfaceSnapshot(
          driverId: driver,
          readings: [reading],
          historySync: CgmHistorySyncState(lastSyncAt: instant),
          metadata: const {
            'cgm.cbio.anchorIndex': '10067',
            'cgm.cbio.anchorEpochSeconds': '1780000000',
          },
        );
        expect(readingTimeText(reading), '--');
        expect(
          liveSurfaceFreshnessAt(
            snapshot: snapshot,
            reading: reading,
            now: instant,
          ),
          isNull,
        );
      },
    );
  }

  testWidgets(
    'normalized GS1 hero uses common reading time without clock details',
    (tester) async {
      final now = DateTime.now();
      final reading = CgmReading(
        valueMgdl: 108,
        source: CgmRecordSource.standard,
        sensorMinute: 10067,
        recordedAt: now.subtract(const Duration(minutes: 1)),
      );
      final snapshot = syntheticSurfaceSnapshot(readings: [reading]);
      SharedPreferences.setMockInitialValues({
        'openHealth.onboarding.completed': true,
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
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Latest reading at'), findsOneWidget);
      expect(find.byKey(const ValueKey('cbioClockState')), findsNothing);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cbioClockState')), findsNothing);
      expect(find.textContaining('clock set by this app'), findsNothing);
      expect(find.textContaining('sensor index'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
}
