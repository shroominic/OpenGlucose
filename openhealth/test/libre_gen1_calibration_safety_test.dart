import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/java/com/aidex/aidex_flutter/';

  test(
    'calibration query cannot write cache, reserve counters or operate RF',
    () {
      final bridge = File(
        '${native}DebugProtocolCaptureBridge.java',
      ).readAsStringSync();
      final query = bridge.substring(
        bridge.indexOf(
          'private Map<String, Object> readMatchedCalibrationEvidence(',
        ),
        bridge.indexOf(
          'private LibreGen1CalibrationPersistence.Result preserveMatchedCalibrationEvidence(',
        ),
      );
      expect(query, contains('synchronized (journal)'));
      expect(query, contains('record.state.equals("confirmed")'));
      expect(query, contains('record.bootstrapId.equals(bootstrapId)'));
      expect(query, contains('record.uid, record.initialPatchInfo'));
      expect(query, contains('LibreGen1CalibrationEvidence.decode('));
      expect(query, contains('LibreGen1CalibrationEvidence.fromCapture('));
      expect(query, contains('readActivationUiProofFile('));
      for (final forbidden in [
        '.write',
        '.reserve(',
        '.prepare(',
        '.confirm(',
        '.mark(',
        'transceive(',
        'startStreaming',
        'enableReaderMode',
        'appendEvent',
        'publishUiEvent',
        'listFiles(',
      ]) {
        expect(query, isNot(contains(forbidden)), reason: forbidden);
      }
      expect(
        RegExp(
          r'value\.put\("([A-Za-z]+)"',
        ).allMatches(query).map((match) => match.group(1)).toSet(),
        {
          'bootstrapId',
          'uid',
          'receiverInitialPatchInfo',
          'calibrationPatchInfo',
          'encryptedFram',
        },
      );
    },
  );

  test(
    'persistent calibration is independent, protected and readback verified',
    () {
      final source = File(
        '${native}LibreGen1CalibrationStore.java',
      ).readAsStringSync();
      expect(source, contains('context.getNoBackupFilesDir()'));
      expect(source, contains('openglucose_libre_gen1_calibration_v1'));
      expect(source, contains('AES/GCM/NoPadding'));
      expect(source, contains('cipher.updateAAD(AAD)'));
      expect(source, contains('OsConstants.O_NOFOLLOW'));
      expect(source, contains('OsConstants.O_EXCL'));
      expect(source, contains('(stat.st_mode & 0777) != 0600'));
      expect(source, contains('stat.st_uid != android.os.Process.myUid()'));
      expect(source, contains('stat.st_size > 541'));
      expect(source, contains('Os.lstat('));
      expect(source, contains('Os.rename('));
      expect(source, contains('output.getFD().sync()'));
      expect(source, contains('Os.fsync(parent)'));
      expect(source, contains('Arrays.equals(clear, confirmed)'));
      expect(source, isNot(contains('LibreGen1StreamingStore')));
      expect(source, isNot(contains('LibreGen1StreamingJournal')));
      final read = source.substring(
        source.indexOf('byte[] read()'),
        source.indexOf('void writeVerified('),
      );
      expect(read, contains('key(false)'));
      expect(read, isNot(contains('key(true)')));
      expect(read, isNot(contains('write(')));
    },
  );

  test(
    'preservation requires a successful explicit read and exact receiver',
    () {
      final bridge = File(
        '${native}DebugProtocolCaptureBridge.java',
      ).readAsStringSync();
      final read = bridge.substring(
        bridge.indexOf('private void captureExplicitLifecycleOnce('),
        bridge.indexOf('private void captureGen1FramOnce('),
      );
      expect(
        read.indexOf('preserveMatchedCalibrationEvidence('),
        greaterThan(read.indexOf('if (terminalized)')),
      );
      expect(
        read.indexOf('preserveMatchedCalibrationEvidence('),
        greaterThan(
          read.indexOf('finishAuthorizationMutationLease(terminalLease)'),
        ),
      );
      expect(read, contains('terminalFailureReason != null'));
      final preserve = bridge.substring(
        bridge.indexOf(
          'private LibreGen1CalibrationPersistence.Result preserveMatchedCalibrationEvidence(',
        ),
        bridge.indexOf('private void recordCalibrationCacheResultAfterUi('),
      );
      for (final guard in [
        'expectedEpoch != captureEpoch',
        '!captureReady',
        '!captureWritable',
        '!rfTransactionLeaseBinding.isEmpty()',
        'synchronized (journal)',
      ]) {
        expect(preserve, contains(guard));
      }
      final policy = File(
        '${native}LibreGen1CalibrationPersistence.java',
      ).readAsStringSync();
      expect(policy, contains('"confirmed".equals(receiver.state)'));
      expect(policy, contains('Arrays.equals(uid, receiver.uid)'));
      expect(
        policy,
        contains(
          'LibreGen1CalibrationEvidence.matchesReceiverPatch(receiver.initialPatchInfo, patch)',
        ),
      );
      expect(preserve, contains('LibreGen1CalibrationPersistence.preserve('));
      expect(
        preserve,
        contains(
          'evidence -> new LibreGen1CalibrationStore(activity).writeVerified(evidence)',
        ),
      );
      expect(
        policy.indexOf('writer.writeVerified(owned)'),
        greaterThan(policy.indexOf('LibreGen1CalibrationEvidence.verified(')),
      );
      expect(
        policy.indexOf('return Result.SAVED'),
        greaterThan(policy.indexOf('writer.writeVerified(owned)')),
      );
      expect(preserve, isNot(contains('transceive(')));
      expect(preserve, isNot(contains('.reserve(')));
    },
  );

  test('cache diagnostics stay closed and follow the original NFC result', () {
    final bridge = File(
      '${native}DebugProtocolCaptureBridge.java',
    ).readAsStringSync();
    final read = bridge.substring(
      bridge.indexOf('private void captureExplicitLifecycleOnce('),
      bridge.indexOf('private void captureGen1FramOnce('),
    );
    final cache = read.substring(
      read.indexOf('final LibreGen1CalibrationPersistence.Result cacheResult'),
    );
    expect(
      cache.indexOf('recordCalibrationCacheResultAfterUi('),
      greaterThan(cache.indexOf('publishExplicitUiEventForEpoch(')),
    );
    expect(cache, contains('"metadataRead"'));
    final diagnostic = bridge.substring(
      bridge.indexOf('private void recordCalibrationCacheResultAfterUi('),
      bridge.indexOf('private void startStreamingAttempt('),
    );
    expect(
      diagnostic.indexOf('statusExecutor.execute('),
      greaterThan(diagnostic.indexOf('mainHandler.post(')),
    );
    expect(
      diagnostic,
      contains(
        'appendEventForEpoch(expectedEpoch, "nfc.calibration.cache", data)',
      ),
    );
    expect(
      RegExp(
        r'put\(data, "([A-Za-z]+)"',
      ).allMatches(diagnostic).map((match) => match.group(1)).toSet(),
      {'outcome', 'reason'},
    );
    for (final forbidden in [
      '.getMessage(',
      '.getCause(',
      '.toString(',
      'hex(',
      'transceive(',
      '.reserve(',
      '.mark(',
      '.confirm(',
      'captureWritable =',
      'captureReady =',
      'uiEventSink.success(',
    ]) {
      expect(diagnostic, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
