import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';

/// Deterministic fresh-session proof for UI-only synthetic records.
///
/// This fixture models an epoch-less counter era at 12000 + index * 60.
/// A checkpoint stops at the first contiguous run, never after an unresolved
/// hole. Anchored fixtures explicitly provide their app-clock evidence instead.
/// Actual driver proof production is covered separately by the real-session
/// fake-BLE/controller integration suite. This helper never repairs row flags.
/// High starting indexes are intentionally compact UI abstractions: they model
/// an already-populated in-memory session, not full fresh-radio retrieval from1.
Map<String, String> syntheticCbioFreshMetadata(
  DiscoveredSensor sensor,
  List<CgmReading> history, {
  CbioIndexTimeAnchor? anchor,
}) {
  if (history.isEmpty) {
    return {cbioResumeStatusMetadataKey: CbioResumeStatus.fresh};
  }
  final indexes = history.map((row) => row.sensorMinute!).toList()..sort();
  var witness = indexes.first;
  for (final index in indexes.skip(1)) {
    if (index != witness + 1) break;
    witness = index;
  }
  final checkpoint = CbioSessionCheckpoint(
    sensorKey: sensor.storageKey,
    index: witness,
    rawTime: anchor == null
        ? 12000 + witness * 60
        : anchor.timeForIndex(witness).millisecondsSinceEpoch ~/ 1000,
    anchor: anchor,
  );
  if (CbioSessionCheckpoint.decode(checkpoint.encode(), sensor.storageKey) ==
      null) {
    throw StateError('Synthetic CBIO fixture must have a valid bound witness');
  }
  return {
    cbioResumeStatusMetadataKey: CbioResumeStatus.fresh,
    cbioCheckpointMetadataKey: checkpoint.encode(),
  };
}
