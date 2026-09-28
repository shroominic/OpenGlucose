import 'dart:convert';

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('YuwellRecordState', () {
    test('round trips an empty bound state canonically', () {
      final state = YuwellRecordState.empty(binding: _binding());

      final encoded = state.encode();
      final restored = YuwellRecordState.decode(encoded);

      expect(
        encoded,
        '{"version":1,"driverId":"yuwell-anytime",'
        '"sensorBinding":"${'a' * 64}",'
        '"historyGeneration":"${'b' * 32}",'
        '"firmware":"V1150","historyOpcode":71,'
        '"layout":"alert17","slots":[]}',
      );
      expect(restored.nextIndex, 0);
      expect(restored.slots, isEmpty);
      restored.requireBinding(_binding());
    });

    test('round trips exact record bytes and an explicit empty slot', () {
      final record = _indexedRecord(0, seed: 1);
      final state = YuwellRecordState.empty(binding: _binding()).appendBatch(
        YuwellRecordBatch(
          startIndex: 0,
          consumedSlots: 2,
          records: <YuwellIndexedHistoryRecord>[record],
        ),
      );

      final restored = YuwellRecordState.decode(state.encode());

      expect(restored.nextIndex, 2);
      expect(restored.slots, hasLength(2));
      expect(restored.slots.first, isA<YuwellRawRecordSlot>());
      expect(
        (restored.slots.first as YuwellRawRecordSlot).bytes,
        record.record.rawBytes,
      );
      expect(restored.slots.last, isA<YuwellEmptyRecordSlot>());
      expect(state.encode(), isNot(contains('glucoseMgDl')));
      expect(state.encode(), isNot(contains('temperature')));
    });

    test('accepts an exact duplicate batch without extending state', () {
      final batch = YuwellRecordBatch(
        startIndex: 0,
        consumedSlots: 2,
        records: <YuwellIndexedHistoryRecord>[_indexedRecord(0, seed: 2)],
      );
      final state = YuwellRecordState.empty(
        binding: _binding(),
      ).appendBatch(batch);

      final duplicate = state.appendBatch(batch);

      expect(duplicate.encode(), state.encode());
      expect(duplicate.nextIndex, 2);
    });

    test('rejects gaps and out-of-range batches', () {
      final empty = YuwellRecordState.empty(binding: _binding());

      expect(
        () => empty.appendBatch(
          YuwellRecordBatch(
            startIndex: 1,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_indexedRecord(1)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      for (final invalid in <YuwellRecordBatch>[
        YuwellRecordBatch(
          startIndex: -1,
          consumedSlots: 1,
          records: const <YuwellIndexedHistoryRecord>[],
        ),
        YuwellRecordBatch(
          startIndex: 0,
          consumedSlots: 0,
          records: const <YuwellIndexedHistoryRecord>[],
        ),
        YuwellRecordBatch(
          startIndex: 7694,
          consumedSlots: 2,
          records: const <YuwellIndexedHistoryRecord>[],
        ),
      ]) {
        expect(
          () => empty.appendBatch(invalid),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('accepts exactly 7695 slots and rejects any extension', () {
      final full = YuwellRecordState.empty(binding: _binding()).appendBatch(
        YuwellRecordBatch(
          startIndex: 0,
          consumedSlots: 7695,
          records: const <YuwellIndexedHistoryRecord>[],
        ),
      );

      expect(full.nextIndex, 7695);
      expect(
        () => full.appendBatch(
          YuwellRecordBatch(
            startIndex: 7695,
            consumedSlots: 1,
            records: const <YuwellIndexedHistoryRecord>[],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects duplicate record indexes and records outside the batch', () {
      final empty = YuwellRecordState.empty(binding: _binding());
      final record = _indexedRecord(0);

      expect(
        () => empty.appendBatch(
          YuwellRecordBatch(
            startIndex: 0,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[record, record],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => empty.appendBatch(
          YuwellRecordBatch(
            startIndex: 0,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_indexedRecord(1)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects record-byte and record-versus-empty conflicts', () {
      final state = YuwellRecordState.empty(binding: _binding()).appendBatch(
        YuwellRecordBatch(
          startIndex: 0,
          consumedSlots: 2,
          records: <YuwellIndexedHistoryRecord>[_indexedRecord(0, seed: 3)],
        ),
      );

      expect(
        () => state.appendBatch(
          YuwellRecordBatch(
            startIndex: 0,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_indexedRecord(0, seed: 4)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(
        () => state.appendBatch(
          YuwellRecordBatch(
            startIndex: 1,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_indexedRecord(1, seed: 5)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects record layout and opcode-layout mismatches', () {
      expect(
        () => YuwellRecordState.empty(
          binding: _binding(
            opcode: YuwellCt5Commands.historyCommand,
            layout: YuwellHistoryRecordLayout.alert17,
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      final compactState = YuwellRecordState.empty(
        binding: _binding(
          opcode: YuwellCt5Commands.historyCommand,
          layout: YuwellHistoryRecordLayout.compact11,
        ),
      );
      expect(
        () => compactState.appendBatch(
          YuwellRecordBatch(
            startIndex: 0,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_indexedRecord(0)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects foreign bindings field by field', () {
      final state = YuwellRecordState.empty(binding: _binding());
      final foreignBindings = <YuwellRecordBinding>[
        _binding(sensorBinding: 'c' * 64),
        _binding(historyGeneration: 'd' * 32),
        _binding(firmware: 'V1151'),
        _binding(
          opcode: YuwellCt5Commands.historyCommand,
          layout: YuwellHistoryRecordLayout.voltage15,
        ),
        _binding(
          opcode: YuwellCt5Commands.historyCommand,
          layout: YuwellHistoryRecordLayout.compact11,
        ),
      ];

      for (final foreign in foreignBindings) {
        expect(
          () => state.requireBinding(foreign),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('enforces exact binding grammars', () {
      final invalidBindings = <YuwellRecordBinding>[
        _binding(sensorBinding: 'A' * 64),
        _binding(sensorBinding: 'a' * 63),
        _binding(historyGeneration: 'B' * 32),
        _binding(historyGeneration: 'b' * 31),
        _binding(firmware: ''),
        _binding(firmware: 'v1150'),
        _binding(firmware: 'V${'A' * 32}'),
      ];

      for (final invalid in invalidBindings) {
        expect(
          () => YuwellRecordState.empty(binding: invalid),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('rejects malformed, noncanonical, and future envelopes', () {
      final canonical = YuwellRecordState.empty(binding: _binding())
          .appendBatch(
            YuwellRecordBatch(
              startIndex: 0,
              consumedSlots: 1,
              records: <YuwellIndexedHistoryRecord>[_indexedRecord(0)],
            ),
          )
          .encode();
      final decoded = jsonDecode(canonical) as Map<String, Object?>;

      final malformedCases = <String>[
        '{',
        ' $canonical',
        jsonEncode(<String, Object?>{...decoded, 'extra': true}),
        jsonEncode(<String, Object?>{...decoded, 'version': 2}),
        jsonEncode(<String, Object?>{
          ...decoded,
          'slots': <Object?>[
            <String, Object?>{'kind': 'record', 'bytes': '!not-base64!'},
          ],
        }),
        jsonEncode(<String, Object?>{
          ...decoded,
          'slots': <Object?>[
            <String, Object?>{'kind': 'empty', 'bytes': ''},
          ],
        }),
      ];

      for (final malformed in malformedCases) {
        expect(
          () => YuwellRecordState.decode(malformed),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
      expect(
        () => YuwellRecordState.decode(' ' * 524289),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    });

    test('rejects wrong-length and sentinel record bytes in envelopes', () {
      final base =
          jsonDecode(YuwellRecordState.empty(binding: _binding()).encode())
              as Map<String, Object?>;
      for (final bytes in <List<int>>[
        List<int>.filled(16, 1),
        List<int>.filled(17, 0xfc),
        List<int>.filled(17, 0xff),
      ]) {
        final encoded = jsonEncode(<String, Object?>{
          ...base,
          'slots': <Object?>[
            <String, Object?>{'kind': 'record', 'bytes': base64Encode(bytes)},
          ],
        });
        expect(
          () => YuwellRecordState.decode(encoded),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });

    test('returns immutable slot and byte lists and redacts strings', () {
      final state = YuwellRecordState.empty(binding: _binding()).appendBatch(
        YuwellRecordBatch(
          startIndex: 0,
          consumedSlots: 1,
          records: <YuwellIndexedHistoryRecord>[_indexedRecord(0)],
        ),
      );
      final raw = state.slots.single as YuwellRawRecordSlot;

      expect(
        () => state.slots.add(const YuwellEmptyRecordSlot()),
        throwsA(anything),
      );
      expect(() => raw.bytes[0] = 0, throwsA(anything));
      expect(state.toString(), isNot(contains('a' * 64)));
      expect(state.toString(), isNot(contains('b' * 32)));
      expect(state.binding.toString(), isNot(contains('a' * 64)));
      expect(raw.toString(), isNot(contains(raw.bytes.join(','))));
    });
  });
}

YuwellRecordBinding _binding({
  String? sensorBinding,
  String? historyGeneration,
  String firmware = 'V1150',
  int opcode = YuwellCt5Commands.alternateHistoryCommand,
  YuwellHistoryRecordLayout layout = YuwellHistoryRecordLayout.alert17,
}) => YuwellRecordBinding(
  sensorBinding: sensorBinding ?? 'a' * 64,
  historyGeneration: historyGeneration ?? 'b' * 32,
  firmware: firmware,
  historyOpcode: opcode,
  layout: layout,
);

YuwellIndexedHistoryRecord _indexedRecord(int index, {int seed = 1}) {
  final bytes = List<int>.generate(17, (offset) => (seed + offset) & 0xff);
  return YuwellIndexedHistoryRecord(
    index: index,
    record: YuwellHistoryRecord.parse(bytes),
  );
}
