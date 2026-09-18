/// Streaming history assembly for the authenticated GS1 raw (`08`) path.
///
/// The sensor answers one `06 08` request with many `08` batches pushed back to
/// back on the same characteristic, so a history fetch is an ingest loop, not a
/// request/response pair. This archive ingests those plaintext frames in
/// arrival order, keeps one record per index, and reports continuity instead of
/// guessing when a batch is missing or out of order.
library;

import 'cbio_frames.dart';

/// One raw (`08`) record with derived, explicitly unverified glucose values.
///
/// The vendor layout is `temp LE16, dump LE16, payload LE16, processed LE16`.
/// Two independent implementations of this protocol divide the payload word by
/// 10 to get mmol/L and `temp` by 10 to get Celsius, and the observed live
/// values are consistent with that reading. It is still a derived value: no
/// reference measurement has confirmed it, so [isUnitVerified] stays false and
/// callers must show [rawPayload] alongside any converted number.
///
/// The processed word shares the `0A` packed layout and is empty on the
/// observed firmware. It is exposed as [rawProcessed] so a caller can see that
/// for itself; it is not the reading.
final class CbioRawGlucoseRecord {
  const CbioRawGlucoseRecord({
    required this.index,
    required this.rawTime,
    required this.reindex,
    required this.rawTemperature,
    required this.rawDump,
    required this.rawPayload,
    required this.rawProcessed,
  });

  final int index;

  /// Sensor-recorded epoch seconds, from the batch base plus 60 s per record.
  final int rawTime;

  final int reindex;

  /// Raw temperature field. Independent clients read this as tenths of Celsius.
  final int rawTemperature;

  /// Raw dump field; no meaning is established.
  final int rawDump;

  /// The reading-bearing payload word; independent clients read this as tenths
  /// of mmol/L.
  final int rawPayload;

  /// The firmware's processed word, in the `0A` packed layout. Zero in every
  /// captured GS1 record on the observed firmware.
  final int rawProcessed;

  /// Derived mmol/L, `rawPayload / 10`. Not independently validated.
  double get derivedMillimolesPerLitre => rawPayload / 10;

  /// Derived mg/dL from the derived mmol/L. Not independently validated.
  int get derivedMilligramsPerDecilitre =>
      (derivedMillimolesPerLitre * 18.0182).round();

  /// Always false until a reference measurement confirms the scale.
  bool get isUnitVerified => false;
}

/// Outcome of ingesting one frame.
enum CbioArchiveIngestStatus {
  /// New records were added.
  accepted,

  /// Every index in the frame was already known.
  duplicate,

  /// The frame is not a plaintext `08` batch.
  notRawBatch,

  /// The frame starts after a missing index range.
  gap,
}

/// Ordered history assembled from a stream of `08` batches.
final class CbioHistoryArchive {
  final Map<int, CbioRawGlucoseRecord> _byIndex = <int, CbioRawGlucoseRecord>{};
  final List<int> _batchCounts = <int>[];
  var _gapDetected = false;
  var _outOfOrder = false;

  /// Records sorted by index, oldest first.
  List<CbioRawGlucoseRecord> get records {
    final indexes = _byIndex.keys.toList()..sort();
    return [for (final index in indexes) _byIndex[index]!];
  }

  /// Number of records ingested.
  int get length => _byIndex.length;

  /// Record counts of every accepted batch, in arrival order.
  List<int> get batchCounts => List.unmodifiable(_batchCounts);

  int? get oldestIndex => _byIndex.isEmpty ? null : records.first.index;
  int? get newestIndex => _byIndex.isEmpty ? null : records.last.index;

  /// True when a batch began after an index the archive never received.
  bool get hasGap => _gapDetected;

  /// True when a batch started at or below an index already received.
  bool get sawOverlap => _outOfOrder;

  /// True when the archive covers every index between its ends.
  bool get contiguous => !_gapDetected;

  int? get oldestTime => _byIndex.isEmpty ? null : records.first.rawTime;
  int? get newestTime => _byIndex.isEmpty ? null : records.last.rawTime;

  /// Ingests one notification payload, masked or already unmasked by the caller.
  CbioArchiveIngestStatus ingest(List<int> frame) {
    final CbioRawBatch batch;
    try {
      batch = parseCbioRawDataFrame(frame);
    } on CbioFrameException {
      return CbioArchiveIngestStatus.notRawBatch;
    }
    final known = batch.records
        .where((r) => _byIndex.containsKey(r.processed.index))
        .length;
    if (known == batch.records.length) {
      return CbioArchiveIngestStatus.duplicate;
    }
    if (known > 0) {
      _outOfOrder = true;
    }
    final records = <CbioRawGlucoseRecord>[
      for (final record in batch.records)
        CbioRawGlucoseRecord(
          index: record.processed.index,
          rawTime: record.processed.rawTime,
          reindex: record.processed.reindex,
          rawTemperature: record.rawTemperature,
          rawDump: record.rawDump,
          rawPayload: record.rawPayload,
          rawProcessed: record.processed.rawWord,
        ),
    ];
    final newest = newestIndex;
    final startsAfterNewest =
        newest != null && records.first.index > newest + 1;
    if (startsAfterNewest) {
      _gapDetected = true;
    }
    for (final record in records) {
      _byIndex.putIfAbsent(record.index, () => record);
    }
    _batchCounts.add(records.length);
    return startsAfterNewest
        ? CbioArchiveIngestStatus.gap
        : CbioArchiveIngestStatus.accepted;
  }
}
