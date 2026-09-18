import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

List<int> _checked(List<int> prefix) => [
  ...prefix,
  (-prefix.fold<int>(0, (sum, byte) => sum + byte)) & 255,
];

/// One synthetic plaintext `08` batch holding indexes [first..last].
///
/// Layout mirrors the captured vendor frames: `len, 0x08, count, index LE16,
/// baseTime LE32`, then `temp LE16, dump LE16, current LE16, extra LE16` per
/// record, then a `reindex` LE16 trailer and a checksum byte.
List<int> _rawBatch({
  required int first,
  required int count,
  required int baseTime,
  int reindexBase = 5000,
  int current = 80,
  int temperature = 320,
}) {
  return _checked([
    11 + 8 * count,
    0x08,
    count,
    first & 255,
    (first >> 8) & 255,
    baseTime & 255,
    (baseTime >> 8) & 255,
    (baseTime >> 16) & 255,
    (baseTime >> 24) & 255,
    for (var i = 0; i < count; i++) ...[
      temperature & 255,
      (temperature >> 8) & 255,
      0,
      0,
      current & 255,
      (current >> 8) & 255,
      0,
      0,
    ],
    (reindexBase - count + 1) & 255,
    ((reindexBase - count + 1) >> 8) & 255,
  ]);
}

void main() {
  test('accepts one batch and derives values with the unit unverified', () {
    final archive = CbioHistoryArchive();
    final status = archive.ingest(
      _rawBatch(first: 1, count: 4, baseTime: 1757534220, current: 78),
    );

    expect(status, CbioArchiveIngestStatus.accepted);
    expect(archive.length, 4);
    expect(archive.batchCounts, [4]);
    expect(archive.oldestIndex, 1);
    expect(archive.newestIndex, 4);
    expect(archive.contiguous, isTrue);
    expect(archive.hasGap, isFalse);
    expect(archive.sawOverlap, isFalse);

    final first = archive.records.first;
    expect(first.index, 1);
    expect(first.rawTime, 1757534220);
    expect(first.reindex, 5000);
    expect(first.rawPayload, 78);
    expect(first.rawProcessed, 0);
    expect(first.rawTemperature, 320);
    expect(first.rawPayloadScaled, 7.8);
    expect(first.isUnitVerified, isFalse);
    expect(archive.records.last.rawTime, 1757534220 + 180);
    expect(archive.records.last.reindex, 4997);
  });

  test('the record carries no glucose unit in any accessor', () {
    final archive = CbioHistoryArchive();
    archive.ingest(_rawBatch(first: 1, count: 1, baseTime: 1000));
    final record = archive.records.first;

    // The scaled value is the raw field over ten and nothing more. A unit-bearing
    // accessor would let a surface render a unit the protocol never established,
    // which is exactly what the raw-scale issue reports.
    expect(record.rawPayloadScaled, record.rawPayload / 10);
    expect(record.isUnitVerified, isFalse);
    expect(
      () => (record as dynamic).derivedMilligramsPerDecilitre,
      throwsNoSuchMethodError,
      reason: 'a derived mg/dL accessor must not come back',
    );
    expect(
      () => (record as dynamic).derivedMillimolesPerLitre,
      throwsNoSuchMethodError,
      reason: 'a derived mmol/L accessor must not come back',
    );
  });

  test('walks consecutive batches without reporting a gap', () {
    final archive = CbioHistoryArchive();
    expect(
      archive.ingest(_rawBatch(first: 1, count: 3, baseTime: 1000)),
      CbioArchiveIngestStatus.accepted,
    );
    expect(
      archive.ingest(_rawBatch(first: 4, count: 3, baseTime: 1180)),
      CbioArchiveIngestStatus.accepted,
    );

    expect(archive.length, 6);
    expect([archive.oldestIndex, archive.newestIndex], [1, 6]);
    expect(archive.contiguous, isTrue);
    expect(archive.oldestTime, 1000);
    expect(archive.newestTime, 1180 + 120);
  });

  test('flags a gap when a batch starts past the newest index', () {
    final archive = CbioHistoryArchive();
    archive.ingest(_rawBatch(first: 1, count: 2, baseTime: 1000));
    final status = archive.ingest(
      _rawBatch(first: 10, count: 2, baseTime: 1540),
    );

    expect(status, CbioArchiveIngestStatus.gap);
    expect(archive.hasGap, isTrue);
    expect(archive.contiguous, isFalse);
    expect(archive.length, 4);
    expect([archive.oldestIndex, archive.newestIndex], [1, 11]);
  });

  test('reports a duplicate batch without changing the archive', () {
    final archive = CbioHistoryArchive();
    final batch = _rawBatch(first: 1, count: 3, baseTime: 1000);
    archive.ingest(batch);
    final status = archive.ingest(batch);

    expect(status, CbioArchiveIngestStatus.duplicate);
    expect(archive.length, 3);
    expect(archive.batchCounts, [3]);
    expect(archive.sawOverlap, isFalse);
  });

  test('keeps the first value on overlap and records the overlap', () {
    final archive = CbioHistoryArchive();
    archive.ingest(_rawBatch(first: 1, count: 3, baseTime: 1000, current: 60));
    final status = archive.ingest(
      _rawBatch(first: 3, count: 3, baseTime: 1120, current: 95),
    );

    expect(status, CbioArchiveIngestStatus.accepted);
    expect(archive.sawOverlap, isTrue);
    expect(archive.length, 5);
    expect(archive.records[2].rawPayload, 60);
    expect(archive.records[4].rawPayload, 95);
  });

  test('ignores frames that are not plaintext 08 batches', () {
    final archive = CbioHistoryArchive();
    expect(
      archive.ingest([4, 0x0a, 0, 0, 0]),
      CbioArchiveIngestStatus.notRawBatch,
    );
    expect(
      archive.ingest([5, 0x01, 1, 0, 0xfa]),
      CbioArchiveIngestStatus.notRawBatch,
    );
    expect(archive.length, 0);
    expect(archive.oldestIndex, isNull);
    expect(archive.newestIndex, isNull);
    expect(archive.oldestTime, isNull);
    expect(archive.batchCounts, isEmpty);
  });

  test('rejects a raw batch whose checksum or length is wrong', () {
    final archive = CbioHistoryArchive();
    final good = _rawBatch(first: 1, count: 2, baseTime: 1000);
    final badChecksum = [...good]..last = good.last ^ 0xff;
    final badLength = [...good]..[0] = good[0] - 1;

    expect(archive.ingest(badChecksum), CbioArchiveIngestStatus.notRawBatch);
    expect(archive.ingest(badLength), CbioArchiveIngestStatus.notRawBatch);
    expect(archive.length, 0);
  });

  test('agrees with parseCbioRawDataFrame on the same frames', () {
    final frame = _rawBatch(
      first: 1521,
      count: 3,
      baseTime: 1789207021,
      current: 63,
      temperature: 305,
    );
    final archive = CbioHistoryArchive();
    archive.ingest(frame);
    final parsed = parseCbioRawDataFrame(frame);

    expect(parsed.records.length, archive.length);
    for (var i = 0; i < parsed.records.length; i++) {
      final fromFrame = parsed.records[i];
      final fromArchive = archive.records[i];
      expect(fromArchive.rawTemperature, fromFrame.rawTemperature);
      expect(fromArchive.rawDump, fromFrame.rawDump);
      expect(fromArchive.rawPayload, fromFrame.rawPayload);
      expect(fromArchive.rawProcessed, fromFrame.processed.rawWord);
      expect(fromArchive.index, fromFrame.processed.index);
      expect(fromArchive.rawTime, fromFrame.processed.rawTime);
      expect(fromArchive.reindex, fromFrame.processed.reindex);
    }
  });

  test('the archive reads the payload word, not the processed word', () {
    // A record whose processed word is zero while the payload carries a value:
    // the shape every captured GS1 record has on this firmware.
    final archive = CbioHistoryArchive();
    final frame = _rawBatch(first: 1, count: 1, baseTime: 1000, current: 64);
    expect(archive.ingest(frame), CbioArchiveIngestStatus.accepted);

    final record = archive.records.single;
    expect(record.rawPayload, 64);
    expect(record.rawProcessed, 0);
    // The payload word is the reading; the scale stays unit-free here.
    expect(record.rawPayloadScaled, 6.4);
    expect(record.isUnitVerified, isFalse);
  });

  test('the archive and the frame parser decode the same words', () {
    for (final current in [0, 1, 64, 0xffff]) {
      final frame = _rawBatch(
        first: 1,
        count: 2,
        baseTime: 1000,
        current: current,
      );
      final archive = CbioHistoryArchive();
      expect(archive.ingest(frame), CbioArchiveIngestStatus.accepted);
      final parsed = parseCbioRawDataFrame(frame);
      for (var i = 0; i < parsed.records.length; i++) {
        expect(archive.records[i].rawPayload, parsed.records[i].rawPayload);
        expect(
          archive.records[i].rawProcessed,
          parsed.records[i].processed.rawWord,
        );
      }
    }
  });

  test('assembles a long history that stays contiguous and ordered', () {
    final archive = CbioHistoryArchive();
    var index = 1;
    var time = 1757534220;
    for (var batch = 0; batch < 95; batch++) {
      const count = 16;
      expect(
        archive.ingest(_rawBatch(first: index, count: count, baseTime: time)),
        CbioArchiveIngestStatus.accepted,
      );
      index += count;
      time += 60 * count;
    }

    expect(archive.length, 1520);
    expect(archive.batchCounts.length, 95);
    expect([archive.oldestIndex, archive.newestIndex], [1, 1520]);
    expect(archive.contiguous, isTrue);
    expect(archive.sawOverlap, isFalse);
    final indexes = archive.records.map((r) => r.index).toList();
    expect(indexes, List<int>.generate(1520, (i) => i + 1));
  });
}
