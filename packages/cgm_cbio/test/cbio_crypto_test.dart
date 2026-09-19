import 'dart:io' show Platform;

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

/// Synthetic material for the structural tests in this file.
///
/// The package compiles no vendor material, so these bytes are chosen to be
/// obviously synthetic and are unrelated to the real link. The tests that need
/// the real material read it from the injected environment instead.
final CbioCredentials _synthetic = CbioCredentials(
  streamKey: _ascii('CGMTESTKEY000000'),
  authMaterial: _ascii('CGMTESTMATERIAL1'),
  authenticationTrigger: const <int>[0x10, 0x20, 0x30, 0x40, 0x50],
);

/// The material the process was launched with, if a bench supplied any.
final CbioCredentialSource _injected = CbioMapCredentialSource(
  Platform.environment,
);

List<int> _ascii(String value) => value.codeUnits;

/// A well-formed synthetic value per entry, plus one that is one digit short.
const String _hex16 = '00112233445566778899aabbccddeeff';
const String _hex16Short = '00112233445566778899aabbccddee';
const String _trigger5 = '1020304050';

/// The same synthetic value with the separators the parser tolerates.
///
/// Composed rather than written out: a 32-digit hex literal next to a
/// `streamKey` argument reads as an API credential to secret scanners, and
/// this value is a fixture, not a credential.
String _separated(String hex) =>
    '${hex.substring(0, 2)}:${hex.substring(2, 4)} ${hex.substring(4, 6)}'
    '-${hex.substring(6, 12)}_${hex.substring(12)}';

/// The same synthetic value with the last nibble dropped.
String _oddDigitCount(String hex) => hex.substring(0, hex.length - 1);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('an unconfigured source fails closed instead of compiling a key', () {
    expect(
      () => const CbioMapCredentialSource(<String, String>{}).read(),
      throwsA(isA<CbioCredentialUnavailable>()),
    );
    expect(
      () => const CbioMapCredentialSource(<String, String>{
        cbioStreamKeyDefine: 'aabb',
      }).read(),
      throwsA(
        isA<CbioCredentialUnavailable>().having(
          (error) => error.message,
          'message',
          contains(cbioAuthMaterialDefine),
        ),
      ),
    );
  });

  test('malformed material is rejected, never partially accepted', () {
    expect(
      () => const CbioMapCredentialSource(<String, String>{
        cbioStreamKeyDefine: _hex16,
        cbioAuthMaterialDefine: _hex16Short,
        cbioAuthTriggerDefine: _trigger5,
      }).read(),
      throwsA(
        isA<CbioCredentialUnavailable>().having(
          (error) => error.message,
          'message',
          contains('malformed'),
        ),
      ),
    );
    expect(
      () => CbioCredentials.fromHex(
        streamKey: _hex16Short,
        authMaterial: _hex16,
        authenticationTrigger: _trigger5,
      ),
      throwsArgumentError,
    );
    expect(
      () => CbioCredentials.fromHex(
        streamKey: _oddDigitCount(_hex16),
        authMaterial: _hex16,
        authenticationTrigger: _trigger5,
      ),
      throwsArgumentError,
    );
  });

  test('material is validated, separated from its hex spelling', () {
    final credentials = CbioCredentials.fromHex(
      streamKey: _separated(_hex16),
      authMaterial: _hex16,
      authenticationTrigger: _trigger5,
    );
    expect(credentials.streamKey, hasLength(CbioCredentials.streamKeyLength));
    expect(
      credentials.authMaterial,
      hasLength(CbioCredentials.authMaterialLength),
    );
    expect(
      credentials.authenticationTrigger,
      hasLength(CbioCredentials.authenticationTriggerLength),
    );
    expect(
      () => CbioCredentials(
        streamKey: _ascii('too short'),
        authMaterial: _ascii('CGMTESTMATERIAL1'),
        authenticationTrigger: const <int>[0x10, 0x20, 0x30, 0x40, 0x50],
      ),
      throwsArgumentError,
    );
    expect(credentials.toString(), contains('redacted'));
    expect(credentials.toString(), isNot(contains('11')));
    expect(
      () => credentials.authMaterial.add(0x00),
      throwsUnsupportedError,
      reason: 'the material must not be mutable after validation',
    );
  });

  test('masking is symmetric and resets per frame', () {
    for (final plaintext in [
      [0x03, 0xf0, 0x02, 0x0b],
      [0x06, 0x0a, 0x01, 0x00, 0x00, 0x00, 0xef],
    ]) {
      final masked = maskCbioFrame(plaintext, key: _synthetic.streamKey);
      expect(masked, isNot(plaintext));
      expect(unmaskCbioFrame(masked, key: _synthetic.streamKey), plaintext);
      expect(
        unmaskCbioFrame(masked, key: _synthetic.streamKey),
        unmaskCbioFrame(masked, key: _synthetic.streamKey),
      );
    }
  });

  test('the key is an input: a different key yields a different frame', () {
    const plaintext = <int>[0x03, 0xf0, 0x02, 0x0b];
    final masked = maskCbioFrame(plaintext, key: _synthetic.streamKey);
    final otherKey = List<int>.generate(16, (index) => index + 1);
    expect(
      unmaskCbioFrame(masked, key: otherKey),
      isNot(plaintext),
      reason: 'there is no compiled fallback key to fall back to',
    );
  });

  test(
    'the authentication frame carries the reversed address and material',
    () {
      final plaintext = unmaskCbioFrame(
        buildMaskedCbioAuthentication(
          const [0x66, 0x55, 0x44, 0x33, 0x22, 0x11],
          key: _synthetic.streamKey,
          material: _synthetic.authMaterial,
        ),
        key: _synthetic.streamKey,
      );
      expect(plaintext.length, 26);
      expect(plaintext.sublist(0, 3), [0x19, 0x01, 0x00]);
      expect(plaintext.sublist(3, 9), [0x66, 0x55, 0x44, 0x33, 0x22, 0x11]);
      expect(plaintext.sublist(9, 25), _synthetic.authMaterial);
      expect(plaintext.fold<int>(0, (a, b) => a + b) & 255, 0);
    },
  );

  test('every builder produces a zero-sum masked frame', () {
    for (final masked in <List<int>>[
      buildMaskedCbioDeviceInformation(2, key: _synthetic.streamKey),
      buildMaskedCbioClock(1700000000, key: _synthetic.streamKey),
      buildMaskedCbioGlucoseQuery(1, key: _synthetic.streamKey),
      buildMaskedCbioRawQuery(1, key: _synthetic.streamKey),
    ]) {
      final plaintext = unmaskCbioFrame(masked, key: _synthetic.streamKey);
      expect(
        plaintext.fold<int>(0, (a, b) => a + b) & 255,
        0,
        reason: 'checksum of ${_hex(plaintext)}',
      );
    }
  });

  test('address octets and epochs are validated', () {
    expect(
      () => buildMaskedCbioAuthentication(
        const [1, 2, 3],
        key: _synthetic.streamKey,
        material: _synthetic.authMaterial,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildMaskedCbioAuthentication(
        const [1, 2, 3, 4, 5, 6],
        key: _synthetic.streamKey,
        material: const [1, 2, 3],
      ),
      throwsArgumentError,
    );
    expect(
      () => buildMaskedCbioClock(-1, key: _synthetic.streamKey),
      throwsArgumentError,
    );
    expect(
      () => buildMaskedCbioClock(0x100000000, key: _synthetic.streamKey),
      throwsArgumentError,
    );
    expect(
      () => buildMaskedCbioGlucoseQuery(0x10000, key: _synthetic.streamKey),
      throwsArgumentError,
    );
    expect(
      () => buildMaskedCbioRawQuery(-1, key: _synthetic.streamKey),
      throwsArgumentError,
    );
  });

  test('unmasking a partial or empty payload stays bounded', () {
    expect(unmaskCbioFrame(const [], key: _synthetic.streamKey), isEmpty);
    final partial = buildMaskedCbioDeviceInformation(
      2,
      key: _synthetic.streamKey,
    );
    expect(
      unmaskCbioFrame(partial.sublist(0, 2), key: _synthetic.streamKey),
      hasLength(2),
    );
  });

  test('a key shorter than one keystream block is rejected', () {
    expect(
      () => maskCbioFrame(const [1, 2, 3], key: const []),
      throwsArgumentError,
    );
    expect(
      () => cbioRc4Keystream(-1, key: _synthetic.streamKey),
      throwsArgumentError,
    );
  });

  group('injected vendor material', () {
    test(
      'the injected prompt unmasks to the documented control frame',
      () {
        final credentials = _injected.read();
        expect(
          unmaskCbioFrame(
            credentials.authenticationTrigger,
            key: credentials.streamKey,
          ),
          <int>[0x04, 0x00, 0x00, 0x00, 0xfc],
        );
      },
      skip: _injected.isConfigured
          ? false
          : 'run with CBIO_VENDOR_* injected to check the real material',
    );

    test(
      'the injected key masks the device-information query',
      () {
        final credentials = _injected.read();
        final plaintext = unmaskCbioFrame(
          buildMaskedCbioDeviceInformation(2, key: credentials.streamKey),
          key: credentials.streamKey,
        );
        expect(_hex(plaintext), '03f0020b');
      },
      skip: _injected.isConfigured
          ? false
          : 'run with CBIO_VENDOR_* injected to check the real material',
    );
  });
}
