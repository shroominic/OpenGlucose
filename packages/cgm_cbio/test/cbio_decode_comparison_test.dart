// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:test/test.dart';

/// One complete plaintext `08` frame captured from the GS1 sensor on
/// 2026-09-18. Sensor record bytes only: no address, key, or credential.
const String capturedRawFrameHex =
    '8b 08 10 01 00 8c 0b a3 6a '
    '3a 01 6a 0b 40 00 00 00 '
    '3a 01 6a 0b 40 00 00 00 '
    '39 01 6a 0b 3f 00 00 00 '
    '38 01 6a 0b 3f 00 00 00 '
    '3a 01 6b 0b 3f 00 00 00 '
    '3b 01 6c 0b 3e 00 00 00 '
    '3b 01 6b 0b 3e 00 00 00 '
    '3b 01 6a 0b 3d 00 00 00 '
    '44 01 6b 0b 3d 00 00 00 '
    '49 01 6b 0b 3c 00 00 00 '
    '48 01 6d 0b 3c 00 00 00 '
    '3f 01 6d 0b 3c 00 00 00 '
    '39 01 6b 0b 3b 00 00 00 '
    '32 01 6d 0b 39 00 00 00 '
    '29 01 6b 0b 36 00 00 00 '
    '24 01 6d 0b 33 00 00 00 '
    'ad 29 0e';

List<int> _captured() => [
  for (final byte in capturedRawFrameHex.split(' ')) int.parse(byte, radix: 16),
];

void main() {
  test('the captured frame decodes as one 16-record raw batch', () {
    final frame = _captured();
    expect(frame.length, 140);
    final batch = parseCbioRawDataFrame(frame);
    expect(batch.records.length, 16);
    expect(batch.records.first.processed.index, 1);
    expect(batch.records.last.processed.index, 16);
    expect(batch.records.first.processed.rawTime, 1789070220);
  });

  test('the payload word carries content and the packed field is empty', () {
    final batch = parseCbioRawDataFrame(_captured());
    expect(
      [for (final r in batch.records) r.rawPayload],
      [64, 64, 63, 63, 63, 62, 62, 61, 61, 60, 60, 60, 59, 57, 54, 51],
    );
    expect(
      [for (final r in batch.records) r.rawTemperature],
      [
        314,
        314,
        313,
        312,
        314,
        315,
        315,
        315,
        324,
        329,
        328,
        319,
        313,
        306,
        297,
        292,
      ],
    );
    expect([
      for (final r in batch.records) r.processed.rawGlucose,
    ], List<int>.filled(16, 0));
  });

  test('a zero packed field is arithmetic on zero bytes, not an offset', () {
    // Record 1 of the captured frame, byte for byte.
    final record = parseCbioRawDataFrame(_captured()).records.first;
    expect(
      _captured()
          .sublist(9, 17)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      '3a016a0b40000000',
    );
    expect(record.rawPayload, 0x0040);
    expect(record.processed.rawGlucose, (0x00 >> 6) | (0x00 << 2));
    expect(record.processed.rawGlucose, 0);
  });

  test('the two paths disagree only on which field they read', () {
    final frames = [_captured()];
    final comparison = compareCbioDecode(frames);

    expect(comparison.recordCount, 16);
    expect(comparison.payloadCount, 16);
    expect(comparison.processedCount, 16);
    expect(comparison.payloadMinimum, 51);
    expect(comparison.payloadMaximum, 64);
    expect(comparison.payloadNonZero, 16);
    expect(comparison.processedNonZero, 0);
    expect(comparison.agrees, isFalse);
    // The two spans of record 1, byte for byte: the payload word holds
    // `0x0040`, the processed word holds `0x0000`.
    expect(comparison.records.first.payloadSpan, '4000');
    expect(comparison.records.first.processedSpan, '0000');
  });

  test('the comparison is JSON and carries no identity or masked bytes', () {
    final json = compareCbioDecode([_captured()]).toJson();
    expect(json['schema'], 'cbio.decode-comparison/1');
    expect((json['records']! as List).length, 16);
    final encoded = jsonEncode(json);
    expect(RegExp(r'[0-9a-f]{32,}').hasMatch(encoded), isFalse);
  });

  test('the app path and the frame path agree record by record', () {
    final frames = [_captured()];
    final comparison = compareCbioDecode(frames);
    final archive = CbioHistoryArchive();
    frames.forEach(archive.ingest);

    final agreement = compareCbioWithArchive(comparison, archive.records);
    expect(agreement.compared, 16);
    expect(agreement.agreeing, 16);
    expect(agreement.missing, 0);
    expect(agreement.disagreeing, 0);
    expect(agreement.agrees, isTrue);
    expect(agreement.toJson()['agrees'], isTrue);
  });

  test('agreement fails closed when a record is missing or differs', () {
    final comparison = compareCbioDecode([_captured()]);
    final archive = CbioHistoryArchive();
    archive.ingest(_captured());

    final missing = compareCbioWithArchive(
      comparison,
      archive.records.take(15),
    );
    expect(missing.missing, 1);
    expect(missing.agrees, isFalse);

    final disagreeing = compareCbioWithArchive(comparison, [
      for (final record in archive.records)
        record.index == 1
            ? CbioRawGlucoseRecord(
                index: record.index,
                rawTime: record.rawTime,
                reindex: record.reindex,
                rawTemperature: record.rawTemperature,
                rawDump: record.rawDump,
                rawPayload: record.rawPayload + 1,
                rawProcessed: record.rawProcessed,
              )
            : record,
    ]);
    expect(disagreeing.disagreeing, 1);
    expect(disagreeing.agrees, isFalse);
  });
}
