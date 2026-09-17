import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Expected values are the synthetic vectors in docs/testing/cbio-gs1-auth-material.md.
const _authMasked = '3ef66fbf5d376bfeacd5ce463a8332d9b2e7bd0576c155804f5e';
const _deviceInformationMasked = '24076dd2';
const _glucoseIndex1Masked = '21fd6ed90873b7';
const _rawIndex1Masked = '21ff6ed90873a9';
const _clockMasked = '21f46f285b1616';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> unhex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

void main() {
  test('the stream key is 16 bytes and never derived from the sensor', () {
    expect(cbioVendorStreamKey.length, 16);
    expect(cbioVendorAuthMaterial.length, 16);
  });

  test('masking reproduces every published synthetic vector', () {
    expect(
      hex(buildMaskedCbioAuthentication([0x66, 0x55, 0x44, 0x33, 0x22, 0x11])),
      _authMasked,
    );
    expect(hex(buildMaskedCbioDeviceInformation(2)), _deviceInformationMasked);
    expect(hex(buildMaskedCbioGlucoseQuery(1)), _glucoseIndex1Masked);
    expect(hex(buildMaskedCbioRawQuery(1)), _rawIndex1Masked);
    expect(hex(buildMaskedCbioClock(1700000000)), _clockMasked);
  });

  test('masking is symmetric and resets per frame', () {
    for (final plaintext in [
      [0x03, 0xf0, 0x02, 0x0b],
      [0x06, 0x0a, 0x01, 0x00, 0x00, 0x00, 0xef],
    ]) {
      final masked = maskCbioFrame(plaintext);
      expect(masked, isNot(plaintext));
      expect(unmaskCbioFrame(masked), plaintext);
      expect(unmaskCbioFrame(masked), unmaskCbioFrame(masked));
    }
  });

  test('the live five-byte prompt unmasks to a valid control frame', () {
    final plaintext = unmaskCbioFrame(cbioAuthenticationTrigger);
    expect(plaintext, [0x04, 0x00, 0x00, 0x00, 0xfc]);
    expect(plaintext[0] + 1, plaintext.length);
    expect(plaintext.fold<int>(0, (a, b) => a + b) & 255, 0);
    final frame = parseCbioPlaintextFrame(plaintext) as CbioAcknowledgement;
    expect(frame.opcode, 0x00);
    expect(frame.result, 0x00);
    expect(frame.rawStatus, 0x00);
  });

  test('the acknowledgement trigger is the observed prompt bytes', () {
    expect(cbioAuthenticationTrigger, cbioAuthenticationTrigger);
  });

  test(
    'the authentication frame carries the reversed address and material',
    () {
      final plaintext = unmaskCbioFrame(
        buildMaskedCbioAuthentication([0x66, 0x55, 0x44, 0x33, 0x22, 0x11]),
      );
      expect(plaintext.length, 26);
      expect(plaintext.sublist(0, 3), [0x19, 0x01, 0x00]);
      expect(plaintext.sublist(3, 9), [0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);
      expect(plaintext.sublist(9, 25), cbioVendorAuthMaterial);
      expect(plaintext.fold<int>(0, (a, b) => a + b) & 255, 0);
    },
  );

  test('address octets and epochs are validated', () {
    expect(() => buildMaskedCbioAuthentication([1, 2, 3]), throwsArgumentError);
    expect(() => buildMaskedCbioClock(-1), throwsArgumentError);
    expect(() => buildMaskedCbioClock(0x100000000), throwsArgumentError);
    expect(() => buildMaskedCbioGlucoseQuery(0x10000), throwsArgumentError);
    expect(() => buildMaskedCbioRawQuery(-1), throwsArgumentError);
  });

  test('unmasking a partial or empty payload stays bounded', () {
    expect(unmaskCbioFrame(const []), isEmpty);
    expect(hex(unmaskCbioFrame(unhex(_deviceInformationMasked))), '03f0020b');
  });
}
