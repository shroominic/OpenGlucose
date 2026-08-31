import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
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
    for (var sample = 0; sample < 24; sample++) {
      readings.add(
        _reading(
          110,
          DateTime(2026, 6, day).add(Duration(minutes: sample * 30)),
        ),
      );
    }
  }
  readings.add(_reading(240, DateTime(2026, 6, 20, 13))); // Saturday spike
  // Last week: higher average (more above range) for a clear delta.
  for (var day = 9; day <= 15; day++) {
    for (var sample = 0; sample < 24; sample++) {
      readings.add(
        _reading(
          170,
          DateTime(2026, 6, day).add(Duration(minutes: sample * 30)),
        ),
      );
    }
  }
  return readings;
}

void main() {
  testWidgets('renders recap cards with data', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
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
    expect(find.textContaining('self-experimentation'), findsWidgets);

    // Lower cards are below the fold in a ListView; scroll them into view.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Versus last week'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('Versus last week'), findsOneWidget);
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
      find.text("This week's daily averages"),
      300,
      scrollable: scrollable,
    );
    expect(find.text("This week's daily averages"), findsOneWidget);
  });

  testWidgets('shows empty state when no readings', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
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

  testWidgets(
    'does not let prior partial-day readings satisfy recap coverage',
    (tester) async {
      final readings = <CgmReading>[
        for (var index = 0; index < 160; index++)
          _reading(
            110,
            DateTime(2026, 6, 15, 13).add(Duration(minutes: index * 4)),
          ),
        _reading(110, DateTime(2026, 6, 16, 13)),
        _reading(110, DateTime(2026, 6, 17, 13)),
        _reading(110, DateTime(2026, 6, 18, 13)),
      ];

      await tester.pumpWidget(
        _localizedApp(
          home: WeeklyRecapScreen(
            readings: readings,
            preferences: const DisplayPreferences(),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not enough readings yet'), findsOneWidget);
      expect(find.textContaining('currently has 3 readings'), findsOneWidget);
      expect(find.text('This week at a glance'), findsNothing);
    },
  );

  testWidgets('renders mmol/L when preference is set', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
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

  testWidgets('uses Chinese recap copy on a Chinese device', (tester) async {
    await tester.pumpWidget(
      _localizedApp(
        locale: const Locale('zh'),
        home: WeeklyRecapScreen(
          readings: _twoWeeks(),
          preferences: const DisplayPreferences(),
          now: _now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('每周回顾'), findsOneWidget);
    expect(find.text('本周概览'), findsOneWidget);
    expect(find.textContaining('自我探索'), findsWidgets);
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
