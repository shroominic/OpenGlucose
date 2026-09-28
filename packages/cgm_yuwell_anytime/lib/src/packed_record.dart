import 'byte_utils.dart';
import 'errors.dart';

enum YuwellPackedRecordKind { currentAndTemperature, glucose }

/// Base type for a strict passive 3-byte record.
sealed class YuwellPackedRecord {
  YuwellPackedRecord._(List<int> bytes, this.encodedWord)
    : rawBytes = List<int>.unmodifiable(bytes);

  factory YuwellPackedRecord.parse(
    Iterable<int> input, {
    required YuwellPackedRecordKind kind,
  }) {
    final bytes = checkedProtocolBytes(input, field: 'packed record');
    if (bytes.length != 3) {
      throw const YuwellProtocolFormatException(
        'packed record must contain exactly three bytes',
      );
    }
    final word = readUint24BigEndian(bytes);
    return switch (kind) {
      YuwellPackedRecordKind.currentAndTemperature =>
        YuwellPackedCurrentTemperatureRecord._(bytes, word),
      YuwellPackedRecordKind.glucose => YuwellPackedGlucoseRecord._(
        bytes,
        word,
      ),
    };
  }

  final List<int> rawBytes;
  final int encodedWord;

  @override
  String toString() => '$runtimeType(bytes: <redacted>)';
}

final class YuwellPackedCurrentTemperatureRecord extends YuwellPackedRecord {
  YuwellPackedCurrentTemperatureRecord._(super.bytes, super.encodedWord)
    : currentRaw = encodedWord >> 10,
      temperatureRaw = encodedWord & 0x03ff,
      super._();

  final int currentRaw;
  final int temperatureRaw;

  double get current => currentRaw * 0.01;
  double get temperatureCelsius => temperatureRaw * 0.1 - 40;
}

final class YuwellPackedGlucoseRecord extends YuwellPackedRecord {
  YuwellPackedGlucoseRecord._(super.bytes, super.encodedWord)
    : trendCode = encodedWord & 0x1f,
      errorCode = (encodedWord >> 5) & 0xff,
      glucoseMgDl = (encodedWord >> 13) & 0x07ff,
      super._();

  final int trendCode;
  final int errorCode;
  final int glucoseMgDl;
}
