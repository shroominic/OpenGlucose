import 'package:cgm_core/cgm_core.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'chart breaks long gaps and clock discontinuities, not normal cadence',
    () {
      final anchor = DateTime.utc(2026, 9, 10);
      bool gap(int delta, {Duration? clockDelta}) => dashboardChartHasGap(
        previousMinute: 60,
        minute: 60 + delta,
        previousRecordedAt: anchor,
        recordedAt: anchor.add(clockDelta ?? Duration(minutes: delta)),
      );
      for (final delta in [1, 5, 15]) {
        expect(gap(delta), isFalse);
      }
      for (final delta in [-1, 0, 16, 120]) {
        expect(gap(delta), isTrue);
      }
      expect(gap(1, clockDelta: const Duration(minutes: 30)), isTrue);
      expect(gap(1, clockDelta: const Duration(seconds: -1)), isTrue);
      expect(gap(1, clockDelta: Duration.zero), isTrue);
      expect(
        gap(1, clockDelta: const Duration(minutes: 15, seconds: 1)),
        isTrue,
      );
    },
  );

  test('unknown receipt time uses sensor gaps without inventing wall time', () {
    for (final previous in [null, DateTime.utc(2026)]) {
      expect(
        dashboardChartHasGap(
          previousMinute: 60,
          minute: 75,
          previousRecordedAt: previous,
          recordedAt: null,
        ),
        isFalse,
      );
      expect(
        dashboardChartHasGap(
          previousMinute: 60,
          minute: 76,
          previousRecordedAt: previous,
          recordedAt: null,
        ),
        isTrue,
      );
    }
  });

  test(
    'axis label layout reserves latest time and omits overlapping labels',
    () {
      expect(dashboardChartVisibleLabelIndices(const []), isEmpty);
      expect(
        dashboardChartVisibleLabelIndices(const [Rect.fromLTWH(10, 0, 40, 12)]),
        [0],
      );
      expect(
        dashboardChartVisibleLabelIndices(const [
          Rect.fromLTWH(0, 0, 40, 12),
          Rect.fromLTWH(65, 0, 40, 12),
          Rect.fromLTWH(80, 0, 40, 12),
          Rect.fromLTWH(200, 0, 40, 12),
        ]),
        [0, 1, 3],
      );
      expect(
        dashboardChartVisibleLabelIndices(const [
          Rect.fromLTWH(0, 0, 40, 12),
          Rect.fromLTWH(5, 0, 40, 12),
        ]),
        [1],
      );
      expect(
        dashboardChartVisibleLabelIndices(const [
          Rect.fromLTWH(0, 0, 40, 12),
          Rect.fromLTWH(45, 0, 40, 12),
        ]),
        [1],
      );
    },
  );

  testWidgets('aggregation never puts both sides of a data gap in one bucket', (
    tester,
  ) async {
    final anchor = DateTime.utc(2026, 9, 10);
    final readings = [
      for (var minute = 0; minute <= 60; minute++)
        CgmReading(
          valueMgdl: 80,
          source: CgmRecordSource.vendor,
          sensorMinute: minute,
          recordedAt: anchor.add(Duration(minutes: minute)),
        ),
      for (var minute = 120; minute <= 180; minute++)
        CgmReading(
          valueMgdl: 180,
          source: CgmRecordSource.vendor,
          sensorMinute: minute,
          recordedAt: anchor.add(Duration(minutes: minute)),
        ),
    ];
    await tester.pumpWidget(
      _chartHarness(
        readings: readings,
        historySync: CgmHistorySyncState(storedCount: readings.length),
      ),
    );
    await tester.tap(find.text('ALL'));
    await tester.pump(const Duration(milliseconds: 200));
    final points = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .expand((widget) => dashboardChartPlottedData(widget.painter))
        .toList();
    expect(points.length, lessThan(readings.length));
    expect(points.map((point) => point.segment).toSet(), {0, 1});
    expect(
      points.fold<int>(
        0,
        (count, point) => count + point.count,
      ),
      readings.length,
    );
    for (final point in points) {
      expect(point.low, point.high);
      expect(point.value, point.segment == 0 ? 80 : 180);
      expect(
        point.minute,
        point.segment == 0 ? lessThanOrEqualTo(60) : greaterThanOrEqualTo(120),
      );
    }
    expect(tester.takeException(), isNull);
  });

  test('short ALL history uses clock labels, not repeated dates', () {
    final first = DateTime(2026, 9, 10, 18, 5);
    final last = first.add(const Duration(minutes: 7));
    expect(
      dashboardChartAxisLabel(
        recordedAt: first,
        sensorMinute: 6000,
        visibleSpanMinutes: 7,
      ),
      '18:05',
    );
    expect(
      dashboardChartAxisLabel(
        recordedAt: last,
        sensorMinute: 6007,
        visibleSpanMinutes: 7,
      ),
      '18:12',
    );
  });

  test('chart labels use local time without changing the stored instant', () {
    final local = DateTime(2026, 9, 10, 23, 58);
    final utc = local.toUtc();
    expect(
      dashboardChartAxisLabel(
        recordedAt: utc,
        sensorMinute: 60,
        visibleSpanMinutes: 0,
      ),
      '23:58',
    );
    expect(utc.isUtc, isTrue);
    expect(utc, local.toUtc());
  });

  test(
    'long history uses dates and unknown receipt times stay sensor-relative',
    () {
      expect(
        dashboardChartAxisLabel(
          recordedAt: DateTime(2026, 9, 10, 18, 5),
          sensorMinute: 6000,
          visibleSpanMinutes: 4320,
        ),
        'Sep 10',
      );
      expect(
        dashboardChartAxisLabel(
          recordedAt: null,
          sensorMinute: 6000,
          visibleSpanMinutes: 7,
        ),
        'm6000',
      );
    },
  );

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
}) {
  return MaterialApp(
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
