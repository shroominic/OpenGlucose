import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'settings is a full route and remains accessible without sensor',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: DemoCgmDriver(),
      );
      await controller.initialize();

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
      await tester.pump();

      expect(controller.snapshot, isNull);
      expect(find.byTooltip('Settings'), findsOneWidget);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      final overview = find.byKey(const ValueKey<String>('settingsOverview'));
      expect(overview, findsOneWidget);
      // A Material 3 large SliverAppBar keeps both expanded and collapsed
      // title renderers in the tree.
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('No active sensor'), findsOneWidget);
      expect(find.text('Connect a sensor'), findsOneWidget);
      expect(find.text('Sensor archive'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Apple Health'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Apple Health'), findsOneWidget);

      final route = ModalRoute.of(tester.element(overview));
      expect(route, isA<MaterialPageRoute<void>>());
      expect((route! as MaterialPageRoute<void>).fullscreenDialog, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('macOS preview routes AI settings to a fail-closed pane', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
    );
    await controller.initialize();

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
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('AI & models'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('AI & models'));
    await tester.pumpAndSettle();

    expect(find.text('AI unavailable in macOS preview'), findsOneWidget);
    await tester.tap(find.text('AI & models'));
    await tester.pumpAndSettle();

    expect(find.text('AI unavailable in macOS preview'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
