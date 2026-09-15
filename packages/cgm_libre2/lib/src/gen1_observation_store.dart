import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart';

import 'gen1_security.dart';
import 'gen1_glucose_decoder.dart';

/// Restricted, non-secret binding for one saved receiver's observation history.
///
/// The digest is an identity check, not encryption or authentication. Keep it
/// private. A new bootstrap is a new storage identity; this contract does not
/// establish continuity across re-enrollment of the same physical sensor.
final class LibreGen1ObservationBinding {
  LibreGen1ObservationBinding({
    required this.bootstrapId,
    required this.sensorBindingDigest,
  }) {
    if (bootstrapId.isEmpty ||
        bootstrapId.length > 128 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sensorBindingDigest)) {
      throw ArgumentError('Invalid Libre observation binding.');
    }
  }

  factory LibreGen1ObservationBinding.forSensor({
    required String bootstrapId,
    required LibreGen1Uid uid,
    required LibreGen1PatchInfo initialPatchInfo,
  }) => LibreGen1ObservationBinding(
    bootstrapId: bootstrapId,
    sensorBindingDigest: sha256.convert(<int>[
      ...utf8.encode('OpenGlucose/libre2-gen1/observations/v1\u0000'),
      ...uid.value.bytes,
      ...initialPatchInfo.value.bytes.take(4),
    ]).toString(),
  );

  final String bootstrapId;
  final String sensorBindingDigest;
  String get driverId => 'libre2-gen1';
  String get storageKey => '$driverId:$bootstrapId';

  @override
  String toString() => 'LibreGen1ObservationBinding(data: <redacted>)';
}

/// Durable history only. Loading this state never proves current freshness.
///
/// Legacy accepted history can establish only a lower-bound frontier. The app
/// store retains that migration provenance; this type cannot upgrade it.
final class LibreGen1ObservationState {
  LibreGen1ObservationState({
    this.observedMinute,
    this.replayBarrierMinute,
    List<CgmReading> history = const [],
  }) : history = List<CgmReading>.unmodifiable(history) {
    if (observedMinute != null &&
        (observedMinute! < 0 || observedMinute! > 0xffff)) {
      throw ArgumentError('Invalid Libre observation frontier.');
    }
    if (replayBarrierMinute != null &&
        (replayBarrierMinute! < 0 ||
            replayBarrierMinute! > 0xffff ||
            (observedMinute != null &&
                replayBarrierMinute! < observedMinute!))) {
      throw ArgumentError('Invalid Libre observation replay barrier.');
    }
  }

  /// Highest committed live BLE observation, not an NFC scan or current value.
  final int? observedMinute;

  /// Optional additional replay limit established by historical import/clear.
  ///
  /// This can exceed [observedMinute]. It only excludes older live packets;
  /// it cannot establish live freshness, elapsed timing, or receiver selection.
  /// Existing stores can omit it and retain the original observed-only policy.
  final int? replayBarrierMinute;
  int? get effectiveReplayBarrierMinute =>
      replayBarrierMinute ?? observedMinute;
  final List<CgmReading> history;

  @override
  String toString() => 'LibreGen1ObservationState(data: <redacted>)';
}

final class LibreGen1ObservationCommit {
  const LibreGen1ObservationCommit({
    required this.advanced,
    required this.state,
  });

  final bool advanced;
  final LibreGen1ObservationState state;

  @override
  String toString() => 'LibreGen1ObservationCommit(data: <redacted>)';
}

/// Accepted older BLE slot. Its timestamp is relative to the packet receipt,
/// not a new receipt, live observation, or NFC acquisition.
final class LibreGen1HistoricalReading {
  const LibreGen1HistoricalReading({required this.reading, required this.kind});

  final CgmReading reading;
  final LibreGen1BleHistoryKind kind;

  @override
  String toString() => 'LibreGen1HistoricalReading(data: <redacted>)';
}

/// App-owned atomic persistence for CRC-validated sensor observations.
///
/// All reads, merges, clears and writes to this history identity must use the
/// same serialized owner. For a newer minute, commit the frontier and optional
/// reading and bounded historical batch together before completing. A missing/rejected/warmup glucose value
/// still consumes the minute. A repeated/regressed minute returns advanced=false
/// without adding a reading or refreshing its first receipt time. A store with
/// historical imports can also reject a minute at or below its separate replay
/// barrier without advancing the live observation frontier. Returned
/// history is authoritative, including any explicit readings-only deletion.
///
/// Accept wire minutes 0..65535. An optional reading must have that exact
/// sensorMinute and receivedAt, preserving source/provisional flags unchanged.
/// Historical readings are distinct, older accepted packet slots, at most nine:
/// trend offsets 2/4/6/7/12/15 and three history positions starting at
/// ((sensorMinute - 2) ~/ 15) * 15, then minus 15/30. Each timestamp must equal
/// receivedAt minus its age difference. Keep the first retained observation
/// unchanged on duplicate identity, omit cleared minutes, and never advance
/// a live frontier from a historical sample. Reject malformed batches atomically.
/// Preserve unknown schema/binding failures instead of overwriting their data.
/// Throw on failed or uncertain durability; a timeout does not cancel a write.
/// Implementations must retain their queue after a lost completion and must not
/// permit a second owner to overwrite a still-pending transaction. No sensor
/// command, credential, raw frame or glucose conversion belongs in this store.
abstract interface class LibreGen1ObservationStore {
  Future<LibreGen1ObservationState> load(LibreGen1ObservationBinding binding);

  Future<LibreGen1ObservationCommit> commit(
    LibreGen1ObservationBinding binding, {
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  });
}
