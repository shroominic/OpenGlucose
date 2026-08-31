// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'OpenGlucose';

  @override
  String get settings => 'Settings';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get saveSettings => 'Save settings';

  @override
  String get close => 'Close';

  @override
  String get back => 'Back';

  @override
  String get done => 'Done';

  @override
  String get continueLabel => 'Continue';

  @override
  String get skip => 'Skip';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get tryAgain => 'Try again';

  @override
  String get scanAgain => 'Scan again';

  @override
  String get findMySensor => 'Find my sensor';

  @override
  String get scanning => 'Scanning…';

  @override
  String get nearbySensors => 'Nearby sensors';

  @override
  String sensorsFound(int count) {
    return '$count found';
  }

  @override
  String get noSensorsFound =>
      'No sensors found yet. Hold your phone near your sensor and try again.';

  @override
  String get exploreSampleData => 'Explore sample data';

  @override
  String get sampleDataNotSensor => 'Sample data — not from a sensor';

  @override
  String get sensor => 'Sensor';

  @override
  String get sensors => 'Sensors';

  @override
  String get currentSensor => 'Current sensor';

  @override
  String get connectSensor => 'Connect a sensor';

  @override
  String get sensorArchive => 'Sensor archive';

  @override
  String get glucoseAndDisplay => 'Glucose & display';

  @override
  String get appleHealth => 'Apple Health';

  @override
  String get privacyAndData => 'Privacy & data';

  @override
  String get aboutOpenGlucose => 'About OpenGlucose';

  @override
  String get advanced => 'Advanced';

  @override
  String get language => 'Language';

  @override
  String get appLanguage => 'App language';

  @override
  String get languageSystem => 'Follow device language';

  @override
  String get languageSystemDescription =>
      'Uses Simplified Chinese on Chinese devices and English on other devices.';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => 'Simplified Chinese';

  @override
  String get languageSimplifiedChineseNative => '简体中文';

  @override
  String languageCurrent(String language) {
    return 'Current: $language';
  }

  @override
  String get languageChangeDescription =>
      'Choose the language used throughout OpenGlucose. This does not change your sensor data.';

  @override
  String get sensorStatusSubtitle => 'Status, life, identity, and connection';

  @override
  String get noSensorActive => 'No sensor is active';

  @override
  String get sensorArchiveSubtitle => 'Previous sensor sessions and exports';

  @override
  String get displaySubtitle => 'Units, target range, and chart style';

  @override
  String get appleHealthSubtitle => 'Glucose export and health data controls';

  @override
  String get privacySubtitle => 'Local storage and retention';

  @override
  String get aboutSubtitle => 'Version, purpose, and open-source project';

  @override
  String get advancedSubtitle => 'Diagnostics and developer tools';

  @override
  String get history => 'History';

  @override
  String get patterns => 'Patterns';

  @override
  String get weeklyRecap => 'Weekly recap';

  @override
  String get viewWeeklyRecap => 'View weekly recap';

  @override
  String latestReadingAt(String time) {
    return 'Latest reading at $time';
  }

  @override
  String get supportCodeCopied => 'Support code copied';

  @override
  String get copySupportCode => 'Copy support code';

  @override
  String get chooseAnotherSensor => 'Choose another sensor';

  @override
  String get reviewMove => 'Review move';

  @override
  String get moveNeedsSupport => 'Move needs support';

  @override
  String get moveSensorToAnotherPhone => 'Move sensor to another phone';

  @override
  String get sensorDetails => 'Sensor details';

  @override
  String get serial => 'Serial';

  @override
  String get model => 'Model';

  @override
  String get firmware => 'Firmware';

  @override
  String get sensorStart => 'Sensor start';

  @override
  String readingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings',
      one: 'reading',
    );
    return '$count $_temp0';
  }

  @override
  String get showGlucoseInLiveNotification =>
      'Show glucose in live notification';

  @override
  String get showGlucoseInLiveNotificationDescription =>
      'Allows glucose values, trends, and update times to appear in the Android live notification or iOS Live Activity. Anyone who can view your lock screen may see this health data.';

  @override
  String get showSampleDashboard => 'Open sample dashboard';

  @override
  String get sampleDashboard => 'Sample dashboard';

  @override
  String get openSampleWeeklyRecap => 'Open sample weekly recap';

  @override
  String get welcomeTitle => 'Welcome to OpenGlucose';

  @override
  String get welcomeBody =>
      'An open-source, local-first way to watch your glucose. Built for wellness, sport and self-experimentation — not as a medical device.';

  @override
  String get storedLocallyTitle => 'Stored locally by default';

  @override
  String get storedLocallyBody =>
      'History stays on this device. Optional Apple Health or AI features share data only when you enable them.';

  @override
  String get openSourceTitle => 'Open source & hackable';

  @override
  String get openSourceBody =>
      'MIT-licensed. Inspect it, extend it, make it yours.';

  @override
  String get wellnessDisclaimer =>
      'OpenGlucose is for wellness and self-experimentation. It is not a medical device and not a substitute for medical advice.';

  @override
  String get howItWorksTitle => 'How it works';

  @override
  String get howItWorksBody =>
      'Apply your Aidex X sensor, pair it over Bluetooth, and let it warm up. After that, readings stream straight to your phone.';

  @override
  String get applySensorTitle => 'Apply the sensor';

  @override
  String get applySensorBody =>
      'A small all-in-one sensor you wear for up to 15 days.';

  @override
  String get warmupTitle => 'About 1 hour warm-up';

  @override
  String get warmupBody =>
      'The sensor calibrates itself before the first reading.';

  @override
  String get readingEveryMinuteTitle => 'A reading every minute';

  @override
  String get readingEveryMinuteBody =>
      'Live values and trends, refreshed continuously.';

  @override
  String get targetRangeTitle => 'Set your target range';

  @override
  String get targetRangeBody =>
      'Choose the range you want to stay within. You can change this any time in settings.';

  @override
  String get targetRangeHint =>
      'Most people start with 70–180 mg/dL (about 3.9–10 mmol/L).';

  @override
  String get readyTitle => 'You\'re all set';

  @override
  String get readyBody =>
      'Have your Aidex X sensor on and nearby. We’ll scan for it over Bluetooth and connect — then your live dashboard takes over.';

  @override
  String get turnOnBluetoothTitle => 'Turn on Bluetooth';

  @override
  String get turnOnBluetoothBody =>
      'Keep your phone close to the sensor while it pairs.';

  @override
  String get watchItComeAliveTitle => 'Watch it come alive';

  @override
  String get watchItComeAliveBody =>
      'Trends and readings appear as soon as warm-up finishes.';

  @override
  String get connectMySensor => 'Connect my sensor';

  @override
  String get lifeRemainingUnavailable => 'Life remaining unavailable';

  @override
  String get sensorExpired => 'Sensor expired';

  @override
  String hoursLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hours',
      one: 'hour',
    );
    return '$count $_temp0 left';
  }

  @override
  String daysLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'days',
      one: 'day',
    );
    return '$count $_temp0 left';
  }

  @override
  String get minutesShort => 'min';

  @override
  String get waitingForFirstReading => 'waiting for first reading';

  @override
  String get warmingUp => 'Warming up';

  @override
  String get warmupComplete => 'Warmup complete';

  @override
  String get warmup => 'Warmup';

  @override
  String get waiting => 'Waiting';

  @override
  String get notSyncedYet => 'Not synced yet';

  @override
  String get syncedJustNow => 'Synced just now';

  @override
  String syncedMinutesAgo(int count) {
    return 'Synced $count min ago';
  }

  @override
  String syncedHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hours',
      one: 'hour',
    );
    return 'Synced $count $_temp0 ago';
  }

  @override
  String syncedDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'days',
      one: 'day',
    );
    return 'Synced $count $_temp0 ago';
  }

  @override
  String get stageError => 'Error';

  @override
  String get stageDisconnected => 'Disconnected';

  @override
  String get stageReconnecting => 'Reconnecting';

  @override
  String get stageSettingUp => 'Setting up';

  @override
  String get stageConnected => 'Connected';

  @override
  String get stageConnecting => 'Connecting';

  @override
  String get stageLive => 'Live';

  @override
  String get attentionNeeded => 'Attention needed';

  @override
  String updatedAt(String time) {
    return 'Updated $time';
  }

  @override
  String get openAppToViewGlucose => 'Open the app to view your glucose';

  @override
  String get sensorWarmingUp => 'Sensor warming up';

  @override
  String get waitingForSensor => 'Waiting for sensor';

  @override
  String get waitingForGlucoseUpdate => 'Waiting for glucose update';

  @override
  String get stale => 'Stale';

  @override
  String get glucoseUnavailable => 'Glucose unavailable';

  @override
  String get bluetoothPermissionRequired =>
      'OpenGlucose needs Bluetooth access. In your phone settings, allow Bluetooth and any nearby-device permissions requested by the app. Some phones also require Location to be allowed and turned on for scanning. Then try again.';

  @override
  String get bluetoothOff =>
      'Bluetooth is off. Turn it on in your phone\'s quick settings or Settings, then try scanning again.';

  @override
  String get bluetoothUnavailable =>
      'Bluetooth is not available on this phone right now. Restart Bluetooth or the phone, then try again.';

  @override
  String get pairingRejected =>
      'The phone did not complete pairing. Keep it close and accept the pairing prompt. If this sensor is already bonded or connected to another phone, stop that connection before trying again. Do not reset an active sensor.';

  @override
  String get pairingTimedOut =>
      'Pairing timed out. Keep the phone close and accept the system pairing prompt. If another phone is using this sensor, stop that connection before trying again.';

  @override
  String get sensorPossiblyInUse =>
      'The sensor became unavailable during setup. It may be out of range or already bonded or connected to another phone. Keep it close and stop the other connection, if applicable, before trying again. Do not reset an active sensor.';

  @override
  String get sensorDisconnected =>
      'The sensor disconnected. Keep the phone close and try again.';

  @override
  String get bluetoothSetupTimedOut =>
      'Bluetooth setup timed out. Keep the phone close and try again.';

  @override
  String get bluetoothSetupFailed =>
      'Bluetooth setup could not be completed. Restart Bluetooth and try again.';

  @override
  String get appPurpose =>
      'OpenGlucose is wellness/reference software, not a medical device. Do not use it for diagnosis, medication or insulin dosing, treatment decisions, or emergency monitoring.';

  @override
  String get unit => 'Unit';

  @override
  String get chartStyle => 'Chart style';

  @override
  String get targetLow => 'Target low (mg/dL)';

  @override
  String get targetHigh => 'Target high (mg/dL)';

  @override
  String get targetRangeInvalid => 'Enter an increasing target glucose range.';

  @override
  String get line => 'Line';

  @override
  String get dots => 'Dots';

  @override
  String get candles => 'Candles';

  @override
  String get preferencesSection => 'Preferences';

  @override
  String get dataAndIntegrationsSection => 'Data & integrations';

  @override
  String get appSection => 'App';

  @override
  String archivedSensorsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sensors',
      one: 'sensor',
    );
    return '$count previous $_temp0';
  }

  @override
  String get aiAndModels => 'AI & models';

  @override
  String get noActiveSensor => 'No active sensor';

  @override
  String get previousDataStaysOnThisPhone =>
      'Your previous data stays on this phone.';

  @override
  String get inactiveSensorExpired =>
      'Your last sensor expired. Your previous readings are still here—connect a new sensor to resume live glucose.';

  @override
  String get inactiveSensorReplaced =>
      'Your previous sensor was replaced. Its readings are still here—connect your new sensor to resume live glucose.';

  @override
  String get inactiveSensorDisconnected =>
      'No sensor is active. Your previous readings are still here—connect a sensor to resume live glucose.';

  @override
  String get inactiveSensorWelcome =>
      'Your glucose, on your terms. Connect your sensor to see live readings and trends.';

  @override
  String get bluetoothOffTitle => 'Bluetooth is off';

  @override
  String get bluetoothPermissionTitle => 'Bluetooth access needed';

  @override
  String get bluetoothUnavailableTitle => 'Bluetooth is unavailable';

  @override
  String get scanSensorsFailedTitle => 'Could not scan for sensors';

  @override
  String get scanSensorHelp =>
      'Check Bluetooth, keep the sensor nearby, and try again.';

  @override
  String get scanSensorHelpShort => 'Check Bluetooth and try scanning again.';

  @override
  String get yourGlucoseHistory => 'Your glucose history';

  @override
  String get firstReading => 'First reading';

  @override
  String get latestReading => 'Latest reading';

  @override
  String get storedSessions => 'Stored sessions';

  @override
  String get historySessionSeparation =>
      'Each sensor keeps its own chart in Sensor archive, so separate sessions are never joined into one line.';

  @override
  String get demoDataWarning => 'DEMO DATA — NOT REAL GLUCOSE';

  @override
  String lastAt(String time) {
    return 'last $time';
  }

  @override
  String failedToStart(String error) {
    return 'Failed to start: $error';
  }

  @override
  String counter(int count) {
    return 'Counter $count';
  }

  @override
  String get demoTransport => 'Demo transport';

  @override
  String get unknownSensorResponse =>
      'The sensor response is unknown. Do not reconnect or forget the Android bond. Contact support for a reviewed recovery.';

  @override
  String get reviewInterruptedSensorMove => 'Review interrupted sensor move';

  @override
  String get interruptedSensorMoveReview =>
      'Open Android Bluetooth settings before you continue. Confirm that the sensor is not listed as paired. If it is listed, choose Forget first. This action only clears the app safety marker. It does not contact the sensor or change a Bluetooth bond.';

  @override
  String get interruptedSelectedSensorMoveReview =>
      'Open Android Bluetooth settings. Confirm that the sensor is not listed as paired. If it is listed, choose Forget first. Continuing clears the app safety marker and archives this selection. It does not contact the sensor or change a Bluetooth bond.';

  @override
  String get checkedBluetooth => 'I checked Bluetooth';

  @override
  String get interruptedSensorMoveCouldNotClear =>
      'The interrupted sensor move could not be cleared.';

  @override
  String get sensorNoLongerActive => 'This sensor is no longer active';

  @override
  String get inactiveSensorSettingsDescription =>
      'Return to Settings to review Sensor archive or connect another sensor.';

  @override
  String get backToSettings => 'Back to Settings';

  @override
  String get sensorArchiveEmpty =>
      'Previous sensors will appear here after they expire or are replaced.';

  @override
  String get previousSensor => 'Previous sensor';

  @override
  String archiveSessionSummary(String reason, String readings, String date) {
    return '$reason · $readings$date';
  }

  @override
  String archiveHistoryOnly(String reason) {
    return '$reason · history only, not connected';
  }

  @override
  String get readings => 'Readings';

  @override
  String get started => 'Started';

  @override
  String get ended => 'Ended';

  @override
  String get recapThisSensor => 'Recap this sensor';

  @override
  String get exportData => 'Export data';

  @override
  String get exportArchivedSensorData => 'Export archived sensor data';

  @override
  String storedGlucoseReadings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings',
      one: 'reading',
    );
    return '$count stored glucose $_temp0';
  }

  @override
  String hiddenWarmupDisclosure(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings are',
      one: 'reading is',
    );
    return '$count warmup $_temp0 included for a complete export. These remain hidden from charts, recaps, and Apple Health.';
  }

  @override
  String get dateRangeUnavailable => 'Date range unavailable';

  @override
  String get fileFormat => 'File format';

  @override
  String get includedInFile => 'Included in the file';

  @override
  String get exportIncludesGlucose => '• Glucose values in mg/dL and mmol/L';

  @override
  String get exportIncludesTiming =>
      '• Reading times, source, and sensor minute';

  @override
  String get exportIncludesQuality =>
      '• Raw quality fields and provisional state';

  @override
  String get exportIncludesArchive => '• Archive reason and session timing';

  @override
  String get exportExcludesIdentity =>
      'Sensor serials, device IDs, and storage identifiers are not included.';

  @override
  String shareFormat(String format) {
    return 'Share $format';
  }

  @override
  String get csvExportDescription =>
      'Best for importing into most spreadsheet and analysis apps.';

  @override
  String get txtExportDescription =>
      'A tab-separated plain-text file that is easy to inspect anywhere.';

  @override
  String get xlsxExportDescription =>
      'A real Excel workbook with glucose measurements stored as numbers.';

  @override
  String get archivedSensorExportFailed =>
      'The archived sensor data could not be exported.';

  @override
  String get archiveReasonExpired => 'Expired';

  @override
  String get archiveReasonReplaced => 'Replaced';

  @override
  String get archiveReasonDisconnected => 'Disconnected';

  @override
  String get storedInMacAppContainer => 'Stored in this Mac app container';

  @override
  String get storedOnIphone => 'Stored on this iPhone';

  @override
  String get localDataMacDescription =>
      'Sensor identity and glucose history remain local. Backup exclusion is not verified for this preview; check this Mac\'s backup policy.';

  @override
  String get localDataIphoneDescription =>
      'Sensor identity and glucose history remain local and are excluded from device backups.';

  @override
  String get noOpenGlucoseCloud => 'No OpenGlucose cloud';

  @override
  String get noOpenGlucoseCloudDescription =>
      'Data leaves the app only when you explicitly enable an integration.';

  @override
  String appVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutAppDescription =>
      'A local-first, open-source wellness app for viewing your own glucose data. OpenGlucose is not a medical device and does not provide diagnosis or treatment advice.';

  @override
  String get displaySettings => 'Display settings';

  @override
  String get targetLowMgdl => 'Target low (mg/dL)';

  @override
  String get targetHighMgdl => 'Target high (mg/dL)';

  @override
  String get reviewSelectedInterruptedMove => 'Review interrupted move';

  @override
  String get removeAllSensorPhoneBonds => 'Remove all sensor phone bonds?';

  @override
  String get moveSensorToAnotherPhoneQuestion =>
      'Move sensor to another phone?';

  @override
  String get removeAllSensorPhoneBondsDescription =>
      'This sensor only supports removing every phone bond stored by the transmitter. It will disconnect from this phone and all other phones. The sensor session is not reset. Keep the sensor close and do not retry if an error appears.';

  @override
  String get moveSensorToAnotherPhoneDescription =>
      'This removes this phone\'s bond from the sensor and Android, then disconnects. The sensor session is not reset. Keep the sensor close and do not retry if an error appears.';

  @override
  String get moveSensor => 'Move sensor';

  @override
  String get sensorReadyToPairAnotherPhone =>
      'Sensor is ready to pair with another phone.';

  @override
  String get sensorCannotMoveSafely => 'The sensor cannot be moved safely.';

  @override
  String get sensorTransferStopped =>
      'Sensor transfer stopped. Do not retry automatically.';

  @override
  String get developer => 'Developer';

  @override
  String get mockScenario => 'Mock scenario';

  @override
  String get simulatedSensorState => 'Simulated sensor state';

  @override
  String get engineeringControls => 'Engineering controls';

  @override
  String get engineeringControlsDescription =>
      'Advanced corrections for diagnostics and sensor-data troubleshooting.';

  @override
  String get calibrationScale => 'Calibration scale';

  @override
  String get calibrationOffset => 'Calibration offset';

  @override
  String get cropFirstSamples => 'Crop first N samples';

  @override
  String get engineeringValuesInvalid =>
      'Enter valid engineering correction values.';

  @override
  String get engineeringSettingsSaved => 'Engineering settings saved.';

  @override
  String get saveEngineeringSettings => 'Save engineering settings';

  @override
  String get clearActiveSensorCache => 'Clear active sensor cache';

  @override
  String get clearActiveSensorCacheDescription =>
      'Clears only the active sensor’s local cache. Sensor archive is not deleted, and available readings may download again from the sensor.';

  @override
  String get metadata => 'Metadata';

  @override
  String get diagnostics => 'Diagnostics';

  @override
  String get noDiagnosticsLoaded => 'No diagnostics loaded yet.';

  @override
  String get calibrations => 'Calibrations';

  @override
  String get noCalibrationEntries => 'No calibration entries loaded.';

  @override
  String get logs => 'Logs';

  @override
  String get noLogs => 'No logs yet.';

  @override
  String get clearActiveSensorCacheQuestion => 'Clear active sensor cache?';

  @override
  String get clearActiveSensorCacheReview =>
      'This removes only the locally cached history for the active sensor. Archived sensors are kept, and available readings may download again.';

  @override
  String get clearCache => 'Clear cache';

  @override
  String get activeSensorCacheCleared => 'Active sensor cache cleared.';

  @override
  String get noActiveSensorCacheCleared =>
      'No active sensor cache was cleared.';

  @override
  String timeframeHoursShort(int hours) {
    return '${hours}h';
  }

  @override
  String timeframeDaysShort(int days) {
    return '${days}d';
  }

  @override
  String get timeframeAll => 'ALL';

  @override
  String chartMinute(int minute) {
    return 'Minute $minute';
  }

  @override
  String chartAxisMinute(int minute) {
    return 'm$minute';
  }

  @override
  String get patternsDescription =>
      'Observations for self-experimentation, not medical metrics.';

  @override
  String get timeInRange => 'Time in range';

  @override
  String get belowAbove => 'Below / above';

  @override
  String get belowAboveRange => 'Below / above range';

  @override
  String get average => 'Average';

  @override
  String get variabilityCv => 'Variability (CV)';

  @override
  String get estimatedGmi => 'Estimated GMI';

  @override
  String get spikes => 'Spikes';

  @override
  String get unavailable => 'Unavailable';

  @override
  String timeInRangeExplanation(String low, String high) {
    return 'Share of readings between $low and $high.';
  }

  @override
  String get belowAboveExplanation =>
      'How often readings were below the low mark or above the high mark.';

  @override
  String get averageExplanation => 'Mean of all readings in this time window.';

  @override
  String variabilityExplanation(String standardDeviation) {
    return 'How spread out readings are around the average (SD $standardDeviation). Lower looks steadier.';
  }

  @override
  String get estimatedGmiExplanation =>
      'A rough indicator derived from the 14-day average glucose. Not a lab result.';

  @override
  String spikesExplanation(String high) {
    return 'Times readings rose past $high.';
  }

  @override
  String patternsInsufficientCoverage(
    String timeframe,
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      readingCount,
      locale: localeName,
      other: '$readingCount readings',
      one: '$readingCount reading',
      zero: 'No readings',
    );
    String _temp1 = intl.Intl.pluralLogic(
      activeDays,
      locale: localeName,
      other: '$activeDays days',
      one: '$activeDays day',
      zero: '0 days',
    );
    String _temp2 = intl.Intl.pluralLogic(
      minimumActiveDays,
      locale: localeName,
      other: '$minimumActiveDays days',
      one: '$minimumActiveDays day',
    );
    return 'Not enough readings in this $timeframe window yet. $_temp0 across $_temp1; patterns appear after at least $minimumReadings readings across $_temp2.';
  }

  @override
  String get samplePreviewTitle => 'See how OpenGlucose works';

  @override
  String get samplePreviewDescription =>
      'This private preview is generated in memory. It cannot connect, export, notify, or be mixed with your real glucose history.';

  @override
  String get glucoseHistory => 'Glucose history';

  @override
  String get sampleBadge => 'SAMPLE';

  @override
  String get sampleWeeklyRecap => 'Sample weekly recap';

  @override
  String get sensorLifecycle => 'Sensor lifecycle';

  @override
  String get sensorLifecycleUnknownBody =>
      'Life remaining is unavailable while the sensor session is being verified.';

  @override
  String get active => 'Active';

  @override
  String get expiringSoon => 'Expiring soon';

  @override
  String get expired => 'Expired';

  @override
  String get lifeUsed => 'used';

  @override
  String warmupTimeLeft(int minutes) {
    return '$minutes min left';
  }

  @override
  String get sensorAge => 'Sensor age';

  @override
  String get timeRemaining => 'Time remaining';

  @override
  String get totalLife => 'Total life';

  @override
  String sensorTotalLife(int days) {
    return '$days days';
  }

  @override
  String get lastSync => 'Last sync';

  @override
  String get notYet => 'Not yet';

  @override
  String get justNow => 'Just now';

  @override
  String minutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String hoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hours',
      one: 'hour',
    );
    return '$count $_temp0 ago';
  }

  @override
  String daysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'days',
      one: 'day',
    );
    return '$count $_temp0 ago';
  }

  @override
  String get sensorWarmupLifecycleBanner =>
      'Warming up — readings stabilize after the first hour. Keep the sensor on and your phone nearby.';

  @override
  String sensorExpiringSoonBanner(String remaining) {
    return 'This sensor expires in $remaining. Have a replacement ready so you do not miss readings.';
  }

  @override
  String get sensorExpiredDetails =>
      'This sensor reached the end of its 15-day life. The readings below are frozen at the last known values — they are kept for your records but are no longer live.';

  @override
  String get lastReadingPreservedBelow => 'Last reading is preserved below.';

  @override
  String lastReadingAndHistoryPreserved(String time) {
    return 'Last reading $time. Your history is preserved.';
  }

  @override
  String get nextSteps => 'Next steps';

  @override
  String get replaceExpiredSensorStep =>
      'Remove and dispose of the expired sensor.';

  @override
  String get applyReplacementSensorStep =>
      'Apply a new Aidex X sensor and wait for about 1 hour of warmup.';

  @override
  String get startNewSensorSessionStep =>
      'Tap below to start a new sensor session.';

  @override
  String get replaceSensor => 'Replace sensor';

  @override
  String get weeklyRecapDescription =>
      'Patterns and observations from your last 7 days — for self-experimentation, not medical advice.';

  @override
  String get weeklyOverviewTitle => 'This week at a glance';

  @override
  String weeklyOverviewSubtitle(int activeDays, int readingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      readingCount,
      locale: localeName,
      other: '$readingCount readings',
      one: '$readingCount reading',
    );
    return '$activeDays of 7 days with readings · $_temp0.';
  }

  @override
  String get belowAboveRangeExplanation =>
      'Share of readings below your low mark and above your high mark.';

  @override
  String get weeklyAverageExplanation => 'Mean of every reading this week.';

  @override
  String get lowestHighest => 'Lowest / highest';

  @override
  String get observedRangeExplanation =>
      'Observed range inside this seven-day window.';

  @override
  String get variabilityExplanationNoSd =>
      'How spread out readings are around the average. Lower looks steadier.';

  @override
  String get dataCoverage => 'Data coverage';

  @override
  String get dataCoverageDescription =>
      'How much information this recap is based on.';

  @override
  String get timestampedReadingsExplanation =>
      'Timestamped readings inside this seven-day window.';

  @override
  String get daysRepresented => 'Days represented';

  @override
  String get daysRepresentedExplanation =>
      'Calendar days containing at least one reading.';

  @override
  String get observedSpan => 'Observed span';

  @override
  String get observedSpanExplanation =>
      'Time between the first and last included reading.';

  @override
  String durationDays(String value) {
    return '$value days';
  }

  @override
  String durationHours(int value) {
    String _temp0 = intl.Intl.pluralLogic(
      value,
      locale: localeName,
      other: 'hours',
      one: 'hour',
    );
    return '$value $_temp0';
  }

  @override
  String daysOfSeven(int activeDays) {
    return '$activeDays of 7';
  }

  @override
  String get versusLastWeek => 'Versus last week';

  @override
  String get weekOverWeekChange => 'Week-over-week change.';

  @override
  String previousWeekComparisonDescription(int readingCount, int activeDays) {
    String _temp0 = intl.Intl.pluralLogic(
      readingCount,
      locale: localeName,
      other: '$readingCount readings',
      one: '$readingCount reading',
      zero: 'no readings',
    );
    String _temp1 = intl.Intl.pluralLogic(
      activeDays,
      locale: localeName,
      other: '$activeDays days',
      one: '$activeDays day',
      zero: '0 days',
    );
    return 'The previous week has $_temp0 across $_temp1. Comparisons appear only when both weeks have enough coverage.';
  }

  @override
  String get versusLastWeekDescription =>
      'How this week compares with the seven days before.';

  @override
  String get noPriorWeek => 'no prior week';

  @override
  String get aboutTheSame => 'about the same';

  @override
  String percentagePoints(String value) {
    return '$value pts';
  }

  @override
  String get daysByTimeInRange => 'Days by time in range';

  @override
  String get daysByTimeInRangeDescription => 'Ranked by time spent in range.';

  @override
  String get mostInRange => 'Most in range';

  @override
  String get leastInRange => 'Least in range';

  @override
  String weekdayRangeSummary(String day, int percent, String average) {
    return '$day · $percent% in range · avg $average';
  }

  @override
  String get topSpikes => 'Top spikes';

  @override
  String get topSpikesDescription => 'Biggest upward swings this week.';

  @override
  String noSpikesThisWeek(String high) {
    return 'No readings rose past $high this week.';
  }

  @override
  String spikeRiseExplanation(String amount, String baseline) {
    return 'Rose $amount from $baseline.';
  }

  @override
  String get weeklyDailyAveragesTitle => 'This week\'s daily averages';

  @override
  String get weeklyDailyAveragesDescription =>
      'Average reading for each day in this seven-day window.';

  @override
  String get notEnoughReadingsYet => 'Not enough readings yet';

  @override
  String weeklyInsufficientCoverage(
    int readingCount,
    int activeDays,
    int minimumReadings,
    int minimumActiveDays,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      readingCount,
      locale: localeName,
      other: '$readingCount readings',
      one: '$readingCount reading',
      zero: 'no readings',
    );
    String _temp1 = intl.Intl.pluralLogic(
      activeDays,
      locale: localeName,
      other: '$activeDays days',
      one: '$activeDays day',
      zero: '0 days',
    );
    String _temp2 = intl.Intl.pluralLogic(
      minimumActiveDays,
      locale: localeName,
      other: '$minimumActiveDays days',
      one: '$minimumActiveDays day',
    );
    return 'This seven-day window currently has $_temp0 across $_temp1. Patterns appear after at least $minimumReadings readings across $_temp2, so sparse history is not presented as a reliable trend.';
  }

  @override
  String get weeklyRecapDisclaimer =>
      'These are wellness observations for self-experimentation. OpenGlucose is not a medical device, and this recap is not a diagnosis or medical advice. Consult a qualified professional for health decisions.';

  @override
  String get aiInsights => 'AI insights';

  @override
  String get onDeviceModel => 'On-device model';

  @override
  String get onDeviceModelDescription =>
      'Planned · private local inference with a downloaded model';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String onDeviceModelStatus(String status) {
    return 'On-device model status: $status';
  }

  @override
  String get aiWellnessPrivacyNotice =>
      'Wellness and self-experimentation only—not medical advice, diagnosis, or dosing. AI remains off unless you explicitly configure it. A future on-device model will keep inference local; the advanced cloud option below sends only aggregate statistics, never raw readings or note text.';

  @override
  String get customCloudProvider => 'Custom cloud provider';

  @override
  String get advancedSendsAggregatesOffDevice =>
      'Advanced · sends aggregates off-device';

  @override
  String get enableCloudAi => 'Enable cloud AI';

  @override
  String get cloudAiDisabledByDefault =>
      'Off by default. Requires your own API key.';

  @override
  String get apiBaseUrl => 'API base URL';

  @override
  String get aiModel => 'Model';

  @override
  String get authScheme => 'Auth scheme';

  @override
  String get authSchemeBearer => 'Bearer (OpenAI-compatible)';

  @override
  String get authSchemeXApiKey => 'x-api-key (Anthropic)';

  @override
  String get apiKeyStoredSecurely => 'API key (stored securely)';

  @override
  String get apiKeySavedMask => '•••••••• (saved)';

  @override
  String get pasteApiKey => 'Paste your key';

  @override
  String get apiKeySavedHint => 'A key is saved. Leave blank to keep it.';

  @override
  String get apiKeyPlainTextHint => 'Never stored in plain text.';

  @override
  String get saveProvider => 'Save provider';

  @override
  String get removeKey => 'Remove key';

  @override
  String get testWithAggregates => 'Test with aggregates';

  @override
  String get providerSettingsSaved => 'Saved.';

  @override
  String get apiKeyRemoved => 'API key removed.';

  @override
  String get savingProviderSettings => 'Saving provider settings…';

  @override
  String get enableCloudAiBeforeTesting => 'Enable cloud AI before testing.';

  @override
  String get addApiKeyBeforeTesting => 'Add an API key before testing.';

  @override
  String get generatingAiInsight => 'Generating…';

  @override
  String get aiDisabledOrNoKey => 'AI is disabled or no key set.';

  @override
  String generatedAndSaved(String title) {
    return 'Generated & saved: \"$title\".';
  }

  @override
  String get couldNotGenerateAiInsight => 'Could not generate the AI insight.';

  @override
  String get integrations => 'Integrations';

  @override
  String get integrationsIntro =>
      'Send your glucose readings to other apps you control. Nothing leaves your device unless you turn it on.';

  @override
  String get appleHealthExportDescription =>
      'When you opt in and tap Sync now, glucose values and timestamps are written to Apple Health as blood glucose samples. An interrupted sync may write a duplicate when retried.';

  @override
  String get appleHealthOnlyOnIos => 'Apple Health is only available on iOS.';

  @override
  String get appleHealthDisabledWithSimulatedData =>
      'Apple Health export is disabled while using simulated or mock sensor data.';

  @override
  String get exportToAppleHealth => 'Export to Apple Health';

  @override
  String get neverSynced => 'Never synced';

  @override
  String lastSyncedAt(String time) {
    return 'Last synced $time';
  }

  @override
  String get syncNow => 'Sync now';

  @override
  String get appleHealthExportUnavailableInThisMode =>
      'Apple Health export is unavailable in this mode.';

  @override
  String get appleHealthAccessNotGranted =>
      'Apple Health access was not granted.';

  @override
  String get turnOnAppleHealthBeforeSyncing =>
      'Turn on Apple Health export before syncing.';

  @override
  String appleHealthSyncedReadings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings',
      one: 'reading',
    );
    return 'Synced $count $_temp0.';
  }

  @override
  String appleHealthSyncPartial(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings',
      one: 'reading',
    );
    return 'Synced $count $_temp0, then export stopped.';
  }

  @override
  String appleHealthSyncPartialWithReason(int count, String reason) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'readings',
      one: 'reading',
    );
    return 'Synced $count $_temp0, then export stopped: $reason';
  }

  @override
  String get appleHealthAlreadyUpToDate => 'Already up to date.';

  @override
  String get appleHealthExportFailed => 'Export failed.';

  @override
  String get appleHealthSampleRejected =>
      'HealthKit rejected a glucose sample.';

  @override
  String get appleHealthCouldNotSaveSample =>
      'Apple Health could not save a glucose sample.';

  @override
  String get appleHealthExportCouldNotComplete =>
      'Apple Health export could not be completed.';

  @override
  String get appleHealthWritesDisabled =>
      'Apple Health writes are disabled for this mode.';

  @override
  String get macosPreviewLimitations => 'macOS preview limitations';

  @override
  String get macosTransportPreview => 'macOS transport preview';

  @override
  String get macosTransportPreviewDescription =>
      'Real AiDEX pairing, reconnect, and live readings are not verified on Mac hardware. This build cannot remove a system Bluetooth bond or run Move sensor. Use the Move sensor action on the current Android phone before a controlled Mac test.';

  @override
  String get aiUnavailableInMacosPreview => 'AI unavailable in macOS preview';

  @override
  String get macosPreviewAiUnavailableDescription =>
      'This ad-hoc-signed preview cannot supply the macOS Keychain capability required to store an API key. Cloud AI remains disabled. Do not paste a key into this preview.';

  @override
  String get messageWarmupTitle => 'Warming up';

  @override
  String get messageWarmupBody =>
      'Your sensor is settling in. Readings begin after about an hour — no action needed.';

  @override
  String get messageTapReadingTitle => 'Tip';

  @override
  String get messageTapReadingBody =>
      'Tap a point on the chart to see the exact reading and time.';

  @override
  String get scenarioWarmup => 'Warmup';

  @override
  String get scenarioActiveNormal => 'Active — normal';

  @override
  String get scenarioActiveHigh => 'Active — high (alert)';

  @override
  String get scenarioActiveLow => 'Active — low (alert)';

  @override
  String get scenarioRapidRise => 'Rapid rise';

  @override
  String get scenarioRapidFall => 'Rapid fall';

  @override
  String get scenarioExpiringSoon => 'Expiring soon';

  @override
  String get scenarioExpired => 'Expired';

  @override
  String get scenarioSignalLoss => 'Signal loss';

  @override
  String get scenarioDisconnected => 'Disconnected';

  @override
  String get scenarioMultiSensorHistory => 'Multi-sensor history';

  @override
  String get scenarioError => 'Error';

  @override
  String get scenarioWarmupDescription =>
      'Inside the ~1h warmup window — no readings yet.';

  @override
  String get scenarioActiveNormalDescription =>
      'Healthy in-range glucose, gently waving.';

  @override
  String get scenarioActiveHighDescription =>
      'Sustained high glucose — triggers a high alert.';

  @override
  String get scenarioActiveLowDescription =>
      'Sustained low glucose — triggers a low alert.';

  @override
  String get scenarioRapidRiseDescription =>
      'Glucose climbing fast (rising trend).';

  @override
  String get scenarioRapidFallDescription =>
      'Glucose dropping fast (falling trend).';

  @override
  String get scenarioExpiringSoonDescription =>
      'A few hours left on the 15-day sensor.';

  @override
  String get scenarioExpiredDescription =>
      'Sensor expired — offboarding state.';

  @override
  String get scenarioSignalLossDescription =>
      'Connected but signal lost — readings are stale.';

  @override
  String get scenarioDisconnectedDescription =>
      'Disconnected with last-known data.';

  @override
  String get scenarioMultiSensorHistoryDescription =>
      'Current sensor with carried-over previous-sensor history.';

  @override
  String get scenarioErrorDescription => 'Hard error with no usable data.';
}
