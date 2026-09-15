import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  final core = LibreGen1OfflineCore(
    uid: LibreGen1Uid.algorithmOrder(_hex('0011223344556677')),
    patchInfo: LibreGen1PatchInfo(_hex('9d0830013412')),
  );

  group('Gen1 lifecycle evidence', () {
    for (final values in [
      (0, 0),
      (59, 20160),
      (60, 20160),
      (256, 0xffff),
      (20161, 20160),
      (0xffff, 0xffff),
    ]) {
      test('FRAM timing is an observation, not inferred lifecycle $values', () {
        final timing = parseLibreGen1FramTiming(
          core.decryptFram(
            _encryptedFramFixture(0x07, age: values.$1, lifetime: values.$2),
          ),
        );
        expect(timing.elapsedMinutes, values.$1);
        expect(
          timing.expectedLifetimeMinutes,
          values.$2 == 0 ? null : values.$2,
        );
        // In particular age >= lifetime cannot replace the observed state.
        expect(timing.lifecycle, LibreGen1LifecycleState.unknown);
        expect(timing.toString(), 'LibreGen1FramTiming(data: <redacted>)');
      });
    }

    for (final entry in <(int, LibreGen1LifecycleState)>[
      (0x01, LibreGen1LifecycleState.notActivated),
      (0x02, LibreGen1LifecycleState.warmingUp),
      (0x03, LibreGen1LifecycleState.active),
      (0x04, LibreGen1LifecycleState.expired),
      (0x05, LibreGen1LifecycleState.shutdown),
      (0x06, LibreGen1LifecycleState.failure),
    ]) {
      test('maps CRC-valid FRAM state 0x${_twoDigitHex(entry.$1)}', () {
        final fram = core.decryptFram(_encryptedFramFixture(entry.$1));

        final evidence = parseLibreGen1Lifecycle(fram);

        expect(evidence.state, entry.$2);
        expect(
          evidence.evidenceStatus,
          LibreEvidenceStatus.referenceVerifiedTargetUnverified,
        );
        expect(evidence.authorizesStateChange, isFalse);
      });
    }

    for (final value in <int>[0x00, 0x07, 0x80, 0xff]) {
      test('maps unknown CRC-valid FRAM state 0x${_twoDigitHex(value)}', () {
        final fram = core.decryptFram(_encryptedFramFixture(value));

        expect(
          parseLibreGen1Lifecycle(fram).state,
          LibreGen1LifecycleState.unknown,
        );
      });
    }

    test('diagnostics expose no source byte or payload', () {
      final fram = core.decryptFram(_encryptedFramFixture(0x03));

      final diagnostic = parseLibreGen1Lifecycle(fram).toString();

      expect(diagnostic, contains('active'));
      expect(diagnostic, contains('<redacted>'));
      expect(diagnostic, isNot(contains('0x03')));
      expect(diagnostic.toLowerCase(), isNot(contains('glucose')));
    });
  });
}

List<int> _encryptedFramFixture(int lifecycleByte, {int? age, int? lifetime}) {
  final referenceClear = _syntheticClearFram(0x03);
  final desiredClear = _syntheticClearFram(
    lifecycleByte,
    age: age,
    lifetime: lifetime,
  );
  final referenceEncrypted = _hex(
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
  return <int>[
    for (var index = 0; index < referenceEncrypted.length; index += 1)
      referenceEncrypted[index] ^ referenceClear[index] ^ desiredClear[index],
  ];
}

List<int> _syntheticClearFram(int lifecycleByte, {int? age, int? lifetime}) {
  final bytes = List<int>.generate(344, (index) => (index * 73 + 19) & 0xff);
  bytes[4] = lifecycleByte;
  if (age != null) {
    bytes[316] = age & 0xff;
    bytes[317] = age >> 8;
  }
  if (lifetime != null) {
    bytes[326] = lifetime & 0xff;
    bytes[327] = lifetime >> 8;
  }
  _writeRegionCrc(bytes, 0, 24);
  _writeRegionCrc(bytes, 24, 320);
  _writeRegionCrc(bytes, 320, 344);
  return bytes;
}

void _writeRegionCrc(List<int> bytes, int start, int end) {
  final crc = _crc16(bytes.sublist(start + 2, end));
  bytes[start] = crc & 0xff;
  bytes[start + 1] = crc >> 8;
}

int _crc16(Iterable<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
  }
  var reversed = 0;
  for (var bit = 0; bit < 16; bit += 1) {
    reversed = (reversed << 1) | (crc & 1);
    crc >>= 1;
  }
  return reversed & 0xffff;
}

String _twoDigitHex(int value) => value.toRadixString(16).padLeft(2, '0');

List<int> _hex(String value) => <int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
];
