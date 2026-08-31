import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/metrics_section.dart';

void main() {
  testWidgets('uses Chinese copy for the insufficient-coverage state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MetricsSection(
            readings: const <CgmReading>[],
            preferences: const DisplayPreferences(),
            now: DateTime(2026, 6, 22, 12),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('趋势'), findsOneWidget);
    expect(find.textContaining('24小时'), findsOneWidget);
    expect(find.textContaining('读数还不够'), findsOneWidget);
  });
}
