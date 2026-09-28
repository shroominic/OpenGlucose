/// Vendor V120 read queries and the glucose record layout they answer with.
///
/// The builders reproduce the frame templates recovered from the SiSensing GS1
/// app's `libdata-handle-lib.so`: `v120_glouse` (`06 0A LE16(index) LE16(0) C`)
/// and `v120_device_information` (`03 F0 selector C`). Both are read queries.
/// This library never builds an activation, clock, reset, threshold, key, or
/// authentication frame.
library;

import 'cbio_frames.dart';

/// Builds the vendor glucose read `06 0A LE16(index) 00 00 C`.
///
/// `index` is the first record the sensor should return. The frame is complete
/// and plaintext; the vendor can optionally RC4-mask it, which this builder
/// does not do because the key is not available.
List<int> buildCbioGlucoseQuery(int index) {
  if (index < 0 || index > 0xffff) {
    throw ArgumentError.value(index, 'index', 'must fit in 16 bits');
  }
  final head = <int>[0x06, 0x0a, index & 0xff, (index >> 8) & 0xff, 0x00, 0x00];
  return [...head, (-head.fold<int>(0, (sum, byte) => sum + byte)) & 0xff];
}

/// Builds the vendor information read `03 F0 selector C`.
///
/// See the selector table in `docs/testing/cbio-gs1-offline.md`: 3 is device
/// time and last index, 4 is storage state. Only information selectors are
/// exposed here; administrative selectors are not.
List<int> buildCbioInformationQuery(int selector) {
  if (selector < 1 || selector > 255) {
    throw ArgumentError.value(selector, 'selector', 'must be 1..255');
  }
  final head = <int>[0x03, 0xf0, selector];
  return [...head, (0x0d - selector) & 0xff];
}

/// One vendor glucose record with raw fields and no physical unit.
///
/// The 10-bit `rawGlucose` field has no verified scale or unit, so
/// [isUnitVerified] is always false and callers must show the raw value as an
/// unverified engineering value rather than as mg/dL or mmol/L.
final class CbioGlucoseRecord {
  const CbioGlucoseRecord({
    required this.index,
    required this.rawTime,
    required this.reindex,
    required this.rawGlucose,
    required this.trend,
    required this.rawGlucoseWarning,
    required this.rawSharedWarning,
  });

  /// Sensor record index, as reported by the batch header and layout.
  final int index;

  /// Raw timestamp field; no epoch or unit is established.
  final int rawTime;

  /// Raw reindex counter, decreasing with increasing index.
  final int reindex;

  /// Raw 10-bit field, `(p >> 6) | (q << 2)`.
  final int rawGlucose;

  /// Raw 3-bit trend field.
  final int trend;

  /// Raw 2-bit glucose warning field.
  final int rawGlucoseWarning;

  /// Raw shared warning bit.
  final int rawSharedWarning;

  /// Always false: no vendor source establishes the field's unit or scale.
  bool get isUnitVerified => false;
}

/// One decoded `0A` batch. Records are ordered oldest to newest.
final class CbioGlucoseBatch {
  CbioGlucoseBatch({
    required this.count,
    required this.initialIndex,
    required this.initialTime,
    required this.baseReindex,
    required List<CbioGlucoseRecord> records,
  }) : records = List.unmodifiable(records);

  final int count;
  final int initialIndex;
  final int initialTime;
  final int baseReindex;
  final List<CbioGlucoseRecord> records;

  int get lastIndex => initialIndex + count - 1;
}

/// Parses one complete plaintext `0A` glucose batch.
///
/// The `08` raw-data layout is a different eight-byte-per-record shape and is
/// rejected here. Length, count, checksum, and counter bounds are checked
/// strictly; nothing is inferred about success or physical units.
CbioGlucoseBatch parseCbioGlucoseBatch(List<int> bytes) {
  // The shared plaintext entry point owns every bounds and integrity check:
  // size, byte range, declared length, additive checksum, opcode, count, and
  // counter overflow. Only the 0A packed layout is accepted here.
  final frame = parseCbioPlaintextFrame(bytes);
  if (frame is! CbioPackedBatch) {
    throw const CbioFrameException(CbioFrameFailure.opcode);
  }
  final records = frame.records;
  return CbioGlucoseBatch(
    count: records.length,
    initialIndex: records.isEmpty ? 0 : records.first.index,
    initialTime: records.isEmpty ? 0 : records.first.rawTime,
    baseReindex: records.isEmpty ? 0 : records.last.reindex,
    records: [
      for (final record in records)
        CbioGlucoseRecord(
          index: record.index,
          rawTime: record.rawTime,
          reindex: record.reindex,
          rawGlucose: record.rawGlucose,
          trend: record.rawTrend,
          rawGlucoseWarning: record.rawGlucoseWarning,
          rawSharedWarning: record.rawSharedWarning,
        ),
    ],
  );
}
