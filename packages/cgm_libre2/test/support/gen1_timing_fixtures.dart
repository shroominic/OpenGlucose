import 'package:cgm_libre2/cgm_libre2.dart';

// Synthetic UID and ciphertext already used by gen1_security_test.dart.
// Rebuild the plaintext age and CRC, then apply the same XOR keystream.
// No private sensor data or conversion algorithm is used.
List<int> blePacketAtMinute(int minute) {
  RangeError.checkValueInInterval(minute, 0, 0xffff, 'minute');
  final core = LibreGen1OfflineCore(
    uid: LibreGen1Uid.algorithmOrder(_hex('0011223344556677')),
    patchInfo: LibreGen1PatchInfo(_hex('9d0830013412')),
  );
  final original = _hex(
    '1234471336ff3b472ad9beded5f439d8ac2321e91148671898c6d9a87115'
    '374fe9548541dfbb9084271c356f1acf',
  );
  final clear = core.decryptBle(original).value.bytes;
  final changed = List<int>.of(clear);
  changed[40] = minute & 0xff;
  changed[41] = minute >> 8;
  final crc = _crc16(changed.take(42));
  changed[42] = crc & 0xff;
  changed[43] = crc >> 8;
  return [
    ...original.take(2),
    for (var index = 0; index < clear.length; index += 1)
      original[index + 2] ^ clear[index] ^ changed[index],
  ];
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
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];
