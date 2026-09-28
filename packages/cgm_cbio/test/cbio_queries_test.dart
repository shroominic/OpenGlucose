import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

// Synthetic frames only. No live capture, key, or identifier is used.
List<int> checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

/// A synthetic `0A` batch: `count` records from [index], 60 raw seconds apart.
List<int> batch({
  int index = 7,
  int time = 1000,
  int count = 2,
  int firstReindex = 500,
  List<int> packed = const [0xd5, 0x12, 0x2e, 0x80],
}) {
  final trailer = firstReindex - count + 1;
  return checked([
    11 + 2 * count,
    0x0a,
    count,
    index & 255,
    (index >> 8) & 255,
    time & 255,
    (time >> 8) & 255,
    (time >> 16) & 255,
    (time >> 24) & 255,
    ...packed.take(2 * count),
    trailer & 255,
    (trailer >> 8) & 255,
  ]);
}

void main() {
  group('vendor query builders', () {
    test('glucose query is the documented seven-byte frame', () {
      expect(buildCbioGlucoseQuery(0), [
        0x06,
        0x0a,
        0x00,
        0x00,
        0x00,
        0x00,
        0xf0,
      ]);
      expect(buildCbioGlucoseQuery(1), [
        0x06,
        0x0a,
        0x01,
        0x00,
        0x00,
        0x00,
        0xef,
      ]);
      expect(buildCbioGlucoseQuery(0x1234), [
        0x06,
        0x0a,
        0x34,
        0x12,
        0x00,
        0x00,
        0xaa,
      ]);
    });

    test('every glucose query balances its checksum', () {
      for (final index in [0, 1, 2, 255, 256, 0xffff]) {
        final query = buildCbioGlucoseQuery(index);
        expect(query.length, 7);
        expect(query.fold<int>(0, (a, b) => a + b) & 255, 0);
        expect(query[4], 0);
        expect(query[5], 0);
      }
    });

    test('information query matches the documented C = 0x0D - x rule', () {
      expect(buildCbioInformationQuery(3), [0x03, 0xf0, 0x03, 0x0a]);
      expect(buildCbioInformationQuery(4), [0x03, 0xf0, 0x04, 0x09]);
      for (final selector in [1, 2, 3, 4, 10]) {
        final query = buildCbioInformationQuery(selector);
        expect(query[3], (0x0d - selector) & 0xff);
        expect(query.fold<int>(0, (a, b) => a + b) & 255, 0);
      }
    });

    test('out-of-range indices are rejected instead of truncated', () {
      expect(() => buildCbioGlucoseQuery(-1), throwsArgumentError);
      expect(() => buildCbioGlucoseQuery(0x10000), throwsArgumentError);
      expect(() => buildCbioInformationQuery(0), throwsArgumentError);
      expect(() => buildCbioInformationQuery(256), throwsArgumentError);
    });
  });

  group('glucose batch decoding', () {
    test('reads the documented 0A layout field by field', () {
      final decoded = parseCbioGlucoseBatch(batch());
      expect(decoded.count, 2);
      expect(decoded.initialIndex, 7);
      expect(decoded.initialTime, 1000);
      expect(decoded.lastIndex, 8);
      expect(decoded.baseReindex, 499);
      expect(decoded.records.first.index, 7);
      expect(decoded.records.first.rawTime, 1000);
      expect(decoded.records.last.rawTime, 1060);
      expect(decoded.records.first.reindex, 500);
      expect(decoded.records.last.reindex, 499);
      expect(decoded.records.first.rawGlucose, 75);
      expect(decoded.records.first.trend, 2);
      expect(decoded.records.first.rawGlucoseWarning, 2);
      expect(decoded.records.first.rawSharedWarning, 1);
      expect(decoded.records.last.rawGlucose, 512);
      expect(decoded.records.last.trend, 5);
    });

    test('never labels the raw field as mg/dL', () {
      final decoded = parseCbioGlucoseBatch(batch());
      for (final record in decoded.records) {
        expect(record.isUnitVerified, isFalse);
        expect(record.rawGlucose, inInclusiveRange(0, 1023));
      }
    });

    test('rejects a 08 raw-data frame and malformed frames', () {
      expect(
        () => parseCbioGlucoseBatch(checked([8, 0x08, 0, 1, 0, 0, 0, 0])),
        throwsA(isA<CbioFrameException>()),
      );
      final good = batch();
      expect(
        () => parseCbioGlucoseBatch(
          checked([good[0], good[1], 9, ...good.sublist(3, good.length - 1)]),
        ),
        throwsA(
          isA<CbioFrameException>().having(
            (e) => e.reason,
            'reason',
            CbioFrameFailure.count,
          ),
        ),
      );
      expect(
        () => parseCbioGlucoseBatch([...good.sublist(0, good.length - 1), 0]),
        throwsA(
          isA<CbioFrameException>().having(
            (e) => e.reason,
            'reason',
            CbioFrameFailure.checksum,
          ),
        ),
      );
    });
  });
}
