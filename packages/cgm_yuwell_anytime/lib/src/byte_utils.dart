import 'errors.dart';

List<int> checkedProtocolBytes(Iterable<int> input, {required String field}) {
  final bytes = input.toList(growable: false);
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xff) {
      throw YuwellProtocolFormatException('$field contains a non-byte value');
    }
  }
  return List<int>.unmodifiable(bytes);
}

List<int> checkedArgumentBytes(Iterable<int> input, {required String field}) {
  final bytes = input.toList(growable: false);
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xff) {
      throw RangeError.range(byte, 0, 0xff, field);
    }
  }
  return List<int>.unmodifiable(bytes);
}

int readUint16BigEndian(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int readUint24BigEndian(List<int> bytes) =>
    (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];

int sum8Unchecked(Iterable<int> bytes) =>
    bytes.fold<int>(0, (sum, byte) => (sum + byte) & 0xff);
