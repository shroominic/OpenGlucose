import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/sensor_lifecycle_card.dart';

void main() {
  // Fixed clock matching the mock catalog's deterministic clock.
  final now = DateTime.utc(2026, 6, 23, 12);
  final catalog = MockScenarioCatalog(clock: () => now);

  Future<void> pumpCard(
    WidgetTester tester,
    MockScenario scenario, {
    VoidCallback? onReplace,
  }) async {
    final snapshot = catalog.buildSnapshot(scenario);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SensorLifecycleCard(
              snapshot: snapshot,
              latestReading: snapshot.latestReading,
              onReplaceSensor: onReplace,
              clock: () => now,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  CgmReading storedReading({
    DateTime? at,
    double value = 123,
    CgmRecordSource source = CgmRecordSource.vendor,
    bool provisional = true,
  }) => CgmReading(
    valueMgdl: value,
    recordedAt: at,
    sensorMinute: 80,
    source: source,
    isDisplayProvisional: provisional,
  );

  CgmSessionSnapshot retainedSnapshot({
    String driverId = 'libre2-gen1',
    List<CgmReading> history = const [],
    CgmHistorySyncState historySync = const CgmHistorySyncState(),
    CgmSyncStage stage = CgmSyncStage.syncing,
  }) => CgmSessionSnapshot(
    stage: stage,
    statusText: 'Synthetic retained history',
    sensor: DiscoveredSensor(
      driverId: driverId,
      deviceId: 'synthetic-lifecycle',
      displayName: 'Synthetic sensor',
      storageKey: '$driverId:synthetic-lifecycle',
      rssi: -45,
      capabilities: const CgmCapabilities(),
    ),
    capabilities: const CgmCapabilities(),
    sessionInfo: const CgmSessionInfo(elapsedMinutes: 100),
    history: history,
    historySync: historySync,
  );

  Future<void> pumpRetained(
    WidgetTester tester,
    CgmSessionSnapshot snapshot,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SensorLifecycleCard(snapshot: snapshot, clock: () => now),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  }

  for (final driverId in ['aidex', 'yuwell-anytime']) {
    testWidgets('$driverId completed history sync keeps its own time', (
      tester,
    ) async {
      final sync = CgmHistorySyncState(
        lastSyncAt: now.subtract(const Duration(minutes: 2)),
      );
      final snapshot = retainedSnapshot(
        driverId: driverId,
        history: [storedReading(at: now.subtract(const Duration(hours: 2)))],
        historySync: sync,
      );
      await pumpRetained(tester, snapshot);
      expect(find.text('Last history sync'), findsOneWidget);
      expect(find.text('2 min ago'), findsOneWidget);
      expect(find.text('Latest stored reading'), findsNothing);
      expect(identical(snapshot.historySync, sync), isTrue);
    });
  }

  testWidgets(
    'Libre history without current glucose shows stored sample time',
    (
      tester,
    ) async {
      final snapshot = retainedSnapshot(
        history: [storedReading(at: now.subtract(const Duration(minutes: 12)))],
      );
      await pumpRetained(tester, snapshot);
      expect(find.text('Latest stored reading'), findsOneWidget);
      expect(find.text('12 min ago'), findsOneWidget);
      expect(find.text('Not yet'), findsNothing);
      expect(snapshot.latestReading, isNull);
      expect(snapshot.stage, CgmSyncStage.syncing);
      expect(snapshot.historySync.lastSyncAt, isNull);
    },
  );

  testWidgets('old imported history does not acquire the render time', (
    tester,
  ) async {
    final at = now.subtract(const Duration(hours: 2));
    final reading = storedReading(at: at);
    final snapshot = retainedSnapshot(history: [reading]);
    await pumpRetained(tester, snapshot);
    expect(find.text('2 hours ago'), findsOneWidget);
    expect(find.text('just now'), findsNothing);
    expect(snapshot.history.single.recordedAt, at);
    expect(snapshot.latestReading, isNull);
    expect(snapshot.historySync.lastSyncAt, isNull);
  });

  testWidgets('restored history preserves its stored sample timestamp', (
    tester,
  ) async {
    final at = now.subtract(const Duration(minutes: 25));
    final snapshot = retainedSnapshot(
      history: [storedReading(at: at)],
      stage: CgmSyncStage.disconnected,
    );
    await pumpRetained(tester, snapshot);
    expect(find.text('25 min ago'), findsOneWidget);
    expect(snapshot.stage, CgmSyncStage.disconnected);
    expect(snapshot.latestReading, isNull);
  });

  testWidgets('empty and untimed history have distinct honest labels', (
    tester,
  ) async {
    await pumpRetained(tester, retainedSnapshot());
    expect(find.text('No readings yet'), findsOneWidget);
    await pumpRetained(
      tester,
      retainedSnapshot(history: [storedReading()]),
    );
    expect(find.text('Time unavailable'), findsOneWidget);
    expect(find.text('No readings yet'), findsNothing);
  });

  testWidgets('future newest sample never falls back to an older timestamp', (
    tester,
  ) async {
    await pumpRetained(
      tester,
      retainedSnapshot(
        history: [
          storedReading(at: now.subtract(const Duration(minutes: 3))),
          storedReading(at: now.add(const Duration(seconds: 1))),
        ],
      ),
    );
    expect(find.text('Time unavailable'), findsOneWidget);
    expect(find.text('3 min ago'), findsNothing);
    expect(find.text('just now'), findsNothing);
  });

  testWidgets('stored time includes provisional but excludes raw and invalid', (
    tester,
  ) async {
    await pumpRetained(
      tester,
      retainedSnapshot(
        history: [
          storedReading(at: now.subtract(const Duration(minutes: 8))),
          storedReading(at: now, source: CgmRecordSource.raw),
          storedReading(at: now, value: double.nan),
          storedReading(at: now, value: double.infinity),
          storedReading(at: now, value: 0),
          storedReading(at: now, value: -1),
        ],
      ),
    );
    expect(find.text('8 min ago'), findsOneWidget);
    expect(find.text('just now'), findsNothing);
  });

  testWidgets('active scenario shows lifecycle, %-used, and time remaining', (
    tester,
  ) async {
    await pumpCard(tester, MockScenario.activeNormal);

    expect(find.byKey(const ValueKey('sensorLifecycleCard')), findsOneWidget);
    expect(find.text('Sensor lifecycle'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('used'), findsOneWidget);
    expect(find.text('Time remaining'), findsOneWidget);
    expect(find.text('Sensor age'), findsOneWidget);
    expect(find.text('15 days'), findsOneWidget);
  });

  testWidgets('unknown lifecycle remains explicit while session is verified', (
    tester,
  ) async {
    final active = catalog.buildSnapshot(MockScenario.activeNormal);
    final snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.connecting,
      statusText: 'Reconnecting',
      sensor: active.sensor,
      capabilities: active.capabilities,
      sessionInfo: const CgmSessionInfo(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SensorLifecycleCard(snapshot: snapshot, clock: () => now),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('sensorLifecycleCard')), findsOneWidget);
    expect(find.text('Sensor lifecycle'), findsOneWidget);
    expect(find.textContaining('Life remaining unavailable'), findsOneWidget);
  });

  testWidgets('warmup scenario shows the warmup countdown', (tester) async {
    await pumpCard(tester, MockScenario.warmup);

    expect(find.text('Warming up'), findsWidgets);
    expect(find.text('min'), findsOneWidget);
    expect(find.textContaining('min left'), findsOneWidget);
  });

  testWidgets('expiringSoon scenario shows the heads-up banner', (
    tester,
  ) async {
    await pumpCard(tester, MockScenario.expiringSoon);

    expect(find.text('Expiring soon'), findsOneWidget);
    expect(find.textContaining('Have a replacement ready'), findsOneWidget);
  });

  testWidgets('expired scenario renders the offboarding flow', (tester) async {
    var replaced = false;
    await pumpCard(
      tester,
      MockScenario.expired,
      onReplace: () => replaced = true,
    );

    // Clear expired messaging.
    expect(find.text('Sensor expired'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
    expect(
      find.textContaining('frozen at the last known values'),
      findsOneWidget,
    );
    expect(find.textContaining('Last reading 2 hours ago'), findsOneWidget);
    expect(find.textContaining('Last reading just now'), findsNothing);
    // Offboarding steps + replace flow.
    expect(find.text('Next steps'), findsOneWidget);
    expect(find.byKey(const ValueKey('replaceSensorButton')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('replaceSensorButton')));
    expect(replaced, isTrue);
  });

  testWidgets('expired card preserves data (does not blank the dashboard)', (
    tester,
  ) async {
    final snapshot = catalog.buildSnapshot(MockScenario.expired);
    // The expired scenario must still carry its history so the dashboard can
    // render the last-known readings rather than going blank.
    expect(snapshot.history, isNotEmpty);
    expect(snapshot.latestReading, isNotNull);

    await pumpCard(tester, MockScenario.expired);
    // Card renders without throwing and shows the offboarding state.
    expect(find.byKey(const ValueKey('sensorLifecycleCard')), findsOneWidget);
  });
}
