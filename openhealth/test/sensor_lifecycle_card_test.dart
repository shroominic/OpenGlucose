import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
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
    Locale locale = const Locale('en'),
  }) async {
    final snapshot = catalog.buildSnapshot(scenario);
    await tester.pumpWidget(
      _localizedApp(
        locale: locale,
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
      _localizedApp(
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

  testWidgets('uses Chinese lifecycle copy on a Chinese device', (
    tester,
  ) async {
    await pumpCard(
      tester,
      MockScenario.activeNormal,
      locale: const Locale('zh'),
    );

    expect(find.text('传感器使用周期'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('剩余时间'), findsOneWidget);
    expect(find.text('15 天'), findsOneWidget);
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

Widget _localizedApp({
  required Widget home,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}
