import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _withLfLineEndings(String value) =>
    value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

void main() {
  group('privacy-safe platform defaults', () {
    test('Android excludes app data from backup and device transfer', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final legacyRules = _read(
        'android/app/src/main/res/xml/backup_rules.xml',
      );
      final modernRules = _read(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );

      expect(manifest, contains('android:allowBackup="false"'));
      expect(
        manifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      for (final domain in <String>['root', 'file', 'database', 'sharedpref']) {
        expect(legacyRules, contains('domain="$domain" path="."'));
        expect(modernRules, contains('domain="$domain" path="."'));
      }
      expect(modernRules, contains('<device-transfer>'));
    });

    test('Android release permits explicit HTTPS integrations', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest,
        contains('android.permission.INTERNET'),
        reason: 'The opt-in BYO-key AI transport must work in release builds.',
      );
    });

    test('lock-screen glucose requires an explicit opt-in', () {
      final android = _read(
        'android/app/src/main/java/com/aidex/aidex_flutter/'
        'GlucoseLiveUpdateService.java',
      );
      final ios = _read('ios/Runner/GlucoseLiveActivityController.swift');
      final iosBridge = _read('lib/src/ios_live_activity_bridge.dart');

      expect(android, contains('PREF_SENSITIVE_LOCK_SCREEN_OPT_IN'));
      expect(
        android,
        contains('getBoolean(PREF_SENSITIVE_LOCK_SCREEN_OPT_IN, false)'),
      );
      expect(android, contains('buildRedactedNotification(payload)'));
      expect(android, contains('validatedWarmupMinutes(payload)'));
      expect(android, contains('.setPublicVersion(publicVersion)'));
      expect(android, contains('Open the app to view your glucose'));
      expect(android, contains('.commit()'));
      expect(android, isNot(contains('.apply()')));

      expect(ios, contains('sensitiveLockScreenOptInKey'));
      expect(
        ios,
        contains('sensitiveContentEnabled: defaults.bool(forKey:'),
      );
      expect(ios, contains('case "getSensitiveContentEnabled"'));
      expect(ios, contains('case "setSensitiveContentEnabled"'));
      expect(ios, contains('defaults.synchronize()'));
      expect(ios, contains('failClosedAfterPreferenceFailure('));
      expect(
        ios,
        contains('defaults.set(false, forKey: sensitiveLockScreenOptInKey)'),
      );
      expect(ios, contains('"sensorName": "OpenGlucose"'));
      expect(ios, contains('let sensorName = displayPayload["sensorName"]'));
      expect(ios, contains('sensorName: displaySensorName'));
      expect(ios, contains('clearPersistedBackgroundPayload()'));
      expect(
        iosBridge,
        isNot(contains('catch (_)')),
        reason: 'Native restricted-storage failures must reach the controller.',
      );
      expect(iosBridge, contains("'setSensitiveContentEnabled'"));
      expect(android, contains('setSensitiveContentEnabled'));
      expect(android, contains('.putBoolean('));
      expect(android, contains('.commit()'));
      expect(android, contains('validatedWarmupMinutes(payload)'));
      expect(android, contains('.setContentText("Sensor warming up")'));
      expect(android, contains('remainingMinutes >= 1'));
      expect(android, contains('remainingMinutes <= 180'));
      final androidBridge = _read('lib/src/android_live_update_bridge.dart');
      expect(androidBridge, contains("'setSensitiveContentEnabled'"));
      final androidActivity = _read(
        'android/app/src/main/java/com/aidex/aidex_flutter/MainActivity.java',
      );
      expect(androidActivity, contains('removeVisibleLiveUpdateForPrivacy()'));
      expect(androidActivity, contains('manager.cancel('));
      expect(
        androidActivity,
        contains(
          'GlucoseLiveUpdateService.setSensitiveContentEnabled(this, false)',
        ),
      );
      final app = _read('lib/main.dart');
      expect(app, contains('Show glucose in live notification'));
      expect(app, contains('Anyone '));
      expect(app, contains('who can view your lock screen'));
      expect(ios, contains('func enforceLaunchPrivacy()'));
      expect(
        ios,
        contains('Activity<GlucoseLiveActivityAttributes>.activities'),
      );
      final appDelegate = _read('ios/Runner/AppDelegate.swift');
      expect(
        appDelegate,
        contains('GlucoseLiveActivityController.shared.enforceLaunchPrivacy()'),
      );
    });

    test(
      'native restricted state is stored outside preferences and backups',
      () {
        final bootstrap = _read('lib/main.dart');
        final store = _read('lib/src/health_state_store_io.dart');
        final appDelegate = _read('ios/Runner/AppDelegate.swift');
        final privacyStorageChannel = _read(
          'ios/Runner/PrivacyStorageChannel.swift',
        );
        final nativeStore = _read(
          'ios/Runner/NativeRestrictedStateStore.swift',
        );
        final backgroundMonitor = _read(
          'ios/Runner/AidexBackgroundMonitor.swift',
        );
        final liveActivityController = _read(
          'ios/Runner/GlucoseLiveActivityController.swift',
        );

        expect(bootstrap, contains('createHealthStateStore(preferences)'));
        expect(store, contains('restricted-health-state.json'));
        expect(store, contains('RestrictedHealthState'));
        expect(
          store.indexOf('await _excludeFromBackup(directory.path)') <
              store.indexOf('final file = File('),
          isTrue,
          reason:
              'The directory must be excluded before a sensitive file exists.',
        );
        expect(store, contains("'schemaVersion': _schemaVersion"));
        expect(store, contains('static const _schemaVersion = 3'));
        expect(store, contains('_serializeMutation'));
        expect(store, contains('.previous'));
        expect(store, contains('openHealth.history.'));
        expect(store, contains('crypto.sha256.convert'));
        expect(store, contains('_migrateLegacyHistoryBlobNames'));
        expect(store, contains('_filesHaveEqualContents'));
        expect(store, contains('openHealth.lastSensor'));
        expect(store, contains('excludeFromBackup'));
        expect(privacyStorageChannel, contains('case "excludeFromBackup"'));
        expect(
          privacyStorageChannel,
          contains('case "prepareProtectedDatabase"'),
        );
        expect(
          privacyStorageChannel,
          contains('values.isExcludedFromBackup = true'),
        );
        expect(privacyStorageChannel, contains('.isExcludedFromBackupKey'));
        expect(appDelegate, contains('initializeAndPurgeLegacyDefaults()'));
        expect(nativeStore, contains('RestrictedNativeState'));
        expect(nativeStore, contains('restricted-native-state.json'));
        expect(nativeStore, contains('isExcludedFromBackup = true'));
        expect(nativeStore, contains('.isExcludedFromBackupKey'));
        expect(nativeStore, contains('legacyLiveActivityPayloadKey'));
        expect(nativeStore, contains('legacyPreferencesSynchronizer'));
        expect(
          nativeStore,
          contains('throw NativeRestrictedStateStoreError.legacyPurgeFailed'),
        );
        expect(
          nativeStore,
          contains('.completeFileProtectionUntilFirstUserAuthentication'),
        );
        expect(backgroundMonitor, isNot(contains('UserDefaults')));
        expect(
          backgroundMonitor.indexOf('targetSensorName = nil') <
              backgroundMonitor.indexOf('throw persistenceError'),
          isTrue,
          reason:
              'Volatile BLE state must clear even if durable deletion fails.',
        );
        expect(
          liveActivityController,
          isNot(contains('defaults.dictionary(forKey:')),
        );
        expect(
          liveActivityController.indexOf(
                'Activity<GlucoseLiveActivityAttributes>.activities',
                liveActivityController.indexOf('private func end(result:'),
              ) <
              liveActivityController.indexOf(
                'result(self.storageError())',
                liveActivityController.indexOf('private func end(result:'),
              ),
          isTrue,
          reason:
              'Visible activities must end before a storage error is returned.',
        );
      },
    );

    test('release startup disables native BLE logs before app bootstrap', () {
      final bootstrap = _read('lib/main.dart');
      final driverFactory = _read('lib/src/driver_factory_io.dart');
      final pluginLogging = _read(
        '../packages/cgm_ble_flutter/lib/src/'
        'flutter_blue_plus_logging.dart',
      );

      expect(bootstrap, contains('await configurePlatformPrivacyDefaults();'));
      expect(
        bootstrap.indexOf('await configurePlatformPrivacyDefaults();'),
        lessThan(bootstrap.indexOf('await clearStaleArchivedSensorShareFiles')),
      );
      expect(
        bootstrap.indexOf('await configurePlatformPrivacyDefaults();'),
        lessThan(bootstrap.indexOf('SharedPreferences.getInstance()')),
      );
      expect(driverFactory, contains('if (kReleaseMode)'));
      expect(driverFactory, contains('await disableFlutterBluePlusLogs();'));
      expect(pluginLogging, contains('fbp.LogLevel.none'));
      expect(pluginLogging, contains('color: false'));
    });

    test('startup export cleanup targets the exact legacy CSV shape', () {
      final cleanup = _read('lib/src/sensor_archive_share_file_io.dart');

      expect(cleanup, contains('_legacySensorExportFileName'));
      expect(cleanup, contains('entry is File'));
      expect(cleanup, contains('entry is Directory'));
      expect(cleanup, contains(r'\.csv$'));
    });
  });

  group('release safety defaults', () {
    test('CI isolates the pinned CocoaPods installation', () {
      final workflow = _read('../.github/workflows/ci.yml');

      expect(workflow, contains(r'cocoapods_root="$RUNNER_TEMP/cocoapods/'));
      expect(workflow, contains('gem install --install-dir'));
      expect(workflow, contains(r'GEM_HOME="$cocoapods_root"'));
      expect(workflow, contains(r'GEM_PATH="$cocoapods_root"'));
      expect(
        workflow,
        contains(r'test "$actual_cocoapods" = "$cocoapods_version"'),
      );
      expect(workflow, isNot(contains('gem install --user-install')));
    });

    test('Android release never falls back to debug signing', () {
      final gradle = _read('android/app/build.gradle.kts');
      expect(gradle, contains('ANDROID_KEYSTORE_PATH'));
      expect(gradle, contains('ANDROID_KEYSTORE_PASSWORD'));
      expect(gradle, contains('ANDROID_KEY_ALIAS'));
      expect(gradle, contains('ANDROID_KEY_PASSWORD'));
      expect(gradle, contains('signingConfigs.getByName("release")'));
      expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
      expect(gradle, contains('never falls back to debug signing'));
    });

    test('Android USB debug builds stay separate from tester installs', () {
      final gradle = _read('android/app/build.gradle.kts');
      final debugManifest = _read('android/app/src/debug/AndroidManifest.xml');

      expect(gradle, contains('applicationIdSuffix = ".debug"'));
      expect(gradle, contains('versionNameSuffix = "-debug"'));
      expect(debugManifest, contains('android:label="OpenGlucose Debug"'));
    });

    test('Android release is source-bound and draft-first', () {
      final workflow = _withLfLineEndings(
        _read('../.github/workflows/release-android.yml'),
      );
      final verifier = _read(
        '../scripts/verify-android-release-artifact.sh',
      );

      expect(workflow, contains('push:\n    tags:'));
      expect(workflow, contains('workflow_dispatch:'));
      expect(workflow, isNot(contains('github.event.release')));
      expect(workflow, contains('permissions: {}'));
      expect(workflow, contains('environment: android-release'));
      expect(workflow, contains('persist-credentials: false'));
      expect(workflow, contains('git merge-base --is-ancestor'));
      expect(workflow, contains('ANDROID_KEYSTORE_BASE64'));
      expect(workflow, contains('ANDROID_SIGNING_CERT_SHA256'));
      expect(workflow, contains('draft: true'));
      expect(workflow, contains('prerelease: false'));
      expect(workflow, contains('make_latest: "true"'));
      expect(workflow, contains('group: android-release'));
      expect(workflow, contains('greatest eligible release tag'));
      expect(workflow, contains('asset_state" = starter'));
      expect(
        workflow,
        contains('Refusing to discard a non-empty starter asset'),
      );
      expect(
        workflow,
        contains('Refusing to discard a starter asset with a digest'),
      );
      expect(workflow, contains('releases/latest'));
      expect(workflow, contains('https://uploads.github.com/repos/'));
      expect(workflow, contains("'.assets | length'"));
      expect(workflow, contains('verify-android-release-artifact.sh'));
      expect(workflow, contains('actions/attest@'));
      expect(
        workflow,
        contains('gh api --method POST'),
      );
      expect(workflow, contains('resolve_release_tag_commit'));
      expect(
        workflow,
        contains(
          r'test "$(resolve_release_tag_commit)" = "$RELEASE_COMMIT"',
        ),
      );
      expect(workflow, isNot(contains('--clobber')));
      expect(workflow, isNot(contains('softprops/action-gh-release')));
      expect(workflow, isNot(contains('key.properties')));

      expect(
        verifier,
        contains('apksigner verify --verbose --print-certs --Werr'),
      );
      expect(verifier, contains('Number of signers: 1'));
      expect(verifier, contains('APK Signature Scheme v2 is required'));
      expect(verifier, contains('com.openglucose.app'));
      expect(verifier, contains('application-debuggable'));
      expect(verifier, contains('android.permission.INTERNET'));
      expect(verifier, contains('historical_debug_digest'));
      expect(verifier, contains('CN=Android Debug'));
    });

    test('TestFlight distribution is immutable and explicitly gated', () {
      final script = _read('scripts/testflight.sh');
      final project = _read('ios/Runner.xcodeproj/project.pbxproj');
      final liveActivityConfiguration = _read(
        'ios/Flutter/LiveActivity.xcconfig',
      );
      final runnerInfo = _read('ios/Runner/Info.plist');
      final runnerEntitlements = _read('ios/Runner/Runner.entitlements');
      final releasePolicy = _read('../docs/releases.md');
      expect(script, contains('RELEASE_APPROVED'));
      expect(script, contains('DISTRIBUTE_EXTERNAL'));
      expect(script, contains('DISTRIBUTE_INTERNAL'));
      expect(script, contains('TESTFLIGHT_MODE'));
      expect(script, contains('TESTFLIGHT_TESTER_ID'));
      expect(script, contains('DISTRIBUTE_INTERNAL must be yes or no'));
      expect(script, contains('DISTRIBUTE_EXTERNAL must be yes or no'));
      expect(script, contains('RELEASE_COMMIT'));
      expect(script, contains('git status --porcelain'));
      expect(script, contains('mktemp -d'));
      expect(script, contains('trap cleanup EXIT'));
      expect(script, contains("trap 'exit 130' INT"));
      expect(script, contains("trap 'exit 143' TERM"));
      expect(script, contains('codesign --verify --deep --strict'));
      expect(script, contains('embedded.mobileprovision'));
      expect(script, contains('security cms -D -i'));
      expect(script, contains('beta-reports-active'));
      expect(script, contains('APPLE_TEAM_ID'));
      expect(script, contains('scripts/flutter-workspace.sh'));
      expect(script, contains('dependency_state_after'));
      expect(script, contains('LIVE_ACTIVITY_BUNDLE_ID'));
      expect(script, contains('EXPECTED_MARKETING_VERSION'));
      expect(script, contains('EXPECTED_BUILD_NUMBER'));
      expect(script, contains('com.apple.developer.team-identifier'));
      expect(script, contains('application-identifier'));
      expect(script, contains('verify_main_app_healthkit_entitlement'));
      expect(script, contains('verify_main_app_healthkit_profile'));
      expect(script, contains('com.apple.developer.healthkit'));
      expect(runnerEntitlements, contains('com.apple.developer.healthkit'));
      expect(
        runnerInfo,
        isNot(contains('ITSAppUsesNonExemptEncryption')),
        reason:
            'External beta export compliance requires an explicit, recorded '
            'Account Holder determination.',
      );
      expect(releasePolicy, contains('Account Holder'));
      expect(releasePolicy, contains('export-compliance determination'));
      expect(
        runnerEntitlements,
        isNot(contains('com.apple.developer.healthkit.access')),
        reason: 'Verifiable Health Records requires separate Apple approval.',
      );
      expect(script, contains('verify-native-tooling.sh'));
      expect(script, contains('verify_external_group'));
      expect(script, contains('verify_internal_group'));
      expect(script, contains('verify_internal_build'));
      expect(script, contains('associate_external_build'));
      expect(script, contains('notify_external_build'));
      expect(script, contains('TESTFLIGHT_NOTIFY_ONLY'));
      expect(script, contains('TESTFLIGHT_NOTIFICATION_RECEIPT_PATH'));
      expect(script, contains('assert_hermetic_fastlane_environment'));
      expect(script, contains('Fastlane auto-loads ignored dotenv files'));
      expect(script, contains('PILOT_* | SPACESHIP_*'));
      expect(script, contains('APP_STORE_CONNECT_API_KEY'));
      expect(script, contains('TESTFLIGHT_APPLE_ID'));
      expect(script, contains('RUBYOPT'));
      expect(script, contains('RUBYLIB'));
      expect(script, contains('RUBYGEMS_GEMDEPS'));
      expect(script, contains('SSL_CERT_FILE'));
      expect(script, contains('SSL_CERT_DIR'));
      expect(script, contains('FASTLANE_ITUNES_TRANSPORTER_PATH'));
      expect(script, contains('FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT'));
      expect(script, contains('ITMSTRANSPORTER_FORCE_ITMS_PACKAGE_UPLOAD'));
      expect(
        script.indexOf('assert_hermetic_fastlane_environment\n') <
            script.indexOf('require_command fastlane'),
        isTrue,
        reason: 'Dotenv must be rejected before the first Fastlane process.',
      );
      expect(
        script,
        contains(r'$label parent must have mode 700'),
        reason:
            'Every external release-record parent must stay private, including '
            'the notification, attempt, and provenance records.',
      );
      expect(script, contains('--skip_submission true'));
      expect(script, contains('--distribute_external false'));
      expect(script, contains('--notify_external_testers false'));
      expect(script, contains("find \"\$app\" -name 'Runner.debug.dylib'"));
      expect(script, contains('testFlightInternalTestingOnly'));
      expect(script, contains('FASTLANE_SKIP_DOCS=1'));
      expect(
        script,
        contains(r'FL_REPORT_PATH="$release_temp/fastlane-reports"'),
      );
      expect(script, isNot(contains('--distribute_external true')));
      expect(script, isNot(contains(r'--groups "$TESTFLIGHT_GROUP"')));
      final fastfile = _read('fastlane/Fastfile');
      expect(fastfile, contains('build.add_beta_groups(beta_groups: [group])'));
      expect(fastfile, contains('v1/buildBetaNotifications'));
      expect(fastfile, contains('post_build_beta_notification_once'));
      expect(fastfile, contains('request_client.client.run_request('));
      expect(
        fastfile,
        isNot(contains('test_flight_request_client.post(')),
        reason: 'Spaceship wraps its POST helper in internal retries.',
      );
      expect(fastfile, contains('require_exact_external_association'));
      expect(fastfile, contains('APP_STORE_ELIGIBLE'));
      expect(fastfile, contains('externalGroupId'));
      expect(fastfile, contains('automaticInternalGroupId'));
      expect(fastfile, contains('associatedGroupIds'));
      expect(fastfile, contains('externalTesterCount'));
      expect(fastfile, contains('externalTesterIdsSha256'));
      expect(fastfile, contains('require_exact_external_group_testers'));
      expect(fastfile, contains('exact_internal_automatic_group'));
      expect(fastfile, contains('audience classification'));
      expect(fastfile, contains('require_exact_internal_group_tester'));
      expect(fastfile, contains('require_exclusive_internal_association'));
      expect(fastfile, contains('require_internal_only_build'));
      expect(fastfile, contains('buildAudienceType'));
      expect(fastfile, contains('INTERNAL_ONLY'));
      expect(fastfile, contains('/relationships/betaTesters'));
      expect(fastfile, contains('require_no_individual_testers'));
      expect(
        fastfile,
        contains('test_flight_request_client.logger = Logger.new('),
      );
      expect(fastfile, contains('File::NULL'));
      expect(fastfile, contains('/relationships/individualTesters'));
      expect(
        fastfile,
        isNot(contains('build.id}/individualTesters')),
        reason:
            'The resource endpoint exposes tester names and email addresses.',
      );
      expect(fastfile, contains('notification_receipt_state'));
      expect(fastfile, contains('create_notification_claim'));
      expect(fastfile, contains('complete_notification_claim'));
      expect(fastfile, contains('"status" => "pending"'));
      expect(fastfile, contains('"status" => "complete"'));
      expect(fastfile, contains('File::EXCL'));
      expect(fastfile, contains('File.rename'));
      expect(fastfile, contains('fsync_parent_directory'));
      expect(fastfile, contains('notificationId'));
      expect(fastfile, contains('sourceCommit'));
      expect(fastfile, isNot(contains('detail.did_notify')));
      final notifyLane = fastfile.substring(
        fastfile.indexOf('lane :notify_external_build'),
      );
      expect(
        notifyLane.indexOf('create_notification_claim('),
        lessThan(notifyLane.indexOf('post_build_beta_notification_once(')),
        reason: 'The durable claim must exist before the non-idempotent POST.',
      );
      expect(_read('../.fastlane-version').trim(), '2.232.2');
      expect(_read('../.xcode-version').trim(), '26.6');
      expect(_read('../.cocoapods-version').trim(), '1.16.2');
      expect(project, contains(r'MARKETING_VERSION = "$(FLUTTER_BUILD_NAME)"'));
      expect(
        project,
        contains(r'CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)"'),
      );
      expect(
        liveActivityConfiguration,
        contains('#include "Generated.xcconfig"'),
      );
      expect(script, isNot(contains('brew install')));
      expect(script, isNot(contains('sed -i')));
      expect(
        script,
        isNot(contains(r'$HOME/.appstoreconnect/fastlane_api_key')),
      );
    });
  });
}
