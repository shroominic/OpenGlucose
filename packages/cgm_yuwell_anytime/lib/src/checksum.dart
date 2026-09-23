import 'byte_utils.dart';
import 'errors.dart';

/// Returns the additive, wrapping 8-bit sum of [bytes].
int yuwellSum8(Iterable<int> bytes) =>
    sum8Unchecked(checkedArgumentBytes(bytes, field: 'bytes'));

/// Returns an immutable copy of [body] followed by its 8-bit sum.
List<int> appendYuwellSum8(Iterable<int> body) {
  final bytes = checkedArgumentBytes(body, field: 'body');
  return List<int>.unmodifiable(<int>[...bytes, sum8Unchecked(bytes)]);
}

/// Returns whether [frame] has at least a body byte and a valid final sum byte.
bool hasValidSum8Frame(List<int>? frame) {
  if (frame == null || frame.length < 2) {
    return false;
  }
  for (final byte in frame) {
    if (byte < 0 || byte > 0xff) {
      return false;
    }
  }
  return sum8Unchecked(frame.take(frame.length - 1)) == frame.last;
}

/// Validates [frame] and returns an immutable byte copy.
List<int> requireValidSum8Frame(Iterable<int> frame, {String field = 'frame'}) {
  final bytes = checkedProtocolBytes(frame, field: field);
  if (bytes.length < 2) {
    throw YuwellProtocolFormatException('$field is too short');
  }
  if (!hasValidSum8Frame(bytes)) {
    throw YuwellProtocolFormatException('$field has an invalid checksum');
  }
  return bytes;
}
