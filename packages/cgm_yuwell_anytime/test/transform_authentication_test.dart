import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('CT5 byte transform', () {
    test('matches simple synthetic bit vectors', () {
      expect(YuwellCt5ByteTransform.decode(<int>[0x00], key: 0), <int>[0xfe]);
      expect(YuwellCt5ByteTransform.encode(<int>[0xfe], key: 0), <int>[0x00]);
      expect(YuwellCt5ByteTransform.decode(<int>[0xa5], key: 0x5a), <int>[
        0xff,
      ]);
    });

    test('uses wire-to-clear direction for a fixed multi-byte vector', () {
      const wire = <int>[0x12, 0x34, 0x56];
      const clear = <int>[0x27, 0x4d, 0xea];
      expect(YuwellCt5ByteTransform.decode(wire, key: 0x5a), clear);
      expect(YuwellCt5ByteTransform.encode(clear, key: 0x5a), wire);
    });

    test('round trips across byte boundaries', () {
      for (final key in <int>[0, 1, 0x5a, 0xff]) {
        for (final cleartext in <List<int>>[
          <int>[],
          <int>[0],
          <int>[0xff],
          <int>[0x12, 0x34, 0x56],
          <int>[0xaa, 0x00, 0x55, 0xff],
        ]) {
          final encoded = YuwellCt5ByteTransform.encode(cleartext, key: key);
          expect(YuwellCt5ByteTransform.decode(encoded, key: key), cleartext);
        }
      }
    });

    test('rejects invalid bytes and keys', () {
      expect(
        () => YuwellCt5ByteTransform.encode(<int>[0x100], key: 0),
        throwsRangeError,
      );
      expect(
        () => YuwellCt5ByteTransform.decode(<int>[0], key: -1),
        throwsRangeError,
      );
    });
  });

  group('communication identity', () {
    test('strictly splits four ID, A, and B digits', () {
      final identity = YuwellCommunicationIdentity.parse('123456789012');
      expect(identity.idPrefix, '1234');
      expect(identity.randomA, <int>[5, 6, 7, 8]);
      expect(identity.randomB, <int>[9, 0, 1, 2]);
      expect(identity.toString(), contains('<redacted>'));
      expect(identity.toString(), isNot(contains('1234')));
    });

    test('does not pad, truncate, or accept non-decimal input', () {
      for (final value in <String>[
        '',
        '12345678901',
        '1234567890123',
        '12345678A012',
        '+661234567890',
      ]) {
        expect(
          () => YuwellCommunicationIdentity.parse(value),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('encodes a synthetic set-ID frame', () {
      final identity = YuwellCommunicationIdentity.parse('123456789012');
      final frame = identity.encodeSetId();
      expect(frame, <int>[0x30, 9, 0, 1, 2, 45, 54, 68, 88, 0x3b]);
      expect(hasValidSum8Frame(frame), isTrue);
    });

    test('derives a one-byte cipher from a strict synthetic response', () {
      final identity = YuwellCommunicationIdentity.parse('123456789012');
      final response = <int>[0x30, 10, 11, 12, 13, 2, 3, 4, 5, 0x6c];
      expect(identity.deriveCipherFromSetIdResponse(response), 0x73);

      expect(
        () => identity.deriveCipherFromSetIdResponse(<int>[
          0x31,
          10,
          11,
          12,
          13,
          2,
          3,
          4,
          5,
          0x6d,
        ]),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => identity.deriveCipherFromSetIdResponse(<int>[0x30, 0x30]),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => identity.deriveCipherFromSetIdResponse(<int>[
          0x30,
          10,
          11,
          12,
          13,
          2,
          3,
          4,
          5,
          0,
        ]),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });
  });
}
