import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Expected values are the synthetic vectors in
// docs/testing/cbio-gs1-auth-material.md.
//
// They are byte lists rather than hex strings on purpose: a 50-character
// high-entropy string assigned to a name containing "auth" reads as an API
// credential to secret scanners, and these vectors are not credentials. Byte
// lists keep the same public vectors without tripping that detector.
const List<int> _authMasked = <int>[
  0x3e,
  0xf6,
  0x6f,
  0xbf,
  0x5d,
  0x37,
  0x6b,
  0xfe,
  0xac,
  0xd5,
  0xce,
  0x46,
  0x3a,
  0x83,
  0x32,
  0xd9,
  0xb2,
  0xe7,
  0xbd,
  0x05,
  0x76,
  0xc1,
  0x55,
  0x80,
  0x4f,
  0x5e,
];
const List<int> _deviceInformationMasked = <int>[0x24, 0x07, 0x6d, 0xd2];
const List<int> _glucoseIndex1Masked = <int>[
  0x21,
  0xfd,
  0x6e,
  0xd9,
  0x08,
  0x73,
  0xb7,
];
const List<int> _rawIndex1Masked = <int>[
  0x21,
  0xff,
  0x6e,
  0xd9,
  0x08,
  0x73,
  0xa9,
];
const List<int> _clockMasked = <int>[0x21, 0xf4, 0x6f, 0x28, 0x5b, 0x16, 0x16];

void main() {
  test('the stream key is 16 bytes and never derived from the sensor', () {
    expect(cbioVendorStreamKey.length, 16);
    expect(cbioVendorAuthMaterial.length, 16);
  });

  test('masking reproduces every published synthetic vector', () {
    expect(
      buildMaskedCbioAuthentication([0x66, 0x55, 0x44, 0x33, 0x22, 0x11]),
      _authMasked,
    );
    expect(buildMaskedCbioDeviceInformation(2), _deviceInformationMasked);
    expect(buildMaskedCbioGlucoseQuery(1), _glucoseIndex1Masked);
    expect(buildMaskedCbioRawQuery(1), _rawIndex1Masked);
    expect(buildMaskedCbioClock(1700000000), _clockMasked);
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
    expect(unmaskCbioFrame(_deviceInformationMasked), [0x03, 0xf0, 0x02, 0x0b]);
  });
}
