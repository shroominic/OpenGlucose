import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'OpenGlucose'**
  String get appTitle;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @saveSettings.
  ///
  /// In en, this message translates to:
  /// **'Save settings'**
  String get saveSettings;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// No description provided for @scanAgain.
  ///
  /// In en, this message translates to:
  /// **'Scan again'**
  String get scanAgain;

  /// No description provided for @findMySensor.
  ///
  /// In en, this message translates to:
  /// **'Find my sensor'**
  String get findMySensor;

  /// No description provided for @scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get scanning;

  /// No description provided for @nearbySensors.
  ///
  /// In en, this message translates to:
  /// **'Nearby sensors'**
  String get nearbySensors;

  /// No description provided for @sensorsFound.
  ///
  /// In en, this message translates to:
  /// **'{count} found'**
  String sensorsFound(int count);

  /// No description provided for @noSensorsFound.
  ///
  /// In en, this message translates to:
  /// **'No sensors found yet. Hold your phone near your sensor and try again.'**
  String get noSensorsFound;

  /// No description provided for @exploreSampleData.
  ///
  /// In en, this message translates to:
  /// **'Explore sample data'**
  String get exploreSampleData;

  /// No description provided for @sampleDataNotSensor.
  ///
  /// In en, this message translates to:
  /// **'Sample data — not from a sensor'**
  String get sampleDataNotSensor;

  /// No description provided for @sensor.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get sensor;

  /// No description provided for @sensors.
  ///
  /// In en, this message translates to:
  /// **'Sensors'**
  String get sensors;

  /// No description provided for @currentSensor.
  ///
  /// In en, this message translates to:
  /// **'Current sensor'**
  String get currentSensor;

  /// No description provided for @connectSensor.
  ///
  /// In en, this message translates to:
  /// **'Connect a sensor'**
  String get connectSensor;

  /// No description provided for @sensorArchive.
  ///
  /// In en, this message translates to:
  /// **'Sensor archive'**
  String get sensorArchive;

  /// No description provided for @glucoseAndDisplay.
  ///
  /// In en, this message translates to:
  /// **'Glucose & display'**
  String get glucoseAndDisplay;

  /// No description provided for @appleHealth.
  ///
  /// In en, this message translates to:
  /// **'Apple Health'**
  String get appleHealth;

  /// No description provided for @privacyAndData.
  ///
  /// In en, this message translates to:
  /// **'Privacy & data'**
  String get privacyAndData;

  /// No description provided for @aboutOpenGlucose.
  ///
  /// In en, this message translates to:
  /// **'About OpenGlucose'**
  String get aboutOpenGlucose;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @appLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get appLanguage;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow device language'**
  String get languageSystem;

  /// No description provided for @languageSystemDescription.
  ///
  /// In en, this message translates to:
  /// **'Uses Simplified Chinese on Chinese devices and English on other devices.'**
  String get languageSystemDescription;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageSimplifiedChinese.
  ///
  /// In en, this message translates to:
  /// **'Simplified Chinese'**
  String get languageSimplifiedChinese;

  /// No description provided for @languageSimplifiedChineseNative.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get languageSimplifiedChineseNative;

  /// No description provided for @languageCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {language}'**
  String languageCurrent(String language);

  /// No description provided for @languageChangeDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose the language used throughout OpenGlucose. This does not change your sensor data.'**
  String get languageChangeDescription;

  /// No description provided for @sensorStatusSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Status, life, identity, and connection'**
  String get sensorStatusSubtitle;

  /// No description provided for @noSensorActive.
  ///
  /// In en, this message translates to:
  /// **'No sensor is active'**
  String get noSensorActive;

  /// No description provided for @sensorArchiveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Previous sensor sessions and exports'**
  String get sensorArchiveSubtitle;

  /// No description provided for @displaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Units, target range, and chart style'**
  String get displaySubtitle;

  /// No description provided for @appleHealthSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Glucose export and health data controls'**
  String get appleHealthSubtitle;

  /// No description provided for @privacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Local storage and retention'**
  String get privacySubtitle;

  /// No description provided for @aboutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Version, purpose, and open-source project'**
  String get aboutSubtitle;

  /// No description provided for @advancedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics and developer tools'**
  String get advancedSubtitle;

  /// No description provided for @history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get history;

  /// No description provided for @patterns.
  ///
  /// In en, this message translates to:
  /// **'Patterns'**
  String get patterns;

  /// No description provided for @weeklyRecap.
  ///
  /// In en, this message translates to:
  /// **'Weekly recap'**
  String get weeklyRecap;

  /// No description provided for @viewWeeklyRecap.
  ///
  /// In en, this message translates to:
  /// **'View weekly recap'**
  String get viewWeeklyRecap;

  /// No description provided for @latestReadingAt.
  ///
  /// In en, this message translates to:
  /// **'Latest reading at {time}'**
  String latestReadingAt(String time);

  /// No description provided for @supportCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Support code copied'**
  String get supportCodeCopied;

  /// No description provided for @copySupportCode.
  ///
  /// In en, this message translates to:
  /// **'Copy support code'**
  String get copySupportCode;

  /// No description provided for @chooseAnotherSensor.
  ///
  /// In en, this message translates to:
  /// **'Choose another sensor'**
  String get chooseAnotherSensor;

  /// No description provided for @reviewMove.
  ///
  /// In en, this message translates to:
  /// **'Review move'**
  String get reviewMove;

  /// No description provided for @moveNeedsSupport.
  ///
  /// In en, this message translates to:
  /// **'Move needs support'**
  String get moveNeedsSupport;

  /// No description provided for @moveSensorToAnotherPhone.
  ///
  /// In en, this message translates to:
  /// **'Move sensor to another phone'**
  String get moveSensorToAnotherPhone;

  /// No description provided for @sensorDetails.
  ///
  /// In en, this message translates to:
  /// **'Sensor details'**
  String get sensorDetails;

  /// No description provided for @serial.
  ///
  /// In en, this message translates to:
  /// **'Serial'**
  String get serial;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @firmware.
  ///
  /// In en, this message translates to:
  /// **'Firmware'**
  String get firmware;

  /// No description provided for @sensorStart.
  ///
  /// In en, this message translates to:
  /// **'Sensor start'**
  String get sensorStart;

  /// No description provided for @readingCount.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one{reading} other{readings}}'**
  String readingCount(int count);

  /// No description provided for @showGlucoseInLiveNotification.
  ///
  /// In en, this message translates to:
  /// **'Show glucose in live notification'**
  String get showGlucoseInLiveNotification;

  /// No description provided for @showGlucoseInLiveNotificationDescription.
  ///
  /// In en, this message translates to:
  /// **'Allows glucose values, trends, and update times to appear in the Android live notification or iOS Live Activity. Anyone who can view your lock screen may see this health data.'**
  String get showGlucoseInLiveNotificationDescription;

  /// No description provided for @showSampleDashboard.
  ///
  /// In en, this message translates to:
  /// **'Open sample dashboard'**
  String get showSampleDashboard;

  /// No description provided for @sampleDashboard.
  ///
  /// In en, this message translates to:
  /// **'Sample dashboard'**
  String get sampleDashboard;

  /// No description provided for @openSampleWeeklyRecap.
  ///
  /// In en, this message translates to:
  /// **'Open sample weekly recap'**
  String get openSampleWeeklyRecap;

  /// No description provided for @welcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to OpenGlucose'**
  String get welcomeTitle;

  /// No description provided for @welcomeBody.
  ///
  /// In en, this message translates to:
  /// **'An open-source, local-first way to watch your glucose. Built for wellness, sport and self-experimentation — not as a medical device.'**
  String get welcomeBody;

  /// No description provided for @storedLocallyTitle.
  ///
  /// In en, this message translates to:
  /// **'Stored locally by default'**
  String get storedLocallyTitle;

  /// No description provided for @storedLocallyBody.
  ///
  /// In en, this message translates to:
  /// **'History stays on this device. Optional Apple Health or AI features share data only when you enable them.'**
  String get storedLocallyBody;

  /// No description provided for @openSourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Open source & hackable'**
  String get openSourceTitle;

  /// No description provided for @openSourceBody.
  ///
  /// In en, this message translates to:
  /// **'MIT-licensed. Inspect it, extend it, make it yours.'**
  String get openSourceBody;

  /// No description provided for @wellnessDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'OpenGlucose is for wellness and self-experimentation. It is not a medical device and not a substitute for medical advice.'**
  String get wellnessDisclaimer;

  /// No description provided for @howItWorksTitle.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get howItWorksTitle;

  /// No description provided for @howItWorksBody.
  ///
  /// In en, this message translates to:
  /// **'Apply your Aidex X sensor, pair it over Bluetooth, and let it warm up. After that, readings stream straight to your phone.'**
  String get howItWorksBody;

  /// No description provided for @applySensorTitle.
  ///
  /// In en, this message translates to:
  /// **'Apply the sensor'**
  String get applySensorTitle;

  /// No description provided for @applySensorBody.
  ///
  /// In en, this message translates to:
  /// **'A small all-in-one sensor you wear for up to 15 days.'**
  String get applySensorBody;

  /// No description provided for @warmupTitle.
  ///
  /// In en, this message translates to:
  /// **'About 1 hour warm-up'**
  String get warmupTitle;

  /// No description provided for @warmupBody.
  ///
  /// In en, this message translates to:
  /// **'The sensor calibrates itself before the first reading.'**
  String get warmupBody;

  /// No description provided for @readingEveryMinuteTitle.
  ///
  /// In en, this message translates to:
  /// **'A reading every minute'**
  String get readingEveryMinuteTitle;

  /// No description provided for @readingEveryMinuteBody.
  ///
  /// In en, this message translates to:
  /// **'Live values and trends, refreshed continuously.'**
  String get readingEveryMinuteBody;

  /// No description provided for @targetRangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Set your target range'**
  String get targetRangeTitle;

  /// No description provided for @targetRangeBody.
  ///
  /// In en, this message translates to:
  /// **'Choose the range you want to stay within. You can change this any time in settings.'**
  String get targetRangeBody;

  /// No description provided for @targetRangeHint.
  ///
  /// In en, this message translates to:
  /// **'Most people start with 70–180 mg/dL (about 3.9–10 mmol/L).'**
  String get targetRangeHint;

  /// No description provided for @readyTitle.
  ///
  /// In en, this message translates to:
  /// **'You\'re all set'**
  String get readyTitle;

  /// No description provided for @readyBody.
  ///
  /// In en, this message translates to:
  /// **'Have your Aidex X sensor on and nearby. We’ll scan for it over Bluetooth and connect — then your live dashboard takes over.'**
  String get readyBody;

  /// No description provided for @turnOnBluetoothTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on Bluetooth'**
  String get turnOnBluetoothTitle;

  /// No description provided for @turnOnBluetoothBody.
  ///
  /// In en, this message translates to:
  /// **'Keep your phone close to the sensor while it pairs.'**
  String get turnOnBluetoothBody;

  /// No description provided for @watchItComeAliveTitle.
  ///
  /// In en, this message translates to:
  /// **'Watch it come alive'**
  String get watchItComeAliveTitle;

  /// No description provided for @watchItComeAliveBody.
  ///
  /// In en, this message translates to:
  /// **'Trends and readings appear as soon as warm-up finishes.'**
  String get watchItComeAliveBody;

  /// No description provided for @connectMySensor.
  ///
  /// In en, this message translates to:
  /// **'Connect my sensor'**
  String get connectMySensor;

  /// No description provided for @lifeRemainingUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Life remaining unavailable'**
  String get lifeRemainingUnavailable;

  /// No description provided for @sensorExpired.
  ///
  /// In en, this message translates to:
  /// **'Sensor expired'**
  String get sensorExpired;

  /// No description provided for @hoursLeft.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one{hour} other{hours}} left'**
  String hoursLeft(int count);

  /// No description provided for @daysLeft.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one{day} other{days}} left'**
  String daysLeft(int count);

  /// No description provided for @minutesShort.
  ///
  /// In en, this message translates to:
  /// **'min'**
  String get minutesShort;

  /// No description provided for @waitingForFirstReading.
  ///
  /// In en, this message translates to:
  /// **'waiting for first reading'**
  String get waitingForFirstReading;

  /// No description provided for @warmingUp.
  ///
  /// In en, this message translates to:
  /// **'Warming up'**
  String get warmingUp;

  /// No description provided for @warmupComplete.
  ///
  /// In en, this message translates to:
  /// **'Warmup complete'**
  String get warmupComplete;

  /// No description provided for @warmup.
  ///
  /// In en, this message translates to:
  /// **'Warmup'**
  String get warmup;

  /// No description provided for @waiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get waiting;

  /// No description provided for @notSyncedYet.
  ///
  /// In en, this message translates to:
  /// **'Not synced yet'**
  String get notSyncedYet;

  /// No description provided for @syncedJustNow.
  ///
  /// In en, this message translates to:
  /// **'Synced just now'**
  String get syncedJustNow;

  /// No description provided for @syncedMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} min ago'**
  String syncedMinutesAgo(int count);

  /// No description provided for @syncedHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} {count, plural, one{hour} other{hours}} ago'**
  String syncedHoursAgo(int count);

  /// No description provided for @syncedDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} {count, plural, one{day} other{days}} ago'**
  String syncedDaysAgo(int count);

  /// No description provided for @stageError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get stageError;

  /// No description provided for @stageDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get stageDisconnected;

  /// No description provided for @stageReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get stageReconnecting;

  /// No description provided for @stageSettingUp.
  ///
  /// In en, this message translates to:
  /// **'Setting up'**
  String get stageSettingUp;

  /// No description provided for @stageConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get stageConnected;

  /// No description provided for @stageConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get stageConnecting;

  /// No description provided for @stageLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get stageLive;

  /// No description provided for @attentionNeeded.
  ///
  /// In en, this message translates to:
  /// **'Attention needed'**
  String get attentionNeeded;

  /// No description provided for @updatedAt.
  ///
  /// In en, this message translates to:
  /// **'Updated {time}'**
  String updatedAt(String time);

  /// No description provided for @openAppToViewGlucose.
  ///
  /// In en, this message translates to:
  /// **'Open the app to view your glucose'**
  String get openAppToViewGlucose;

  /// No description provided for @sensorWarmingUp.
  ///
  /// In en, this message translates to:
  /// **'Sensor warming up'**
  String get sensorWarmingUp;

  /// No description provided for @waitingForSensor.
  ///
  /// In en, this message translates to:
  /// **'Waiting for sensor'**
  String get waitingForSensor;

  /// No description provided for @waitingForGlucoseUpdate.
  ///
  /// In en, this message translates to:
  /// **'Waiting for glucose update'**
  String get waitingForGlucoseUpdate;

  /// No description provided for @stale.
  ///
  /// In en, this message translates to:
  /// **'Stale'**
  String get stale;

  /// No description provided for @glucoseUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Glucose unavailable'**
  String get glucoseUnavailable;

  /// No description provided for @bluetoothPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'OpenGlucose needs Bluetooth access. In your phone settings, allow Bluetooth and any nearby-device permissions requested by the app. Some phones also require Location to be allowed and turned on for scanning. Then try again.'**
  String get bluetoothPermissionRequired;

  /// No description provided for @bluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off. Turn it on in your phone\'s quick settings or Settings, then try scanning again.'**
  String get bluetoothOff;

  /// No description provided for @bluetoothUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is not available on this phone right now. Restart Bluetooth or the phone, then try again.'**
  String get bluetoothUnavailable;

  /// No description provided for @pairingRejected.
  ///
  /// In en, this message translates to:
  /// **'The phone did not complete pairing. Keep it close and accept the pairing prompt. If this sensor is already bonded or connected to another phone, stop that connection before trying again. Do not reset an active sensor.'**
  String get pairingRejected;

  /// No description provided for @pairingTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Pairing timed out. Keep the phone close and accept the system pairing prompt. If another phone is using this sensor, stop that connection before trying again.'**
  String get pairingTimedOut;

  /// No description provided for @sensorPossiblyInUse.
  ///
  /// In en, this message translates to:
  /// **'The sensor became unavailable during setup. It may be out of range or already bonded or connected to another phone. Keep it close and stop the other connection, if applicable, before trying again. Do not reset an active sensor.'**
  String get sensorPossiblyInUse;

  /// No description provided for @sensorDisconnected.
  ///
  /// In en, this message translates to:
  /// **'The sensor disconnected. Keep the phone close and try again.'**
  String get sensorDisconnected;

  /// No description provided for @bluetoothSetupTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth setup timed out. Keep the phone close and try again.'**
  String get bluetoothSetupTimedOut;

  /// No description provided for @bluetoothSetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth setup could not be completed. Restart Bluetooth and try again.'**
  String get bluetoothSetupFailed;

  /// No description provided for @appPurpose.
  ///
  /// In en, this message translates to:
  /// **'OpenGlucose is wellness/reference software, not a medical device. Do not use it for diagnosis, medication or insulin dosing, treatment decisions, or emergency monitoring.'**
  String get appPurpose;

  /// No description provided for @unit.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get unit;

  /// No description provided for @chartStyle.
  ///
  /// In en, this message translates to:
  /// **'Chart style'**
  String get chartStyle;

  /// No description provided for @targetLow.
  ///
  /// In en, this message translates to:
  /// **'Target low (mg/dL)'**
  String get targetLow;

  /// No description provided for @targetHigh.
  ///
  /// In en, this message translates to:
  /// **'Target high (mg/dL)'**
  String get targetHigh;

  /// No description provided for @targetRangeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter an increasing target glucose range.'**
  String get targetRangeInvalid;

  /// No description provided for @line.
  ///
  /// In en, this message translates to:
  /// **'Line'**
  String get line;

  /// No description provided for @dots.
  ///
  /// In en, this message translates to:
  /// **'Dots'**
  String get dots;

  /// No description provided for @candles.
  ///
  /// In en, this message translates to:
  /// **'Candles'**
  String get candles;

  /// No description provided for @preferencesSection.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get preferencesSection;

  /// No description provided for @dataAndIntegrationsSection.
  ///
  /// In en, this message translates to:
  /// **'Data & integrations'**
  String get dataAndIntegrationsSection;

  /// No description provided for @appSection.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get appSection;

  /// No description provided for @archivedSensorsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} previous {count, plural, one{sensor} other{sensors}}'**
  String archivedSensorsCount(int count);

  /// No description provided for @aiAndModels.
  ///
  /// In en, this message translates to:
  /// **'AI & models'**
  String get aiAndModels;

  /// No description provided for @noActiveSensor.
  ///
  /// In en, this message translates to:
  /// **'No active sensor'**
  String get noActiveSensor;

  /// No description provided for @previousDataStaysOnThisPhone.
  ///
  /// In en, this message translates to:
  /// **'Your previous data stays on this phone.'**
  String get previousDataStaysOnThisPhone;

  /// No description provided for @inactiveSensorExpired.
  ///
  /// In en, this message translates to:
  /// **'Your last sensor expired. Your previous readings are still here—connect a new sensor to resume live glucose.'**
  String get inactiveSensorExpired;

  /// No description provided for @inactiveSensorReplaced.
  ///
  /// In en, this message translates to:
  /// **'Your previous sensor was replaced. Its readings are still here—connect your new sensor to resume live glucose.'**
  String get inactiveSensorReplaced;

  /// No description provided for @inactiveSensorDisconnected.
  ///
  /// In en, this message translates to:
  /// **'No sensor is active. Your previous readings are still here—connect a sensor to resume live glucose.'**
  String get inactiveSensorDisconnected;

  /// No description provided for @inactiveSensorWelcome.
  ///
  /// In en, this message translates to:
  /// **'Your glucose, on your terms. Connect your sensor to see live readings and trends.'**
  String get inactiveSensorWelcome;

  /// No description provided for @bluetoothOffTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off'**
  String get bluetoothOffTitle;

  /// No description provided for @bluetoothPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth access needed'**
  String get bluetoothPermissionTitle;

  /// No description provided for @bluetoothUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is unavailable'**
  String get bluetoothUnavailableTitle;

  /// No description provided for @scanSensorsFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not scan for sensors'**
  String get scanSensorsFailedTitle;

  /// No description provided for @scanSensorHelp.
  ///
  /// In en, this message translates to:
  /// **'Check Bluetooth, keep the sensor nearby, and try again.'**
  String get scanSensorHelp;

  /// No description provided for @scanSensorHelpShort.
  ///
  /// In en, this message translates to:
  /// **'Check Bluetooth and try scanning again.'**
  String get scanSensorHelpShort;

  /// No description provided for @yourGlucoseHistory.
  ///
  /// In en, this message translates to:
  /// **'Your glucose history'**
  String get yourGlucoseHistory;

  /// No description provided for @firstReading.
  ///
  /// In en, this message translates to:
  /// **'First reading'**
  String get firstReading;

  /// No description provided for @latestReading.
  ///
  /// In en, this message translates to:
  /// **'Latest reading'**
  String get latestReading;

  /// No description provided for @storedSessions.
  ///
  /// In en, this message translates to:
  /// **'Stored sessions'**
  String get storedSessions;

  /// No description provided for @historySessionSeparation.
  ///
  /// In en, this message translates to:
  /// **'Each sensor keeps its own chart in Sensor archive, so separate sessions are never joined into one line.'**
  String get historySessionSeparation;

  /// No description provided for @demoDataWarning.
  ///
  /// In en, this message translates to:
  /// **'DEMO DATA — NOT REAL GLUCOSE'**
  String get demoDataWarning;

  /// No description provided for @lastAt.
  ///
  /// In en, this message translates to:
  /// **'last {time}'**
  String lastAt(String time);

  /// No description provided for @failedToStart.
  ///
  /// In en, this message translates to:
  /// **'Failed to start: {error}'**
  String failedToStart(String error);

  /// No description provided for @counter.
  ///
  /// In en, this message translates to:
  /// **'Counter {count}'**
  String counter(int count);

  /// No description provided for @demoTransport.
  ///
  /// In en, this message translates to:
  /// **'Demo transport'**
  String get demoTransport;

  /// No description provided for @unknownSensorResponse.
  ///
  /// In en, this message translates to:
  /// **'The sensor response is unknown. Do not reconnect or forget the Android bond. Contact support for a reviewed recovery.'**
  String get unknownSensorResponse;

  /// No description provided for @reviewInterruptedSensorMove.
  ///
  /// In en, this message translates to:
  /// **'Review interrupted sensor move'**
  String get reviewInterruptedSensorMove;

  /// No description provided for @interruptedSensorMoveReview.
  ///
  /// In en, this message translates to:
  /// **'Open Android Bluetooth settings before you continue. Confirm that the sensor is not listed as paired. If it is listed, choose Forget first. This action only clears the app safety marker. It does not contact the sensor or change a Bluetooth bond.'**
  String get interruptedSensorMoveReview;

  /// No description provided for @interruptedSelectedSensorMoveReview.
  ///
  /// In en, this message translates to:
  /// **'Open Android Bluetooth settings. Confirm that the sensor is not listed as paired. If it is listed, choose Forget first. Continuing clears the app safety marker and archives this selection. It does not contact the sensor or change a Bluetooth bond.'**
  String get interruptedSelectedSensorMoveReview;

  /// No description provided for @checkedBluetooth.
  ///
  /// In en, this message translates to:
  /// **'I checked Bluetooth'**
  String get checkedBluetooth;

  /// No description provided for @interruptedSensorMoveCouldNotClear.
  ///
  /// In en, this message translates to:
  /// **'The interrupted sensor move could not be cleared.'**
  String get interruptedSensorMoveCouldNotClear;

  /// No description provided for @sensorNoLongerActive.
  ///
  /// In en, this message translates to:
  /// **'This sensor is no longer active'**
  String get sensorNoLongerActive;

  /// No description provided for @inactiveSensorSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Return to Settings to review Sensor archive or connect another sensor.'**
  String get inactiveSensorSettingsDescription;

  /// No description provided for @backToSettings.
  ///
  /// In en, this message translates to:
  /// **'Back to Settings'**
  String get backToSettings;

  /// No description provided for @sensorArchiveEmpty.
  ///
  /// In en, this message translates to:
  /// **'Previous sensors will appear here after they expire or are replaced.'**
  String get sensorArchiveEmpty;

  /// No description provided for @previousSensor.
  ///
  /// In en, this message translates to:
  /// **'Previous sensor'**
  String get previousSensor;

  /// No description provided for @archiveSessionSummary.
  ///
  /// In en, this message translates to:
  /// **'{reason} · {readings}{date}'**
  String archiveSessionSummary(String reason, String readings, String date);

  /// No description provided for @archiveHistoryOnly.
  ///
  /// In en, this message translates to:
  /// **'{reason} · history only, not connected'**
  String archiveHistoryOnly(String reason);

  /// No description provided for @readings.
  ///
  /// In en, this message translates to:
  /// **'Readings'**
  String get readings;

  /// No description provided for @started.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get started;

  /// No description provided for @ended.
  ///
  /// In en, this message translates to:
  /// **'Ended'**
  String get ended;

  /// No description provided for @recapThisSensor.
  ///
  /// In en, this message translates to:
  /// **'Recap this sensor'**
  String get recapThisSensor;

  /// No description provided for @exportData.
  ///
  /// In en, this message translates to:
  /// **'Export data'**
  String get exportData;

  /// No description provided for @exportArchivedSensorData.
  ///
  /// In en, this message translates to:
  /// **'Export archived sensor data'**
  String get exportArchivedSensorData;

  /// No description provided for @storedGlucoseReadings.
  ///
  /// In en, this message translates to:
  /// **'{count} stored glucose {count, plural, one{reading} other{readings}}'**
  String storedGlucoseReadings(int count);

  /// No description provided for @hiddenWarmupDisclosure.
  ///
  /// In en, this message translates to:
  /// **'{count} warmup {count, plural, one{reading is} other{readings are}} included for a complete export. These remain hidden from charts, recaps, and Apple Health.'**
  String hiddenWarmupDisclosure(int count);

  /// No description provided for @dateRangeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Date range unavailable'**
  String get dateRangeUnavailable;

  /// No description provided for @fileFormat.
  ///
  /// In en, this message translates to:
  /// **'File format'**
  String get fileFormat;

  /// No description provided for @includedInFile.
  ///
  /// In en, this message translates to:
  /// **'Included in the file'**
  String get includedInFile;

  /// No description provided for @exportIncludesGlucose.
  ///
  /// In en, this message translates to:
  /// **'• Glucose values in mg/dL and mmol/L'**
  String get exportIncludesGlucose;

  /// No description provided for @exportIncludesTiming.
  ///
  /// In en, this message translates to:
  /// **'• Reading times, source, and sensor minute'**
  String get exportIncludesTiming;

  /// No description provided for @exportIncludesQuality.
  ///
  /// In en, this message translates to:
  /// **'• Raw quality fields and provisional state'**
  String get exportIncludesQuality;

  /// No description provided for @exportIncludesArchive.
  ///
  /// In en, this message translates to:
  /// **'• Archive reason and session timing'**
  String get exportIncludesArchive;

  /// No description provided for @exportExcludesIdentity.
  ///
  /// In en, this message translates to:
  /// **'Sensor serials, device IDs, and storage identifiers are not included.'**
  String get exportExcludesIdentity;

  /// No description provided for @shareFormat.
  ///
  /// In en, this message translates to:
  /// **'Share {format}'**
  String shareFormat(String format);

  /// No description provided for @csvExportDescription.
  ///
  /// In en, this message translates to:
  /// **'Best for importing into most spreadsheet and analysis apps.'**
  String get csvExportDescription;

  /// No description provided for @txtExportDescription.
  ///
  /// In en, this message translates to:
  /// **'A tab-separated plain-text file that is easy to inspect anywhere.'**
  String get txtExportDescription;

  /// No description provided for @xlsxExportDescription.
  ///
  /// In en, this message translates to:
  /// **'A real Excel workbook with glucose measurements stored as numbers.'**
  String get xlsxExportDescription;

  /// No description provided for @archivedSensorExportPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing export…'**
  String get archivedSensorExportPreparing;

  /// No description provided for @archivedSensorExportSharing.
  ///
  /// In en, this message translates to:
  /// **'Sharing export…'**
  String get archivedSensorExportSharing;

  /// No description provided for @archivedSensorExportFinishing.
  ///
  /// In en, this message translates to:
  /// **'Finishing export…'**
  String get archivedSensorExportFinishing;

  /// No description provided for @archivedSensorExportFailed.
  ///
  /// In en, this message translates to:
  /// **'The archived sensor data could not be exported.'**
  String get archivedSensorExportFailed;

  /// No description provided for @archiveReasonExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get archiveReasonExpired;

  /// No description provided for @archiveReasonReplaced.
  ///
  /// In en, this message translates to:
  /// **'Replaced'**
  String get archiveReasonReplaced;

  /// No description provided for @archiveReasonDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get archiveReasonDisconnected;

  /// No description provided for @storedInMacAppContainer.
  ///
  /// In en, this message translates to:
  /// **'Stored in this Mac app container'**
  String get storedInMacAppContainer;

  /// No description provided for @storedOnIphone.
  ///
  /// In en, this message translates to:
  /// **'Stored on this iPhone'**
  String get storedOnIphone;

  /// No description provided for @localDataMacDescription.
  ///
  /// In en, this message translates to:
  /// **'Sensor identity and glucose history remain local. Backup exclusion is not verified for this preview; check this Mac\'s backup policy.'**
  String get localDataMacDescription;

  /// No description provided for @localDataIphoneDescription.
  ///
  /// In en, this message translates to:
  /// **'Sensor identity and glucose history remain local and are excluded from device backups.'**
  String get localDataIphoneDescription;

  /// No description provided for @noOpenGlucoseCloud.
  ///
  /// In en, this message translates to:
  /// **'No OpenGlucose cloud'**
  String get noOpenGlucoseCloud;

  /// No description provided for @noOpenGlucoseCloudDescription.
  ///
  /// In en, this message translates to:
  /// **'Data leaves the app only when you explicitly enable an integration.'**
  String get noOpenGlucoseCloudDescription;

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String appVersion(String version);

  /// No description provided for @aboutAppDescription.
  ///
  /// In en, this message translates to:
  /// **'A local-first, open-source wellness app for viewing your own glucose data. OpenGlucose is not a medical device and does not provide diagnosis or treatment advice.'**
  String get aboutAppDescription;

  /// No description provided for @displaySettings.
  ///
  /// In en, this message translates to:
  /// **'Display settings'**
  String get displaySettings;

  /// No description provided for @targetLowMgdl.
  ///
  /// In en, this message translates to:
  /// **'Target low (mg/dL)'**
  String get targetLowMgdl;

  /// No description provided for @targetHighMgdl.
  ///
  /// In en, this message translates to:
  /// **'Target high (mg/dL)'**
  String get targetHighMgdl;

  /// No description provided for @reviewSelectedInterruptedMove.
  ///
  /// In en, this message translates to:
  /// **'Review interrupted move'**
  String get reviewSelectedInterruptedMove;

  /// No description provided for @removeAllSensorPhoneBonds.
  ///
  /// In en, this message translates to:
  /// **'Remove all sensor phone bonds?'**
  String get removeAllSensorPhoneBonds;

  /// No description provided for @moveSensorToAnotherPhoneQuestion.
  ///
  /// In en, this message translates to:
  /// **'Move sensor to another phone?'**
  String get moveSensorToAnotherPhoneQuestion;

  /// No description provided for @removeAllSensorPhoneBondsDescription.
  ///
  /// In en, this message translates to:
  /// **'This sensor only supports removing every phone bond stored by the transmitter. It will disconnect from this phone and all other phones. The sensor session is not reset. Keep the sensor close and do not retry if an error appears.'**
  String get removeAllSensorPhoneBondsDescription;

  /// No description provided for @moveSensorToAnotherPhoneDescription.
  ///
  /// In en, this message translates to:
  /// **'This removes this phone\'s bond from the sensor and Android, then disconnects. The sensor session is not reset. Keep the sensor close and do not retry if an error appears.'**
  String get moveSensorToAnotherPhoneDescription;

  /// No description provided for @moveSensor.
  ///
  /// In en, this message translates to:
  /// **'Move sensor'**
  String get moveSensor;

  /// No description provided for @sensorReadyToPairAnotherPhone.
  ///
  /// In en, this message translates to:
  /// **'Sensor is ready to pair with another phone.'**
  String get sensorReadyToPairAnotherPhone;

  /// No description provided for @sensorCannotMoveSafely.
  ///
  /// In en, this message translates to:
  /// **'The sensor cannot be moved safely.'**
  String get sensorCannotMoveSafely;

  /// No description provided for @sensorTransferStopped.
  ///
  /// In en, this message translates to:
  /// **'Sensor transfer stopped. Do not retry automatically.'**
  String get sensorTransferStopped;

  /// No description provided for @developer.
  ///
  /// In en, this message translates to:
  /// **'Developer'**
  String get developer;

  /// No description provided for @mockScenario.
  ///
  /// In en, this message translates to:
  /// **'Mock scenario'**
  String get mockScenario;

  /// No description provided for @simulatedSensorState.
  ///
  /// In en, this message translates to:
  /// **'Simulated sensor state'**
  String get simulatedSensorState;

  /// No description provided for @engineeringControls.
  ///
  /// In en, this message translates to:
  /// **'Engineering controls'**
  String get engineeringControls;

  /// No description provided for @engineeringControlsDescription.
  ///
  /// In en, this message translates to:
  /// **'Advanced corrections for diagnostics and sensor-data troubleshooting.'**
  String get engineeringControlsDescription;

  /// No description provided for @calibrationScale.
  ///
  /// In en, this message translates to:
  /// **'Calibration scale'**
  String get calibrationScale;

  /// No description provided for @calibrationOffset.
  ///
  /// In en, this message translates to:
  /// **'Calibration offset'**
  String get calibrationOffset;

  /// No description provided for @cropFirstSamples.
  ///
  /// In en, this message translates to:
  /// **'Crop first N samples'**
  String get cropFirstSamples;

  /// No description provided for @engineeringValuesInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter valid engineering correction values.'**
  String get engineeringValuesInvalid;

  /// No description provided for @engineeringSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Engineering settings saved.'**
  String get engineeringSettingsSaved;

  /// No description provided for @saveEngineeringSettings.
  ///
  /// In en, this message translates to:
  /// **'Save engineering settings'**
  String get saveEngineeringSettings;

  /// No description provided for @clearActiveSensorCache.
  ///
  /// In en, this message translates to:
  /// **'Clear active sensor cache'**
  String get clearActiveSensorCache;

  /// No description provided for @clearActiveSensorCacheDescription.
  ///
  /// In en, this message translates to:
  /// **'Clears only the active sensor’s local cache. Sensor archive is not deleted, and available readings may download again from the sensor.'**
  String get clearActiveSensorCacheDescription;

  /// No description provided for @metadata.
  ///
  /// In en, this message translates to:
  /// **'Metadata'**
  String get metadata;

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnostics;

  /// No description provided for @noDiagnosticsLoaded.
  ///
  /// In en, this message translates to:
  /// **'No diagnostics loaded yet.'**
  String get noDiagnosticsLoaded;

  /// No description provided for @calibrations.
  ///
  /// In en, this message translates to:
  /// **'Calibrations'**
  String get calibrations;

  /// No description provided for @noCalibrationEntries.
  ///
  /// In en, this message translates to:
  /// **'No calibration entries loaded.'**
  String get noCalibrationEntries;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// No description provided for @noLogs.
  ///
  /// In en, this message translates to:
  /// **'No logs yet.'**
  String get noLogs;

  /// No description provided for @clearActiveSensorCacheQuestion.
  ///
  /// In en, this message translates to:
  /// **'Clear active sensor cache?'**
  String get clearActiveSensorCacheQuestion;

  /// No description provided for @clearActiveSensorCacheReview.
  ///
  /// In en, this message translates to:
  /// **'This removes only the locally cached history for the active sensor. Archived sensors are kept, and available readings may download again.'**
  String get clearActiveSensorCacheReview;

  /// No description provided for @clearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get clearCache;

  /// No description provided for @activeSensorCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Active sensor cache cleared.'**
  String get activeSensorCacheCleared;

  /// No description provided for @noActiveSensorCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'No active sensor cache was cleared.'**
  String get noActiveSensorCacheCleared;

  /// No description provided for @timeframeHoursShort.
  ///
  /// In en, this message translates to:
  /// **'{hours}h'**
  String timeframeHoursShort(int hours);

  /// No description provided for @timeframeDaysShort.
  ///
  /// In en, this message translates to:
  /// **'{days}d'**
  String timeframeDaysShort(int days);

  /// No description provided for @timeframeAll.
  ///
  /// In en, this message translates to:
  /// **'ALL'**
  String get timeframeAll;

  /// No description provided for @chartMinute.
  ///
  /// In en, this message translates to:
  /// **'Minute {minute}'**
  String chartMinute(int minute);

  /// No description provided for @chartAxisMinute.
  ///
  /// In en, this message translates to:
  /// **'m{minute}'**
  String chartAxisMinute(int minute);

  /// No description provided for @patternsDescription.
  ///
  /// In en, this message translates to:
  /// **'Observations for self-experimentation, not medical metrics.'**
  String get patternsDescription;

  /// No description provided for @timeInRange.
  ///
  /// In en, this message translates to:
  /// **'Time in range'**
  String get timeInRange;

  /// No description provided for @belowAbove.
  ///
  /// In en, this message translates to:
  /// **'Below / above'**
  String get belowAbove;

  /// No description provided for @belowAboveRange.
  ///
  /// In en, this message translates to:
  /// **'Below / above range'**
  String get belowAboveRange;

  /// No description provided for @average.
  ///
  /// In en, this message translates to:
  /// **'Average'**
  String get average;

  /// No description provided for @variabilityCv.
  ///
  /// In en, this message translates to:
  /// **'Variability (CV)'**
  String get variabilityCv;

  /// No description provided for @estimatedGmi.
  ///
  /// In en, this message translates to:
  /// **'Estimated GMI'**
  String get estimatedGmi;

  /// No description provided for @spikes.
  ///
  /// In en, this message translates to:
  /// **'Spikes'**
  String get spikes;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @timeInRangeExplanation.
  ///
  /// In en, this message translates to:
  /// **'Share of readings between {low} and {high}.'**
  String timeInRangeExplanation(String low, String high);

  /// No description provided for @belowAboveExplanation.
  ///
  /// In en, this message translates to:
  /// **'How often readings were below the low mark or above the high mark.'**
  String get belowAboveExplanation;

  /// No description provided for @averageExplanation.
  ///
  /// In en, this message translates to:
  /// **'Mean of all readings in this time window.'**
  String get averageExplanation;

  /// No description provided for @variabilityExplanation.
  ///
  /// In en, this message translates to:
  /// **'How spread out readings are around the average (SD {standardDeviation}). Lower looks steadier.'**
  String variabilityExplanation(String standardDeviation);

  /// No description provided for @estimatedGmiExplanation.
  ///
  /// In en, this message translates to:
  /// **'A rough indicator derived from the 14-day average glucose. Not a lab result.'**
  String get estimatedGmiExplanation;

  /// No description provided for @spikesExplanation.
  ///
  /// In en, this message translates to:
  /// **'Times readings rose past {high}.'**
  String spikesExplanation(String high);

  /// No description provided for @patternsInsufficientCoverage.
  ///
  /// In en, this message translates to:
  /// **'Not enough readings in this {timeframe} window yet. {readingCount, plural, =0{No readings} one{{readingCount} reading} other{{readingCount} readings}} across {activeDays, plural, =0{0 days} one{{activeDays} day} other{{activeDays} days}}; patterns appear after at least {minimumReadings} readings across {minimumActiveDays, plural, one{{minimumActiveDays} day} other{{minimumActiveDays} days}}.'**
  String patternsInsufficientCoverage(
    String timeframe,
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  );

  /// No description provided for @samplePreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'See how OpenGlucose works'**
  String get samplePreviewTitle;

  /// No description provided for @samplePreviewDescription.
  ///
  /// In en, this message translates to:
  /// **'This private preview is generated in memory. It cannot connect, export, notify, or be mixed with your real glucose history.'**
  String get samplePreviewDescription;

  /// No description provided for @glucoseHistory.
  ///
  /// In en, this message translates to:
  /// **'Glucose history'**
  String get glucoseHistory;

  /// No description provided for @sampleBadge.
  ///
  /// In en, this message translates to:
  /// **'SAMPLE'**
  String get sampleBadge;

  /// No description provided for @sampleWeeklyRecap.
  ///
  /// In en, this message translates to:
  /// **'Sample weekly recap'**
  String get sampleWeeklyRecap;

  /// No description provided for @sensorLifecycle.
  ///
  /// In en, this message translates to:
  /// **'Sensor lifecycle'**
  String get sensorLifecycle;

  /// No description provided for @sensorLifecycleUnknownBody.
  ///
  /// In en, this message translates to:
  /// **'Life remaining is unavailable while the sensor session is being verified.'**
  String get sensorLifecycleUnknownBody;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// No description provided for @expiringSoon.
  ///
  /// In en, this message translates to:
  /// **'Expiring soon'**
  String get expiringSoon;

  /// No description provided for @expired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expired;

  /// No description provided for @lifeUsed.
  ///
  /// In en, this message translates to:
  /// **'used'**
  String get lifeUsed;

  /// No description provided for @warmupTimeLeft.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min left'**
  String warmupTimeLeft(int minutes);

  /// No description provided for @sensorAge.
  ///
  /// In en, this message translates to:
  /// **'Sensor age'**
  String get sensorAge;

  /// No description provided for @timeRemaining.
  ///
  /// In en, this message translates to:
  /// **'Time remaining'**
  String get timeRemaining;

  /// No description provided for @totalLife.
  ///
  /// In en, this message translates to:
  /// **'Total life'**
  String get totalLife;

  /// No description provided for @sensorTotalLife.
  ///
  /// In en, this message translates to:
  /// **'{days} days'**
  String sensorTotalLife(int days);

  /// No description provided for @lastSync.
  ///
  /// In en, this message translates to:
  /// **'Last sync'**
  String get lastSync;

  /// No description provided for @notYet.
  ///
  /// In en, this message translates to:
  /// **'Not yet'**
  String get notYet;

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String minutesAgo(int count);

  /// No description provided for @hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one{hour} other{hours}} ago'**
  String hoursAgo(int count);

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one{day} other{days}} ago'**
  String daysAgo(int count);

  /// No description provided for @sensorWarmupLifecycleBanner.
  ///
  /// In en, this message translates to:
  /// **'Warming up — readings stabilize after the first hour. Keep the sensor on and your phone nearby.'**
  String get sensorWarmupLifecycleBanner;

  /// No description provided for @sensorExpiringSoonBanner.
  ///
  /// In en, this message translates to:
  /// **'This sensor expires in {remaining}. Have a replacement ready so you do not miss readings.'**
  String sensorExpiringSoonBanner(String remaining);

  /// No description provided for @sensorExpiredDetails.
  ///
  /// In en, this message translates to:
  /// **'This sensor reached the end of its 15-day life. The readings below are frozen at the last known values — they are kept for your records but are no longer live.'**
  String get sensorExpiredDetails;

  /// No description provided for @lastReadingPreservedBelow.
  ///
  /// In en, this message translates to:
  /// **'Last reading is preserved below.'**
  String get lastReadingPreservedBelow;

  /// No description provided for @lastReadingAndHistoryPreserved.
  ///
  /// In en, this message translates to:
  /// **'Last reading {time}. Your history is preserved.'**
  String lastReadingAndHistoryPreserved(String time);

  /// No description provided for @nextSteps.
  ///
  /// In en, this message translates to:
  /// **'Next steps'**
  String get nextSteps;

  /// No description provided for @replaceExpiredSensorStep.
  ///
  /// In en, this message translates to:
  /// **'Remove and dispose of the expired sensor.'**
  String get replaceExpiredSensorStep;

  /// No description provided for @applyReplacementSensorStep.
  ///
  /// In en, this message translates to:
  /// **'Apply a new Aidex X sensor and wait for about 1 hour of warmup.'**
  String get applyReplacementSensorStep;

  /// No description provided for @startNewSensorSessionStep.
  ///
  /// In en, this message translates to:
  /// **'Tap below to start a new sensor session.'**
  String get startNewSensorSessionStep;

  /// No description provided for @replaceSensor.
  ///
  /// In en, this message translates to:
  /// **'Replace sensor'**
  String get replaceSensor;

  /// No description provided for @weeklyRecapDescription.
  ///
  /// In en, this message translates to:
  /// **'Patterns and observations from your last 7 days — for self-experimentation, not medical advice.'**
  String get weeklyRecapDescription;

  /// No description provided for @weeklyOverviewTitle.
  ///
  /// In en, this message translates to:
  /// **'This week at a glance'**
  String get weeklyOverviewTitle;

  /// No description provided for @weeklyOverviewSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{activeDays} of 7 days with readings · {readingCount, plural, one{{readingCount} reading} other{{readingCount} readings}}.'**
  String weeklyOverviewSubtitle(int activeDays, int readingCount);

  /// No description provided for @belowAboveRangeExplanation.
  ///
  /// In en, this message translates to:
  /// **'Share of readings below your low mark and above your high mark.'**
  String get belowAboveRangeExplanation;

  /// No description provided for @weeklyAverageExplanation.
  ///
  /// In en, this message translates to:
  /// **'Mean of every reading this week.'**
  String get weeklyAverageExplanation;

  /// No description provided for @lowestHighest.
  ///
  /// In en, this message translates to:
  /// **'Lowest / highest'**
  String get lowestHighest;

  /// No description provided for @observedRangeExplanation.
  ///
  /// In en, this message translates to:
  /// **'Observed range inside this seven-day window.'**
  String get observedRangeExplanation;

  /// No description provided for @variabilityExplanationNoSd.
  ///
  /// In en, this message translates to:
  /// **'How spread out readings are around the average. Lower looks steadier.'**
  String get variabilityExplanationNoSd;

  /// No description provided for @dataCoverage.
  ///
  /// In en, this message translates to:
  /// **'Data coverage'**
  String get dataCoverage;

  /// No description provided for @dataCoverageDescription.
  ///
  /// In en, this message translates to:
  /// **'How much information this recap is based on.'**
  String get dataCoverageDescription;

  /// No description provided for @timestampedReadingsExplanation.
  ///
  /// In en, this message translates to:
  /// **'Timestamped readings inside this seven-day window.'**
  String get timestampedReadingsExplanation;

  /// No description provided for @daysRepresented.
  ///
  /// In en, this message translates to:
  /// **'Days represented'**
  String get daysRepresented;

  /// No description provided for @daysRepresentedExplanation.
  ///
  /// In en, this message translates to:
  /// **'Calendar days containing at least one reading.'**
  String get daysRepresentedExplanation;

  /// No description provided for @observedSpan.
  ///
  /// In en, this message translates to:
  /// **'Observed span'**
  String get observedSpan;

  /// No description provided for @observedSpanExplanation.
  ///
  /// In en, this message translates to:
  /// **'Time between the first and last included reading.'**
  String get observedSpanExplanation;

  /// No description provided for @durationDays.
  ///
  /// In en, this message translates to:
  /// **'{value} days'**
  String durationDays(String value);

  /// No description provided for @durationHours.
  ///
  /// In en, this message translates to:
  /// **'{value} {value, plural, one{hour} other{hours}}'**
  String durationHours(int value);

  /// No description provided for @daysOfSeven.
  ///
  /// In en, this message translates to:
  /// **'{activeDays} of 7'**
  String daysOfSeven(int activeDays);

  /// No description provided for @versusLastWeek.
  ///
  /// In en, this message translates to:
  /// **'Versus last week'**
  String get versusLastWeek;

  /// No description provided for @weekOverWeekChange.
  ///
  /// In en, this message translates to:
  /// **'Week-over-week change.'**
  String get weekOverWeekChange;

  /// No description provided for @previousWeekComparisonDescription.
  ///
  /// In en, this message translates to:
  /// **'The previous week has {readingCount, plural, =0{no readings} one{{readingCount} reading} other{{readingCount} readings}} across {activeDays, plural, =0{0 days} one{{activeDays} day} other{{activeDays} days}}. Comparisons appear only when both weeks have enough coverage.'**
  String previousWeekComparisonDescription(int readingCount, int activeDays);

  /// No description provided for @versusLastWeekDescription.
  ///
  /// In en, this message translates to:
  /// **'How this week compares with the seven days before.'**
  String get versusLastWeekDescription;

  /// No description provided for @noPriorWeek.
  ///
  /// In en, this message translates to:
  /// **'no prior week'**
  String get noPriorWeek;

  /// No description provided for @aboutTheSame.
  ///
  /// In en, this message translates to:
  /// **'about the same'**
  String get aboutTheSame;

  /// No description provided for @percentagePoints.
  ///
  /// In en, this message translates to:
  /// **'{value} pts'**
  String percentagePoints(String value);

  /// No description provided for @daysByTimeInRange.
  ///
  /// In en, this message translates to:
  /// **'Days by time in range'**
  String get daysByTimeInRange;

  /// No description provided for @daysByTimeInRangeDescription.
  ///
  /// In en, this message translates to:
  /// **'Ranked by time spent in range.'**
  String get daysByTimeInRangeDescription;

  /// No description provided for @mostInRange.
  ///
  /// In en, this message translates to:
  /// **'Most in range'**
  String get mostInRange;

  /// No description provided for @leastInRange.
  ///
  /// In en, this message translates to:
  /// **'Least in range'**
  String get leastInRange;

  /// No description provided for @weekdayRangeSummary.
  ///
  /// In en, this message translates to:
  /// **'{day} · {percent}% in range · avg {average}'**
  String weekdayRangeSummary(String day, int percent, String average);

  /// No description provided for @topSpikes.
  ///
  /// In en, this message translates to:
  /// **'Top spikes'**
  String get topSpikes;

  /// No description provided for @topSpikesDescription.
  ///
  /// In en, this message translates to:
  /// **'Biggest upward swings this week.'**
  String get topSpikesDescription;

  /// No description provided for @noSpikesThisWeek.
  ///
  /// In en, this message translates to:
  /// **'No readings rose past {high} this week.'**
  String noSpikesThisWeek(String high);

  /// No description provided for @spikeRiseExplanation.
  ///
  /// In en, this message translates to:
  /// **'Rose {amount} from {baseline}.'**
  String spikeRiseExplanation(String amount, String baseline);

  /// No description provided for @weeklyDailyAveragesTitle.
  ///
  /// In en, this message translates to:
  /// **'This week\'s daily averages'**
  String get weeklyDailyAveragesTitle;

  /// No description provided for @weeklyDailyAveragesDescription.
  ///
  /// In en, this message translates to:
  /// **'Average reading for each day in this seven-day window.'**
  String get weeklyDailyAveragesDescription;

  /// No description provided for @notEnoughReadingsYet.
  ///
  /// In en, this message translates to:
  /// **'Not enough readings yet'**
  String get notEnoughReadingsYet;

  /// No description provided for @weeklyInsufficientCoverage.
  ///
  /// In en, this message translates to:
  /// **'This seven-day window currently has {readingCount, plural, =0{no readings} one{{readingCount} reading} other{{readingCount} readings}} across {activeDays, plural, =0{0 days} one{{activeDays} day} other{{activeDays} days}}. Patterns appear after at least {minimumReadings} readings across {minimumActiveDays, plural, one{{minimumActiveDays} day} other{{minimumActiveDays} days}}, so sparse history is not presented as a reliable trend.'**
  String weeklyInsufficientCoverage(
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  );

  /// No description provided for @weeklyRecapDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'These are wellness observations for self-experimentation. OpenGlucose is not a medical device, and this recap is not a diagnosis or medical advice. Consult a qualified professional for health decisions.'**
  String get weeklyRecapDisclaimer;

  /// No description provided for @aiInsights.
  ///
  /// In en, this message translates to:
  /// **'AI insights'**
  String get aiInsights;

  /// No description provided for @onDeviceModel.
  ///
  /// In en, this message translates to:
  /// **'On-device model'**
  String get onDeviceModel;

  /// No description provided for @onDeviceModelDescription.
  ///
  /// In en, this message translates to:
  /// **'Planned · private local inference with a downloaded model'**
  String get onDeviceModelDescription;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @onDeviceModelStatus.
  ///
  /// In en, this message translates to:
  /// **'On-device model status: {status}'**
  String onDeviceModelStatus(String status);

  /// No description provided for @aiWellnessPrivacyNotice.
  ///
  /// In en, this message translates to:
  /// **'Wellness and self-experimentation only—not medical advice, diagnosis, or dosing. AI remains off unless you explicitly configure it. A future on-device model will keep inference local; the advanced cloud option below sends only aggregate statistics, never raw readings or note text.'**
  String get aiWellnessPrivacyNotice;

  /// No description provided for @customCloudProvider.
  ///
  /// In en, this message translates to:
  /// **'Custom cloud provider'**
  String get customCloudProvider;

  /// No description provided for @advancedSendsAggregatesOffDevice.
  ///
  /// In en, this message translates to:
  /// **'Advanced · sends aggregates off-device'**
  String get advancedSendsAggregatesOffDevice;

  /// No description provided for @enableCloudAi.
  ///
  /// In en, this message translates to:
  /// **'Enable cloud AI'**
  String get enableCloudAi;

  /// No description provided for @cloudAiDisabledByDefault.
  ///
  /// In en, this message translates to:
  /// **'Off by default. Requires your own API key.'**
  String get cloudAiDisabledByDefault;

  /// No description provided for @apiBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'API base URL'**
  String get apiBaseUrl;

  /// No description provided for @aiModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiModel;

  /// No description provided for @authScheme.
  ///
  /// In en, this message translates to:
  /// **'Auth scheme'**
  String get authScheme;

  /// No description provided for @authSchemeBearer.
  ///
  /// In en, this message translates to:
  /// **'Bearer (OpenAI-compatible)'**
  String get authSchemeBearer;

  /// No description provided for @authSchemeXApiKey.
  ///
  /// In en, this message translates to:
  /// **'x-api-key (Anthropic)'**
  String get authSchemeXApiKey;

  /// No description provided for @apiKeyStoredSecurely.
  ///
  /// In en, this message translates to:
  /// **'API key (stored securely)'**
  String get apiKeyStoredSecurely;

  /// No description provided for @apiKeySavedMask.
  ///
  /// In en, this message translates to:
  /// **'•••••••• (saved)'**
  String get apiKeySavedMask;

  /// No description provided for @pasteApiKey.
  ///
  /// In en, this message translates to:
  /// **'Paste your key'**
  String get pasteApiKey;

  /// No description provided for @apiKeySavedHint.
  ///
  /// In en, this message translates to:
  /// **'A key is saved. Leave blank to keep it.'**
  String get apiKeySavedHint;

  /// No description provided for @apiKeyPlainTextHint.
  ///
  /// In en, this message translates to:
  /// **'Never stored in plain text.'**
  String get apiKeyPlainTextHint;

  /// No description provided for @saveProvider.
  ///
  /// In en, this message translates to:
  /// **'Save provider'**
  String get saveProvider;

  /// No description provided for @removeKey.
  ///
  /// In en, this message translates to:
  /// **'Remove key'**
  String get removeKey;

  /// No description provided for @testWithAggregates.
  ///
  /// In en, this message translates to:
  /// **'Test with aggregates'**
  String get testWithAggregates;

  /// No description provided for @providerSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved.'**
  String get providerSettingsSaved;

  /// No description provided for @apiKeyRemoved.
  ///
  /// In en, this message translates to:
  /// **'API key removed.'**
  String get apiKeyRemoved;

  /// No description provided for @savingProviderSettings.
  ///
  /// In en, this message translates to:
  /// **'Saving provider settings…'**
  String get savingProviderSettings;

  /// No description provided for @enableCloudAiBeforeTesting.
  ///
  /// In en, this message translates to:
  /// **'Enable cloud AI before testing.'**
  String get enableCloudAiBeforeTesting;

  /// No description provided for @addApiKeyBeforeTesting.
  ///
  /// In en, this message translates to:
  /// **'Add an API key before testing.'**
  String get addApiKeyBeforeTesting;

  /// No description provided for @generatingAiInsight.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get generatingAiInsight;

  /// No description provided for @aiDisabledOrNoKey.
  ///
  /// In en, this message translates to:
  /// **'AI is disabled or no key set.'**
  String get aiDisabledOrNoKey;

  /// No description provided for @generatedAndSaved.
  ///
  /// In en, this message translates to:
  /// **'Generated & saved: \"{title}\".'**
  String generatedAndSaved(String title);

  /// No description provided for @couldNotGenerateAiInsight.
  ///
  /// In en, this message translates to:
  /// **'Could not generate the AI insight.'**
  String get couldNotGenerateAiInsight;

  /// No description provided for @integrations.
  ///
  /// In en, this message translates to:
  /// **'Integrations'**
  String get integrations;

  /// No description provided for @integrationsIntro.
  ///
  /// In en, this message translates to:
  /// **'Send your glucose readings to other apps you control. Nothing leaves your device unless you turn it on.'**
  String get integrationsIntro;

  /// No description provided for @appleHealthExportDescription.
  ///
  /// In en, this message translates to:
  /// **'When you opt in and tap Sync now, glucose values and timestamps are written to Apple Health as blood glucose samples. An interrupted sync may write a duplicate when retried.'**
  String get appleHealthExportDescription;

  /// No description provided for @appleHealthOnlyOnIos.
  ///
  /// In en, this message translates to:
  /// **'Apple Health is only available on iOS.'**
  String get appleHealthOnlyOnIos;

  /// No description provided for @appleHealthDisabledWithSimulatedData.
  ///
  /// In en, this message translates to:
  /// **'Apple Health export is disabled while using simulated or mock sensor data.'**
  String get appleHealthDisabledWithSimulatedData;

  /// No description provided for @exportToAppleHealth.
  ///
  /// In en, this message translates to:
  /// **'Export to Apple Health'**
  String get exportToAppleHealth;

  /// No description provided for @neverSynced.
  ///
  /// In en, this message translates to:
  /// **'Never synced'**
  String get neverSynced;

  /// No description provided for @lastSyncedAt.
  ///
  /// In en, this message translates to:
  /// **'Last synced {time}'**
  String lastSyncedAt(String time);

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncNow;

  /// No description provided for @appleHealthExportUnavailableInThisMode.
  ///
  /// In en, this message translates to:
  /// **'Apple Health export is unavailable in this mode.'**
  String get appleHealthExportUnavailableInThisMode;

  /// No description provided for @appleHealthAccessNotGranted.
  ///
  /// In en, this message translates to:
  /// **'Apple Health access was not granted.'**
  String get appleHealthAccessNotGranted;

  /// No description provided for @turnOnAppleHealthBeforeSyncing.
  ///
  /// In en, this message translates to:
  /// **'Turn on Apple Health export before syncing.'**
  String get turnOnAppleHealthBeforeSyncing;

  /// No description provided for @appleHealthSyncedReadings.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} {count, plural, one{reading} other{readings}}.'**
  String appleHealthSyncedReadings(int count);

  /// No description provided for @appleHealthSyncPartial.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} {count, plural, one{reading} other{readings}}, then export stopped.'**
  String appleHealthSyncPartial(int count);

  /// No description provided for @appleHealthSyncPartialWithReason.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} {count, plural, one{reading} other{readings}}, then export stopped: {reason}'**
  String appleHealthSyncPartialWithReason(int count, String reason);

  /// No description provided for @appleHealthAlreadyUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Already up to date.'**
  String get appleHealthAlreadyUpToDate;

  /// No description provided for @appleHealthExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed.'**
  String get appleHealthExportFailed;

  /// No description provided for @appleHealthSampleRejected.
  ///
  /// In en, this message translates to:
  /// **'HealthKit rejected a glucose sample.'**
  String get appleHealthSampleRejected;

  /// No description provided for @appleHealthCouldNotSaveSample.
  ///
  /// In en, this message translates to:
  /// **'Apple Health could not save a glucose sample.'**
  String get appleHealthCouldNotSaveSample;

  /// No description provided for @appleHealthExportCouldNotComplete.
  ///
  /// In en, this message translates to:
  /// **'Apple Health export could not be completed.'**
  String get appleHealthExportCouldNotComplete;

  /// No description provided for @appleHealthWritesDisabled.
  ///
  /// In en, this message translates to:
  /// **'Apple Health writes are disabled for this mode.'**
  String get appleHealthWritesDisabled;

  /// No description provided for @macosPreviewLimitations.
  ///
  /// In en, this message translates to:
  /// **'macOS preview limitations'**
  String get macosPreviewLimitations;

  /// No description provided for @macosTransportPreview.
  ///
  /// In en, this message translates to:
  /// **'macOS transport preview'**
  String get macosTransportPreview;

  /// No description provided for @macosTransportPreviewDescription.
  ///
  /// In en, this message translates to:
  /// **'Real AiDEX pairing, reconnect, and live readings are not verified on Mac hardware. This build cannot remove a system Bluetooth bond or run Move sensor. Use the Move sensor action on the current Android phone before a controlled Mac test.'**
  String get macosTransportPreviewDescription;

  /// No description provided for @aiUnavailableInMacosPreview.
  ///
  /// In en, this message translates to:
  /// **'AI unavailable in macOS preview'**
  String get aiUnavailableInMacosPreview;

  /// No description provided for @macosPreviewAiUnavailableDescription.
  ///
  /// In en, this message translates to:
  /// **'This ad-hoc-signed preview cannot supply the macOS Keychain capability required to store an API key. Cloud AI remains disabled. Do not paste a key into this preview.'**
  String get macosPreviewAiUnavailableDescription;

  /// No description provided for @messageWarmupTitle.
  ///
  /// In en, this message translates to:
  /// **'Warming up'**
  String get messageWarmupTitle;

  /// No description provided for @messageWarmupBody.
  ///
  /// In en, this message translates to:
  /// **'Your sensor is settling in. Readings begin after about an hour — no action needed.'**
  String get messageWarmupBody;

  /// No description provided for @messageTapReadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Tip'**
  String get messageTapReadingTitle;

  /// No description provided for @messageTapReadingBody.
  ///
  /// In en, this message translates to:
  /// **'Tap a point on the chart to see the exact reading and time.'**
  String get messageTapReadingBody;

  /// No description provided for @scenarioWarmup.
  ///
  /// In en, this message translates to:
  /// **'Warmup'**
  String get scenarioWarmup;

  /// No description provided for @scenarioActiveNormal.
  ///
  /// In en, this message translates to:
  /// **'Active — normal'**
  String get scenarioActiveNormal;

  /// No description provided for @scenarioActiveHigh.
  ///
  /// In en, this message translates to:
  /// **'Active — high (alert)'**
  String get scenarioActiveHigh;

  /// No description provided for @scenarioActiveLow.
  ///
  /// In en, this message translates to:
  /// **'Active — low (alert)'**
  String get scenarioActiveLow;

  /// No description provided for @scenarioRapidRise.
  ///
  /// In en, this message translates to:
  /// **'Rapid rise'**
  String get scenarioRapidRise;

  /// No description provided for @scenarioRapidFall.
  ///
  /// In en, this message translates to:
  /// **'Rapid fall'**
  String get scenarioRapidFall;

  /// No description provided for @scenarioExpiringSoon.
  ///
  /// In en, this message translates to:
  /// **'Expiring soon'**
  String get scenarioExpiringSoon;

  /// No description provided for @scenarioExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get scenarioExpired;

  /// No description provided for @scenarioSignalLoss.
  ///
  /// In en, this message translates to:
  /// **'Signal loss'**
  String get scenarioSignalLoss;

  /// No description provided for @scenarioDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get scenarioDisconnected;

  /// No description provided for @scenarioMultiSensorHistory.
  ///
  /// In en, this message translates to:
  /// **'Multi-sensor history'**
  String get scenarioMultiSensorHistory;

  /// No description provided for @scenarioError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get scenarioError;

  /// No description provided for @scenarioWarmupDescription.
  ///
  /// In en, this message translates to:
  /// **'Inside the ~1h warmup window — no readings yet.'**
  String get scenarioWarmupDescription;

  /// No description provided for @scenarioActiveNormalDescription.
  ///
  /// In en, this message translates to:
  /// **'Healthy in-range glucose, gently waving.'**
  String get scenarioActiveNormalDescription;

  /// No description provided for @scenarioActiveHighDescription.
  ///
  /// In en, this message translates to:
  /// **'Sustained high glucose — triggers a high alert.'**
  String get scenarioActiveHighDescription;

  /// No description provided for @scenarioActiveLowDescription.
  ///
  /// In en, this message translates to:
  /// **'Sustained low glucose — triggers a low alert.'**
  String get scenarioActiveLowDescription;

  /// No description provided for @scenarioRapidRiseDescription.
  ///
  /// In en, this message translates to:
  /// **'Glucose climbing fast (rising trend).'**
  String get scenarioRapidRiseDescription;

  /// No description provided for @scenarioRapidFallDescription.
  ///
  /// In en, this message translates to:
  /// **'Glucose dropping fast (falling trend).'**
  String get scenarioRapidFallDescription;

  /// No description provided for @scenarioExpiringSoonDescription.
  ///
  /// In en, this message translates to:
  /// **'A few hours left on the 15-day sensor.'**
  String get scenarioExpiringSoonDescription;

  /// No description provided for @scenarioExpiredDescription.
  ///
  /// In en, this message translates to:
  /// **'Sensor expired — offboarding state.'**
  String get scenarioExpiredDescription;

  /// No description provided for @scenarioSignalLossDescription.
  ///
  /// In en, this message translates to:
  /// **'Connected but signal lost — readings are stale.'**
  String get scenarioSignalLossDescription;

  /// No description provided for @scenarioDisconnectedDescription.
  ///
  /// In en, this message translates to:
  /// **'Disconnected with last-known data.'**
  String get scenarioDisconnectedDescription;

  /// No description provided for @scenarioMultiSensorHistoryDescription.
  ///
  /// In en, this message translates to:
  /// **'Current sensor with carried-over previous-sensor history.'**
  String get scenarioMultiSensorHistoryDescription;

  /// No description provided for @scenarioErrorDescription.
  ///
  /// In en, this message translates to:
  /// **'Hard error with no usable data.'**
  String get scenarioErrorDescription;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
