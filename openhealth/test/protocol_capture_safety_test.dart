import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('optional NFC reader is default-off and excludes the debug recorder', () {
    final mainManifest = _read('android/app/src/main/AndroidManifest.xml');
    final gradle = _read('android/app/build.gradle.kts');
    final mainActivity = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/MainActivity.java',
    );

    expect(mainManifest, contains('android.permission.NFC'));
    expect(
      RegExp(
        r'<uses-feature\s+android:name="android.hardware.nfc"\s+'
        r'android:required="false"\s*/>',
      ).hasMatch(mainManifest),
      isTrue,
      reason: 'NFC must not exclude phones that use Bluetooth-only sensors',
    );
    expect(
      RegExp(
        r'<meta-data\s+android:name="com.openglucose.libre_nfc.read_only"\s+'
        r'android:value="\$\{openGlucoseLibreNfcReadOnly\}"\s*/>',
      ).hasMatch(mainManifest),
      isTrue,
    );
    expect(
      mainManifest,
      isNot(contains('com.openglucose.protocol_capture.available')),
    );
    expect(
      gradle,
      contains('providers.gradleProperty("openGlucoseLibreNfcReadOnly")'),
    );
    expect(gradle, contains('require(value == "true" || value == "false")'));
    expect(gradle, contains('}.getOrElse("false")'));
    expect(
      gradle,
      contains(
        'manifestPlaceholders["openGlucoseLibreNfcReadOnly"] = libreNfcReadOnly',
      ),
    );

    expect(
      RegExp(r'\.getApplicationInfo\(').allMatches(mainActivity),
      hasLength(1),
      reason: 'both backends must use the same metadata snapshot',
    );
    expect(
      mainActivity,
      contains(
        '!(readerBackendInfo.metaData.get(LIBRE_READ_ONLY_METADATA) '
        'instanceof Boolean)',
      ),
    );
    expect(
      mainActivity,
      contains(
        'catch (PackageManager.NameNotFoundException | RuntimeException ignored) '
        '{\n      readerBackendInfo = null;',
      ),
    );
    expect(
      RegExp(
        r'if \(libreReadOnlyAvailable\(\)\) \{\s+'
        r'libre2NfcBridge = new Libre2NfcBridge\(this\);\s+'
        r'libre2NfcBridge.register\('
        r'flutterEngine.getDartExecutor\(\).getBinaryMessenger\(\)\);\s+'
        r'if \(libreReceiverValidationAvailable\(\)\) \{\s+'
        r'libreGen1ReceiverBridge = new LibreGen1ReceiverBridge\(\s+'
        r'this, this::libreReceiverValidationAvailable\);\s+'
        r'libreGen1ReceiverBridge.register\('
        r'flutterEngine.getDartExecutor\(\).getBinaryMessenger\(\)\);\s+\}\s+'
        r'\} else if \(protocolCaptureAvailable\(\)\) \{\s+'
        r'protocolCaptureBridge = new DebugProtocolCaptureBridge\(this\);',
      ).hasMatch(mainActivity),
      isTrue,
      reason:
          'the read-only reader and private recorder cannot register together',
    );
    expect(
      RegExp(r'new Libre2NfcBridge\(').allMatches(mainActivity),
      hasLength(1),
    );
    expect(
      RegExp(r'new DebugProtocolCaptureBridge\(').allMatches(mainActivity),
      hasLength(1),
    );
    expect(
      mainActivity,
      contains('info.metaData.getBoolean(LIBRE_READ_ONLY_METADATA, false)'),
    );
    expect(
      mainActivity,
      contains('info.metaData.getBoolean(PROTOCOL_CAPTURE_METADATA, false)'),
    );
    expect(
      mainActivity,
      contains('&& (info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0'),
    );
  });

  test(
    'recorder-free receiver registration is private and detach retains ownership',
    () {
      final mainActivity = _read(
        'android/app/src/main/java/com/aidex/aidex_flutter/MainActivity.java',
      );
      final bridge = _read(
        'android/app/src/main/java/com/aidex/aidex_flutter/LibreGen1ReceiverBridge.java',
      );
      final policy = _read(
        'android/app/src/main/java/com/aidex/aidex_flutter/LibreGen1ReceiverBackendPolicy.java',
      );
      expect(mainActivity, contains('LibreGen1ReceiverBackendPolicy.allows('));
      expect(mainActivity, contains('libreReadOnlyAvailable(),'));
      expect(
        mainActivity,
        contains(
          'info != null && (info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0,',
        ),
      );
      expect(mainActivity, contains('libre2NfcBridge != null,'));
      expect(mainActivity, contains('protocolCaptureBridge != null)'));
      expect(
        policy,
        contains(
          'readOnlySelected && debuggable && readOnlyRegistered && !recorderRegistered',
        ),
      );
      expect(
        RegExp(r'new LibreGen1ReceiverBridge\(').allMatches(mainActivity),
        hasLength(1),
      );
      expect(
        RegExp(
          r'libreGen1ReceiverBridge.destroy\(\);',
        ).allMatches(mainActivity),
        hasLength(2),
      );
      final destroy = bridge.substring(
        bridge.indexOf('void destroy()'),
        bridge.indexOf('private boolean allowed()'),
      );
      expect(destroy, contains('destroyed = true'));
      expect(destroy, contains('setMethodCallHandler(null)'));
      expect(destroy, isNot(contains('release(')));
      expect(destroy, isNot(contains('transportClosed')));
      expect(bridge, contains('value.put("enrollmentAvailable", false)'));
      expect(bridge, contains('value.put("rawCapture", false)'));
    },
  );

  test('protocol capture is debug-only, private, and explicitly gated', () {
    final mainManifest = _read('android/app/src/main/AndroidManifest.xml');
    final debugManifest = _read('android/app/src/debug/AndroidManifest.xml');
    final profileManifest = _read(
      'android/app/src/profile/AndroidManifest.xml',
    );
    final mainActivity = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/MainActivity.java',
    );
    final nativeBridge = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'DebugProtocolCaptureBridge.java',
    );
    final publishedGrantEnvelope = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'NfcPublishedGrantEnvelope.java',
    );
    final rfLeaseBinding = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'NfcRfTransactionLeaseBinding.java',
    );
    final rfReadiness = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'NfcRfReadiness.java',
    );
    final explicitExpiryBinding = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'Libre2NfcSetupExpiryBinding.java',
    );
    final gen1Frames = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'LibreGen1NfcFrames.java',
    );
    final gen1Activation = _read(
      'android/app/src/main/java/com/aidex/aidex_flutter/'
      'LibreGen1Activation.java',
    );
    final driverFactory = _read('lib/src/driver_factory_io.dart');
    final captureEntrypoint = _read('lib/protocol_capture_main.dart');
    final captureProfile = _read('lib/src/protocol_capture_profile.dart');
    final observationDriver = _read(
      'lib/src/protocol_capture_observation_driver.dart',
    );

    expect(
      mainManifest,
      isNot(contains('com.openglucose.protocol_capture.available')),
    );
    expect(profileManifest, isNot(contains('android.permission.NFC')));
    expect(
      profileManifest,
      isNot(contains('com.openglucose.protocol_capture.available')),
    );
    expect(debugManifest, contains('android.permission.NFC'));
    expect(
      debugManifest,
      contains('com.openglucose.protocol_capture.available'),
    );
    expect(mainActivity, contains('protocolCaptureAvailable()'));
    expect(mainActivity, contains('PackageManager.GET_META_DATA'));
    expect(mainActivity, contains('ApplicationInfo.FLAG_DEBUGGABLE'));
    expect(
      driverFactory,
      contains("bool.fromEnvironment('OG_PROTOCOL_TRACE')"),
    );
    expect(
      driverFactory,
      allOf(
        contains('if (kReleaseMode)'),
        contains('else if (kOgProtocolTrace)'),
      ),
      reason: 'raw BLE plugin logs stay disabled during private capture',
    );
    expect(
      driverFactory,
      contains("'OG_PROTOCOL_CAPTURE_LIVE_AIDEX'"),
    );
    expect(
      driverFactory,
      contains("'OG_PROTOCOL_CAPTURE_LIVE_YUWELL'"),
    );
    final platformRegistryStart = driverFactory.indexOf(
      'CgmDriverRegistry buildHardwareDriverRegistry',
    );
    final captureRegistryStart = driverFactory.indexOf(
      'CgmDriver _buildCaptureRegistry',
    );
    expect(platformRegistryStart, greaterThanOrEqualTo(0));
    expect(captureRegistryStart, greaterThan(platformRegistryStart));
    final normalRegistry = driverFactory.substring(
      platformRegistryStart,
      captureRegistryStart,
    );
    expect(normalRegistry, isNot(contains('YuwellAnytimeDriver')));
    expect(normalRegistry, isNot(contains('YuwellSecureSessionStore')));
    expect(
      driverFactory.substring(captureRegistryStart),
      contains('YuwellAnytimeDriver'),
    );
    expect(
      driverFactory.substring(captureRegistryStart),
      contains('YuwellV1150GlucoseOutputPolicy.engineeringProvisional'),
      reason: 'the existing live-Yuwell debug gate enables provisional output',
    );
    expect(
      driverFactory,
      contains('OG_DEMO and OG_PROTOCOL_TRACE cannot be enabled together.'),
    );
    expect(driverFactory, contains('if (!kDebugMode)'));
    expect(
      driverFactory,
      contains('OG_PROTOCOL_TRACE requires a debug build.'),
    );
    expect(captureProfile, contains('0000fde3-0000-1000-8000-00805f9b34fb'));
    expect(captureProfile, contains("defaultValue: 'libre'"));
    expect(captureProfile, contains("'yuwell_anytime_passive'"));
    expect(captureProfile, contains('usesUnfilteredScan: true'));
    expect(driverFactory, contains('selectedProtocolCaptureProfile()'));
    expect(driverFactory, contains('DebugSharedScanTransport'));
    expect(driverFactory, contains('ProtocolCaptureObservationDriver'));
    expect(observationDriver, contains("'protocol_capture_observation'"));
    expect(
      observationDriver,
      contains('Protocol capture does not authorize a sensor connection.'),
    );
    expect(driverFactory, contains("'setBleCaptureStatus'"));
    expect(driverFactory, contains('recordCaptureHeartbeat'));
    expect(driverFactory, contains("'processSessionId': processSessionId"));
    expect(
      driverFactory,
      contains('newProtocolCaptureProcessSessionId()'),
    );
    expect(
      driverFactory,
      contains('_protocolCaptureProcessSessionId = null'),
    );
    expect(driverFactory, contains("'stopProtocolCapture'"));
    expect(
      driverFactory,
      isNot(contains('_startPassiveLibreScan')),
    );
    expect(captureEntrypoint, contains('OG_PROTOCOL_TRACE'));
    expect(captureEntrypoint, contains('if (!kDebugMode'));
    expect(
      captureEntrypoint,
      contains('configurePlatformPrivacyDefaults()'),
    );
    expect(captureEntrypoint, isNot(contains('buildDefaultDriver')));
    expect(captureEntrypoint, isNot(contains('CgmAppController')));

    expect(nativeBridge, contains('TARGET_UNVERIFIED_PROBE_GRANT_FILE'));
    expect(
      nativeBridge,
      contains('target-unverified-nfc-grant.json'),
    );
    expect(
      nativeBridge,
      contains('target-unverified-gen1-fram-read-grant.json'),
    );
    expect(
      nativeBridge,
      contains('target_unverified_gen1_fram_read'),
    );
    expect(
      nativeBridge,
      contains('target-unverified-gen1-activation-grant.json'),
    );
    expect(
      nativeBridge,
      contains('target_unverified_gen1_activation'),
    );
    expect(
      nativeBridge,
      contains('nfc-gen1-activation-journal.json'),
    );
    expect(nativeBridge, contains('nfc-patch-info-context.json'));
    expect(nativeBridge, contains('nfc-gen1-fram-capture.json'));
    expect(nativeBridge, contains('nfc-grant-context.json'));
    expect(nativeBridge, contains('capture-status.json'));
    expect(nativeBridge, contains('setBleCaptureStatus'));
    expect(nativeBridge, contains('stopProtocolCapture'));
    expect(nativeBridge, contains('lastCommittedBleSequence'));
    expect(nativeBridge, contains('heartbeatMonotonicMicroseconds'));
    expect(
      nativeBridge,
      contains('MAX_STANDARD_GRANT_LIFETIME_MILLIS = 120_000L'),
    );
    expect(
      nativeBridge,
      contains('MAX_GEN1_FRAM_READ_GRANT_LIFETIME_MILLIS =\n      300_000L'),
    );
    expect(
      publishedGrantEnvelope,
      contains('kind == Kind.GEN1_FRAM_READ'),
    );
    expect(
      publishedGrantEnvelope,
      contains(': maxStandardLifetimeMillis'),
    );
    expect(nativeBridge, contains('expiresAtElapsedRealtimeNanos'));
    expect(nativeBridge, contains('strictJsonInteger'));
    expect(nativeBridge, contains('expiresAt > issuedAt'));
    expect(nativeBridge, contains('expectedCaptureEpoch != captureEpoch'));
    expect(nativeBridge, contains('invalidateCaptureStatusForEpoch'));
    expect(nativeBridge, contains('grantNonce.equals('));
    expect(nativeBridge, contains('installedLastUpdateTime'));
    expect(nativeBridge, contains('Treat transmission as R3'));
    expect(nativeBridge, contains('LIBRE_PATCH_INFO_FLAGS = (byte) 0x02'));
    expect(nativeBridge, contains('LIBRE_PATCH_INFO_CODE = (byte) 0xA1'));
    expect(nativeBridge, contains('uid.length != 8'));
    expect(nativeBridge, contains('uid[6]'));
    expect(nativeBridge, isNot(contains('(byte) 0xA0')));
    expect(nativeBridge, isNot(contains('removeBond')));
    expect(nativeBridge, isNot(contains('createBond')));
    expect(nativeBridge, contains('isExactProtocolCaptureFilter'));
    expect(
      nativeBridge,
      contains('serviceUuids.length() == 1'),
    );
    expect(
      nativeBridge,
      contains('serviceUuids.length() == 2'),
    );
    expect(
      nativeBridge,
      contains('AIDEX_CGM_SERVICE_UUID.equals(serviceUuids.optString(1'),
    );
    expect(
      nativeBridge,
      contains('LIBRE2_REFERENCE_SERVICE_UUID.equals(serviceUuids.optString'),
    );
    String guardedTransceiveBody(String methodName, String nextDeclaration) {
      final start = nativeBridge.indexOf('private byte[] $methodName(');
      final end = nativeBridge.indexOf(nextDeclaration, start);
      expect(start, greaterThanOrEqualTo(0), reason: '$methodName exists');
      expect(end, greaterThan(start), reason: '$methodName has a closed body');
      return nativeBridge.substring(start, end);
    }

    final guardedTransceiveBodies = <String, String>{
      'probe': guardedTransceiveBody(
        'transceiveProbeAuthorized',
        'private byte[] transceiveFramAuthorized(',
      ),
      'fram': guardedTransceiveBody(
        'transceiveFramAuthorized',
        'private byte[] transceiveActivationAuthorized(',
      ),
      'activation': guardedTransceiveBody(
        'transceiveActivationAuthorized',
        'private byte[] transceiveExplicitNfcSetupAuthorized(',
      ),
      'explicitPatch': guardedTransceiveBody(
        'transceiveExplicitNfcSetupAuthorized',
        'private byte[] transceiveExplicitNfcFramAuthorized(',
      ),
      'explicitFram': guardedTransceiveBody(
        'transceiveExplicitNfcFramAuthorized',
        'private boolean advanceExplicitNfcSetupState(',
      ),
      'streaming': guardedTransceiveBody(
        'transceiveStreamingAuthorized',
        'private static final class StreamingAttempt',
      ),
    };
    final guardedAuthorizationChecks = <String, String>{
      'probe': 'isRfAuthorizedLocked(',
      'fram': 'isFramRfAuthorizedLocked(',
      'activation': 'isActivationRfAuthorizedLocked(',
      'explicitPatch': 'isExplicitNfcSetupRfAuthorizedLocked(',
      'explicitFram': 'isExplicitNfcSetupRfAuthorizedLocked(',
      'streaming': 'requireStreamingAuthorized(',
    };
    for (final entry in guardedTransceiveBodies.entries) {
      expect(
        entry.value,
        contains('synchronized (rfAuthorizationLock)'),
        reason: '${entry.key} holds the authorization lock through RF',
      );
      expect(
        entry.value,
        contains(guardedAuthorizationChecks[entry.key]),
        reason: '${entry.key} performs its final authorization check',
      );
      expect(
        'nfcV.transceive(request);'.allMatches(entry.value),
        hasLength(1),
        reason: '${entry.key} has exactly one guarded RF send',
      );
    }
    expect(
      'nfcV.transceive(request);'.allMatches(nativeBridge),
      hasLength(guardedTransceiveBodies.length),
      reason: 'no raw transceive exists outside a guarded wrapper',
    );
    final streamingSend = guardedTransceiveBodies['streaming']!;
    expect(streamingSend, contains('attempt.sequence.consume(request)'));
    expect(
      streamingSend.indexOf('attempt.sequence.consume(request)'),
      lessThan(streamingSend.indexOf('nfcV.transceive(request)')),
      reason: 'the exact streaming send slot is consumed before RF I/O',
    );
    final streamingCapture = nativeBridge.substring(
      nativeBridge.indexOf('private void captureStreamingTag('),
      nativeBridge.indexOf('private boolean finishStreamingRfLease('),
    );
    expect(
      streamingCapture,
      contains('closeNfcVQuietly(nfcV) && !attempt.closeUncertain'),
    );
    expect(
      streamingCapture,
      contains('closed, audited, () -> finishStreamingRfLease(lease)'),
    );
    expect(
      streamingCapture.indexOf('finishStreamingRfLease(lease)'),
      lessThan(streamingCapture.indexOf('.confirm(')),
      reason:
          'bootstrap promotion follows proven close, audit and exact lease release',
    );
    expect(
      streamingCapture,
      isNot(contains('finishRfTransactionLease(lease)')),
    );
    expect(
      nativeBridge,
      contains('inFlightNfcV == expectedNfcV'),
      reason: 'explicit authorization binds the active NFC connection',
    );
    expect(
      'transceiveProbeAuthorized('.allMatches(nativeBridge),
      hasLength(2),
    );
    expect(
      'transceiveExplicitNfcSetupAuthorized('.allMatches(nativeBridge),
      hasLength(2),
    );
    expect(
      'transceiveExplicitNfcFramAuthorized('.allMatches(nativeBridge),
      hasLength(2),
    );
    expect(
      'transceiveFramAuthorized('.allMatches(nativeBridge),
      hasLength(3),
    );
    expect(
      'transceiveActivationAuthorized('.allMatches(nativeBridge),
      hasLength(4),
    );
    expect(
      'transceiveStreamingAuthorized('.allMatches(nativeBridge),
      hasLength(4),
      reason:
          'streaming exposes only patch, fixed FRAM and one enable call sites',
    );
    expect(
      streamingCapture,
      contains('intent ? "outcomeUnknown" : failureReason'),
      reason: 'every post-intent cleanup failure stays an unknown send outcome',
    );
    final activationUiQueries = nativeBridge.substring(
      nativeBridge.indexOf('private boolean handleLibreActivationUiMethod('),
      nativeBridge.indexOf('private boolean handleLibreStreamingMethod('),
    );
    expect(activationUiQueries, contains('Libre2ActivationUiProof.verified('));
    expect(
      activationUiQueries,
      contains('Libre2ActivationUiProof.currentBindings('),
    );
    expect(
      activationUiQueries,
      contains('LibreGen1Activation.validatedLifecycle('),
    );
    expect(activationUiQueries, contains('OsConstants.O_NOFOLLOW'));
    expect(
      activationUiQueries,
      contains('result.put("event", "activationVerified")'),
    );
    expect(
      activationUiQueries,
      contains('result.put("lifecycleAtActivation", "warmingUp")'),
    );
    expect(activationUiQueries, isNot(contains('transceive(')));
    expect(activationUiQueries, isNot(contains('writePrivateJson(')));
    expect(
      nativeBridge.indexOf(
        'publishVerifiedActivationUiForEpoch(expectedCaptureEpoch);',
      ),
      greaterThan(
        nativeBridge.indexOf('"nfc.gen1_activation.post_state_verified"'),
      ),
      reason:
          'correlated activation UI follows persisted proof and verified-state trace',
    );
    expect(nativeBridge, contains('synchronized (rfAuthorizationLock)'));
    expect(
      nativeBridge,
      contains('claimExplicitForMaintenance(attempt)'),
      reason: 'lifecycle cleanup promotes only the exact explicit attempt',
    );
    expect(
      nativeBridge,
      contains('claimHostForMaintenance(hostLease)'),
      reason: 'lifecycle cleanup promotes only the captured host lease',
    );
    expect(
      nativeBridge,
      contains('isHeldByMaintenance(maintenanceLease)'),
      reason: 'maintenance mutations verify their exact lease token',
    );
    expect(
      nativeBridge,
      contains('attempt != failedAttempt'),
      reason: 'a stale explicit callback cannot fail a replacement attempt',
    );
    expect(rfLeaseBinding, isNot(contains('takeAny(')));
    expect(rfLeaseBinding, isNot(contains('claimForMaintenance(')));
    expect(
      rfLeaseBinding,
      contains('lease != expectedLease'),
      reason: 'host and maintenance release paths require exact identity',
    );
    final revokeStart = nativeBridge.indexOf(
      'private void revokeRfEligibility(boolean deleteGrant)',
    );
    final revokeEnd = nativeBridge.indexOf(
      'private void finishRfEligibilityRevocation(',
      revokeStart,
    );
    expect(revokeStart, greaterThanOrEqualTo(0));
    expect(revokeEnd, greaterThan(revokeStart));
    final revokeBody = nativeBridge.substring(revokeStart, revokeEnd);
    expect(
      revokeBody.indexOf('closeNfcVQuietly(cancelled)'),
      lessThan(revokeBody.indexOf('finishRfEligibilityRevocation(')),
      reason: 'the NFC transport closes before cleanup releases the RF lease',
    );
    expect(nativeBridge, contains('EXPLICIT_LIBRE2_SETUP_OPERATION'));
    expect(nativeBridge, contains('startLibre2NfcSetup'));
    expect(nativeBridge, contains('stopLibre2NfcSetup'));
    expect(nativeBridge, contains('LibreGen1NfcFrames.frames()'));
    expect(nativeBridge, contains('LibreGen1Activation.validatedLifecycle('));
    final explicitReadinessStart = rfReadiness.indexOf(
      'static boolean isExplicitUnclaimedReady(',
    );
    final explicitReadinessBody = rfReadiness.substring(
      explicitReadinessStart,
    );
    expect(explicitReadinessStart, greaterThanOrEqualTo(0));
    expect(
      explicitReadinessBody,
      isNot(contains('bleCaptureRfEligible')),
      reason: 'the app-owned explicit NFC lane is independent from BLE',
    );
    expect(
      rfReadiness,
      contains('static boolean isHostReady('),
      reason: 'host RF retains its separate BLE health gate',
    );
    expect(
      nativeBridge,
      contains('revokeBleHostRfEligibility(true);'),
      reason: 'valid BLE-ineligible status revokes only the host RF lane',
    );
    final readerStatusStart = nativeBridge.indexOf(
      'private void publishReaderStatusForEpoch(',
    );
    final readerStatusEnd = nativeBridge.indexOf(
      'private boolean hasNfcPermission()',
      readerStatusStart,
    );
    expect(readerStatusStart, greaterThanOrEqualTo(0));
    expect(readerStatusEnd, greaterThan(readerStatusStart));
    final readerStatusBody = nativeBridge.substring(
      readerStatusStart,
      readerStatusEnd,
    );
    expect(
      readerStatusBody,
      contains('attempt.isClaimed()'),
      reason: 'claimed attempts suppress stale reader-status publication',
    );
    expect(
      readerStatusBody,
      contains('inFlightExplicitNfcSetupAttemptId'),
      reason: 'in-flight attempts suppress BLE-triggered UI regression',
    );
    final invalidateStatusStart = nativeBridge.indexOf(
      'private void invalidateCaptureStatus()',
    );
    final invalidateStatusEnd = nativeBridge.indexOf(
      'private void invalidateCaptureStatusForEpoch(',
      invalidateStatusStart,
    );
    expect(invalidateStatusStart, greaterThanOrEqualTo(0));
    expect(invalidateStatusEnd, greaterThan(invalidateStatusStart));
    expect(
      nativeBridge.substring(invalidateStatusStart, invalidateStatusEnd),
      contains('revokeRfEligibility(true);'),
      reason: 'capture invalidation still cancels every RF lane',
    );
    expect(
      nativeBridge,
      contains('attempt.consumePatchInfoTransceiveOnce(request)'),
      reason: 'one explicit attempt can send patch-info only once',
    );
    expect(
      nativeBridge,
      contains('attempt.consumeFramTransceive(frameIndex, request)'),
      reason: 'every explicit FRAM send consumes its exact frame slot',
    );
    expect(nativeBridge, contains('request.length != 3'));
    expect(
      nativeBridge,
      contains('request[1] != LIBRE_PATCH_INFO_CODE'),
      reason: 'the explicit wrapper rejects non-A1 commands at runtime',
    );
    final explicitCaptureStart = nativeBridge.indexOf(
      'private void captureExplicitLifecycleOnce(',
    );
    final explicitCaptureEnd = nativeBridge.indexOf(
      'private void captureGen1FramOnce(',
      explicitCaptureStart,
    );
    expect(explicitCaptureStart, greaterThanOrEqualTo(0));
    expect(explicitCaptureEnd, greaterThan(explicitCaptureStart));
    final explicitCaptureBody = nativeBridge.substring(
      explicitCaptureStart,
      explicitCaptureEnd,
    );
    final terminalizerStart = nativeBridge.indexOf(
      'private NfcRfTransactionLease terminalizeExplicitNfcSetupAttempt(',
    );
    final terminalizerEnd = nativeBridge.indexOf(
      'private void publishCancelledExplicitAttempt(',
      terminalizerStart,
    );
    expect(terminalizerStart, greaterThanOrEqualTo(0));
    expect(terminalizerEnd, greaterThan(terminalizerStart));
    final terminalizerBody = nativeBridge.substring(
      terminalizerStart,
      terminalizerEnd,
    );
    expect(
      terminalizerBody.indexOf('claimExplicitForMaintenance(attempt)'),
      lessThan(
        terminalizerBody.indexOf('closeNfcVQuietly(boundNfcV)'),
      ),
      reason: 'the exact filesystem lease is retained before transport close',
    );
    expect(
      terminalizerBody.indexOf('closeNfcVQuietly(boundNfcV)'),
      lessThan(
        terminalizerBody.indexOf('appendReservedEventForEpoch('),
      ),
      reason: 'the NFC transport closes before durable terminal audit',
    );
    expect(
      terminalizerBody.indexOf('appendReservedEventForEpoch('),
      lessThan(
        terminalizerBody.indexOf(
          'attempt.takeTraceReservationForTerminalization()',
        ),
      ),
      reason: 'terminal audit precedes exact reservation release',
    );
    expect(
      terminalizerBody,
      contains('maintenance-bound filesystem lease'),
      reason: 'audit failure retains the lease as fail-closed quarantine',
    );
    expect(
      terminalizerBody,
      isNot(contains('finishAuthorizationMutationLease(')),
      reason: 'the terminal lock is released before lease unbinding',
    );
    expect(
      explicitCaptureBody,
      contains('terminalizeExplicitNfcSetupAttempt('),
      reason: 'normal callback completion uses the same exact terminalizer',
    );
    expect(
      explicitCaptureBody,
      isNot(contains('appendReservedEventForEpoch(')),
      reason: 'a stale explicit callback never uses the generic reservation',
    );
    expect(
      'appendExplicitReservedEventForEpoch('.allMatches(explicitCaptureBody),
      hasLength(1),
      reason: 'the batched explicit sequence audit is attempt-bound',
    );
    expect(
      'transceiveExplicitNfcSetupAuthorized('.allMatches(explicitCaptureBody),
      hasLength(1),
      reason: 'the explicit lifecycle uses one patch-info call site',
    );
    expect(
      'transceiveExplicitNfcFramAuthorized('.allMatches(explicitCaptureBody),
      hasLength(1),
      reason: 'the fixed 15-frame loop uses one guarded FRAM call site',
    );
    expect(
      explicitCaptureBody,
      isNot(contains('activationRequest(')),
      reason: 'the explicit lifecycle path never sends an activation command',
    );
    expect(
      explicitCaptureBody.indexOf('terminalizeExplicitNfcSetupAttempt('),
      lessThan(
        explicitCaptureBody.indexOf('finishAuthorizationMutationLease('),
      ),
      reason: 'normal completion audits before releasing the exact lease',
    );
    expect(
      terminalizerBody.indexOf('synchronized (rfAuthorizationLock)'),
      lessThan(
        terminalizerBody.indexOf('synchronized (explicitNfcTerminalLock)'),
      ),
      reason: 'terminalization follows the global RF-to-terminal lock order',
    );
    final explicitAppendStart = nativeBridge.indexOf(
      'private boolean appendExplicitReservedEventForEpoch(',
    );
    final explicitAppendEnd = nativeBridge.indexOf(
      'private boolean hasUnreservedExplicitNfcSetupTraceCapacity(',
      explicitAppendStart,
    );
    expect(explicitAppendStart, greaterThanOrEqualTo(0));
    expect(explicitAppendEnd, greaterThan(explicitAppendStart));
    final explicitAppendBody = nativeBridge.substring(
      explicitAppendStart,
      explicitAppendEnd,
    );
    expect(
      explicitAppendBody,
      contains('explicitNfcSetupAttempt != attempt'),
      reason: 'reserved audit requires the exact active attempt object',
    );
    expect(
      explicitAppendBody,
      contains('!attempt.hasActiveTraceReservation()'),
      reason: 'reserved audit requires exact live reservation ownership',
    );
    expect(
      explicitAppendBody.indexOf('synchronized (rfAuthorizationLock)'),
      lessThan(
        explicitAppendBody.indexOf(
          'synchronized (explicitNfcTerminalLock)',
        ),
      ),
      reason: 'callback audit follows RF-to-terminal lock order',
    );
    final metadataRecordStart = nativeBridge.indexOf(
      'private PatchInfoClassification recordMetadataRead(',
    );
    final metadataRecordEnd = nativeBridge.indexOf(
      'private static PatchInfoClassification classifyPatchInfo(',
      metadataRecordStart,
    );
    final metadataRecordBody = nativeBridge.substring(
      metadataRecordStart,
      metadataRecordEnd,
    );
    expect(
      metadataRecordBody,
      contains(': appendExplicitReservedEventForEpoch('),
      reason: 'explicit classification audit is also attempt-bound',
    );

    String lifecycleBody(String startMarker, String endMarker) {
      final start = nativeBridge.indexOf(startMarker);
      final end = nativeBridge.indexOf(endMarker, start);
      expect(start, greaterThanOrEqualTo(0), reason: '$startMarker exists');
      expect(end, greaterThan(start), reason: '$startMarker has a body');
      return nativeBridge.substring(start, end);
    }

    final explicitCancellationBodies = <String, String>{
      'pause': lifecycleBody('void onPause()', 'void close()'),
      'capture stop': lifecycleBody(
        'private synchronized void stopNfcCapture()',
        'private void updateReaderMode()',
      ),
      'explicit stop': lifecycleBody(
        'private void stopExplicitNfcSetup(',
        'private void expireExplicitNfcSetup(',
      ),
      'explicit expiry': lifecycleBody(
        'private void expireExplicitNfcSetup(',
        'private void publishReaderStatusForEpoch(',
      ),
      'explicit failure': lifecycleBody(
        'private boolean failExplicitNfcSetupForEpoch(',
        'private NfcRfTransactionLease terminalizeExplicitNfcSetupAttempt(',
      ),
      'capture restart': lifecycleBody(
        'private NfcRfTransactionLease beginCapturePreparationLease(',
        'private synchronized void prepareCaptureDirectory(',
      ),
      'BLE expiry fallback': lifecycleBody(
        'private void revokeBleHostRfEligibilityIfStatusMatches(',
        'private void revokeBleHostRfEligibility(',
      ),
      'BLE revocation fallback': lifecycleBody(
        'private void revokeBleHostRfEligibility(',
        'private void revokeRfEligibility(',
      ),
      'global revocation': lifecycleBody(
        'private void revokeRfEligibility(',
        'private void finishRfEligibilityRevocation(',
      ),
    };
    for (final entry in explicitCancellationBodies.entries) {
      expect(
        entry.value,
        contains('terminalizeExplicitNfcSetupAttempt('),
        reason: '${entry.key} uses the shared exact-attempt terminalizer',
      );
      expect(
        entry.value,
        isNot(contains('explicitNfcSetupAttempt = null')),
        reason: '${entry.key} cannot bypass terminalization ownership',
      );
    }
    expect(
      explicitExpiryBinding,
      contains('attempt != expectedAttempt'),
      reason: 'a stale terminal winner cannot take replacement expiry',
    );
    expect(
      nativeBridge,
      contains('explicitNfcSetupExpiryBinding.bind(attempt, expiry)'),
      reason: 'expiry registration is bound to the exact attempt object',
    );
    expect(
      nativeBridge,
      isNot(contains('cancelExplicitNfcSetupExpiry()')),
      reason: 'no lifecycle path can globally cancel replacement expiry',
    );
    for (final entry in <String, String>{
      'explicit stop': explicitCancellationBodies['explicit stop']!,
      'explicit failure': explicitCancellationBodies['explicit failure']!,
      'normal completion': explicitCaptureBody,
    }.entries) {
      expect(
        entry.value.indexOf('cancelExplicitNfcSetupExpiry('),
        lessThan(entry.value.indexOf('finishAuthorizationMutationLease(')),
        reason:
            '${entry.key} cancels exact expiry before releasing its RF lease',
      );
    }
    expect(
      nativeBridge,
      contains('response.length != 7 || (response[0] & 0x01) != 0'),
    );
    expect(nativeBridge, contains('EVENT_CHANNEL_NAME'));
    expect(nativeBridge, contains('!"failed".equals(event)'));
    expect(
      nativeBridge,
      isNot(contains('mainHandler.removeCallbacksAndMessages(null)')),
      reason: 'bulk callback removal must not drop queued explicit events',
    );
    expect(nativeBridge, contains('rfEligibilityHandler'));
    expect(nativeBridge, contains('scheduleRfEligibilityExpiry('));
    expect(nativeBridge, contains('expireRfEligibilityIfStale('));
    expect(
      nativeBridge,
      contains('revokeBleHostRfEligibilityIfStatusMatches('),
    );
    expect(nativeBridge, contains('activity.getFilesDir()'));
    expect(nativeBridge, isNot(contains('Log.')));
    expect(
      nativeBridge,
      contains('"nfc.transceive.request", request)'),
    );
    expect(nativeBridge, contains('grant.length() == 13'));
    expect(nativeBridge, contains('grant.length() == 20'));
    expect(nativeBridge, contains('source.length() == 16'));
    expect(
      nativeBridge,
      contains('sourceSchemaVersion == GRANT_SCHEMA_VERSION'),
    );
    expect(nativeBridge, contains('patchContext.length() == 12'));
    expect(
      nativeBridge,
      contains('capture.length() != (explicitAttempt == null ? 16 : 18)'),
    );
    expect(
      nativeBridge,
      contains('final byte[] algorithmOrderUid = androidTagId.clone()'),
    );
    expect(nativeBridge, isNot(contains('reverseCopy(')));
    expect(nativeBridge, contains('sha256PatchInfoPayload'));
    expect(
      'persistPatchInfoContext('.allMatches(nativeBridge),
      hasLength(4),
      reason: 'three host call sites plus one explicit lifecycle call site',
    );
    expect(
      nativeBridge,
      contains('Arrays.copyOfRange(response, 1, response.length)'),
    );
    expect(nativeBridge, contains('"algorithmOrderUidHex"'));
    expect(nativeBridge, contains('"patchInfoHex"'));
    expect(nativeBridge, contains('"encryptedFramHex"'));
    expect(nativeBridge, contains('"captureSessionId"'));
    expect(
      nativeBridge,
      contains('maxTransceiveLength < LibreGen1NfcFrames.MAX_RESPONSE_BYTES'),
    );

    expect(gen1Frames, contains('ISO15693_READ_MULTIPLE_BLOCKS'));
    expect(gen1Frames, contains('(byte) 0x23'));
    expect(gen1Frames, contains('MAX_BLOCKS_PER_REQUEST = 3'));
    expect(gen1Frames, contains('REQUEST_COUNT = 15'));
    expect(gen1Frames, contains('FRAM_BYTES = 344'));
    expect(gen1Frames, contains('response.length != expectedLength'));
    expect(gen1Frames, contains('(response[0] & 0x01) != 0'));
    expect(gen1Frames, isNot(contains('(byte) 0x20')));
    expect(gen1Frames, isNot(contains('(byte) 0xB3')));
    expect(gen1Frames, isNot(contains('transceive')));

    expect(gen1Activation, contains('ACTIVATION_REQUEST_BYTES = 8'));
    expect(gen1Activation, contains('ACTIVATION_RESPONSE_BYTES = 5'));
    expect(gen1Activation, contains('algorithmOrderUid[6]'));
    expect(gen1Activation, contains('(byte) 0x1b'));
    expect(
      gen1Activation,
      contains('response.length != ACTIVATION_RESPONSE_BYTES'),
    );
    expect(gen1Activation, contains('(response[0] & 0x01) != 0'));
    expect(gen1Activation, contains('requireRegionCrc(clear, 0, 24)'));
    expect(gen1Activation, contains('requireRegionCrc(clear, 24, 320)'));
    expect(gen1Activation, contains('requireRegionCrc(clear, 320, 344)'));
    expect(gen1Activation, isNot(contains('transceive')));

    final intentIndex = nativeBridge.indexOf(
      '"transmit_intent_committed",\n          "unknown_outcome",',
    );
    final activationSendIndex = nativeBridge.indexOf(
      'final byte[] activationResponse =\n'
      '          transceiveActivationAuthorized(',
    );
    final responseJournalIndex = nativeBridge.indexOf(
      '"response_received",\n          "unknown_outcome",',
    );
    final verifiedJournalIndex = nativeBridge.indexOf(
      '"post_state_verified",\n          "verified",',
    );
    expect(intentIndex, greaterThanOrEqualTo(0));
    expect(activationSendIndex, greaterThan(intentIndex));
    expect(responseJournalIndex, greaterThan(activationSendIndex));
    expect(verifiedJournalIndex, greaterThan(responseJournalIndex));
  });
}
