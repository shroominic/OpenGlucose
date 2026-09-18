/// Absolute-time anchoring for the GS1 record index.
///
/// The `08` record's own second counter advances 60 s per stored record, but
/// the counter on its own carries no epoch: reading it as a wall clock is the
/// +7 h 28 m skew of #146, so no surface may derive a timestamp from it alone.
/// This file adds the one reference that does exist. The app writes the sensor
/// clock once per session (`06 03 LE32(epoch)`), and afterwards the sensor
/// stamps the records it produces against that clock. When the newest stored
/// record's own stamp agrees with the app's clock to within
/// [cbioAnchorTolerance], the index is anchored to absolute time:
///
///   * [CbioIndexTimeAnchor.anchorIndex] - the newest position the sensor
///     stamped, and [CbioIndexTimeAnchor.anchorEpochSeconds], that position's
///     own stamp in UTC seconds;
///   * [cbioRecordStepSeconds] per index, which is how the vendor layout
///     reports the counter (`base + 60 * i`).
///
/// Everything the counter cannot support stays unsupported. The anchor is
/// absent - and every surface says the sensor clock is unsynced instead of
/// showing a placeholder - when the app never wrote the clock, when no record
/// exists, when the sensor's stamp disagrees with the app's clock, and for
/// every position older than the point where the 60 s step is unbroken.
library;

import 'cbio_history_archive.dart';

/// Seconds between two consecutive stored GS1 records in the vendor layout.
const int cbioRecordStepSeconds = 60;

/// How far the sensor's own stamp may sit from the app's clock before the
/// anchor is refused. The clock write happens once per session and the sensor
/// stamps whole minutes, so a couple of minutes of agreement is expected on a
/// link that accepted the write; anything larger is an unset or unread clock.
const Duration cbioAnchorTolerance = Duration(minutes: 3);

/// Snapshot metadata key: newest anchored position.
const String cbioAnchorIndexMetadataKey = 'cgm.cbio.clock.anchorIndex';

/// Snapshot metadata key: UTC seconds of the anchored position.
const String cbioAnchorEpochMetadataKey = 'cgm.cbio.clock.anchorEpochSeconds';

/// Snapshot metadata key: oldest position the anchor may describe.
const String cbioAnchorCoveredFromMetadataKey =
    'cgm.cbio.clock.anchorCoveredFrom';

/// Snapshot metadata key: when the pairing was last confirmed.
const String cbioAnchorObservedAtMetadataKey =
    'cgm.cbio.clock.anchorObservedAt';

/// Snapshot metadata key: how the pairing was obtained.
const String cbioAnchorSourceMetadataKey = 'cgm.cbio.clock.anchorSource';

/// Snapshot metadata key: the epoch this session wrote into the sensor clock.
const String cbioClockReferenceEpochMetadataKey =
    'cgm.cbio.clock.referenceEpochSeconds';

/// Closed set of anchor provenances. Every value names a reference the app
/// established itself, never a value read out of the record counter.
abstract final class CbioAnchorSource {
  /// The session wrote the sensor clock and the sensor's newest record stamp
  /// agrees with the app's clock. The timestamp comes from the clock this app
  /// set on the sensor, so it inherits that clock's drift.
  static const String appSetSensorClock = 'app-set-sensor-clock';
}

/// One index-to-absolute-time reference for a GS1 session.
///
/// Producers derive it with [deriveCbioIndexTimeAnchor]; consumers read it out
/// of snapshot metadata with [fromMetadata].
final class CbioIndexTimeAnchor {
  const CbioIndexTimeAnchor({
    required this.anchorIndex,
    required this.coveredFromIndex,
    required this.anchorEpochSeconds,
    required this.observedAt,
    this.clockReferenceEpochSeconds,
    this.source = CbioAnchorSource.appSetSensorClock,
    this.uncertainty = const Duration(seconds: cbioRecordStepSeconds),
  });

  /// Newest stored position the sensor stamped when the anchor was taken.
  final int anchorIndex;

  /// Oldest position the anchor may describe: the end of the contiguous
  /// 60 s-per-index run that reaches [anchorIndex].
  final int coveredFromIndex;

  /// The anchored position's own stamp, UTC seconds.
  final int anchorEpochSeconds;

  /// When the app observed the pairing, on the app's own clock.
  final DateTime observedAt;

  /// The epoch the app wrote into the sensor clock this session, when it did.
  final int? clockReferenceEpochSeconds;

  /// How the pairing was obtained; see [CbioAnchorSource].
  final String source;

  /// How far a rendered position may sit from its true instant. The sensor
  /// stamps whole records and the app samples the link between them.
  final Duration uncertainty;

  /// Whether the anchor may speak for [index]. Positions newer than
  /// [anchorIndex] are covered: the sensor keeps producing one record per
  /// minute on the same clock.
  bool coversIndex(int index) => index >= coveredFromIndex;

  /// The absolute instant of [index], in UTC. Callers localise for display.
  DateTime timeForIndex(int index) => DateTime.fromMillisecondsSinceEpoch(
    anchorEpochSeconds * 1000,
    isUtc: true,
  ).add(Duration(seconds: (index - anchorIndex) * cbioRecordStepSeconds));

  /// The measured agreement between the sensor's stamp and the app's clock.
  Duration get clockAgreement => Duration(
    seconds: anchorEpochSeconds - (observedAt.millisecondsSinceEpoch ~/ 1000),
  );

  Map<String, String> toMetadata() => <String, String>{
    cbioAnchorIndexMetadataKey: '$anchorIndex',
    cbioAnchorCoveredFromMetadataKey: '$coveredFromIndex',
    cbioAnchorEpochMetadataKey: '$anchorEpochSeconds',
    cbioAnchorObservedAtMetadataKey: observedAt.toUtc().toIso8601String(),
    cbioAnchorSourceMetadataKey: source,
    if (clockReferenceEpochSeconds != null)
      cbioClockReferenceEpochMetadataKey: '$clockReferenceEpochSeconds',
  };

  /// Reads an anchor back out of snapshot metadata, or null when the snapshot
  /// carries none. An unparsable pair is treated as absent.
  static CbioIndexTimeAnchor? fromMetadata(Map<String, String> metadata) {
    final index = int.tryParse(metadata[cbioAnchorIndexMetadataKey] ?? '');
    final epoch = int.tryParse(metadata[cbioAnchorEpochMetadataKey] ?? '');
    if (index == null || epoch == null) {
      return null;
    }
    final coveredFrom =
        int.tryParse(metadata[cbioAnchorCoveredFromMetadataKey] ?? '') ?? index;
    final observedAt =
        DateTime.tryParse(
          metadata[cbioAnchorObservedAtMetadataKey] ?? '',
        )?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    return CbioIndexTimeAnchor(
      anchorIndex: index,
      coveredFromIndex: coveredFrom <= index ? coveredFrom : index,
      anchorEpochSeconds: epoch,
      observedAt: observedAt,
      clockReferenceEpochSeconds: int.tryParse(
        metadata[cbioClockReferenceEpochMetadataKey] ?? '',
      ),
      source:
          metadata[cbioAnchorSourceMetadataKey] ??
          CbioAnchorSource.appSetSensorClock,
    );
  }

  @override
  String toString() =>
      'CbioIndexTimeAnchor(index: $anchorIndex, from: $coveredFromIndex, '
      'epoch: $anchorEpochSeconds, source: $source)';
}

/// The anchor [records] support right now, or null when they support none.
///
/// [clockReferenceEpochSeconds] is the epoch this session wrote into the
/// sensor clock; without it the app has no reference to offer and the result is
/// null. The newest record's own stamp must agree with [now] to within
/// [tolerance], which is what separates a clock the sensor took from the app
/// from a counter that was never set.
CbioIndexTimeAnchor? deriveCbioIndexTimeAnchor({
  required List<CbioRawGlucoseRecord> records,
  required int? clockReferenceEpochSeconds,
  required DateTime now,
  Duration tolerance = cbioAnchorTolerance,
}) {
  if (clockReferenceEpochSeconds == null || records.isEmpty) {
    return null;
  }
  final newest = records.last;
  final observed = now.toUtc();
  final agreement = newest.rawTime - (observed.millisecondsSinceEpoch ~/ 1000);
  if (agreement.abs() > tolerance.inSeconds) {
    return null;
  }
  return CbioIndexTimeAnchor(
    anchorIndex: newest.index,
    coveredFromIndex: _coveredFromIndex(records),
    anchorEpochSeconds: newest.rawTime,
    observedAt: observed,
    clockReferenceEpochSeconds: clockReferenceEpochSeconds,
  );
}

/// Walks back from the newest record while the index steps by one and the
/// record's own stamp steps by exactly [cbioRecordStepSeconds]. A missing
/// index or a counter jump ends the range, so no position past it is given a
/// time it cannot support.
int _coveredFromIndex(List<CbioRawGlucoseRecord> records) {
  var covered = records.last.index;
  for (var i = records.length - 2; i >= 0; i -= 1) {
    final newer = records[i + 1];
    final older = records[i];
    if (newer.index - older.index != 1) {
      break;
    }
    if (newer.rawTime - older.rawTime != cbioRecordStepSeconds) {
      break;
    }
    covered = older.index;
  }
  return covered;
}
