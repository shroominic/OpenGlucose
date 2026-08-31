import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _preferences([
  Map<String, Object> initialValues = const <String, Object>{},
]) async {
  SharedPreferences.setMockInitialValues(initialValues);
  return SharedPreferences.getInstance();
}

void main() {
  group('AppLanguageController', () {
    test('uses Simplified Chinese for every Chinese device locale', () {
      final chineseDeviceLocales = <List<Locale>>[
        const <Locale>[Locale('zh')],
        const <Locale>[Locale('zh', 'CN')],
        const <Locale>[
          Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        ],
        const <Locale>[
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        ],
        const <Locale>[Locale('en', 'US'), Locale('zh', 'HK')],
      ];

      for (final locales in chineseDeviceLocales) {
        expect(
          AppLanguageController.resolveDeviceLocales(locales),
          AppLanguage.simplifiedChinese,
          reason: 'Expected Chinese fallback for $locales.',
        );
      }
    });

    test('defaults to English for a non-Chinese device locale', () async {
      final controller = AppLanguageController(
        preferences: await _preferences(),
        initialDeviceLocales: const <Locale>[Locale('en', 'GB')],
      );
      addTearDown(controller.dispose);

      expect(controller.preference, AppLanguagePreference.system);
      expect(controller.resolvedLanguage, AppLanguage.english);
      expect(controller.resolvedLocale, const Locale('en'));
    });

    test('persists manual English and Chinese choices', () async {
      final preferences = await _preferences();
      final controller = AppLanguageController(
        preferences: preferences,
        initialDeviceLocales: const <Locale>[Locale('en')],
      );
      addTearDown(controller.dispose);

      await controller.setPreference(AppLanguagePreference.simplifiedChinese);
      expect(controller.preference, AppLanguagePreference.simplifiedChinese);
      expect(controller.resolvedLanguage, AppLanguage.simplifiedChinese);

      final reloadedChinese = AppLanguageController(
        preferences: await SharedPreferences.getInstance(),
        initialDeviceLocales: const <Locale>[Locale('en')],
      );
      addTearDown(reloadedChinese.dispose);
      expect(
        reloadedChinese.preference,
        AppLanguagePreference.simplifiedChinese,
      );
      expect(reloadedChinese.resolvedLanguage, AppLanguage.simplifiedChinese);

      await controller.setPreference(AppLanguagePreference.english);
      expect(controller.preference, AppLanguagePreference.english);
      expect(controller.resolvedLanguage, AppLanguage.english);

      final reloadedEnglish = AppLanguageController(
        preferences: await SharedPreferences.getInstance(),
        initialDeviceLocales: const <Locale>[Locale('zh', 'CN')],
      );
      addTearDown(reloadedEnglish.dispose);
      expect(reloadedEnglish.preference, AppLanguagePreference.english);
      expect(reloadedEnglish.resolvedLanguage, AppLanguage.english);
    });

    test('a manual choice wins when the device language changes', () async {
      final controller = AppLanguageController(
        preferences: await _preferences(),
        initialDeviceLocales: const <Locale>[Locale('zh', 'CN')],
      );
      addTearDown(controller.dispose);

      expect(controller.resolvedLanguage, AppLanguage.simplifiedChinese);

      await controller.setPreference(AppLanguagePreference.english);
      controller.didChangeLocales(const <Locale>[Locale('zh', 'CN')]);
      expect(controller.resolvedLanguage, AppLanguage.english);

      await controller.setPreference(AppLanguagePreference.simplifiedChinese);
      controller.didChangeLocales(const <Locale>[Locale('en', 'US')]);
      expect(controller.resolvedLanguage, AppLanguage.simplifiedChinese);

      await controller.setPreference(AppLanguagePreference.system);
      controller.didChangeLocales(const <Locale>[Locale('en', 'US')]);
      expect(controller.resolvedLanguage, AppLanguage.english);
    });
  });
}
