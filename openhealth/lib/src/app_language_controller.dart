import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's explicit language choice.
///
/// [system] is the default: OpenGlucose uses Simplified Chinese for a Chinese
/// device locale and English for every other locale until more translations
/// are available. This preference contains stable identifiers only; display
/// labels always come from the active localization catalog.
enum AppLanguagePreference {
  system,
  english,
  simplifiedChinese
  ;

  String get storageValue => switch (this) {
    AppLanguagePreference.system => 'system',
    AppLanguagePreference.english => 'en',
    AppLanguagePreference.simplifiedChinese => 'zh-Hans',
  };

  static AppLanguagePreference fromStorageValue(String? value) {
    return switch (value) {
      'en' => AppLanguagePreference.english,
      'zh-Hans' => AppLanguagePreference.simplifiedChinese,
      _ => AppLanguagePreference.system,
    };
  }
}

/// A supported rendered language, distinct from the user's preference.
enum AppLanguage {
  english,
  simplifiedChinese
  ;

  Locale get locale => switch (this) {
    AppLanguage.english => const Locale('en'),
    AppLanguage.simplifiedChinese => const Locale('zh'),
  };

  String get nativePayloadCode => switch (this) {
    AppLanguage.english => 'en',
    AppLanguage.simplifiedChinese => 'zh',
  };

  static AppLanguage fromLocale(Locale locale) {
    return locale.languageCode.toLowerCase() == 'zh'
        ? AppLanguage.simplifiedChinese
        : AppLanguage.english;
  }
}

/// Resolves and persists the app language without storing a device locale.
///
/// Device locales stay platform-owned. We save only the user's optional
/// override, so a system-language change takes effect on the next locale
/// callback without migrating any health or sensor data.
class AppLanguageController extends ChangeNotifier with WidgetsBindingObserver {
  AppLanguageController({
    required SharedPreferences preferences,
    List<Locale>? initialDeviceLocales,
  }) : _preferences = preferences,
       _deviceLocales =
           initialDeviceLocales ??
           WidgetsBinding.instance.platformDispatcher.locales,
       _preference = AppLanguagePreference.fromStorageValue(
         preferences.getString(_preferenceKey),
       ) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _preferenceKey = 'openHealth.appLanguage';

  final SharedPreferences _preferences;
  List<Locale> _deviceLocales;
  AppLanguagePreference _preference;

  AppLanguagePreference get preference => _preference;

  AppLanguage get resolvedLanguage => switch (_preference) {
    AppLanguagePreference.english => AppLanguage.english,
    AppLanguagePreference.simplifiedChinese => AppLanguage.simplifiedChinese,
    AppLanguagePreference.system => resolveDeviceLocales(_deviceLocales),
  };

  Locale get resolvedLocale => resolvedLanguage.locale;

  /// Maps every Chinese device locale to the available Simplified Chinese
  /// catalog. Unsupported locales use English as the intentional fallback.
  static AppLanguage resolveDeviceLocales(Iterable<Locale> locales) {
    for (final locale in locales) {
      if (locale.languageCode.toLowerCase() == 'zh') {
        return AppLanguage.simplifiedChinese;
      }
    }
    return AppLanguage.english;
  }

  Future<void> setPreference(AppLanguagePreference preference) async {
    if (_preference == preference) {
      return;
    }
    final persisted = await _preferences.setString(
      _preferenceKey,
      preference.storageValue,
    );
    if (!persisted) {
      return;
    }
    _preference = preference;
    notifyListeners();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    _deviceLocales =
        locales ?? WidgetsBinding.instance.platformDispatcher.locales;
    if (_preference == AppLanguagePreference.system) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Makes the persisted language preference available to settings descendants.
class AppLanguageScope extends InheritedNotifier<AppLanguageController> {
  const AppLanguageScope({
    super.key,
    required AppLanguageController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppLanguageController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppLanguageScope>();
    assert(scope != null, 'No AppLanguageScope found in context');
    return scope!.notifier!;
  }
}
