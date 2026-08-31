import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Chinese system language renders Chinese and Settings can override it',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final languageController = AppLanguageController(
        preferences: preferences,
        initialDeviceLocales: const <Locale>[Locale('zh', 'CN')],
      );
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
          languageController: languageController,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        languageController.resolvedLanguage,
        AppLanguage.simplifiedChinese,
      );
      expect(find.byTooltip('设置'), findsOneWidget);
      expect(find.text('查找我的传感器'), findsOneWidget);

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('语言'), findsOneWidget);

      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('appLanguageEnglish')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('appLanguageChinese')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('appLanguageEnglish')),
      );
      await tester.pumpAndSettle();

      expect(languageController.preference, AppLanguagePreference.english);
      expect(languageController.resolvedLanguage, AppLanguage.english);
      expect(preferences.getString('openHealth.appLanguage'), 'en');
      expect(find.text('App language'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      languageController.dispose();
      controller.dispose();
    },
  );
}
