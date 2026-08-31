import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows multi-day timeframe controls for long history', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chartHarness(
        readings: _buildHistory(totalMinutes: 7 * 24 * 60),
        historySync: const CgmHistorySyncState(
          storedCount: 2017,
          totalAvailable: 2017,
        ),
      ),
    );

    expect(find.text('3h'), findsOneWidget);
    expect(find.text('12h'), findsOneWidget);
    expect(find.text('1d'), findsOneWidget);
    expect(find.text('3d'), findsOneWidget);
    expect(find.text('7d'), findsOneWidget);
    expect(find.text('ALL'), findsOneWidget);
  });

  testWidgets('uses Chinese timeframe labels on a Chinese device', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chartHarness(
        locale: const Locale('zh'),
        readings: _buildHistory(totalMinutes: 7 * 24 * 60),
        historySync: const CgmHistorySyncState(
          storedCount: 2017,
          totalAvailable: 2017,
        ),
      ),
    );

    expect(find.text('3小时'), findsOneWidget);
    expect(find.text('12小时'), findsOneWidget);
    expect(find.text('1天'), findsOneWidget);
    expect(find.text('3天'), findsOneWidget);
    expect(find.text('7天'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
  });

  testWidgets('keeps reading-count footer out of the chart area', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chartHarness(
        readings: _buildHistory(totalMinutes: 12 * 60),
        historySync: const CgmHistorySyncState(
          inProgress: true,
          storedCount: 145,
          totalAvailable: 480,
        ),
      ),
    );

    expect(find.text('145 / 480 readings'), findsNothing);
  });

  testWidgets('shows a tooltip while dragging across the chart', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chartHarness(
        readings: _buildHistory(totalMinutes: 12 * 60),
        historySync: const CgmHistorySyncState(
          storedCount: 145,
          totalAvailable: 145,
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomPaint).first),
    );
    await tester.pump();

    expect(find.textContaining('mg/dL'), findsOneWidget);

    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(find.textContaining('mg/dL'), findsOneWidget);

    await gesture.up();
    await tester.pump();

    expect(find.textContaining('mg/dL'), findsNothing);
  });

  testWidgets('keeps selected timeframe stable while sync updates stream in', (
    tester,
  ) async {
    var readings = _buildHistory(totalMinutes: 36 * 60);
    var historySync = CgmHistorySyncState(
      inProgress: true,
      storedCount: readings.length,
      totalAvailable: readings.length + 240,
    );

    await tester.pumpWidget(
      _chartHarness(readings: readings, historySync: historySync),
    );

    await tester.tap(find.text('1d'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);

    for (var cycle = 0; cycle < 5; cycle++) {
      readings = _buildHistory(totalMinutes: (36 + cycle) * 60);
      historySync = historySync.copyWith(
        storedCount: readings.length,
        totalAvailable: readings.length + 120,
      );

      await tester.pumpWidget(
        _chartHarness(readings: readings, historySync: historySync),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('1d'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

Widget _chartHarness({
  required List<CgmReading> readings,
  required CgmHistorySyncState historySync,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 390,
          height: 320,
          child: CgmDashboardChart(
            readings: readings,
            preferences: const DisplayPreferences(),
            historySync: historySync,
          ),
        ),
      ),
    ),
  );
}

List<CgmReading> _buildHistory({required int totalMinutes}) {
  final readings = <CgmReading>[];
  final anchor = DateTime.utc(2026, 4, 13, 12);
  for (var minute = 0; minute <= totalMinutes; minute += 5) {
    final hour = minute ~/ 60;
    final value =
        110 + (hour.isEven ? 8 : -6) + ((minute % 90) / 10).clamp(0, 8);
    readings.add(
      CgmReading(
        valueMgdl: value.toDouble(),
        source: CgmRecordSource.vendor,
        sensorMinute: minute,
        recordedAt: anchor.subtract(Duration(minutes: totalMinutes - minute)),
      ),
    );
  }
  return readings;
}
