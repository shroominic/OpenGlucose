import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:intl/intl.dart';

import 'display_preferences.dart';

DateTime? clampedDisplayRecordedAt(DateTime? recordedAt, {DateTime? now}) {
  if (recordedAt == null) {
    return null;
  }
  final effectiveNow = now ?? DateTime.now();
  final localRecordedAt = recordedAt.toLocal();
  if (localRecordedAt.isAfter(effectiveNow) &&
      localRecordedAt.difference(effectiveNow) <= const Duration(minutes: 2)) {
    return effectiveNow;
  }
  return localRecordedAt;
}

String readingTimeText(CgmReading? reading, {DateTime? now}) {
  final recordedAt = clampedDisplayRecordedAt(reading?.recordedAt, now: now);
  if (recordedAt == null) {
    return '--';
  }
  return DateFormat('HH:mm').format(recordedAt);
}

/// How long a live surface may stay silent before it is honestly stale.
const Duration liveSurfaceStaleAfter = Duration(minutes: 10);

/// The youngest honest timestamp behind a snapshot's live surface.
///
/// Drivers that time their own readings are judged by the reading time, which
/// is what the surface shows as the record's own moment. The CBio protocol
/// carries no epoch: a GS1 record is positioned by the sensor's minute counter,
/// so [CgmReading.recordedAt] is null unless the session holds a clock anchor
/// for the position (the clock this app set on the sensor). An anchored record
/// is judged by that time; a record the anchor does not cover falls back to the
/// only clock left, when this phone received the data,
/// [CgmHistorySyncState.lastSyncAt]. A receipt time is returned here for
/// staleness only; it is never published as a sensor time.
DateTime? liveSurfaceFreshnessAt({
  required CgmSessionSnapshot snapshot,
  CgmReading? reading,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  if (!isCbioSnapshot(snapshot)) {
    return clampedDisplayRecordedAt(reading?.recordedAt, now: effectiveNow);
  }
  final anchored = clampedDisplayRecordedAt(
    reading?.recordedAt,
    now: effectiveNow,
  );
  if (anchored != null) {
    return anchored;
  }
  final receivedAt = snapshot.historySync.lastSyncAt;
  if (receivedAt == null) {
    return null;
  }
  final localReceivedAt = receivedAt.toLocal();
  return localReceivedAt.isAfter(effectiveNow) ? effectiveNow : localReceivedAt;
}

bool liveSurfaceIsStale(DateTime? freshnessAt, {DateTime? now}) {
  if (freshnessAt == null) {
    return true;
  }
  final effectiveNow = now ?? DateTime.now();
  return effectiveNow.difference(freshnessAt) > liveSurfaceStaleAfter;
}

/// Local charts and explicit raw exports may retain provisional samples, with
/// their quality flag. They are not inputs to wellness summaries or messaging.
List<CgmReading> readingsForWellness(Iterable<CgmReading> readings) =>
    List<CgmReading>.unmodifiable(
      readings.where(
        (reading) =>
            !reading.isDisplayProvisional &&
            reading.source != CgmRecordSource.raw &&
            reading.valueMgdl.isFinite &&
            reading.valueMgdl > 0,
      ),
    );

enum WarmupPhase { warming, waiting }

class WarmupStatus {
  const WarmupStatus({
    required this.phase,
    required this.elapsedMinutes,
    required this.remainingMinutes,
    required this.totalMinutes,
  });

  final WarmupPhase phase;
  final int elapsedMinutes;
  final int remainingMinutes;
  final int totalMinutes;
}

WarmupStatus? computeWarmupStatus(
  CgmSessionSnapshot snapshot, {
  CgmReading? latestReading,
  DateTime? now,
}) {
  final sessionStart = snapshot.sessionInfo.sessionStart;
  final reportedElapsed = snapshot.sessionInfo.elapsedMinutes;
  if (sessionStart == null && reportedElapsed == null) {
    return null;
  }
  final total = snapshot.sessionInfo.warmupMinutes;
  if (total <= 0) {
    return null;
  }
  final effectiveNow = now ?? DateTime.now();
  // Prefer the sensor's monotonic session counter over wall-clock arithmetic.
  // Phone clock changes and delayed session-start discovery must not shorten or
  // extend the warmup shown to the user.
  final elapsed =
      reportedElapsed ?? effectiveNow.difference(sessionStart!).inMinutes;
  if (elapsed < 0) {
    return WarmupStatus(
      phase: WarmupPhase.warming,
      elapsedMinutes: 0,
      remainingMinutes: total,
      totalMinutes: total,
    );
  }
  if (elapsed < total) {
    // Inside the warmup window readings are unreliable (sensor noise during
    // equilibration), so the warmup countdown always wins over any value the
    // sensor happens to broadcast.
    return WarmupStatus(
      phase: WarmupPhase.warming,
      elapsedMinutes: elapsed,
      remainingMinutes: total - elapsed,
      totalMinutes: total,
    );
  }
  if (latestReading != null) {
    return null;
  }
  return WarmupStatus(
    phase: WarmupPhase.waiting,
    elapsedMinutes: elapsed,
    remainingMinutes: 0,
    totalMinutes: total,
  );
}

/// Returns the readings suitable for charts and wellness analytics after the
/// sensor's initial warmup window.
///
/// Sensor-relative minutes are authoritative when present because they remain
/// stable across wall-clock corrections. Timestamp comparison is a fallback
/// for normalized readings that do not carry a sensor minute. If neither can
/// place a reading relative to activation, the reading is retained rather than
/// silently discarding data of unknown provenance.
List<CgmReading> readingsAfterWarmup(
  Iterable<CgmReading> readings, {
  required int warmupMinutes,
  DateTime? sessionStart,
}) {
  if (warmupMinutes <= 0) {
    return List<CgmReading>.unmodifiable(readings);
  }
  final warmupEndsAt = sessionStart?.add(Duration(minutes: warmupMinutes));
  return List<CgmReading>.unmodifiable(
    readings.where((reading) {
      final sensorMinute = reading.sensorMinute;
      if (sensorMinute != null) {
        return sensorMinute >= warmupMinutes;
      }
      final recordedAt = reading.recordedAt;
      if (recordedAt != null && warmupEndsAt != null) {
        return !recordedAt.isBefore(warmupEndsAt);
      }
      return true;
    }),
  );
}

String warmupBigValueText(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => status.remainingMinutes.toString(),
    WarmupPhase.waiting => '…',
  };
}

String warmupUnitText(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'min',
    WarmupPhase.waiting => 'waiting for first reading',
  };
}

String warmupSubtext(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'Warming up',
    WarmupPhase.waiting => 'Warmup complete',
  };
}

String warmupStageLabel(WarmupStatus status) {
  return switch (status.phase) {
    WarmupPhase.warming => 'Warmup',
    WarmupPhase.waiting => 'Waiting',
  };
}

/// Total wear life of the Aidex X sensor. Single source of truth so the
/// dashboard, lifecycle card, and tests never drift (the device is a 15-day
/// sensor — previously the older 14-day Aidex; see TASK-043).
const Duration kSensorLifeDuration = Duration(days: 15);

/// When less than this remains, the sensor is treated as "expiring soon" and
/// the lifecycle card shows a heads-up to have a replacement ready.
const Duration kSensorExpiringSoonThreshold = Duration(hours: 12);

String sensorLifeText(
  DateTime? sessionStart, {
  DateTime? now,
  Duration totalLife = kSensorLifeDuration,
}) {
  if (sessionStart == null) {
    return 'Life remaining unavailable';
  }
  final effectiveNow = now ?? DateTime.now();
  final remaining = totalLife - effectiveNow.difference(sessionStart);
  if (remaining <= Duration.zero) {
    return 'Sensor expired';
  }
  if (remaining < const Duration(days: 1)) {
    final hours = remaining.inHours <= 0 ? 1 : remaining.inHours;
    return '$hours ${hours == 1 ? 'hour' : 'hours'} left';
  }
  // Round up so a freshly-started 15-day sensor reads "15 days left" rather
  // than "14" (a partial first day still counts as a day of life).
  final days = (remaining.inHours / 24).ceil();
  return '$days ${days == 1 ? 'day' : 'days'} left';
}

/// Lifecycle phase of the sensor derived purely from session timing + health.
enum SensorLifecyclePhase {
  /// No `sessionStart` known yet — can't place the sensor in its life.
  unknown,

  /// Inside the ~1h warmup window after insertion (no reliable readings yet).
  warmup,

  /// Normal in-life operation.
  active,

  /// Within [kSensorExpiringSoonThreshold] of end-of-life — replace soon.
  expiringSoon,

  /// Past 15 days, or the session was stopped / flagged expired by the sensor.
  expired,
}

/// A self-contained, testable view-model for the sensor lifecycle card.
///
/// Derived from the session timing (`sessionStart` / `warmupMinutes`) plus the
/// expiry/stopped health flags. Pure: pass `now` in tests for determinism.
class SensorLifecycle {
  const SensorLifecycle({
    required this.phase,
    required this.lifeUsedFraction,
    required this.age,
    required this.remaining,
    required this.totalLife,
    this.sessionStart,
    this.warmup,
  });

  final SensorLifecyclePhase phase;

  /// Fraction (0.0–1.0) of the 15-day life consumed.
  final double lifeUsedFraction;

  /// Time since the sensor session started (clamped to >= 0).
  final Duration age;

  /// Time left before end-of-life (clamped to >= 0; zero when expired).
  final Duration remaining;

  final Duration totalLife;
  final DateTime? sessionStart;

  /// Non-null only while warming up.
  final WarmupStatus? warmup;

  /// Whole-percent of life used, 0–100.
  int get lifeUsedPercent => (lifeUsedFraction * 100).round().clamp(0, 100);

  bool get isExpired => phase == SensorLifecyclePhase.expired;
  bool get isExpiringSoon => phase == SensorLifecyclePhase.expiringSoon;
  bool get isWarmingUp => phase == SensorLifecyclePhase.warmup;
}

/// Computes the [SensorLifecycle] for [snapshot] as of [now].
SensorLifecycle computeSensorLifecycle(
  CgmSessionSnapshot snapshot, {
  CgmReading? latestReading,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final sessionStart = snapshot.sessionInfo.sessionStart;
  final configuredLife = Duration(
    minutes: snapshot.sessionInfo.expectedLifetimeMinutes,
  );
  final totalLife = configuredLife > Duration.zero
      ? configuredLife
      : kSensorLifeDuration;

  // A stopped session or an explicit expired health flag means the sensor is
  // done regardless of the exact clock math (covers the mock `expired`
  // scenario where readings froze but the wall clock is just past 15 days).
  final stoppedOrFlagged =
      snapshot.sessionInfo.sessionStopped || snapshot.health.expired;

  if (sessionStart == null) {
    return SensorLifecycle(
      phase: stoppedOrFlagged
          ? SensorLifecyclePhase.expired
          : SensorLifecyclePhase.unknown,
      lifeUsedFraction: stoppedOrFlagged ? 1 : 0,
      age: Duration.zero,
      remaining: Duration.zero,
      totalLife: totalLife,
    );
  }

  final rawAge = effectiveNow.difference(sessionStart);
  final age = rawAge.isNegative ? Duration.zero : rawAge;
  final rawRemaining = totalLife - age;
  final remaining = rawRemaining.isNegative ? Duration.zero : rawRemaining;
  final fraction = (age.inSeconds / totalLife.inSeconds).clamp(0.0, 1.0);

  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: latestReading,
    now: effectiveNow,
  );

  final SensorLifecyclePhase phase;
  if (stoppedOrFlagged || remaining <= Duration.zero) {
    phase = SensorLifecyclePhase.expired;
  } else if (warmup != null && warmup.phase == WarmupPhase.warming) {
    phase = SensorLifecyclePhase.warmup;
  } else if (remaining <= kSensorExpiringSoonThreshold) {
    phase = SensorLifecyclePhase.expiringSoon;
  } else {
    phase = SensorLifecyclePhase.active;
  }

  return SensorLifecycle(
    phase: phase,
    lifeUsedFraction: phase == SensorLifecyclePhase.expired ? 1.0 : fraction,
    age: age,
    remaining: phase == SensorLifecyclePhase.expired
        ? Duration.zero
        : remaining,
    totalLife: totalLife,
    sessionStart: sessionStart,
    warmup: warmup,
  );
}

/// "3d 4h" style compact duration for the lifecycle card.
String compactDurationText(Duration duration) {
  if (duration <= Duration.zero) {
    return '0h';
  }
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  return '${minutes}m';
}

/// "Last synced 2 min ago" style relative text for the most recent reading.
String lastSyncText(DateTime? lastSyncAt, {DateTime? now}) {
  if (lastSyncAt == null) {
    return 'Not synced yet';
  }
  final effectiveNow = now ?? DateTime.now();
  final delta = effectiveNow.difference(lastSyncAt.toLocal());
  if (delta.isNegative || delta < const Duration(seconds: 45)) {
    return 'Synced just now';
  }
  if (delta < const Duration(hours: 1)) {
    final mins = delta.inMinutes;
    return 'Synced $mins min ago';
  }
  if (delta < const Duration(days: 1)) {
    final hours = delta.inHours;
    return 'Synced $hours ${hours == 1 ? 'hour' : 'hours'} ago';
  }
  final days = delta.inDays;
  return 'Synced $days ${days == 1 ? 'day' : 'days'} ago';
}

int? historySyncPercent(CgmHistorySyncState historySync) {
  if (!historySync.inProgress || historySync.totalAvailable <= 0) {
    return null;
  }
  final ratio = historySync.storedCount / historySync.totalAvailable;
  return (ratio * 100).clamp(0, 100).round();
}

String stageLabelForSnapshot(CgmSessionSnapshot snapshot) {
  if (isLibreGen1Snapshot(snapshot)) {
    if (libreConnectionWasLost(snapshot)) return 'Connection lost';
    if (snapshot.stage == CgmSyncStage.error) return 'Error';
    if (snapshot.stage == CgmSyncStage.disconnected) return 'Disconnected';
    if (snapshot.stage == CgmSyncStage.ready) {
      return currentReadingForSnapshot(snapshot, snapshot.latestReading) == null
          ? 'Waiting'
          : 'Connected';
    }
    if (snapshot.stage == CgmSyncStage.connecting &&
        snapshot.metadata['cgm.libre2.phase'] == 'awaitingAdvertisement') {
      return 'Searching';
    }
    if (snapshot.stage == CgmSyncStage.syncing &&
        const {
          'awaitingPacket',
          'validatedPacket',
        }.contains(snapshot.metadata['cgm.libre2.phase'])) {
      return 'Waiting';
    }
    return 'Connecting';
  }
  if (isCbioSnapshot(snapshot)) {
    if (snapshot.stage == CgmSyncStage.error) {
      return 'Error';
    }
    if (snapshot.stage == CgmSyncStage.disconnected) {
      return snapshot.latestReading != null || snapshot.history.isNotEmpty
          ? 'Reconnecting'
          : 'Disconnected';
    }
    if (snapshot.stage == CgmSyncStage.syncing) {
      return 'Fetching history';
    }
    return snapshot.stage == CgmSyncStage.ready ? 'Live' : 'Connecting';
  }
  final hasData = snapshot.latestReading != null || snapshot.history.isNotEmpty;

  if (snapshot.stage == CgmSyncStage.error) {
    return 'Error';
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return hasData ? 'Reconnecting' : 'Disconnected';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    if (snapshot.historySync.inProgress && !hasData) {
      return 'Setting up';
    }
    return 'Connected';
  }
  if (snapshot.stage == CgmSyncStage.connecting ||
      snapshot.stage == CgmSyncStage.bonding ||
      snapshot.stage == CgmSyncStage.pairing ||
      snapshot.stage == CgmSyncStage.activating ||
      snapshot.stage == CgmSyncStage.syncing) {
    return hasData ? 'Reconnecting' : 'Connecting';
  }
  return 'Connecting';
}

String stageCodeForSnapshot(CgmSessionSnapshot snapshot) {
  if (isLibreGen1Snapshot(snapshot)) {
    return switch (stageLabelForSnapshot(snapshot)) {
      'Error' || 'Disconnected' || 'Connection lost' => 'error',
      'Connected' => 'live',
      _ => 'progress',
    };
  }
  final hasData = snapshot.latestReading != null || snapshot.history.isNotEmpty;

  if (snapshot.stage == CgmSyncStage.error) {
    return 'error';
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return hasData ? 'progress' : 'error';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    return 'live';
  }
  return 'progress';
}

bool shouldShowPrimaryError(CgmSessionSnapshot snapshot) {
  if (snapshot.lastError == null || snapshot.lastError!.isEmpty) {
    return false;
  }
  if (snapshot.stage == CgmSyncStage.error) {
    return true;
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return true;
  }
  return false;
}

String? primaryErrorTextForSnapshot(CgmSessionSnapshot snapshot) {
  if (!shouldShowPrimaryError(snapshot)) {
    return null;
  }
  if (isLibreGen1Snapshot(snapshot)) {
    return libreConnectionWasLost(snapshot)
        ? userMessageForLibreConnectionLoss(snapshot.lastError)
        : userMessageForLibreConnectionFailure(snapshot.lastError);
  }
  if (isCbioSnapshot(snapshot)) {
    return userMessageForCbioFailure(snapshot.lastError);
  }
  final bleFailure = BleFailure.fromMetadata(snapshot.metadata);
  return bleFailure == null
      ? snapshot.lastError
      : userMessageForBleFailure(bleFailure);
}

bool isLibreGen1Snapshot(CgmSessionSnapshot snapshot) =>
    snapshot.sensor.driverId == 'libre2-gen1';

bool isCbioSnapshot(CgmSessionSnapshot snapshot) =>
    snapshot.sensor.driverId == 'cbio';

/// The failure-card sentence for a closed CBio session code.
///
/// The session publishes machine codes. They are support codes, not copy: the
/// failure card is the one place a user reads them, and `cbio.auth.rejected` is
/// not a sentence. Each code keeps its own failure, because "the sensor refused
/// this build's credential" and "the sensor is out of range" have different
/// next steps.
String userMessageForCbioFailure(String? code) => switch (code) {
  CbioSessionFailure.authMaterial =>
    'OpenGlucose could not read the link credential for this sensor. '
        'Choose another sensor or update the app.',
  CbioSessionFailure.authRejected =>
    'The sensor refused the link credential this build uses. '
        'Choose another sensor or update the app.',
  CbioSessionFailure.authTimeout =>
    'The sensor did not answer the link setup. Keep it close and try again.',
  CbioSessionFailure.topology =>
    'This sensor does not present the link OpenGlucose supports yet. '
        'Choose another sensor.',
  CbioSessionFailure.write =>
    'The link refused a command from this phone. Keep the sensor close and '
        'try again.',
  CbioSessionFailure.disconnected =>
    'The sensor disconnected. Keep it close and try again.',
  CbioSessionFailure.connect =>
    'Could not reach the sensor. Keep it close and try again.',
  _ => 'OpenGlucose could not connect to this sensor.',
};

/// The provisional marker every CBio surface shows.
///
/// The GS1 raw field is divided by ten by two independent clients of the
/// protocol, but no reference measurement has confirmed that scale, so the
/// derived number stays visible with its unit explicitly unsettled.
String? provisionalReadingNoticeForSnapshot(CgmSessionSnapshot snapshot) {
  if (isCbioSnapshot(snapshot)) {
    return cbioProvisionalUnitNotice;
  }
  return libreConnectionDetailForSnapshot(snapshot);
}

/// The history-card quality notice for a provisional reading set.
String historyProvisionalNoticeForSnapshot(CgmSessionSnapshot snapshot) {
  if (isCbioSnapshot(snapshot)) {
    return cbioProvisionalUnitNotice;
  }
  return 'Includes provisional readings. Not validated for body glucose.';
}

/// Progress or completion wording for a fetched sensor history.
String historySyncProgressText(CgmHistorySyncState state) {
  final stored = state.storedCount;
  final target = state.totalAvailable;
  if (target > 0 && stored < target) {
    return 'Fetching sensor history: $stored of $target records';
  }
  return 'Fetching sensor history: $stored records';
}

/// The CBio dashboard value: the sensor's raw field divided by ten.
///
/// No glucose unit is attached, because the protocol's scale is unverified.
/// The number the harness reads out of the same `0x08` field is the same
/// number this renders, so the app and the capture tooling agree.
String? cbioProvisionalValueText(CgmReading? reading) {
  final raw = reading?.rawValue;
  if (raw == null) {
    return null;
  }
  return (raw / 10).toStringAsFixed(1);
}

/// Sensor positions inside the stored span that this phone never received.
///
/// The first and last stored positions bound an *envelope*. The protocol's own
/// `index` counter advances one per stored minute, so a stored span of 1-7 with
/// five records holds two holes - positions the sensor moved past that were
/// never delivered to this app.
int cbioMissingPositions(Iterable<CgmReading> readings) {
  final positions = <int>{
    for (final reading in readings)
      if (reading.sensorMinute != null) reading.sensorMinute!,
  };
  if (positions.isEmpty) {
    return 0;
  }
  final sorted = positions.toList()..sort();
  return (sorted.last - sorted.first + 1) - sorted.length;
}

/// What the app actually stored for this sensor: how many records, which sensor
/// positions they cover, and - when the envelope is not full - how many
/// positions inside it never arrived. Positions are the protocol's own `index`
/// counter, which advances one per stored minute; it is never a wall clock.
String cbioStoredRangeText(Iterable<CgmReading> readings) {
  final positions = <int>[
    for (final reading in readings)
      if (reading.sensorMinute != null) reading.sensorMinute!,
  ];
  if (positions.isEmpty) {
    return '${readings.length} readings stored';
  }
  positions.sort();
  final stored =
      '${readings.length} readings stored · '
      'sensor minutes ${positions.first}–${positions.last}';
  final missing = cbioMissingPositions(readings);
  if (missing <= 0) {
    return stored;
  }
  return '$stored · $missing positions not received';
}

/// The index-to-clock anchor a GS1 session published, or null when it has none.
CbioIndexTimeAnchor? cbioAnchorForSnapshot(CgmSessionSnapshot snapshot) =>
    isCbioSnapshot(snapshot)
    ? CbioIndexTimeAnchor.fromMetadata(snapshot.metadata)
    : null;

/// The clock state of a GS1 surface.
///
/// The record index is a wall clock only where the session holds an anchor for
/// it: the clock this app set on the sensor, confirmed against the sensor's own
/// newest record stamp. Without one the line names the ordering the surface can
/// stand behind instead of a placeholder time, and with one it states the
/// reference and the minute it can be trusted to.
/// [reading] is the same reading the surface shows as the latest, so the clock
/// line and the value above it always describe one position.
String cbioClockStateText(
  CgmSessionSnapshot snapshot, {
  CgmReading? reading,
  DateTime? now,
}) {
  if (!isCbioSnapshot(snapshot)) {
    return '';
  }
  final anchor = cbioAnchorForSnapshot(snapshot);
  if (anchor == null) {
    return 'Sensor clock unsynced · ordered by sensor index, not by clock';
  }
  final latest = reading ?? snapshot.latestReading;
  // The line repeats the reading's own stamp, so a position the publisher left
  // untimed is never given a clock the anchor does not cover.
  if (latest == null ||
      clampedDisplayRecordedAt(latest.recordedAt, now: now) == null) {
    return 'Sensor clock set by this app · this position has no anchored time';
  }
  return 'Sensor clock set by this app · latest '
      '${readingTimeText(latest, now: now)} (${_anchorUncertaintyText(anchor)})';
}

String _anchorUncertaintyText(CbioIndexTimeAnchor anchor) {
  final minutes = anchor.uncertainty.inMinutes;
  return minutes >= 1 ? '±$minutes min' : '±${anchor.uncertainty.inSeconds} s';
}

/// The live driver rebuilds this diagnostic from its in-memory packet counter
/// on each snapshot. Retained glucose history or a saved NFC state is not proof
/// that the current Bluetooth session received verified packets.
bool libreConnectionWasLost(CgmSessionSnapshot? snapshot) {
  if (snapshot == null ||
      !isLibreGen1Snapshot(snapshot) ||
      (snapshot.stage != CgmSyncStage.error &&
          snapshot.stage != CgmSyncStage.disconnected) ||
      snapshot.lastError == null ||
      snapshot.lastError!.isEmpty ||
      snapshot.lastError == 'libre2.cancelled') {
    return false;
  }
  final phase = snapshot.stage == CgmSyncStage.error
      ? 'failed'
      : 'disconnected';
  if (snapshot.metadata['cgm.libre2.phase'] != phase) return false;
  final diagnostics = snapshot.diagnostics.where(
    (item) => item.key == 'libre2.gen1.transport',
  );
  if (diagnostics.length != 1) return false;
  final fields = diagnostics.single.fields;
  return fields['phase'] == phase &&
      RegExp(r'^[1-9][0-9]{0,8}$').hasMatch(fields['validatedPackets'] ?? '');
}

String userMessageForLibreConnectionLoss(String? code) => switch (code) {
  'libre2.cleanupUnconfirmed' || 'libre2.loginOutcomeUnknown' =>
    'The sensor connection stopped, but its final state could not be confirmed. '
        'Stop setup and check the connection before trying again.',
  'libre2.invalidPacket' =>
    'The sensor data could not be verified, so the connection was stopped. '
        'No glucose reading is available.',
  _ =>
    'The sensor was sending data, then the connection stopped. '
        'Keep it close and try again.',
};

/// Cached records remain history during Libre transport setup. Raw protocol
/// samples and advertisements are not calibrated current glucose readings.
CgmReading? currentReadingForSnapshot(
  CgmSessionSnapshot snapshot,
  CgmReading? reading,
) {
  if (isLibreGen1Snapshot(snapshot) &&
      (snapshot.stage != CgmSyncStage.ready ||
          reading?.source == CgmRecordSource.raw)) {
    return null;
  }
  return reading;
}

/// Only closed, stage-consistent Libre progress reaches public surfaces.
/// A saved phase must not turn a disconnected session into a connected claim.
String? libreConnectionDetailForSnapshot(CgmSessionSnapshot snapshot) {
  if (!isLibreGen1Snapshot(snapshot)) return null;
  if (libreConnectionWasLost(snapshot)) {
    return userMessageForLibreConnectionLoss(snapshot.lastError);
  }
  if (snapshot.stage == CgmSyncStage.error) {
    return userMessageForLibreConnectionFailure(snapshot.lastError);
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return 'Sensor disconnected. Connect again to receive data.';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    final reading = currentReadingForSnapshot(snapshot, snapshot.latestReading);
    if (reading == null) return 'Waiting for a verified glucose reading.';
    return reading.isDisplayProvisional
        ? 'Bench estimate. Not validated for body glucose.'
        : null;
  }
  final phase = snapshot.metadata['cgm.libre2.phase'];
  if (snapshot.stage == CgmSyncStage.syncing) {
    return switch (phase) {
      'awaitingPacket' => 'Connected. Waiting for sensor data.',
      'validatedPacket' => libreGlucoseWaitingDetail(
        snapshot.metadata['cgm.libre2.decoder'],
      ),
      _ => 'Waiting for verified sensor data.',
    };
  }
  if (snapshot.stage != CgmSyncStage.connecting) {
    return 'Preparing the sensor connection.';
  }
  return switch (phase) {
    'reconnecting' => 'Connection lost. Reconnecting once to your sensor.',
    'awaitingAdvertisement' => 'Looking for your Libre 2 sensor',
    'discovering' => 'Checking the sensor connection',
    'reservingLogin' || 'loggingIn' => 'Signing in to the sensor',
    'subscribing' => 'Starting sensor updates',
    _ => 'Connecting to FreeStyle Libre 2',
  };
}

/// Closed decoder outcomes only; native exceptions and coefficients stay private.
String libreGlucoseWaitingDetail(String? outcome) => switch (outcome) {
  'warmingUp' => 'Sensor warming up. Waiting for glucose readings.',
  'invalidData' => 'Receiving sensor data. No usable glucose reading yet.',
  _ => 'Receiving sensor data. Glucose decoding is not ready.',
};

String userMessageForLibreConnectionFailure(String? code) => switch (code) {
  'libre2.advertisementUnavailable' =>
    'Your Libre 2 sensor was not found. Keep it close and try again.',
  'libre2.invalidBootstrap' ||
  'libre2.bootstrapUnavailable' ||
  'libre2.targetMismatch' =>
    'The sensor setup could not be verified. Choose your sensor again.',
  'libre2.sessionInUse' =>
    'A sensor connection is already in progress. Wait for it to finish.',
  'libre2.oneShotUnavailable' || 'libre2.topologyRejected' =>
    'This sensor connection is not supported by this build.',
  'libre2.counterUnavailable' =>
    'The sensor connection could not be prepared. Choose your sensor again.',
  'libre2.connectionFailed' =>
    'Could not connect to your Libre 2 sensor. Keep it close and try again.',
  'libre2.loginOutcomeUnknown' || 'libre2.cleanupUnconfirmed' =>
    'The connection result could not be confirmed. '
        'Stop setup and check the connection before trying again.',
  'libre2.subscriptionFailed' =>
    'Could not start sensor updates. Keep the sensor close and try again.',
  'libre2.invalidPacket' =>
    'The sensor data could not be verified. No glucose reading is available.',
  'libre2.disconnected' =>
    'The sensor disconnected. Keep it close and try again.',
  'libre2.cancelled' => 'Sensor connection cancelled.',
  _ => 'OpenGlucose could not connect to your Libre 2 sensor.',
};

/// Compile-time gate for privacy-safe support codes in explicitly marked
/// private test builds. Normal release builds compile this to false.
const bool kOgPrivateSupport = bool.fromEnvironment(
  'OG_PRIVATE_SUPPORT',
  defaultValue: false,
);

/// Returns a copyable, identifier-free setup code for a known AiDEX phase.
///
/// No general snapshot metadata is copied. BLE fields come exclusively from
/// [BleFailure.fromMetadata], which rejects unknown enum values and sanitizes
/// diagnostic codes before returning them.
String? privateBleSupportCodeForSnapshot(CgmSessionSnapshot snapshot) {
  final phase = snapshot.metadata[aidexSetupPhaseMetadataKey];
  if (phase == null || !AidexSetupPhase.values.contains(phase)) {
    return null;
  }
  final fields = <String>['OGSUP1', 'phase=$phase'];
  if (phase == AidexSetupPhase.subscribe) {
    final step = snapshot.metadata[aidexSubscribeStepMetadataKey];
    final attempt = snapshot.metadata[aidexSubscribeAttemptMetadataKey];
    if (step != null &&
        AidexSubscribeStep.values.contains(step) &&
        attempt != null &&
        AidexSubscribeAttempt.values.contains(attempt)) {
      fields
        ..add('step=$step')
        ..add('attempt=$attempt');
    }
  }
  final failure = BleFailure.fromMetadata(snapshot.metadata);
  if (failure != null) {
    fields
      ..add('op=${failure.operation.name}')
      ..add('kind=${failure.kind.name}')
      ..add('code=${failure.diagnosticCode}');
  }
  return fields.join(' ');
}

bool shouldOfferPrivateBleSupportCode(CgmSessionSnapshot snapshot) {
  if (privateBleSupportCodeForSnapshot(snapshot) == null) {
    return false;
  }
  return switch (snapshot.stage) {
    CgmSyncStage.connecting ||
    CgmSyncStage.bonding ||
    CgmSyncStage.pairing ||
    CgmSyncStage.activating ||
    CgmSyncStage.syncing ||
    CgmSyncStage.error ||
    CgmSyncStage.disconnected => true,
    CgmSyncStage.scanning || CgmSyncStage.ready => false,
  };
}

String? userMessageForBleError(Object error) {
  return error is BleFailure ? userMessageForBleFailure(error) : null;
}

String userMessageForBleFailure(BleFailure failure) {
  return switch (failure.kind) {
    BleFailureKind.permissionRequired =>
      'OpenGlucose needs Bluetooth access. In your phone settings, allow '
          'Bluetooth and any nearby-device permissions requested by the app. '
          'Some phones also require Location to be allowed and turned on for '
          'scanning. Then try again.',
    BleFailureKind.bluetoothOff =>
      "Bluetooth is off. Turn it on in your phone's quick settings or "
          'Settings, then try scanning again.',
    BleFailureKind.bluetoothUnavailable =>
      'Bluetooth is not available on this phone right now. Restart Bluetooth '
          'or the phone, then try again.',
    BleFailureKind.bondRejected =>
      'The phone did not complete pairing. Keep it close and accept the '
          'pairing prompt. If this sensor is already bonded or connected to '
          'another phone, stop that connection before trying again. Do not '
          'reset an active sensor.',
    BleFailureKind.bondTimedOut =>
      'Pairing timed out. Keep the phone close and accept the system pairing '
          'prompt. If another phone is using this sensor, stop that connection '
          'before trying again.',
    BleFailureKind.sensorPossiblyInUse =>
      'The sensor became unavailable during setup. It may be out of range or '
          'already bonded or connected to another phone. Keep it close and '
          'stop the other connection, if applicable, before trying again. Do '
          'not reset an active sensor.',
    BleFailureKind.scanUnavailable =>
      "Android paused the scan because the phone's screen is off, so no "
          'sensor could be found - the sensor may be right beside you. Keep '
          'the screen on and try again.',
    BleFailureKind.deviceDisconnected =>
      'The sensor disconnected. Keep the phone close and try again.',
    BleFailureKind.operationTimedOut =>
      'Bluetooth setup timed out. Keep the phone close and try again.',
    BleFailureKind.unexpected =>
      'Bluetooth setup could not be completed. Restart Bluetooth and try '
          'again.',
  };
}

bool bleFailureRequiresUserAction(CgmSessionSnapshot snapshot) {
  final failure = BleFailure.fromMetadata(snapshot.metadata);
  return failure != null && !failure.allowsAutomaticRetry;
}

bool snapshotHasBleFailure(CgmSessionSnapshot snapshot) {
  return BleFailure.fromMetadata(snapshot.metadata) != null;
}

bool snapshotAllowsAutomaticReconnect(CgmSessionSnapshot snapshot) {
  if (snapshot.metadata.containsKey(cgmBondTransferStateMetadataKey)) {
    return false;
  }
  if (snapshot.metadata[cgmAutomaticReconnectAllowedMetadataKey] == 'false') {
    return false;
  }
  return BleFailure.fromMetadata(snapshot.metadata)?.allowsAutomaticRetry ??
      true;
}

class GlucoseTrendSummary {
  const GlucoseTrendSummary({this.symbol = '', this.deltaText = ''});

  final String symbol;
  final String deltaText;

  bool get hasTrend => symbol.isNotEmpty || deltaText.isNotEmpty;
}

GlucoseTrendSummary glucoseTrendSummary(
  List<CgmReading> history,
  DisplayPreferences preferences,
) {
  if (history.length < 2) {
    return const GlucoseTrendSummary();
  }

  final latest = history.last;
  CgmReading? previous;
  for (var index = history.length - 2; index >= 0; index -= 1) {
    final candidate = history[index];
    if (candidate.sensorMinute != latest.sensorMinute ||
        candidate.recordedAt != latest.recordedAt) {
      previous = candidate;
      break;
    }
  }
  if (previous == null) {
    return const GlucoseTrendSummary();
  }

  final deltaMgdl = latest.valueMgdl - previous.valueMgdl;
  final symbol = switch (deltaMgdl) {
    >= 20 => '↑↑',
    >= 8 => '↑',
    > 2 => '↗',
    >= -2 => '→',
    > -8 => '↘',
    > -20 => '↓',
    _ => '↓↓',
  };

  final deltaDisplay = preferences.unit.convertFromMgdl(deltaMgdl);
  final sign = deltaDisplay > 0
      ? '+'
      : deltaDisplay < 0
      ? '-'
      : '';
  final magnitude = deltaDisplay.abs();
  final precision = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
  final deltaText = sign.isEmpty && magnitude == 0
      ? ''
      : '$sign${magnitude.toStringAsFixed(precision)}';

  return GlucoseTrendSummary(symbol: symbol, deltaText: deltaText);
}
