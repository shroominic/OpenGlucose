import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

List<int> _uint24(int value) => <int>[
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

void main() {
  group('passive packed records', () {
    test('parses raw current and temperature bits', () {
      final word = (1234 << 10) | 650;
      final source = _uint24(word);
      final record = YuwellPackedRecord.parse(
        source,
        kind: YuwellPackedRecordKind.currentAndTemperature,
      );

      expect(record, isA<YuwellPackedCurrentTemperatureRecord>());
      final current = record as YuwellPackedCurrentTemperatureRecord;
      expect(current.encodedWord, word);
      expect(current.currentRaw, 1234);
      expect(current.current, closeTo(12.34, 0.0001));
      expect(current.temperatureRaw, 650);
      expect(current.temperatureCelsius, closeTo(25, 0.0001));
      expect(current.rawBytes, source);
      expect(current.toString(), contains('<redacted>'));
    });

    test('parses glucose, error, and trend bits', () {
      final word = (150 << 13) | (42 << 5) | 7;
      final record = YuwellPackedRecord.parse(
        _uint24(word),
        kind: YuwellPackedRecordKind.glucose,
      );

      expect(record, isA<YuwellPackedGlucoseRecord>());
      final glucose = record as YuwellPackedGlucoseRecord;
      expect(glucose.encodedWord, word);
      expect(glucose.glucoseMgDl, 150);
      expect(glucose.errorCode, 42);
      expect(glucose.trendCode, 7);
    });

    test('rejects malformed length and non-byte input', () {
      expect(
        () => YuwellPackedRecord.parse(<int>[
          1,
          2,
        ], kind: YuwellPackedRecordKind.glucose),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => YuwellPackedRecord.parse(<int>[
          1,
          2,
          0x100,
        ], kind: YuwellPackedRecordKind.glucose),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('copies and freezes raw bytes', () {
      final source = <int>[1, 2, 3];
      final record = YuwellPackedRecord.parse(
        source,
        kind: YuwellPackedRecordKind.glucose,
      );
      source[0] = 9;
      expect(record.rawBytes.first, 1);
      expect(() => record.rawBytes.add(4), throwsUnsupportedError);
    });
  });
}
