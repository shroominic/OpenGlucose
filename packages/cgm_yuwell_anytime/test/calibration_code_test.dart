import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('CT5 calibration code', () {
    test('parses the synthetic 17-character legacy layout', () {
      final decoded = YuwellCt5CalibrationCode.parse('A4121234561234XYZ');

      expect(decoded.format, YuwellCt5CalibrationCodeFormat.legacy17);
      expect(decoded.marketNumber, isNull);
      expect(decoded.lifeTimeCode, isNull);
      expect(decoded.electrodeType, 'A');
      expect(decoded.yearCode, 4);
      expect(decoded.serialNumber, '12');
      expect(decoded.unitOrder, 123);
      expect(decoded.sensorNumber, '456');
      expect(decoded.calibrationCode, isNull);
      expect(decoded.k, 1.2);
      expect(decoded.r, 3.4);
      expect(decoded.electrodeTechnologyCode, 'X');
      expect(decoded.enzymeTechnologyCode, 'Y');
      expect(decoded.membraneTechnologyCode, 'Z');
    });

    test('parses the synthetic 18-character legacy layout', () {
      final decoded = YuwellCt5CalibrationCode.parse('B5C912399912345ABC');

      expect(decoded.format, YuwellCt5CalibrationCodeFormat.legacy18);
      expect(decoded.electrodeType, 'B');
      expect(decoded.yearCode, 5);
      expect(decoded.serialNumber, 'C9');
      expect(decoded.unitOrder, 123);
      expect(decoded.sensorNumber, '999');
      expect(decoded.k, 1.23);
      expect(decoded.r, 4.5);
      expect(decoded.electrodeTechnologyCode, 'A');
      expect(decoded.enzymeTechnologyCode, 'B');
      expect(decoded.membraneTechnologyCode, 'C');
    });

    test('parses the synthetic 21-character market layout', () {
      final decoded = YuwellCt5CalibrationCode.parse('M4Z612345678912345ABC');

      expect(decoded.format, YuwellCt5CalibrationCodeFormat.extendedMarket);
      expect(decoded.marketNumber, 'M');
      expect(decoded.lifeTimeCode, 4);
      expect(decoded.electrodeType, 'Z');
      expect(decoded.yearCode, 6);
      expect(decoded.serialNumber, '12');
      expect(decoded.unitOrder, 345);
      expect(decoded.sensorNumber, '678');
      expect(decoded.calibrationCode, 9);
      expect(decoded.k, 1.23);
      expect(decoded.r, 4.5);
      expect(decoded.electrodeTechnologyCode, 'A');
      expect(decoded.enzymeTechnologyCode, 'B');
      expect(decoded.membraneTechnologyCode, 'C');
    });

    test('parses the synthetic 21-character zero-prefix layout', () {
      final decoded = YuwellCt5CalibrationCode.parse('00Q712345678912345XYZ');

      expect(decoded.format, YuwellCt5CalibrationCodeFormat.extendedZeroPrefix);
      expect(decoded.marketNumber, '0');
      expect(decoded.lifeTimeCode, 0);
      expect(decoded.electrodeType, 'Q');
      expect(decoded.yearCode, 7);
      expect(decoded.k, 1.23);
      expect(decoded.r, 4.5);
    });

    test('rejects near misses without exposing their values', () {
      for (final value in <String>[
        '',
        'A4121234561234XY',
        'I4Z612345678912345ABC',
        'M0Z612345678912345ABC',
        'M4z612345678912345ABC',
        'M4Z61234567891234-ABC',
      ]) {
        expect(YuwellCt5CalibrationCode.tryParse(value), isNull);
        expect(
          () => YuwellCt5CalibrationCode.parse(value),
          throwsA(
            isA<YuwellProtocolFormatException>().having(
              (error) => error.toString(),
              'redacted error',
              isNot(contains(value.isEmpty ? '<empty>' : value)),
            ),
          ),
        );
      }
    });

    test('does not expose decoded identifiers in toString', () {
      final decoded = YuwellCt5CalibrationCode.parse('M4Z612345678912345ABC');

      expect(decoded.toString(), contains('<redacted>'));
      expect(decoded.toString(), isNot(contains(decoded.serialNumber)));
      expect(decoded.toString(), isNot(contains(decoded.sensorNumber)));
    });
  });
}
