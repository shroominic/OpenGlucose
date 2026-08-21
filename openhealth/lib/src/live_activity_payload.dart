import 'package:cgm_core/cgm_core.dart';

import 'display_preferences.dart';
import 'session_presentation.dart';

const liveSurfaceBrandName = 'OpenGlucose';

class LiveActivityPayload {
  const LiveActivityPayload({
    required this.sensorName,
    required this.stageCode,
    required this.stageLabel,
    required this.valueText,
    required this.unitText,
    required this.lastReadingText,
    required this.lifeText,
    required this.detailText,
    required this.trendSymbol,
    required this.deltaText,
    required this.isStale,
    this.recordedAtIso8601,
  });

  /// Legacy platform-contract key. Production builders store the app brand,
  /// never the connected sensor identity, in this display-only field.
  final String sensorName;
  final String stageCode;
  final String stageLabel;
  final String valueText;
  final String unitText;
  final String lastReadingText;
  final String lifeText;
  final String detailText;
  final String trendSymbol;
  final String deltaText;
  final bool isStale;
  final String? recordedAtIso8601;

  Map<String, Object> toMap() => <String, Object>{
    'sensorName': sensorName,
    'stageCode': stageCode,
    'stageLabel': stageLabel,
    'valueText': valueText,
    'unitText': unitText,
    'lastReadingText': lastReadingText,
    'lifeText': lifeText,
    'detailText': detailText,
    'trendSymbol': trendSymbol,
    'deltaText': deltaText,
    'isStale': isStale,
    'recordedAtIso8601': ?recordedAtIso8601,
  };
}

bool shouldPublishLiveActivity({
  required CgmSessionSnapshot snapshot,
  required CgmReading? latestReading,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: latestReading,
    now: effectiveNow,
  );
  if (warmup?.phase == WarmupPhase.warming) {
    return true;
  }
  if (snapshot.stage != CgmSyncStage.ready) {
    return false;
  }
  final recordedAt = latestReading?.recordedAt;
  if (recordedAt == null) {
    return false;
  }
  final age = effectiveNow.difference(recordedAt.toLocal());
  return !age.isNegative && age <= const Duration(minutes: 15);
}

LiveActivityPayload buildLiveActivityPayload({
  required CgmSessionSnapshot snapshot,
  required CgmReading? latestReading,
  required DisplayPreferences preferences,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final warmup = computeWarmupStatus(
    snapshot,
    latestReading: latestReading,
    now: effectiveNow,
  );
  if (warmup != null) {
    return LiveActivityPayload(
      sensorName: liveSurfaceBrandName,
      stageCode: 'progress',
      stageLabel: warmupStageLabel(warmup).toUpperCase(),
      valueText: warmupBigValueText(warmup),
      unitText: warmup.phase == WarmupPhase.warming ? 'min' : '',
      lastReadingText: '--',
      lifeText: sensorLifeText(
        snapshot.sessionInfo.sessionStart,
        now: effectiveNow,
      ),
      detailText: warmupSubtext(warmup),
      trendSymbol: '',
      deltaText: '',
      isStale: false,
    );
  }
  final fallbackValue = snapshot.lastAdvertisement?.displayValueMgdl;
  final displayedValue =
      latestReading?.displayValue(preferences) ??
      (fallbackValue == null
          ? null
          : preferences.unit.convertFromMgdl(fallbackValue));
  final valueText = displayedValue == null
      ? '--'
      : displayedValue.toStringAsFixed(
          preferences.unit == GlucoseUnit.mgdl ? 0 : 1,
        );
  final readingTime = readingTimeText(latestReading, now: effectiveNow);
  final displayRecordedAt = clampedDisplayRecordedAt(
    latestReading?.recordedAt,
    now: effectiveNow,
  );
  final isStale =
      displayRecordedAt == null ||
      effectiveNow.difference(displayRecordedAt) > const Duration(minutes: 10);
  final trend = glucoseTrendSummary(snapshot.history, preferences);
  final stageCode = stageCodeForSnapshot(snapshot);
  final stageLabel = stageLabelForSnapshot(snapshot);
  final detailText = snapshot.lastError != null
      ? 'Attention needed'
      : readingTime == '--'
      ? (snapshot.historySync.inProgress
            ? 'Waiting for first reading'
            : snapshot.statusText)
      : 'Updated $readingTime';

  return LiveActivityPayload(
    sensorName: liveSurfaceBrandName,
    stageCode: stageCode,
    stageLabel: stageLabel,
    valueText: valueText,
    unitText: preferences.unit.label,
    lastReadingText: readingTime,
    lifeText: sensorLifeText(
      snapshot.sessionInfo.sessionStart,
      now: effectiveNow,
    ),
    detailText: detailText,
    trendSymbol: trend.symbol,
    deltaText: trend.deltaText,
    isStale: isStale,
    recordedAtIso8601: displayRecordedAt?.toUtc().toIso8601String(),
  );
}
