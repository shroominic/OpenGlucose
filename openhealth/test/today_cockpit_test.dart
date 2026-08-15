import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/today_cockpit.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);

  CgmReading reading(double value, int minutesAgo) => CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.standard,
    recordedAt: now.subtract(Duration(minutes: minutesAgo)),
  );

  testWidgets('shows latest reading and a context action', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayCockpit(
            readings: <CgmReading>[reading(112, 4)],
            preferences: const DisplayPreferences(),
            now: now,
            onAddContext: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey<String>('todayCockpit')), findsOneWidget);
    expect(find.text('112 mg/dL'), findsOneWidget);
    expect(find.text('Today at a glance'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('todayAddContextButton')),
    );
    expect(tapped, isTrue);
  });

  testWidgets('does not overstate a sparse day', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayCockpit(
            readings: <CgmReading>[reading(112, 4)],
            preferences: const DisplayPreferences(),
            now: now,
          ),
        ),
      ),
    );

    expect(find.text('More context needed'), findsOneWidget);
    expect(
      find.text('Keep collecting readings to unlock a more useful day view.'),
      findsOneWidget,
    );
  });
}
