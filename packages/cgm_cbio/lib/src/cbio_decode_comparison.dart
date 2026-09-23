// SPDX-License-Identifier: GPL-3.0-only
/// Side-by-side decode of one window of GS1 `08` frames.
///
/// Two field-identity candidates exist for the eight-byte raw record: the
/// payload word the app's live path renders (`offset 4`, LE16) and the
/// firmware's processed word (`offset 6`, the `0A` packed layout). This module
/// decodes the *same* wire bytes through both and reports, per record, what each
/// path reads, so the difference between "this field is empty" and "this decoder
/// reads the wrong offset" is visible in the bytes instead of in an aggregate.
///
/// It is pure: no transport, no clock, no unit claim. The payload word has no
/// reference measurement behind it, so every derived value stays unverified.
library;

import 'cbio_frames.dart';
import 'cbio_history_archive.dart';

/// Schema identifier for [CbioDecodeComparison.toJson].
const String cbioDecodeComparisonSchema = 'cbio.decode-comparison/1';

/// Agreement between this comparison's payload series and another decode of the
/// same window.
///
/// The two decodes are not required to be independent implementations to be
/// useful: what this proves is that the app's live archive and the frame parser
/// report the *same numbers for the same indices*, which is what gate G1 asks
/// for. A field-identity mistake shows up here as `disagreeing` or `missing`,
/// not as an aggregate difference.
final class CbioPathAgreement {
  const CbioPathAgreement({
    required this.compared,
    required this.agreeing,
    required this.missing,
    required this.disagreeing,
  });

  /// Records present in both decodes.
  final int compared;

  /// Records whose payload word matches.
  final int agreeing;

  /// Records this comparison decoded that the other side never saw.
  final int missing;

  /// Records both sides saw with different payload words.
  final int disagreeing;

  /// True only when every compared record matches and none is missing.
  bool get agrees => compared > 0 && agreeing == compared && missing == 0;

  /// The machine-readable form.
  Map<String, Object?> toJson() => <String, Object?>{
    'compared': compared,
    'agreeing': agreeing,
    'missing': missing,
    'disagreeing': disagreeing,
    'agrees': agrees,
  };
}

/// Compares this window's payload series with a history archive's.
///
/// [archiveRecords] comes from `CbioHistoryArchive`, which is the decoder behind
/// the app's live readings.
CbioPathAgreement compareCbioWithArchive(
  CbioDecodeComparison comparison,
  Iterable<CbioRawGlucoseRecord> archiveRecords,
) {
  final byIndex = <int, int>{
    for (final record in archiveRecords) record.index: record.rawPayload,
  };
  var compared = 0;
  var agreeing = 0;
  var missing = 0;
  var disagreeing = 0;
  for (final record in comparison.records) {
    final other = byIndex[record.index];
    if (other == null) {
      missing += 1;
      continue;
    }
    compared += 1;
    if (other == record.payloadRaw) {
      agreeing += 1;
    } else {
      disagreeing += 1;
    }
  }
  return CbioPathAgreement(
    compared: compared,
    agreeing: agreeing,
    missing: missing,
    disagreeing: disagreeing,
  );
}

/// Wire span of the payload word inside one `08` record.
const int cbioPayloadOffset = 4;

/// Wire span of the processed (packed) word inside one `08` record.
const int cbioProcessedOffset = 6;

/// One record decoded through both candidate fields.
final class CbioDecodeComparisonRecord {
  const CbioDecodeComparisonRecord({
    required this.index,
    required this.rawTime,
    required this.temperatureRaw,
    required this.dumpRaw,
    required this.payloadSpan,
    required this.processedSpan,
    required this.payloadRaw,
    required this.processedRaw,
  });

  /// Sensor record index from the batch header.
  final int index;

  /// Raw sensor time field; no epoch is established here.
  final int rawTime;

  /// The temperature word, as the control that the record stride is right.
  final int temperatureRaw;

  /// The word this library has no meaning for.
  final int dumpRaw;

  /// The two payload bytes in frame order, hex. This is the span the app's
  /// live path reads.
  final String payloadSpan;

  /// The two processed bytes in frame order, hex. This is the span the `0A`
  /// packed layout is read from.
  final String processedSpan;

  /// The payload word as a little-endian unsigned 16-bit integer.
  final int payloadRaw;

  /// The processed word as a little-endian unsigned 16-bit integer.
  final int processedRaw;

  /// The packed ten-bit field inside [processedRaw], exactly as the `0A`
  /// layout defines it.
  int get processedPacked => (processedRaw >> 6) & 0x3ff;

  /// Payload in tenths of a millimole per litre. Unverified; not a claim.
  double get payloadTenthsMillimolesPerLitre => payloadRaw / 10;
}

/// One window of `08` frames decoded through both candidate fields.
final class CbioDecodeComparison {
  CbioDecodeComparison({
    required List<CbioDecodeComparisonRecord> records,
    required this.batchCount,
    required this.decodeFailures,
  }) : records = List.unmodifiable(records);

  /// Records in index order, deduplicated by index.
  final List<CbioDecodeComparisonRecord> records;

  /// Complete plaintext `08` batches the window contained.
  final int batchCount;

  /// Frames the window offered that are not a decodable `08` batch.
  final int decodeFailures;

  int get recordCount => records.length;

  int get payloadCount => records.length;

  int get processedCount => records.length;

  int? get firstIndex => records.isEmpty ? null : records.first.index;

  int? get lastIndex => records.isEmpty ? null : records.last.index;

  int? get payloadMinimum => _extreme((r) => r.payloadRaw, (a, b) => a < b);

  int? get payloadMaximum => _extreme((r) => r.payloadRaw, (a, b) => a > b);

  int? get processedMinimum => _extreme((r) => r.processedRaw, (a, b) => a < b);

  int? get processedMaximum => _extreme((r) => r.processedRaw, (a, b) => a > b);

  /// Records whose payload word is not zero.
  int get payloadNonZero => records.where((r) => r.payloadRaw != 0).length;

  /// Records whose processed word is not zero.
  int get processedNonZero => records.where((r) => r.processedRaw != 0).length;

  /// True when the two candidate fields carry the same series.
  ///
  /// This is field identity, not correctness: two empty fields would also agree.
  bool get agrees =>
      records.isNotEmpty &&
      records.every((r) => r.payloadRaw == r.processedRaw);

  int? _extreme(
    int Function(CbioDecodeComparisonRecord) value,
    bool Function(int, int) better,
  ) {
    if (records.isEmpty) return null;
    var best = value(records.first);
    for (final record in records.skip(1)) {
      final candidate = value(record);
      if (better(candidate, best)) best = candidate;
    }
    return best;
  }

  /// The machine-readable comparison, free of identity and credential bytes.
  Map<String, Object?> toJson() => <String, Object?>{
    'schema': cbioDecodeComparisonSchema,
    'unitStatus': 'unverified',
    'paths': <String, Object?>{
      'appLive': <String, Object?>{
        'frame': '08',
        'recordOffset': cbioPayloadOffset,
        'width': 2,
        'endianness': 'little',
        'field': 'payload',
        'reportedScale': 'raw / 10, scale unverified',
      },
      'harnessEvidenceBeforeFix': <String, Object?>{
        'frame': '08',
        'recordOffset': cbioProcessedOffset,
        'width': 2,
        'endianness': 'little',
        'field': 'processed',
        'packedLayout': '0a',
        'reportedScale': 'packed raw, scale unverified',
      },
    },
    'batches': batchCount,
    'decodeFailures': decodeFailures,
    'index': <String, Object?>{'first': firstIndex, 'last': lastIndex},
    'payload': <String, Object?>{
      'count': payloadCount,
      'minimum': payloadMinimum,
      'maximum': payloadMaximum,
      'nonZero': payloadNonZero,
    },
    'processed': <String, Object?>{
      'count': processedCount,
      'minimum': processedMinimum,
      'maximum': processedMaximum,
      'nonZero': processedNonZero,
    },
    'fieldsAgree': agrees,
    'records': <Map<String, Object?>>[
      for (final record in records)
        <String, Object?>{
          'index': record.index,
          'rawTime': record.rawTime,
          'temperatureRaw': record.temperatureRaw,
          'dumpRaw': record.dumpRaw,
          'payloadSpan': record.payloadSpan,
          'processedSpan': record.processedSpan,
          'payloadRaw': record.payloadRaw,
          'processedRaw': record.processedRaw,
          'processedPacked': record.processedPacked,
        },
    ],
  };
}

/// Decodes a window of complete plaintext frames through both `08` fields.
///
/// Frames that are not `08` batches are counted in
/// [CbioDecodeComparison.decodeFailures] and contribute no records. Records are
/// kept once per index; [maxRecords] bounds the artifact without changing the
/// counts, which are always taken over every decoded record.
CbioDecodeComparison compareCbioDecode(
  Iterable<List<int>> frames, {
  int maxRecords = 4096,
}) {
  final byIndex = <int, CbioDecodeComparisonRecord>{};
  var batches = 0;
  var failures = 0;
  for (final frame in frames) {
    final CbioRawBatch batch;
    try {
      batch = parseCbioRawDataFrame(frame);
    } on CbioFrameException {
      failures += 1;
      continue;
    }
    batches += 1;
    for (var i = 0; i < batch.records.length; i++) {
      final record = batch.records[i];
      final offset = 9 + 8 * i;
      byIndex.putIfAbsent(
        record.processed.index,
        () => CbioDecodeComparisonRecord(
          index: record.processed.index,
          rawTime: record.processed.rawTime,
          temperatureRaw: record.rawTemperature,
          dumpRaw: record.rawDump,
          payloadSpan: _hex(
            frame.sublist(
              offset + cbioPayloadOffset,
              offset + cbioPayloadOffset + 2,
            ),
          ),
          processedSpan: _hex(
            frame.sublist(
              offset + cbioProcessedOffset,
              offset + cbioProcessedOffset + 2,
            ),
          ),
          payloadRaw: record.rawPayload,
          processedRaw: _le16(frame, offset + cbioProcessedOffset),
        ),
      );
    }
  }
  final indexes = byIndex.keys.toList()..sort();
  return CbioDecodeComparison(
    batchCount: batches,
    decodeFailures: failures,
    records: [for (final index in indexes.take(maxRecords)) byIndex[index]!],
  );
}

int _le16(List<int> bytes, int offset) =>
    (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);

String _hex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
