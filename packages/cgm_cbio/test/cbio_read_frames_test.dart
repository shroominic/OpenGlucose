import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Synthetic fixtures only; no live data, identity, key, or ciphertext.
List<int> checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, value) => sum + value)) & 255,
];

List<int> le16(int value) => [value & 255, (value >> 8) & 255];
List<int> le32(int value) => [...le16(value), ...le16(value >> 16)];

List<int> raw({
  int count = 2,
  int index = 7,
  int time = 1234,
  int reindex = 40,
}) => checked([
  11 + 8 * count,
  8,
  count,
  ...le16(index),
  ...le32(time),
  for (var i = 0; i < count; i++) ...[
    ...le16(0x1234 + i), // temperature
    ...le16(0x5678 + i), // dump precedes the payload on wire
    ...le16(0x9abc + i), // payload
    0xd5, 0x12, // processed word: glucose 75, trend 2, warning 2, bit 1
  ],
  ...le16(reindex),
]);

void main() {
  test(
    'start ACKs require the expected command and retain unknown results',
    () {
      for (final opcode in [3, 7]) {
        for (final result in [0, 1, 2, 255]) {
          for (final status in [0, 2, 4, 5, 255]) {
            final ack = parseCbioStartAckFrame(
              checked([4, opcode, result, status]),
              expectedOpcode: opcode,
            );
            expect(ack.opcode, opcode);
            expect(ack.result, result);
            expect(ack.rawStatus, status);
          }
        }
        for (final wrong in [1, 2, 3, 7, 8, 0xf0].where((x) => x != opcode)) {
          expect(
            () => parseCbioStartAckFrame(
              checked([4, wrong, 1, 0]),
              expectedOpcode: opcode,
            ),
            throwsA(isA<CbioFrameException>()),
          );
        }
      }
      for (final invalid in [-1, 0, 1, 2, 8, 0xf0, 256]) {
        expect(
          () => parseCbioStartAckFrame(
            checked([4, 7, 1, 0]),
            expectedOpcode: invalid,
          ),
          throwsA(isA<CbioFrameException>()),
        );
      }
    },
  );

  test('start ACK parsers reject truncation, corruption and data frames', () {
    for (final opcode in [3, 7]) {
      final bytes = checked([4, opcode, 1, 0]);
      for (var n = 0; n < bytes.length; n++) {
        expect(
          () => parseCbioStartAckFrame(
            bytes.sublist(0, n),
            expectedOpcode: opcode,
          ),
          throwsA(isA<CbioFrameException>()),
        );
      }
      for (var offset = 0; offset < bytes.length; offset++) {
        final changed = [...bytes];
        changed[offset] ^= 1;
        expect(
          () => parseCbioStartAckFrame(changed, expectedOpcode: opcode),
          throwsA(isA<CbioFrameException>()),
        );
      }
      expect(
        () => parseCbioStartAckFrame(
          checked([5, opcode, 1, 0, 0]),
          expectedOpcode: opcode,
        ),
        throwsA(isA<CbioFrameException>()),
      );
      expect(
        () => parseCbioStartAckFrame(
          [...bytes]..[3] = 256,
          expectedOpcode: opcode,
        ),
        throwsA(isA<CbioFrameException>()),
      );
    }
  });

  test('activation information preserves all states without ACK semantics', () {
    for (var value = 0; value <= 255; value++) {
      final parsed = parseCbioActivationFrame(checked([4, 0xf0, 2, value]));
      expect(parsed.rawActivation, value);
    }
    for (final bytes in [
      checked([4, 0xf0, 0, 2]),
      checked([4, 0xf0, 1, 0]),
      checked([4, 0x01, 1, 0]),
      checked([4, 0x02, 1, 0]),
      checked([4, 0xf0, 3, 0]),
      checked([5, 0xf0, 2, 1, 0]),
    ]) {
      expect(
        () => parseCbioActivationFrame(bytes),
        throwsA(isA<CbioFrameException>()),
      );
    }
  });

  test('zero history fields retain independent clock and counters', () {
    final storage = parseCbioStorageFrame(checked([8, 0xf0, 4, 0, 0, 0, 7, 9]));
    final timing = parseCbioTimeFrame(
      checked([
        19,
        0xf0,
        3,
        0,
        0,
        ...le32(0),
        ...le32(0x76543210),
        ...le32(0),
        ...le16(0),
      ]),
    );
    expect(storage.rawStatus, 0);
    expect(storage.rawStorageNumber, 0);
    expect(storage.rawConfigTimes, 7);
    expect(storage.rawKeyTimes, 9);
    expect(timing.rawStartoverTime, 0);
    expect(timing.rawActivationTime, 0);
    expect(timing.rawCurrentTime, 0x76543210);
    expect(timing.rawLastTime, 0);
    expect(timing.rawLastIndex, 0);
    // Parsing metadata does not select a read policy or invent an activation
    // verdict. A separate structurally valid index-1 raw frame still parses.
    expect(
      parseCbioRawDataFrame(
        raw(count: 1, index: 1),
      ).records.single.processed.index,
      1,
    );
  });

  test('raw record stride, field order, flags and counters stay distinct', () {
    final bytes = raw();
    final parsed = parseCbioRawDataFrame(bytes);
    expect(parsed.records.length, 2);
    for (var i = 0; i < 2; i++) {
      final r = parsed.records[i];
      expect(r.rawTemperature, 0x1234 + i);
      expect(r.rawDump, 0x5678 + i);
      expect(r.rawPayload, 0x9abc + i);
      expect(r.processed.index, 7 + i);
      expect(r.processed.rawTime, 1234 + 60 * i);
      expect(r.processed.reindex, 41 - i);
      expect(r.processed.rawWord, 0x12d5);
      expect(r.processed.rawGlucose, 75);
      expect(r.processed.rawTrend, 2);
      expect(r.processed.rawGlucoseWarning, 2);
      expect(r.processed.rawSharedWarning, 1);
    }
    bytes.fillRange(0, bytes.length, 0);
    expect(parsed.records.first.rawPayload, 0x9abc);
    expect(() => parsed.records.clear(), throwsUnsupportedError);
  });

  test('raw framing limits, empty batch and unknown wrap are checked', () {
    expect(parseCbioRawDataFrame(raw(count: 0)).records, isEmpty);
    expect(parseCbioRawDataFrame(raw(count: 30)).records.length, 30);
    for (final bytes in [
      raw(count: 31),
      raw(index: 0xffff),
      raw(time: 0xffffffff),
      raw(reindex: 0xffff),
    ]) {
      expect(
        () => parseCbioRawDataFrame(bytes),
        throwsA(isA<CbioFrameException>()),
      );
    }
    expect(
      parseCbioRawDataFrame(
        raw(count: 1, index: 0xffff, time: 0xffffffff, reindex: 0xffff),
      ).records.single.processed.index,
      0xffff,
    );
  });

  test('raw parser rejects ACKs, packed 0A frames and changed counts', () {
    for (final bytes in [
      checked([4, 8, 0, 4]),
      checked([4, 8, 1, 0]),
      checked([11, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      checked(raw().sublist(0, 27)..[2] = 1),
    ]) {
      expect(
        () => parseCbioRawDataFrame(bytes),
        throwsA(isA<CbioFrameException>()),
      );
    }
    // Existing generic parser remains closed to raw data.
    expect(
      () => parseCbioPlaintextFrame(raw()),
      throwsA(isA<CbioFrameException>()),
    );
  });

  test('storage fields preserve byte widths and unknown status', () {
    final info = parseCbioStorageFrame(
      checked([8, 0xf0, 4, 0xe7, 0x34, 0x12, 0xab, 0xcd]),
    );
    expect(info.rawStatus, 0xe7);
    expect(info.rawStorageNumber, 0x1234);
    expect(info.rawConfigTimes, 0xab);
    expect(info.rawKeyTimes, 0xcd);
  });

  test('time reply preserves unsigned values and exact index offset', () {
    final info = parseCbioTimeFrame(
      checked([
        19,
        0xf0,
        3,
        ...le16(0x1234),
        ...le32(0x89abcdef),
        ...le32(0x76543210),
        ...le32(0xffffffff),
        ...le16(0xfedc),
      ]),
    );
    expect(info.rawStartoverTime, 0x1234);
    expect(info.rawActivationTime, 0x89abcdef);
    expect(info.rawCurrentTime, 0x76543210);
    expect(info.rawLastTime, 0xffffffff);
    expect(info.rawLastIndex, 0xfedc);
  });

  test('information replies require their selector, length and data body', () {
    final storage = checked([8, 0xf0, 4, 0, 0, 0, 0, 0]);
    final time = checked([19, 0xf0, 3, ...List.filled(16, 0)]);
    for (final parse in <Object Function(List<int>)>[
      parseCbioStorageFrame,
      parseCbioTimeFrame,
    ]) {
      for (final bytes in [
        checked([4, 0xf0, 0, 2]), // failure control, not information
        checked([4, 0xf0, 1, 0]), // success control, not information
        checked([4, 0xf0, 2, 1]), // activation selector is not supported here
        checked([8, 0xf0, 0, 0, 0, 0, 0, 0]),
      ]) {
        expect(() => parse(bytes), throwsA(isA<CbioFrameException>()));
      }
    }
    expect(
      () => parseCbioStorageFrame(time),
      throwsA(isA<CbioFrameException>()),
    );
    expect(
      () => parseCbioTimeFrame(storage),
      throwsA(isA<CbioFrameException>()),
    );
    expect(
      () => parseCbioStorageFrame(checked([9, ...storage.sublist(1, 8), 0])),
      throwsA(isA<CbioFrameException>()),
    );
  });

  test(
    'all new parsers reject every truncation, corruption and trailing byte',
    () {
      final cases = <(Object Function(List<int>), List<int>)>[
        (parseCbioActivationFrame, checked([4, 0xf0, 2, 0x7e])),
        (parseCbioRawDataFrame, raw()),
        (parseCbioStorageFrame, checked([8, 0xf0, 4, 7, 9, 0, 3, 5])),
        (parseCbioTimeFrame, checked([19, 0xf0, 3, ...List.filled(16, 1)])),
      ];
      for (final (parse, bytes) in cases) {
        for (var length = 0; length < bytes.length; length++) {
          expect(
            () => parse(bytes.sublist(0, length)),
            throwsA(isA<CbioFrameException>()),
          );
        }
        for (var offset = 0; offset < bytes.length; offset++) {
          final changed = [...bytes];
          changed[offset] ^= 1;
          expect(() => parse(changed), throwsA(isA<CbioFrameException>()));
        }
        for (final invalid in [-1, 256]) {
          expect(
            () => parse([...bytes]..[3] = invalid),
            throwsA(isA<CbioFrameException>()),
          );
        }
        expect(() => parse([...bytes, 0]), throwsA(isA<CbioFrameException>()));
      }
    },
  );
}
