import 'dart:convert';

import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:cgm_cbio/src/cbio_recovery_state.dart';
import 'package:test/test.dart';

void main() {
  CbioRecoveryState fresh() => CbioRecoveryState(
    sensorKey: 'synthetic',
    predecessorFullSha256: 'a' * 64,
    predecessorLegacySha256: null,
    active: CbioFullRecordState.pending(
      sensorKey: 'synthetic',
      captureId: 'b' * 32,
    ),
  );

  test('capsule bound includes whitespace and rejects one additional byte', () {
    final encoded = fresh().encode();
    final exact = encoded.padRight(CbioRecoveryState.maxBytes);
    expect(
      CbioRecoveryState.decode(exact, sensorKey: 'synthetic').active.captureId,
      'b' * 32,
    );
    expect(
      () => CbioRecoveryState.decode('$exact ', sensorKey: 'synthetic'),
      throwsFormatException,
    );
  });

  test('opaque original bytes are not duplicated into capsule', () {
    final encoded = fresh().encode();
    final decoded = CbioRecoveryState.decode(encoded, sensorKey: 'synthetic');
    expect(decoded.predecessorLegacySha256, isNull);
    expect(decoded.active.bootstrapCheckpoint, isNull);
    expect(
      (jsonDecode(encoded) as Map).keys,
      unorderedEquals([
        'schemaVersion',
        'driverId',
        'profile',
        'sensorKey',
        'reason',
        'predecessorFullSha256',
        'predecessorLegacySha256',
        'active',
      ]),
    );
  });

  for (final change in [
    'foreign',
    'reason',
    'digest',
    'extra',
    'version',
    'legacy',
  ]) {
    test('rejects invalid capsule $change', () {
      final json = jsonDecode(fresh().encode()) as Map<String, dynamic>;
      switch (change) {
        case 'foreign':
          json['sensorKey'] = 'foreign';
        case 'reason':
          json['reason'] = 'arbitrary native details';
        case 'digest':
          json['predecessorFullSha256'] = 'A' * 64;
        case 'extra':
          json['newBudget'] = 1;
        case 'version':
          json['schemaVersion'] = 1.0;
        case 'legacy':
          json['predecessorLegacySha256'] = '';
      }
      expect(
        () =>
            CbioRecoveryState.decode(jsonEncode(json), sensorKey: 'synthetic'),
        throwsFormatException,
      );
    });
  }

  test('active capture identity cannot rotate', () {
    expect(
      () => fresh().withActive(
        CbioFullRecordState.pending(
          sensorKey: 'synthetic',
          captureId: 'c' * 32,
        ),
      ),
      throwsFormatException,
    );
  });
}
