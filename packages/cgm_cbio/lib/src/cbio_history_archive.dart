/// Streaming history assembly for the authenticated GS1 raw (`08`) path.
///
/// The sensor answers one `06 08` request with many `08` batches pushed back to
/// back on the same characteristic, so a history fetch is an ingest loop, not a
/// request/response pair. This archive ingests those plaintext frames in
/// arrival order, keeps one record per index, and reports continuity instead of
/// guessing when a batch is missing or out of order.
library;

/// One raw (`08`) record with derived, explicitly unverified glucose values.
///
/// The vendor layout is `temp LE16, dump LE16, current LE16, extra LE16`. Two
/// independent implementations of this protocol divide `current` by 10 to get
/// mmol/L and `temp` by 10 to get Celsius, and the observed live values are
/// consistent with that reading. It is still a derived value: no reference
/// measurement has confirmed it, so [isUnitVerified] stays false and callers
/// must show [rawCurrent] alongside any converted number.
final class CbioRawGlucoseRecord {
  const CbioRawGlucoseRecord({
    required this.index,
    required this.rawTime,
    required this.reindex,
    required this.rawTemperature,
    required this.rawDump,
    required this.rawCurrent,
    required this.rawExtra,
  });

  final int index;

  /// Sensor-recorded epoch seconds, from the batch base plus 60 s per record.
  final int rawTime;

  final int reindex;

  /// Raw temperature field. Independent clients read this as tenths of Celsius.
  final int rawTemperature;

  /// Raw dump field; no meaning is established.
  final int rawDump;

  /// Raw value field. Independent clients read this as tenths of mmol/L.
  final int rawCurrent;

  /// Raw trailing field; no meaning is established.
  final int rawExtra;

  /// Derived mmol/L, `rawCurrent / 10`. Not independently validated.
  double get derivedMillimolesPerLitre => rawCurrent / 10;

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
    final batch = _parseRawBatch(frame);
    if (batch == null) {
      return CbioArchiveIngestStatus.notRawBatch;
    }
    final known = batch.records
        .where((r) => _byIndex.containsKey(r.index))
        .length;
    if (known == batch.records.length) {
      return CbioArchiveIngestStatus.duplicate;
    }
    if (known > 0) {
      _outOfOrder = true;
    }
    final newest = newestIndex;
    final startsAfterNewest =
        newest != null && batch.records.first.index > newest + 1;
    if (startsAfterNewest) {
      _gapDetected = true;
    }
    for (final record in batch.records) {
      _byIndex.putIfAbsent(record.index, () => record);
    }
    _batchCounts.add(batch.records.length);
    return startsAfterNewest
        ? CbioArchiveIngestStatus.gap
        : CbioArchiveIngestStatus.accepted;
  }

  /// One decoded raw batch, or null when the frame is not a plaintext `08`.
  static _RawBatch? _parseRawBatch(List<int> frame) {
    if (frame.length < 12) return null;
    if (frame[0] + 1 != frame.length) return null;
    if ((frame.fold<int>(0, (a, b) => a + b) & 255) != 0) return null;
    if (frame[1] != 0x08) return null;
    final count = frame[2];
    if (frame.length != 12 + 8 * count) return null;
    int le16(int offset) => frame[offset] | (frame[offset + 1] << 8);
    int le32(int offset) => le16(offset) | (le16(offset + 2) << 16);
    final startIndex = le16(3);
    final baseTime = le32(5);
    final baseReindex = le16(frame.length - 3);
    final records = <CbioRawGlucoseRecord>[
      for (var i = 0; i < count; i++)
        CbioRawGlucoseRecord(
          index: startIndex + i,
          rawTime: baseTime + 60 * i,
          reindex: baseReindex + count - 1 - i,
          rawTemperature: le16(9 + 8 * i),
          rawDump: le16(11 + 8 * i),
          rawCurrent: le16(13 + 8 * i),
          rawExtra: le16(15 + 8 * i),
        ),
    ];
    return _RawBatch(records);
  }
}

final class _RawBatch {
  const _RawBatch(this.records);

  final List<CbioRawGlucoseRecord> records;
}
