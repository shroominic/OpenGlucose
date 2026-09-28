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
      expect(
        () => requireValidSum8Frame(<int>[0x31]),
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

    test('encodes the fixed self-check request', () {
      // Pairs with selfCheckAccepted (CT5 response validators, above): not
      // currently called anywhere in driver.dart, but public clean-room API
      // with its own encoding contract.
      final frame = YuwellCt5Commands.selfCheck();
      expect(frame, <int>[0x05, 0x55, 0xaa, 0x04]);
      expect(hasValidSum8Frame(frame), isTrue);
    });

    test('encodes both initialize branches', () {
      final transmitterComputed = YuwellCt5Commands.initialize(
        transmitterComputed: true,
        initializationIndex: 20,
      );
      expect(transmitterComputed, <int>[0x06, 20, 0x01, 0x1b]);
      expect(hasValidSum8Frame(transmitterComputed), isTrue);

      // The non-transmitter-computed branch ignores initializationIndex
      // entirely and sends the same fixed request the reference app does
      // for that case -- confirms the index argument cannot leak into the
      // wrong wire form by accident.
      final notTransmitterComputed = YuwellCt5Commands.initialize(
        transmitterComputed: false,
        initializationIndex: 20,
      );
      expect(notTransmitterComputed, <int>[0x06, 0x55, 0xaa, 0x05]);
      expect(hasValidSum8Frame(notTransmitterComputed), isTrue);

      expect(
        () => YuwellCt5Commands.initialize(
          transmitterComputed: true,
          initializationIndex: -1,
        ),
        throwsRangeError,
      );
      expect(
        () => YuwellCt5Commands.initialize(
          transmitterComputed: true,
          initializationIndex: 0x100,
        ),
        throwsRangeError,
      );
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
    test('accepts the exact self-check response shape and rejects any '
        'other length', () {
      // The driver does not currently send 0x05 -- this validator has no
      // call site in driver.dart today -- but it is public, clean-room
      // API surface with no test of its own. Covering its shape contract
      // on its own terms, not as a claim that the live session exercises
      // it.
      final valid = appendYuwellSum8(<int>[
        YuwellCt5Commands.selfCheckCommand,
        ...List<int>.filled(18, 0),
      ]);
      expect(
        () => YuwellCt5Responses.selfCheckAccepted(valid),
        returnsNormally,
      );

      final wrongLength = appendYuwellSum8(<int>[
        YuwellCt5Commands.selfCheckCommand,
        0,
        0,
      ]);
      expect(
        () => YuwellCt5Responses.selfCheckAccepted(wrongLength),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

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

  group('CT5 history frame layout inference', () {
    // YuwellHistoryFrame.parse infers a base-opcode payload's record layout
    // from length divisibility alone when no expectedLayout is supplied.
    // Neither case below needs real per-record content: the ambiguous-length
    // rejection happens before any record is read, and an all-0xFC slot is
    // the documented end sentinel, so the frame terminates on the first slot
    // without calling into the per-record parser at all.
    List<int> historyFrame(List<int> clear) => appendYuwellSum8(<int>[
      YuwellCt5Commands.historyCommand,
      0,
      0,
      ...YuwellCt5ByteTransform.encode(clear, key: 0),
    ]);

    test('rejects a payload length divisible by both known record sizes', () {
      final ambiguous = historyFrame(List<int>.filled(11 * 15, 0));

      expect(
        () => YuwellHistoryFrame.parse(ambiguous, cipher: 0),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('infers compact11 for a length only compact11 divides', () {
      final clear = List<int>.filled(22, 0xfc);
      final parsed = YuwellHistoryFrame.parse(historyFrame(clear), cipher: 0);

      expect(parsed.layout, YuwellHistoryRecordLayout.compact11);
      expect(parsed.terminated, isTrue);
      expect(parsed.consumedSlots, 0);
      expect(parsed.indexedRecords, isEmpty);
    });

    test('rejects explicit layouts that do not match the history opcode', () {
      final invalidHints = <({int opcode, YuwellHistoryRecordLayout layout})>[
        (
          opcode: YuwellCt5Commands.alternateHistoryCommand,
          layout: YuwellHistoryRecordLayout.compact11,
        ),
        (
          opcode: YuwellCt5Commands.alternateHistoryCommand,
          layout: YuwellHistoryRecordLayout.voltage15,
        ),
        (
          opcode: YuwellCt5Commands.historyCommand,
          layout: YuwellHistoryRecordLayout.alert17,
        ),
      ];

      for (final invalid in invalidHints) {
        final length = switch (invalid.layout) {
          YuwellHistoryRecordLayout.compact11 => 11,
          YuwellHistoryRecordLayout.voltage15 => 15,
          YuwellHistoryRecordLayout.alert17 => 17,
        };
        final frame = appendYuwellSum8(<int>[
          invalid.opcode,
          0,
          0,
          ...YuwellCt5ByteTransform.encode(
            List<int>.filled(length, 0xfc),
            key: 0,
          ),
        ]);

        expect(
          () => YuwellHistoryFrame.parse(
            frame,
            cipher: 0,
            expectedLayout: invalid.layout,
          ),
          throwsA(isA<YuwellProtocolFormatException>()),
          reason: '${invalid.opcode.toRadixString(16)} ${invalid.layout}',
        );
      }
    });

    test('preserves valid explicit layouts and empty terminators', () {
      final cases =
          <({int opcode, YuwellHistoryRecordLayout? layout, int clearLength})>[
            (
              opcode: YuwellCt5Commands.alternateHistoryCommand,
              layout: YuwellHistoryRecordLayout.alert17,
              clearLength: 17,
            ),
            (
              opcode: YuwellCt5Commands.historyCommand,
              layout: YuwellHistoryRecordLayout.compact11,
              clearLength: 11,
            ),
            (
              opcode: YuwellCt5Commands.historyCommand,
              layout: YuwellHistoryRecordLayout.voltage15,
              clearLength: 15,
            ),
            (
              opcode: YuwellCt5Commands.historyCommand,
              layout: YuwellHistoryRecordLayout.compact11,
              clearLength: 165,
            ),
            (
              opcode: YuwellCt5Commands.historyCommand,
              layout: YuwellHistoryRecordLayout.voltage15,
              clearLength: 165,
            ),
            (
              opcode: YuwellCt5Commands.historyCommand,
              layout: null,
              clearLength: 0,
            ),
          ];

      for (final value in cases) {
        final clear = List<int>.filled(value.clearLength, 0xfc);
        final frame = appendYuwellSum8(<int>[
          value.opcode,
          0,
          0,
          ...YuwellCt5ByteTransform.encode(clear, key: 0),
        ]);

        final parsed = YuwellHistoryFrame.parse(
          frame,
          cipher: 0,
          expectedLayout: value.layout,
        );

        expect(parsed.layout, value.layout);
        expect(parsed.terminated, isTrue);
        expect(parsed.indexedRecords, isEmpty);
      }
    });
  });
}
