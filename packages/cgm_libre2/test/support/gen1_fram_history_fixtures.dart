import 'package:cgm_libre2/cgm_libre2.dart';

// Synthetic UID/ciphertext already used by gen1_lifecycle_test.dart. Rebuild
// all plaintext regions and CRCs, then apply that same XOR keystream. No real
// sensor, captured health data or calibrated conversion appears in fixtures.
LibreGen1OfflineCore syntheticFramHistoryCore() => LibreGen1OfflineCore(
  uid: LibreGen1Uid.algorithmOrder(_hex('0011223344556677')),
  patchInfo: LibreGen1PatchInfo(_hex('9d0830013412')),
);

List<int> syntheticEncryptedFramHistory({
  required int age,
  int trendIndex = 0,
  int? historyIndex,
  void Function(List<int> bytes)? edit,
}) {
  RangeError.checkValueInInterval(age, 0, 0xffff, 'age');
  final reference = _hex(
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
  final referenceClear = syntheticFramHistoryCore()
      .decryptFram(reference)
      .value
      .bytes;
  final bytes = List<int>.filled(344, 0);
  bytes[4] = 3;
  bytes[26] = trendIndex;
  bytes[27] = historyIndex ?? (age < 3 ? 0 : ((age - 3) ~/ 15) % 32);
  bytes[316] = age & 0xff;
  bytes[317] = age >> 8;
  bytes[326] = 20160 & 0xff;
  bytes[327] = 20160 >> 8;
  edit?.call(bytes);
  for (final region in [(0, 24), (24, 320), (320, 344)]) {
    final crc = _crc16(bytes.sublist(region.$1 + 2, region.$2));
    bytes[region.$1] = crc & 0xff;
    bytes[region.$1 + 1] = crc >> 8;
  }
  return [
    for (var i = 0; i < bytes.length; i += 1)
      reference[i] ^ referenceClear[i] ^ bytes[i],
  ];
}

void writeSyntheticFramField(
  List<int> bytes,
  int offset,
  int start,
  int length,
  int value,
) {
  RangeError.checkValueInInterval(value, 0, (1 << length) - 1, 'value');
  for (var bit = 0; bit < length; bit += 1) {
    final at = start + bit;
    final index = offset + at ~/ 8;
    final mask = 1 << (at % 8);
    bytes[index] = (bytes[index] & ~mask) | (((value >> bit) & 1) * mask);
  }
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

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];
