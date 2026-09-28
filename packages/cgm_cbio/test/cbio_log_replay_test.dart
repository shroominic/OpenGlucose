// SPDX-License-Identifier: GPL-3.0-only
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

const String _capturedRawFrameHex =
    '8b 08 10 01 00 8c 0b a3 6a '
    '3a 01 6a 0b 40 00 00 00 '
    '3a 01 6a 0b 40 00 00 00 '
    '39 01 6a 0b 3f 00 00 00 '
    '38 01 6a 0b 3f 00 00 00 '
    '3a 01 6b 0b 3f 00 00 00 '
    '3b 01 6c 0b 3e 00 00 00 '
    '3b 01 6b 0b 3e 00 00 00 '
    '3b 01 6a 0b 3d 00 00 00 '
    '44 01 6b 0b 3d 00 00 00 '
    '49 01 6b 0b 3c 00 00 00 '
    '48 01 6d 0b 3c 00 00 00 '
    '3f 01 6d 0b 3c 00 00 00 '
    '39 01 6b 0b 3b 00 00 00 '
    '32 01 6d 0b 39 00 00 00 '
    '29 01 6b 0b 36 00 00 00 '
    '24 01 6d 0b 33 00 00 00 '
    'ad 29 0e';

String _log() => [
  'Running openhealth/integration_test/cbio_glucose_authenticated_test.dart',
  'CBIO-A notify t=10 masked=de ad be ef plaintext=$_capturedRawFrameHex',
  'CBIO-A notify t=20 masked=01 02 03 04 plaintext=04 08 01 00 f3',
  'CBIO-EVIDENCE {"schema":"cbio.session-evidence/2","identity":{'
      '"harness":"openhealth/integration_test/cbio_glucose_authenticated_test.dart",'
      '"harnessRevision":"deadbee","appPackage":"com.openglucose.app.debug",'
      '"appRevision":"unknown","platform":"android"}}',
].join('\n');

void main() {
  test('keeps the plaintext frames and drops the masked bytes', () {
    final log = parseCbioHarnessLog(_log());
    expect(log.plaintextFrames.length, 2);
    expect(log.plaintextFrames.first.length, 140);
    expect(log.plaintextFrames.first.first, 0x8b);
    expect(log.plaintextFrames.last, [0x04, 0x08, 0x01, 0x00, 0xf3]);
    final encoded = log.plaintextFrames
        .expand((frame) => frame)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    // The masked span of the first notification must not survive the replay.
    expect(encoded.contains('deadbeef'), isFalse);
  });

  test('reads the harness identity out of the evidence line', () {
    final log = parseCbioHarnessLog(_log());
    expect(
      log.harness,
      'openhealth/integration_test/cbio_glucose_authenticated_test.dart',
    );
    expect(log.harnessRevision, 'deadbee');
    expect(log.appPackage, 'com.openglucose.app.debug');
  });

  test('a log with no frames and no identity stays empty, not guessed', () {
    final log = parseCbioHarnessLog('flutter test exit status: 1\n');
    expect(log.plaintextFrames, isEmpty);
    expect(log.harness, 'unknown');
    expect(log.harnessRevision, 'unknown');
    expect(log.appPackage, 'unknown');
  });

  test('a replayed window decodes through both fields', () {
    final log = parseCbioHarnessLog(_log());
    final comparison = compareCbioDecode(log.plaintextFrames);
    expect(comparison.batchCount, 1);
    expect(comparison.decodeFailures, 1);
    expect(comparison.recordCount, 16);
    expect(comparison.payloadNonZero, 16);
    expect(comparison.processedNonZero, 0);
  });
}
