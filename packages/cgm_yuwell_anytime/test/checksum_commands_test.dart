import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('sum8 frames', () {
    test('wraps and appends the additive checksum', () {
      expect(yuwellSum8(<int>[0xff, 0x02]), 0x01);
      expect(appendYuwellSum8(<int>[0x31, 1, 2, 3, 4]), <int>[
        0x31,
        1,
        2,
        3,
        4,
        0x3b,
      ]);
    });

    test('validates structure, byte range, and checksum', () {
      expect(hasValidSum8Frame(<int>[0x31, 0x31]), isTrue);
      expect(hasValidSum8Frame(<int>[0x31, 0x30]), isFalse);
      expect(hasValidSum8Frame(<int>[0x100, 0]), isFalse);
      expect(hasValidSum8Frame(<int>[0x00]), isFalse);
      expect(hasValidSum8Frame(null), isFalse);
      expect(
        () => requireValidSum8Frame(<int>[0x31, 0x30]),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('returns immutable frame bytes', () {
      final frame = appendYuwellSum8(<int>[1]);
      expect(() => frame.add(2), throwsUnsupportedError);
    });
  });

  group('CT5 command encoders', () {
    test('encodes the one-byte version query', () {
      expect(YuwellCt5Commands.readVersion(), <int>[0x01]);
    });

    test('encodes exactly four check-ID bytes', () {
      final frame = YuwellCt5Commands.checkId(<int>[1, 2, 3, 4]);
      expect(frame, <int>[0x31, 1, 2, 3, 4, 0x3b]);
      expect(hasValidSum8Frame(frame), isTrue);
      expect(
        () => YuwellCt5Commands.checkId(<int>[1, 2, 3]),
        throwsArgumentError,
      );
      expect(
        () => YuwellCt5Commands.checkId(<int>[1, 2, 3, 0x100]),
        throwsRangeError,
      );
    });

    test('encodes literal date fields without timezone conversion', () {
      final frame = YuwellCt5Commands.setDate(DateTime(2026, 8, 31, 14, 5, 6));
      expect(frame, <int>[0x03, 126, 8, 31, 14, 5, 6, 0xc1]);
      expect(hasValidSum8Frame(frame), isTrue);
      expect(() => YuwellCt5Commands.setDate(DateTime(1899)), throwsRangeError);
      expect(() => YuwellCt5Commands.setDate(DateTime(2156)), throwsRangeError);
    });

    test('encodes little-endian history start and count', () {
      final frame = YuwellCt5Commands.readHistory(
        startIndex: 0x1234,
        recordCount: 5,
      );
      expect(frame, <int>[0x37, 0x34, 0x12, 5, 0x82]);
      expect(hasValidSum8Frame(frame), isTrue);
      expect(
        () => YuwellCt5Commands.readHistory(startIndex: -1),
        throwsRangeError,
      );
      expect(
        () => YuwellCt5Commands.readHistory(startIndex: 0, recordCount: 0),
        throwsRangeError,
      );
    });
  });

  group('CT5 response validators', () {
    test('rejects an invalid reset-reason value as activation evidence', () {
      final malformed = appendYuwellSum8(<int>[
        0x11,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0x22,
      ]);

      expect(
        () => YuwellCt5Responses.bindingStatus(malformed),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        YuwellCt5Responses.bindingStatus(
          appendYuwellSum8(<int>[0x11, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0x22]),
        ),
        isFalse,
      );
    });
  });
}
