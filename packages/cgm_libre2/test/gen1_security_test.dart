import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  final uid = LibreGen1Uid.algorithmOrder(_hex('0011223344556677'));
  final patchInfo = LibreGen1PatchInfo(_hex('9d0830013412'));
  final core = LibreGen1OfflineCore(uid: uid, patchInfo: patchInfo);

  group('strict Gen1 inputs', () {
    for (final entry in <String, LibreGen1Model>{
      '9d0830': LibreGen1Model.libre2,
      'c50930': LibreGen1Model.libre2,
      '7f0e30': LibreGen1Model.libre2,
      'c60931': LibreGen1Model.libre2Plus,
      '7f0e31': LibreGen1Model.libre2Plus,
    }.entries) {
      test('describes only the accepted ${entry.key} signature', () {
        // The remaining bytes are synthetic, not regional identity evidence.
        for (final suffix in ['000000', '013412', '02ffff', 'ffabcd']) {
          final patch = LibreGen1PatchInfo(_hex('${entry.key}$suffix'));
          final variant = patch.sensorVariant;
          expect(patch.model, entry.value);
          expect(variant.protocolFamily, 'abbott-sas');
          expect(variant.source, CgmSensorVariantSource.nfcPatchInfo);
          expect(
            variant.model,
            entry.value == LibreGen1Model.libre2
                ? 'FreeStyle Libre 2'
                : 'FreeStyle Libre 2 Plus',
          );
          expect(variant.variantCode, entry.key);
          expect(variant.securityGeneration, 'gen1');
          expect(variant.region, isNull);
          expect(variant.hardwareRevision, isNull);
          expect(variant.firmwareRevision, isNull);
          expect(variant.softwareRevision, isNull);
          expect(variant.toJson(), {
            'protocolFamily': 'abbott-sas',
            'source': 'nfcPatchInfo',
            'model': variant.model,
            'variantCode': entry.key,
            'securityGeneration': 'gen1',
          });
          expect(variant.toString(), contains('<redacted>'));
        }
      });
    }

    for (final marker in ['39', '3f', '74', '7f']) {
      test('variant metadata does not admit Gen2 marker $marker', () {
        expect(
          () => LibreGen1PatchInfo(_hex('9d08${marker}013412')),
          throwsA(
            isA<LibreProtocolError>()
                .having(
                  (error) => error.kind,
                  'kind',
                  LibreProtocolErrorKind.unsupportedSecurityGeneration,
                )
                .having(
                  (error) => error.generation,
                  'generation',
                  LibreSecurityGeneration.gen2,
                ),
          ),
        );
      });
    }

    for (final signature in ['9d0838', '9d0873', '9d0800', 'aabb30']) {
      test('variant metadata does not admit unknown signature $signature', () {
        expect(
          () => LibreGen1PatchInfo(_hex('${signature}013412')),
          throwsA(
            isA<LibreProtocolError>().having(
              (error) => error.kind,
              'kind',
              LibreProtocolErrorKind.unsupportedPatchInfo,
            ),
          ),
        );
      });
    }

    test('accepts only exact UID and patch-info lengths', () {
      expect(
        () => LibreGen1Uid.algorithmOrder(List<int>.filled(7, 0)),
        _lengthError(expected: 8, actual: 7),
      );
      expect(
        () => LibreGen1Uid.algorithmOrder(List<int>.filled(9, 0)),
        _lengthError(expected: 8, actual: 9),
      );
      expect(
        () => LibreGen1PatchInfo(List<int>.filled(5, 0)),
        _lengthError(expected: 6, actual: 5),
      );
      expect(
        () => LibreGen1PatchInfo(List<int>.filled(7, 0)),
        _lengthError(expected: 6, actual: 7),
      );
      expect(
        () => LibreGen1Uid.algorithmOrder(<int>[0, 1, 2, 3, 4, 5, 6, 256]),
        throwsA(
          isA<LibreProtocolError>().having(
            (error) => error.kind,
            'kind',
            LibreProtocolErrorKind.invalidPayloadByte,
          ),
        ),
      );
    });

    test('accepts the closed Gen1 model set and rejects other branches', () {
      expect(patchInfo.model, LibreGen1Model.libre2);
      expect(
        LibreGen1PatchInfo(_hex('c60931010000')).model,
        LibreGen1Model.libre2Plus,
      );
      expect(
        () => LibreGen1PatchInfo(_hex('2b0a39010000')),
        throwsA(
          isA<LibreProtocolError>()
              .having(
                (error) => error.kind,
                'kind',
                LibreProtocolErrorKind.unsupportedSecurityGeneration,
              )
              .having(
                (error) => error.generation,
                'generation',
                LibreSecurityGeneration.gen2,
              ),
        ),
      );
      expect(
        () => LibreGen1PatchInfo(_hex('aabb30010000')),
        throwsA(
          isA<LibreProtocolError>().having(
            (error) => error.kind,
            'kind',
            LibreProtocolErrorKind.unsupportedPatchInfo,
          ),
        ),
      );
    });

    test('snapshots inputs and redacts them from diagnostics', () {
      final source = _hex('0011223344556677');
      final copied = LibreGen1Uid.algorithmOrder(source);
      source[0] = 0xff;

      expect(copied.value.bytes.first, 0x00);
      for (final diagnostic in <String>[
        copied.toString(),
        patchInfo.toString(),
        core.toString(),
      ]) {
        expect(diagnostic, contains('<redacted>'));
        expect(diagnostic, isNot(contains('001122')));
        expect(diagnostic, isNot(contains('9d0830')));
      }
    });
  });

  group('common primitive and pure command plans', () {
    test('matches the synthetic primitive and command vectors', () {
      expect(core.derivePrimitive(x: 0x1b, y: 0x1b6a).bytes, _hex('eb0956b9'));

      final activation = core.planActivation();
      expect(activation.customCommandCode, 0xa1);
      expect(activation.requestParameters.bytes, _hex('1beb0956b9'));
      expect(activation.referenceResponseLength, 4);
      expect(activation.changesSensorState, isTrue);

      final enable = core.planEnableStreaming(streamingBase: 0x12345678);
      expect(enable.customCommandCode, 0xa1);
      expect(enable.requestParameters.bytes, _hex('1e78563412bbd4c70e'));
      expect(enable.referenceResponseLength, 6);
      expect(enable.changesSensorState, isTrue);

      final login = core.planBleLogin(
        streamingBase: 0x12345678,
        unlockCount: 1,
      );
      expect(login.value.bytes, _hex('79563412c7bb30289c3b68c9'));
      expect(login.characteristicUuid, LibreUuids.sasLogin);
      expect(login.subscribeAfterWriteUuid, LibreUuids.sasData);
      expect(login.writeMode, LibreGen1BleLoginWriteMode.withResponse);
    });

    test('rejects out-of-range parameters and counter overflow', () {
      expect(() => core.derivePrimitive(x: -1, y: 0), _numericRangeError);
      expect(
        () => core.planEnableStreaming(streamingBase: 0x100000000),
        _numericRangeError,
      );
      expect(
        () => core.planBleLogin(streamingBase: 0, unlockCount: 0),
        _numericRangeError,
      );
      expect(
        () => core.planBleLogin(streamingBase: 0xffffffff, unlockCount: 1),
        _numericRangeError,
      );
    });

    test('redacts every derived command from diagnostics', () {
      final activation = core.planActivation();
      final enable = core.planEnableStreaming(streamingBase: 0x12345678);
      final login = core.planBleLogin(
        streamingBase: 0x12345678,
        unlockCount: 1,
      );
      for (final diagnostic in <String>[
        activation.toString(),
        enable.toString(),
        login.toString(),
      ]) {
        expect(diagnostic, contains('<redacted>'));
        expect(diagnostic, isNot(contains('1beb0956b9')));
        expect(diagnostic, isNot(contains('78563412')));
        expect(diagnostic, isNot(contains('c7bb3028')));
      }
    });
  });

  group('FRAM decryption', () {
    final encrypted = _hex(
      'fbd6e447b519369a3bfe1348b837c3820b31c742fe1c595f'
      'f557302d47328c477e07b30886ce3e4548a3c4873fe0cb5d'
      '38ec900db9cb51c08ea8e7a200e5c45883377e52eb8c8bac'
      '355309dd5222fe34851c5d571489e46933582a382d27b1f1d'
      'a81737b94e269176c258474ad4c1c8f1cea507eabe706122a'
      '2ea7519249930ab82fca59886099de8ecb3d56b14e6cc6be'
      '04e95cf765f61b88c01e334e4b2303cb329d168fb79101fd'
      '96ea99369964198dd9be13b0b2fe843b9dc9bc099c6b1c36'
      '02504ce2f524e8806627c35b5b5170302973491df04b2d866'
      'd0426245e1eb53b67deab0083aa318dc329a4392ddfa9fd0c'
      'fdae3f86c534cbc80a810628502cdbcf7f933c695bf8ed2b8'
      '89c0547aee0dde45c96436c343deb20abf9fa42e125a8d228'
      'dc3bbe53279e765f538290a63fee390bd904bb3ca2587d7c7'
      '6bd95a93a359ee58656fce6cee3869209ef52935653c9c683'
      'a9f9890b',
    );

    test('decrypts 43 blocks and accepts all three synthetic CRCs', () {
      final expected = List<int>.generate(
        344,
        (index) => (index * 73 + 19) & 0xff,
      );
      expected[4] = 0x03;
      expected[0] = 0xe5;
      expected[1] = 0x90;
      expected[24] = 0x23;
      expected[25] = 0x96;
      expected[320] = 0x33;
      expected[321] = 0xe0;

      final clear = core.decryptFram(encrypted);

      expect(clear.value.length, 344);
      expect(clear.value.bytes, expected);
      expect(clear.toString(), contains('<redacted>'));
      expect(clear.toString(), isNot(contains('e590')));
    });

    test('requires exact encrypted FRAM length', () {
      expect(
        () => core.decryptFram(encrypted.sublist(0, 343)),
        _lengthError(expected: 344, actual: 343),
      );
      expect(
        () => core.decryptFram(<int>[...encrypted, 0]),
        _lengthError(expected: 344, actual: 345),
      );
    });

    for (final entry in <(int, LibreIntegrityRegion)>[
      (10, LibreIntegrityRegion.framHeader),
      (100, LibreIntegrityRegion.framBody),
      (330, LibreIntegrityRegion.framFooter),
    ]) {
      test('rejects a ${entry.$2.name} CRC mismatch', () {
        final corrupted = List<int>.of(encrypted);
        corrupted[entry.$1] ^= 1;

        expect(() => core.decryptFram(corrupted), _integrityError(entry.$2));
      });
    }
  });

  group('BLE decryption', () {
    final encrypted = _hex(
      '1234471336ff3b472ad9beded5f439d8ac2321e91148671898c6d9a87115'
      '374fe9548541dfbb9084271c356f1acf',
    );
    final clear = _hex(
      '0724415e7b98b5d2ef0c294663809dbad7f4112e4b6885a2bfdcf9163350'
      '6d8aa7c4e1fe1b3855728fac514a',
    );

    test('decrypts exactly 46 bytes and validates the payload CRC', () {
      final result = core.decryptBle(encrypted);

      expect(result.value.length, 44);
      expect(result.value.bytes, clear);
      expect(result.toString(), contains('<redacted>'));
      expect(result.toString(), isNot(contains('0724415e')));
    });

    test('requires exact encrypted BLE length', () {
      expect(
        () => core.decryptBle(encrypted.sublist(0, 45)),
        _lengthError(expected: 46, actual: 45),
      );
      expect(
        () => core.decryptBle(<int>[...encrypted, 0]),
        _lengthError(expected: 46, actual: 47),
      );
    });

    test('rejects a BLE CRC mismatch', () {
      final corrupted = List<int>.of(encrypted);
      corrupted[10] ^= 1;

      expect(
        () => core.decryptBle(corrupted),
        _integrityError(LibreIntegrityRegion.blePayload),
      );
    });
  });
}

Matcher _lengthError({required int expected, required int actual}) => throwsA(
  isA<LibreProtocolError>()
      .having(
        (error) => error.kind,
        'kind',
        LibreProtocolErrorKind.payloadLengthMismatch,
      )
      .having((error) => error.expectedLength, 'expectedLength', expected)
      .having((error) => error.actualLength, 'actualLength', actual),
);

final Matcher _numericRangeError = throwsA(
  isA<LibreProtocolError>().having(
    (error) => error.kind,
    'kind',
    LibreProtocolErrorKind.invalidNumericRange,
  ),
);

Matcher _integrityError(LibreIntegrityRegion region) => throwsA(
  isA<LibreProtocolError>()
      .having(
        (error) => error.kind,
        'kind',
        LibreProtocolErrorKind.integrityCheckFailed,
      )
      .having((error) => error.integrityRegion, 'integrityRegion', region),
);

List<int> _hex(String value) {
  if (!value.length.isEven) {
    throw ArgumentError.value(value.length, 'value.length', 'must be even');
  }
  return <int>[
    for (var offset = 0; offset < value.length; offset += 2)
      int.parse(value.substring(offset, offset + 2), radix: 16),
  ];
}
