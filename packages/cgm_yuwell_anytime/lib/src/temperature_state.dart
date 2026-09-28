import 'dart:typed_data';

/// The reviewed reachable temperature-state recurrence for CT5 selector 11.
///
/// This internal research primitive does not decide whether a sample is
/// admissible and does not calculate glucose. The caller owns reset and gap
/// policy. Inputs and outputs are exact IEEE-754 binary32 words.
final class YuwellCt5TemperatureState {
  double? _state;

  /// Discards prior state and returns the positive-zero uninitialized word.
  int reset() {
    _state = null;
    return 0x00000000;
  }

  /// Advances with a finite binary32 temperature word and returns state bits.
  int advance(int temperatureBits) {
    _validateFiniteBinary32Bits(temperatureBits);

    final temperature = _float32FromBits(temperatureBits);
    final clamped = temperature.clamp(12.0, 48.0).toDouble();
    final prior = _state;
    if (prior == null) {
      _state = clamped;
      return _bitsFromFloat32(clamped);
    }

    final weightedPrior = _roundToFloat32(0.75 * prior);
    final weightedInput = _roundToFloat32(0.25 * clamped);
    final next = _roundToFloat32(weightedPrior + weightedInput);
    _state = next;
    return _bitsFromFloat32(next);
  }
}

void _validateFiniteBinary32Bits(int bits) {
  if (bits < 0 || bits > 0xffffffff) {
    throw RangeError.range(bits, 0, 0xffffffff, 'temperatureBits');
  }
  if ((bits & 0x7f800000) == 0x7f800000) {
    throw ArgumentError.value(
      bits,
      'temperatureBits',
      'must encode a finite binary32 value',
    );
  }
}

double _float32FromBits(int bits) {
  final bytes = ByteData(4)..setUint32(0, bits, Endian.big);
  return bytes.getFloat32(0, Endian.big);
}

double _roundToFloat32(double value) {
  final bytes = ByteData(4)..setFloat32(0, value, Endian.big);
  return bytes.getFloat32(0, Endian.big);
}

int _bitsFromFloat32(double value) {
  final bytes = ByteData(4)..setFloat32(0, value, Endian.big);
  return bytes.getUint32(0, Endian.big);
}
