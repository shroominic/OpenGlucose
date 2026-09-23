import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  const base = <int>[
    0x30,
    0x39, // current A: 123.45
    0x5b,
    0xa0, // current B: 234.56
    65,
    50, // temperature: 25.50
    0x31, // trend 3, high glucose nibble 1
    0x2c, // glucose: 300
    7,
  ];

  group('history records', () {
    test('parses 11-byte layout and preserves unknown suffix', () {
      final source = <int>[...base, 0xaa, 0xbb];
      final record = YuwellHistoryRecord.parse(source);

      expect(record.layout, YuwellHistoryRecordLayout.compact11);
      expect(record.currentARaw, 12345);
      expect(record.currentA, closeTo(123.45, 0.0001));
      expect(record.currentBRaw, 23456);
      expect(record.currentB, closeTo(234.56, 0.0001));
      expect(record.temperatureCelsius, closeTo(25.5, 0.0001));
      expect(record.trendCode, 3);
      expect(record.glucoseMgDl, 300);
      expect(record.errorCode, 7);
      expect(record.unknownBytes, <int>[0xaa, 0xbb]);
      expect(record.electrodeRaw, isEmpty);
      expect(record.batteryRaw, isNull);
      expect(record.rawBytes, source);
      expect(record.toString(), contains('<redacted>'));
    });

    test('parses 15-byte voltage layout', () {
      final record = YuwellHistoryRecord.parse(<int>[
        ...base,
        1,
        2,
        3,
        4,
        0x12,
        0x34,
      ]);

      expect(record.layout, YuwellHistoryRecordLayout.voltage15);
      expect(record.unknownBytes, isEmpty);
      expect(record.electrodeRaw, <int>[1, 2, 3, 4]);
      expect(record.electrodeScaled, <int>[6, 12, 18, 24]);
      expect(record.batteryRaw, 0x1234);
      expect(record.calibrationStatus, isNull);
    });

    test('parses 17-byte alert layout', () {
      final record = YuwellHistoryRecord.parse(<int>[
        ...base,
        1,
        2,
        3,
        4,
        0x12,
        0x34,
        0x8d,
        0x53,
      ]);

      expect(record.layout, YuwellHistoryRecordLayout.alert17);
      expect(record.electrodeRaw, <int>[1, 2, 3, 4]);
      expect(record.electrodeScaled, <int>[8, 16, 24, 32]);
      expect(record.batteryRaw, 0x1234);
      expect(record.hypoglycemiaWarningMinutes, 17);
      expect(record.calibrationStatus, 5);
      expect(record.hyperglycemiaWarningMinutes, 10);
      expect(record.warningCode, 3);
    });

    test('rejects malformed lengths, non-bytes, and no-data sentinels', () {
      expect(
        () => YuwellHistoryRecord.parse(List<int>.filled(12, 0)),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => YuwellHistoryRecord.parse(<int>[...base, 0, 0x100]),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => YuwellHistoryRecord.parse(List<int>.filled(11, 0xfc)),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => YuwellHistoryRecord.parse(List<int>.filled(17, 0xff)),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('copies and freezes source and unknown bytes', () {
      final source = <int>[...base, 0xaa, 0xbb];
      final record = YuwellHistoryRecord.parse(source);
      source[0] = 0;
      expect(record.rawBytes.first, 0x30);
      expect(() => record.rawBytes.add(1), throwsUnsupportedError);
      expect(() => record.unknownBytes.add(1), throwsUnsupportedError);
    });
  });
}
