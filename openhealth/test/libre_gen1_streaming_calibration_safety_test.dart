import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/java/com/aidex/aidex_flutter/';

  test('first streaming cache follows confirmed cleanup and precedes UI', () {
    final bridge = File(
      '${native}DebugProtocolCaptureBridge.java',
    ).readAsStringSync();
    final transaction = bridge.substring(
      bridge.indexOf('private void captureStreamingTag('),
      bridge.indexOf('private boolean finishStreamingRfLease('),
    );
    expect(transaction, contains('LibreGen1StreamingCalibration.fromRead('));
    expect(transaction, contains('lifecycle = calibration.lifecycle()'));
    final save = transaction.indexOf('preserveStreamingCalibration(attempt,');
    expect(save, greaterThan(transaction.indexOf('.confirm(')));
    expect(save, greaterThan(transaction.indexOf('confirmed = true')));
    expect(save, greaterThan(transaction.indexOf('completeTransport(')));
    expect(save, greaterThan(transaction.indexOf('streamingAttempt = null')));
    expect(save, lessThan(transaction.indexOf('"streamingEnabled"')));
    expect(
      transaction.indexOf('recordCalibrationCacheResultAfterUi('),
      greaterThan(transaction.indexOf('"streamingEnabled"')),
    );
    expect(
      transaction,
      contains('if (calibration != null) calibration.close()'),
    );
    final preservation = transaction.substring(
      transaction.indexOf('private LibreGen1CalibrationPersistence.Result'),
    );
    for (final guard in [
      '!terminalReady',
      'attempt.cancelled',
      'attempt.closeUncertain',
      'captureEpoch != attempt.epoch',
      'rfAuthorizationGeneration != attempt.generation',
      '!attempt.processSessionId.equals(expectedDartProcessSessionId)',
      '!isCaptureReadyForRfLocked()',
      'streamingAttempt != null',
      '!rfTransactionLeaseBinding.isEmpty()',
      'quarantinedStreamingLease != null',
      'synchronized (journal)',
      'confirmed = journal.read()',
      'calibration.preserveAfterConfirmation(',
      'new LibreGen1CalibrationStore(activity).writeVerified(evidence)',
    ]) {
      expect(preservation, contains(guard), reason: guard);
    }
    for (final forbidden in [
      'transceive(',
      '.prepare(',
      '.commitIntent(',
      '.confirm(',
      '.reserve(',
      '.mark(',
      'fromCapture(',
      'readActivationUiProofFile(',
    ]) {
      expect(preservation, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
