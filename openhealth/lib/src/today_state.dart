import 'package:cgm_core/cgm_core.dart';

import 'session_presentation.dart';

/// A safe, compact classification for top-level product destinations.
///
/// This deliberately separates retained and stale readings from [live]. Tabs
/// other than Today use it before showing any glucose value or derived trend.
enum TodayDataState {
  noActiveSensor,
  retainedHistory,
  inactiveSensor,
  warmup,
  unavailable,
  stale,
  live,
}

/// Maps the current controller inputs into one user-visible data state.
///
/// [displayReading] must already exclude provisional warmup readings. A
/// disconnected or signal-lost snapshot can still retain a number, but it is
/// never classified as [TodayDataState.live].
TodayDataState classifyTodayDataState({
  required CgmSessionSnapshot? snapshot,
  required CgmReading? displayReading,
  required int retainedHistoryCount,
  DateTime? now,
}) {
  if (snapshot == null) {
    return retainedHistoryCount > 0
        ? TodayDataState.retainedHistory
        : TodayDataState.noActiveSensor;
  }

  if (snapshot.health.expired || snapshot.sessionInfo.sessionStopped) {
    return TodayDataState.inactiveSensor;
  }

  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: displayReading,
    now: now,
  );
  if (warmup?.phase == WarmupPhase.warming) {
    return TodayDataState.warmup;
  }

  if (displayReading == null) {
    return TodayDataState.unavailable;
  }

  if (snapshot.health.signalLost ||
      snapshot.health.error ||
      snapshot.health.malfunction ||
      snapshot.stage != CgmSyncStage.ready) {
    return TodayDataState.stale;
  }

  return TodayDataState.live;
}

extension TodayDataStateCopy on TodayDataState {
  String get title => switch (this) {
    TodayDataState.noActiveSensor => 'No active sensor',
    TodayDataState.retainedHistory => 'Earlier readings are retained',
    TodayDataState.inactiveSensor => 'This sensor is no longer active',
    TodayDataState.warmup => 'Sensor is warming up',
    TodayDataState.unavailable => 'No glucose reading is available',
    TodayDataState.stale => 'Live glucose is unavailable',
    TodayDataState.live => 'Live glucose is available',
  };

  String get description => switch (this) {
    TodayDataState.noActiveSensor =>
      'Connect a sensor to show current glucose context.',
    TodayDataState.retainedHistory =>
      'Earlier readings remain on this device, but they are not live.',
    TodayDataState.inactiveSensor =>
      'Any retained readings are historical and are not live.',
    TodayDataState.warmup =>
      'Glucose context appears after the sensor completes warmup. Early values are not shown as live.',
    TodayDataState.unavailable =>
      'The sensor has not provided a usable glucose reading yet.',
    TodayDataState.stale =>
      'The last glucose value is not live. Reconnect or wait for a fresh sensor update.',
    TodayDataState.live => 'Current glucose context is available.',
  };
}
