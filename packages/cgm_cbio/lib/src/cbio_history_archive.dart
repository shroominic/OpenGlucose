/// Streaming history assembly for the authenticated GS1 raw (`08`) path.
///
/// The sensor answers one `06 08` request with many `08` batches pushed back to
/// back on the same characteristic, so a history fetch is an ingest loop, not a
/// request/response pair. This archive ingests those plaintext frames in
/// arrival order, keeps one record per index, and reports continuity instead of
/// guessing when a batch is missing, out of order, or numbered by a counter
/// that restarted.
library;

import 'cbio_frames.dart';

/// One raw (`08`) record with an explicit, unverified engineering value.
///
/// The vendor layout is `temp LE16, dump LE16, payload LE16, processed LE16`.
/// Two independent implementations of this protocol divide the payload word by
/// 10, and the observed live values are consistent with that reading. Nothing
/// establishes that the divisor is ten *of a particular unit*, and no reference
/// measurement exists for this sensor, so the record exposes the raw field and
/// its scaled value and no unit at all: [isUnitVerified] stays false, no
/// accessor carries a unit in its name, and callers must show [rawPayload]
/// alongside anything scaled.
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

  /// Epoch-less sensor counter: the batch base plus 60 per record.
  ///
  /// This is the sensor's own position, not Unix time. It advances exactly one
  /// step per stored record, so a surface that renders it as `HH:mm` reports
  /// the ingest position and calls it a wall clock. No clock can be derived
  /// from it without the sensor's activation time.
  ///
  /// The app never renders it: the only timestamp a record can carry comes from
  /// an anchor, and an anchor exists only once the sensor's own counter agreed
  /// with the clock the app wrote into it. The live-edge gate compares the
  /// counter against the app's own clock as an observation and fails closed
  /// when the counter was never set.
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

  /// `rawPayload / 10`, the scale this package and the capture harness read.
  ///
  /// This is an unverified engineering value, not mmol/L, not mg/dL, and not any
  /// other unit. Rendering it with a unit suffix asserts a unit the protocol
  /// does not establish, which is what the tracking issue is about. A converted
  /// mg/dL accessor used to live here and was removed for that reason.
  double get rawPayloadScaled => rawPayload / 10;

  /// Always false until a reference measurement confirms the scale and unit.
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

  /// The frame re-used an index for a record from a different counter era.
  ///
  /// The sensor stamps each position once, when it produces that record, so a
  /// position that comes back carrying a different counter is not a
  /// retransmission: the sensor's counter restarted or was reset, and the old
  /// numbering is being re-used for a new stretch of time. The batch is refused
  /// rather than merged, because merging would staple two unrelated stretches
  /// onto one index space.
  counterRestart,
}

/// Ordered history assembled from a stream of `08` batches.
final class CbioHistoryArchive {
  final Map<int, CbioRawGlucoseRecord> _byIndex = <int, CbioRawGlucoseRecord>{};
  final List<int> _batchCounts = <int>[];
  var _gapDetected = false;
  var _outOfOrder = false;
  var _counterRestart = false;
  int? _counterRestartIndex;

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

  /// True when an index came back carrying a record from a different counter.
  ///
  /// The archive keeps the record it already held and refuses the conflicting
  /// batch, so this flag is the only signal that the sensor's numbering
  /// restarted. Consumers must read the positions as two timelines rather than
  /// one, and no position may be spliced onto the other's numbering.
  bool get sawCounterRestart => _counterRestart;

  /// Lowest index of the refused batch that came back on a different counter.
  int? get counterRestartIndex => _counterRestartIndex;

  /// True when the archive covers every index between its ends, on one counter.
  ///
  /// A detected counter restart also clears this: the index space no longer
  /// describes a single unbroken stretch of the sensor's own timeline.
  bool get contiguous => !_gapDetected && !_counterRestart;

  /// Lowest sensor counter in the archive, or null when it is empty.
  ///
  /// Named for what it is. A time-shaped name invites a caller to build a
  /// `DateTime` from it, which is the defect this rename closes.
  int? get oldestSensorCounter =>
      _byIndex.isEmpty ? null : records.first.rawTime;

  /// Highest sensor counter in the archive, or null when it is empty.
  int? get newestSensorCounter =>
      _byIndex.isEmpty ? null : records.last.rawTime;

  /// Ingests one notification payload, masked or already unmasked by the caller.
  CbioArchiveIngestStatus ingest(List<int> frame) {
    final CbioRawBatch batch;
    try {
      batch = parseCbioRawDataFrame(frame);
    } on CbioFrameException {
      return CbioArchiveIngestStatus.notRawBatch;
    }
    // A position the archive already holds is only a retransmission when it
    // carries the counter it carried before. The sensor stamps a record once,
    // and the three captured sessions agree on the stamp for every shared index
    // (index 1 is the same counter in all of them), so a differing counter is
    // the restart, not a re-delivery. Refuse it instead of merging it.
    final conflicting = batch.records.where((r) {
      final stored = _byIndex[r.processed.index];
      return stored != null && stored.rawTime != r.processed.rawTime;
    }).length;
    if (conflicting > 0) {
      _counterRestart = true;
      _counterRestartIndex = batch.records
          .map((r) => r.processed.index)
          .reduce((a, b) => a < b ? a : b);
      return CbioArchiveIngestStatus.counterRestart;
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
