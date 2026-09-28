import 'byte_utils.dart';

/// Reversible CT5 byte transform with a one-byte XOR key.
///
/// This is a pure transform. It does not obtain keys or perform I/O.
abstract final class YuwellCt5ByteTransform {
  /// Encodes clear bytes into the target-unverified wire representation.
  static List<int> encode(Iterable<int> cleartext, {required int key}) {
    RangeError.checkValueInInterval(key, 0, 0xff, 'key');
    final bytes = checkedArgumentBytes(cleartext, field: 'cleartext');
    final bits = _toBits(bytes);
    for (var index = bits.length - 2; index >= 0; index--) {
      if (bits[index + 1] == 0) {
        bits[index] ^= 1;
      }
    }
    return List<int>.unmodifiable(_fromBits(bits).map((byte) => byte ^ key));
  }

  /// Decodes wire bytes by applying XOR, then the forward adjacent-bit step.
  static List<int> decode(Iterable<int> wireBytes, {required int key}) {
    RangeError.checkValueInInterval(key, 0, 0xff, 'key');
    final bytes = checkedArgumentBytes(wireBytes, field: 'wireBytes');
    final bits = _toBits(bytes.map((byte) => byte ^ key));
    for (var index = 0; index + 1 < bits.length; index++) {
      if (bits[index + 1] == 0) {
        bits[index] ^= 1;
      }
    }
    return _fromBits(bits);
  }

  static List<int> _toBits(Iterable<int> bytes) {
    final bits = <int>[];
    for (final byte in bytes) {
      for (var shift = 7; shift >= 0; shift--) {
        bits.add((byte >> shift) & 1);
      }
    }
    return bits;
  }

  static List<int> _fromBits(List<int> bits) {
    final bytes = <int>[];
    for (var offset = 0; offset < bits.length; offset += 8) {
      var byte = 0;
      for (var bit = 0; bit < 8; bit++) {
        byte = (byte << 1) | bits[offset + bit];
      }
      bytes.add(byte);
    }
    return List<int>.unmodifiable(bytes);
  }
}
