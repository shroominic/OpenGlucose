import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Synthetic byte patterns only. No live capture, key, or identifier is used.
List<int> checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

Matcher fails(CbioFrameFailure reason) => throwsA(
  isA<CbioFrameException>().having((e) => e.reason, 'reason', reason),
);

List<int> batch({int index = 100, int time = 1000, int remaining = 20}) =>
    checked([
      15, 0x0a, 2,
      index & 255, index >> 8,
      time & 255, (time >> 8) & 255, (time >> 16) & 255, (time >> 24) & 255,
      0xd5, 0x12, // 75, trend 2, warning 2, shared bit 1.
      0x2e, 0x80, // 512, trend 5, warning 3, shared bit 0.
      remaining & 255, remaining >> 8,
    ]);

void main() {
  test('ACK fields retain raw status and only correlate the opcode', () {
    final ack =
        parseCbioPlaintextFrame(checked([4, 0x01, 0, 0x7e]))
            as CbioAcknowledgement;
    expect(ack.result, 0);
    expect(ack.rawStatus, 0x7e);
    expect(ack.echoesCommand(0x01), isTrue);
    expect(ack.echoesCommand(0x0a), isFalse);
    expect(
      parseCbioPlaintextFrame(checked([4, 0x0a, 1, 0])),
      isA<CbioAcknowledgement>(),
    );
  });

  test('packed records preserve bits, endian order, and opposing counters', () {
    final input = batch();
    final data = parseCbioPlaintextFrame(input) as CbioPackedBatch;
    final first = data.records[0];
    expect([first.index, first.rawTime, first.reindex], [100, 1000, 21]);
    expect(
      [
        first.rawGlucose,
        first.rawTrend,
        first.rawGlucoseWarning,
        first.rawSharedWarning,
      ],
      [75, 2, 2, 1],
    );
    final second = data.records[1];
    expect([second.index, second.rawTime, second.reindex], [101, 1060, 20]);
    expect(
      [
        second.rawGlucose,
        second.rawTrend,
        second.rawGlucoseWarning,
        second.rawSharedWarning,
      ],
      [512, 5, 3, 0],
    );
    input.fillRange(0, input.length, 0);
    expect(first.rawGlucose, 75);
    expect(() => data.records.clear(), throwsUnsupportedError);
  });

  test('all packed bit combinations decode without field overlap', () {
    for (var word = 0; word <= 0xffff; word++) {
      final p = word & 255;
      final q = word >> 8;
      final parsed =
          parseCbioPlaintextFrame(
                checked([13, 0x0a, 1, 0, 0, 0, 0, 0, 0, p, q, 0, 0]),
              )
              as CbioPackedBatch;
      final r = parsed.records.single;
      final rebuilt =
          r.rawSharedWarning |
          (r.rawGlucoseWarning << 1) |
          (r.rawTrend << 3) |
          (r.rawGlucose << 6);
      expect(rebuilt, word);
    }
  });

  test('empty and maximum count batches have exact bounded lengths', () {
    final empty =
        parseCbioPlaintextFrame(checked([11, 0x0a, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
            as CbioPackedBatch;
    expect(empty.records, isEmpty);
    final max =
        parseCbioPlaintextFrame(
              checked([
                255,
                0x0a,
                122,
                0,
                0,
                0,
                0,
                0,
                0,
                ...List.filled(244, 255),
                0,
                0,
              ]),
            )
            as CbioPackedBatch;
    expect(max.records.length, 122);
    expect(max.records.last.rawGlucose, 1023);
    expect(max.records.last.rawTime, 7260);
  });

  test('every truncated prefix and a trailing byte are rejected', () {
    final valid = batch();
    for (var length = 0; length < valid.length; length++) {
      expect(
        () => parseCbioPlaintextFrame(valid.sublist(0, length)),
        throwsA(isA<CbioFrameException>()),
      );
    }
    expect(
      () => parseCbioPlaintextFrame([...valid, 0]),
      fails(CbioFrameFailure.length),
    );
  });

  test(
    'corruption, byte range, wrong opcode, and count mismatch fail closed',
    () {
      final corrupt = batch()..[9] ^= 1;
      expect(
        () => parseCbioPlaintextFrame(corrupt),
        fails(CbioFrameFailure.checksum),
      );
      for (final byte in [-1, 256]) {
        expect(
          () => parseCbioPlaintextFrame(batch()..[9] = byte),
          fails(CbioFrameFailure.byteRange),
        );
      }
      expect(
        () => parseCbioPlaintextFrame(checked([4, 0x08, 1, 0])),
        fails(CbioFrameFailure.opcode),
      );
      final prefix = batch().sublist(0, 15)..[1] = 0x08;
      expect(
        () => parseCbioPlaintextFrame(checked(prefix)),
        fails(CbioFrameFailure.opcode),
      );
      prefix[1] = 0x0a;
      prefix[2] = 3;
      expect(
        () => parseCbioPlaintextFrame(checked(prefix)),
        fails(CbioFrameFailure.count),
      );
    },
  );

  test('unknown counter wrap is rejected rather than silently projected', () {
    for (final input in [
      batch(index: 65535),
      batch(time: 0xffffffff),
      batch(remaining: 65535),
    ]) {
      expect(
        () => parseCbioPlaintextFrame(input),
        fails(CbioFrameFailure.overflow),
      );
    }
  });
}
