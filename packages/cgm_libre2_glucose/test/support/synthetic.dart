// SPDX-License-Identifier: GPL-3.0-only
// Synthetic test-only encryption uses the MIT cgm_libre2 primitive.
// See THIRD_PARTY_NOTICES.md. This file cannot send data to a sensor.
const syntheticUid = <int>[0, 0x11, 0x22, 0x33, 0x44, 0x55, 7, 0xe0];
const syntheticPatch = <int>[0x9d, 8, 0x30, 1, 0x34, 0x12];
const _key = <int>[0xa0c5, 0x6860, 0, 0x14c6];
int _littleEndian16(List<int> bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8;

List<int> clearFram({
  int index = 300,
  int offset = 20,
  int scale = 500,
  int reference = 12000,
  int state = 3,
  int age = 60,
  int maxLife = 20160,
}) {
  final bytes = List<int>.filled(344, 0);
  bytes[4] = state;
  putBits(bytes, 2, 3, 10, index);
  putBits(bytes, 336, 0, 8, offset.abs());
  putBits(bytes, 336, 33, 1, offset < 0 ? 1 : 0);
  putBits(bytes, 336, 8, 14, scale);
  putBits(bytes, 336, 52, 12, reference >> 2);
  putBits(bytes, 316, 0, 16, age);
  putBits(bytes, 326, 0, 16, maxLife);
  return bytes;
}

List<int> encryptedFram(
  List<int> clear, {
  List<int> patchInfo = syntheticPatch,
}) {
  final bytes = List<int>.of(clear);
  for (final region in [(0, 24), (24, 320), (320, 344)]) {
    putBits(
      bytes,
      region.$1,
      0,
      16,
      _crc16(bytes.sublist(region.$1 + 2, region.$2)),
    );
  }
  final result = <int>[];
  for (var block = 0; block < 43; block++) {
    final key = _wordsToLittleEndian(
      _processCrypto(
        _prepareVariables(
          syntheticUid,
          block,
          _littleEndian16(patchInfo, 4) ^ 0x44,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      result.add(bytes[block * 8 + i] ^ key[i]);
    }
  }
  return result;
}

List<int> clearBle({
  int age = 120,
  int raw = 1400,
  int temperature = 6400,
  int adjustment = 24,
}) {
  final bytes = List<int>.filled(44, 0);
  for (var i = 0; i < 10; i++) {
    putBits(bytes, i * 4, 0, 14, raw);
    putBits(bytes, i * 4, 14, 12, temperature >> 2);
    putBits(bytes, i * 4, 26, 5, adjustment.abs() >> 2);
    putBits(bytes, i * 4, 31, 1, adjustment < 0 ? 1 : 0);
  }
  putBits(bytes, 40, 0, 16, age);
  return bytes;
}

List<int> encryptedBle(List<int> clear) {
  final bytes = List<int>.of(clear);
  putBits(bytes, 42, 0, 16, _crc16(bytes.sublist(0, 42)));
  final activation = _usefulFunction(syntheticUid, 0x1b, 0x1b6a);
  final x =
      (_littleEndian16(activation, 0) ^ _littleEndian16(activation, 2)) | 0x63;
  var words = _processCrypto(_prepareVariables(syntheticUid, x, 0x3412 ^ 0x63));
  final key = <int>[];
  for (var i = 0; i < 8; i++) {
    key.addAll(_wordsToLittleEndian(words));
    words = _processCrypto(words);
  }
  return [0x12, 0x34, for (var i = 0; i < 44; i++) bytes[i] ^ key[i]];
}

void putBits(List<int> bytes, int offset, int bit, int count, int value) {
  for (var i = 0; i < count; i++) {
    final at = offset * 8 + bit + i;
    bytes[at ~/ 8] =
        (bytes[at ~/ 8] & ~(1 << (at % 8))) | (((value >> i) & 1) << (at % 8));
  }
}

List<int> _prepareVariables(List<int> uid, int x, int y) => <int>[
  (_littleEndian16(uid, 4) + x + y) & 0xffff,
  (_littleEndian16(uid, 2) + _key[2]) & 0xffff,
  (_littleEndian16(uid, 0) + x * 2) & 0xffff,
  0x241a ^ _key[3],
];

List<int> _processCrypto(List<int> input) {
  int operation(int value) {
    var result = value >> 2;
    if ((value & 1) != 0) result ^= _key[1];
    if ((value & 2) != 0) result ^= _key[0];
    return result & 0xffff;
  }

  final r0 = operation(input[0]) ^ input[3];
  final r1 = operation(r0) ^ input[2];
  final r2 = operation(r1) ^ input[1];
  final r3 = operation(r2) ^ input[0];
  final r4 = operation(r3);
  final r5 = operation(r4 ^ r0);
  final r6 = operation(r5 ^ r1);
  final r7 = operation(r6 ^ r2);
  return <int>[r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4];
}

List<int> _usefulFunction(List<int> uid, int x, int y) {
  final words = _processCrypto(_prepareVariables(uid, x, y));
  return _wordsToLittleEndian(<int>[words[0] ^ 0x4163, words[1] ^ 0x4344]);
}

List<int> _wordsToLittleEndian(List<int> words) => <int>[
  for (final word in words) ...<int>[word & 0xff, (word >> 8) & 0xff],
];

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
