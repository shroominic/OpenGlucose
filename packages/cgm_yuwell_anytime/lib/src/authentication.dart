import 'checksum.dart';
import 'errors.dart';

/// Strictly split, caller-provided CT5 communication identity.
///
/// The value is never generated, logged, or recovered by this package.
final class YuwellCommunicationIdentity {
  YuwellCommunicationIdentity._({
    required this.idPrefix,
    required List<int> randomA,
    required List<int> randomB,
  }) : randomA = List<int>.unmodifiable(randomA),
       randomB = List<int>.unmodifiable(randomB);

  factory YuwellCommunicationIdentity.parse(String value) {
    if (!RegExp(r'^\d{12}$').hasMatch(value)) {
      throw const YuwellProtocolFormatException(
        'communication identity must contain exactly 12 decimal digits',
      );
    }
    List<int> digits(String part) =>
        List<int>.unmodifiable(part.codeUnits.map((unit) => unit - 0x30));

    return YuwellCommunicationIdentity._(
      idPrefix: value.substring(0, 4),
      randomA: digits(value.substring(4, 8)),
      randomB: digits(value.substring(8, 12)),
    );
  }

  /// The four-character protocol ID field.
  final String idPrefix;

  /// The second group of four decimal digits.
  final List<int> randomA;

  /// The final group of four decimal digits.
  final List<int> randomB;

  /// Encodes a target-unverified set-ID frame without transmitting it.
  List<int> encodeSetId() {
    final mixed = _truncatedConvolution(randomB, randomA);
    return appendYuwellSum8(<int>[0x30, ...randomB, ...mixed]);
  }

  /// Returns the sensitive canonical value for a platform secure store.
  ///
  /// Callers must pass this directly to Keychain/Keystore and must never log,
  /// expose in metadata, or place it in preferences or a regular database.
  String serializeForSecureStorage() =>
      '$idPrefix${randomA.join()}${randomB.join()}';

  /// Derives the one-byte transform key from a strict set-ID response frame.
  int deriveCipherFromSetIdResponse(Iterable<int> response) {
    final frame = requireValidSum8Frame(response, field: 'set-ID response');
    if (frame.length < 10) {
      throw const YuwellProtocolFormatException(
        'set-ID response does not contain a complete cipher factor',
      );
    }
    if (frame.first != 0x30) {
      throw const YuwellProtocolFormatException(
        'set-ID response has an unexpected command',
      );
    }
    final mixed = _truncatedConvolution(frame.sublist(5, 9), randomA);
    return mixed.fold<int>(0, (cipher, value) => cipher ^ value) & 0xff;
  }

  @override
  String toString() => 'YuwellCommunicationIdentity(<redacted>)';
}

List<int> _truncatedConvolution(List<int> left, List<int> right) {
  if (left.length != 4 || right.length != 4) {
    throw const YuwellProtocolFormatException(
      'authentication factors must contain exactly four values',
    );
  }
  final result = List<int>.filled(left.length, 0);
  for (var output = 0; output < left.length; output++) {
    for (var input = 0; input < right.length; input++) {
      final rightIndex = output - input;
      if (rightIndex >= 0) {
        result[output] += left[input] * right[rightIndex];
      }
    }
    result[output] &= 0xff;
  }
  return List<int>.unmodifiable(result);
}
