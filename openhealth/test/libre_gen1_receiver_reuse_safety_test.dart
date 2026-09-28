import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/java/com/aidex/aidex_flutter/';

  test('saved receiver proof is read-only and fails closed at delivery', () {
    final bridge = File(
      '${native}DebugProtocolCaptureBridge.java',
    ).readAsStringSync();
    final query = bridge.substring(
      bridge.indexOf('private boolean handleLibreReceiverReuseProofMethod('),
      bridge.indexOf('private boolean handleLibreActivationUiMethod('),
    );
    expect(query, contains('readLibreGen1ReceiverReuseProof'));
    expect(query, contains('exactStreamingArguments(arguments, 1)'));
    expect(query, contains('statusExecutor.execute('));
    expect(query, contains('synchronized (captureEpochLock)'));
    expect(query, contains('synchronized (rfAuthorizationLock)'));
    expect(query, contains('synchronized (journal)'));
    expect(query, contains('receiver = journal.read()'));
    expect(query, contains('receiverPresent != (receiver != null)'));
    expect(query, contains('receiverPresent != receiverReuseRecordPresent()'));
    expect(query, contains('"libre-gen1-streaming-v1.bin"'));
    expect(query, contains('OsConstants.S_ISREG(record.st_mode)'));
    expect(query, contains('(record.st_mode & 0777) != 0600'));
    expect(query, contains('record.st_uid != android.os.Process.myUid()'));
    expect(query, contains('record.st_size < 30 || record.st_size > 2048'));
    expect(query, contains('absent.errno == OsConstants.ENOENT) return false'));
    expect(query, contains('readActivationUiProofFile('));
    expect(query, contains('LibreGen1ReceiverReuseProof.read('));
    expect(query, contains('sessionToken, expectedDartProcessSessionId'));
    expect(query, contains('expectedEpoch != captureEpoch'));
    expect(query, contains('expectedGeneration != rfAuthorizationGeneration'));
    for (final guard in [
      '!captureRequested',
      '!resumed',
      '!captureReady',
      '!captureWritable',
      'explicitNfcSetupAttempt != null',
      'streamingAttempt != null',
      'nfcCallbackActive',
      'inFlightNfcV != null',
      '!rfTransactionLeaseBinding.isEmpty()',
      'grantKindForEpoch(expectedEpoch) != GrantKind.NONE',
      'OsConstants.S_ISDIR(directory.st_mode)',
      'directory.st_uid != android.os.Process.myUid()',
      '(directory.st_mode & 0777) != 0700',
      'NfcRfTransactionLease.DIRECTORY_NAME',
      'absent.errno == OsConstants.ENOENT',
    ]) {
      expect(query, contains(guard), reason: guard);
    }
    final delivery = query.substring(
      query.indexOf('postResult(() -> {'),
      query.indexOf('result.success(proof)'),
    );
    expect(
      delivery,
      contains(
        'requireReceiverReuseQueryReadyLocked(expectedEpoch, expectedGeneration)',
      ),
    );
    expect(query, contains('libre_receiver_reuse_unavailable'));
    for (final forbidden in [
      '.prepare(',
      '.reserve(',
      '.confirm(',
      '.mark(',
      '.write(',
      '.commitIntent(',
      'startStreamingAttempt(',
      'transceive(',
      'enableReaderMode(',
      'tryAcquire(',
      'delete',
      'mkdir',
      'appendEvent',
      'publishUiEvent',
      'result.success(null)',
      '.getMessage(',
    ]) {
      expect(query, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('pure proof emits only the exact closed fresh-read result', () {
    final helper = File(
      '${native}LibreGen1ReceiverReuseProof.java',
    ).readAsStringSync();
    expect(helper, contains('Libre2ActivationUiProof.parse(sourceJson)'));
    expect(helper, contains('source.keySet().equals(KEYS)'));
    expect(helper, contains('Long.valueOf(2).equals'));
    expect(helper, contains('120_000_000_000L'));
    expect(
      helper,
      contains('attemptId.equals(source.get("explicitAttemptId"))'),
    );
    expect(helper, contains('Arrays.equals(uid, receiver.uid)'));
    expect(helper, contains('"confirmed".equals(receiver.state)'));
    expect(
      helper.indexOf('if (receiver == null) return null'),
      greaterThan(
        helper.indexOf('LibreGen1Streaming.requireLifecycle(lifecycle)'),
      ),
    );
    expect(
      helper,
      contains('LibreGen1Activation.validatedLifecycle(uid, patch, fram)'),
    );
    expect(
      RegExp(
        r'proof\.put\("([A-Za-z]+)"',
      ).allMatches(helper).map((match) => match.group(1)).toSet(),
      {'attemptId', 'event', 'model', 'lifecycle'},
    );
    for (final forbidden in [
      'android.',
      'java.nio.file',
      'java.io.File',
      'java.net',
      'transceive(',
      '.reserve(',
      '.prepare(',
      '.write(',
      '.getMessage(',
      '.getCause(',
    ]) {
      expect(helper, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
