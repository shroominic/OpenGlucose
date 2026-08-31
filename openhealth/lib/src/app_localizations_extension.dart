import 'package:flutter/widgets.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';

import 'app_language_controller.dart';

extension AppLocalizationsBuildContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  AppLanguage get appLanguage => AppLanguage.fromLocale(
    Localizations.localeOf(this),
  );
}
