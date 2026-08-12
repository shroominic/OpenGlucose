import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/weekly_recap/weekly_recap_screen.dart';

/// A Monday noon so day bucketing is deterministic.
final DateTime _now = DateTime(2026, 6, 22, 12);

CgmReading _reading(double mgdl, DateTime at) => CgmReading(
  valueMgdl: mgdl,
  source: CgmRecordSource.standard,
  recordedAt: at,
);

List<CgmReading> _twoWeeks() {
  final readings = <CgmReading>[];
  // This week: steady, mostly in range, with one spike on Saturday.
  for (var day = 16; day <= 22; day++) {
    for (var h = 6; h < 22; h += 2) {
      readings.add(_reading(110, DateTime(2026, 6, day, h)));
    }
  }
  readings.add(_reading(240, DateTime(2026, 6, 20, 13))); // Saturday spike
  // Last week: higher average (more above range) for a clear delta.
  for (var day = 9; day <= 15; day++) {
    for (var h = 6; h < 22; h += 2) {
      readings.add(_reading(170, DateTime(2026, 6, day, h)));
    }
  }
  return readings;
}

void main() {
  testWidgets('renders recap cards with data', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WeeklyRecapScreen(
          readings: _twoWeeks(),
          preferences: const DisplayPreferences(),
          now: _now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Weekly recap'), findsOneWidget);
    expect(find.text('This week at a glance'), findsOneWidget);
    expect(find.text('Versus last week'), findsOneWidget);
    expect(find.textContaining('self-experimentation'), findsWidgets);

    // Lower cards are below the fold in a ListView; scroll them into view.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Days by time in range'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('Days by time in range'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Top spikes'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('Top spikes'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text("This week's weekdays"),
      300,
      scrollable: scrollable,
    );
    expect(find.text("This week's weekdays"), findsOneWidget);
  });

  testWidgets('shows empty state when no readings', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WeeklyRecapScreen(
          readings: const <CgmReading>[],
          preferences: const DisplayPreferences(),
          now: _now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not enough readings yet'), findsOneWidget);
    expect(find.text('This week at a glance'), findsNothing);
  });

  testWidgets('renders mmol/L when preference is set', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WeeklyRecapScreen(
          readings: _twoWeeks(),
          preferences: const DisplayPreferences(unit: GlucoseUnit.mmolL),
          now: _now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('mmol/L'), findsWidgets);
    expect(find.textContaining('mg/dL'), findsNothing);
  });
}
