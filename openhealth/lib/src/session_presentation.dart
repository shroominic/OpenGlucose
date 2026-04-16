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

String sensorLifeText(DateTime? sessionStart, {DateTime? now}) {
  if (sessionStart == null) {
    return 'Life remaining unavailable';
  }
  final effectiveNow = now ?? DateTime.now();
  final remaining =
      const Duration(days: 15) - effectiveNow.difference(sessionStart);
  if (remaining <= Duration.zero) {
    return 'Sensor expired';
  }
  if (remaining < const Duration(days: 1)) {
    final hours = remaining.inHours <= 0 ? 1 : remaining.inHours;
    return '$hours ${hours == 1 ? 'hour' : 'hours'} left';
  }
  final days = remaining.inDays <= 0 ? 1 : remaining.inDays;
  return '$days ${days == 1 ? 'day' : 'days'} left';
}

int? historySyncPercent(CgmHistorySyncState historySync) {
  if (!historySync.inProgress || historySync.totalAvailable <= 0) {
    return null;
  }
  final ratio = historySync.storedCount / historySync.totalAvailable;
  return (ratio * 100).clamp(0, 100).round();
}

String stageLabelForSnapshot(CgmSessionSnapshot snapshot) {
  final syncPercent = historySyncPercent(snapshot.historySync);
  if (snapshot.historySync.inProgress) {
    if (syncPercent == null || syncPercent >= 90) {
      return 'SYNCING';
    }
    return 'SYNC $syncPercent%';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    return 'LIVE';
  }
  return snapshot.stage.name.toUpperCase();
}

String stageCodeForSnapshot(CgmSessionSnapshot snapshot) {
  if (snapshot.historySync.inProgress ||
      snapshot.stage == CgmSyncStage.pairing ||
      snapshot.stage == CgmSyncStage.syncing ||
      snapshot.stage == CgmSyncStage.activating) {
    return 'progress';
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    return 'live';
  }
  if (snapshot.stage == CgmSyncStage.error) {
    return 'error';
  }
  return 'pending';
}

bool shouldShowPrimaryError(CgmSessionSnapshot snapshot) {
  if (snapshot.lastError == null || snapshot.lastError!.isEmpty) {
    return false;
  }
  if (snapshot.stage == CgmSyncStage.error) {
    return snapshot.latestReading == null && snapshot.history.isEmpty;
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return snapshot.latestReading == null && snapshot.history.isEmpty;
  }
  return false;
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
