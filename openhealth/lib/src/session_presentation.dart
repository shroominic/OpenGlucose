import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'app_language_controller.dart';
import 'display_preferences.dart';

String _localized(AppLanguage language, String english, String chinese) =>
    language == AppLanguage.simplifiedChinese ? chinese : english;

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

String readingTimeText(
  CgmReading? reading, {
  DateTime? now,
  AppLanguage language = AppLanguage.english,
}) {
  final recordedAt = clampedDisplayRecordedAt(reading?.recordedAt, now: now);
  if (recordedAt == null) {
    return '--';
  }
  // A glucose timestamp is numeric in both supported languages. Formatting it
  // directly avoids a dependency on global intl locale initialization in
  // background payload builders and keeps Android/iOS live surfaces aligned.
  final hour = recordedAt.hour.toString().padLeft(2, '0');
  final minute = recordedAt.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

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

String warmupUnitText(
  WarmupStatus status, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (status.phase) {
    WarmupPhase.warming => _localized(language, 'min', '分钟'),
    WarmupPhase.waiting => _localized(
      language,
      'waiting for first reading',
      '正在等待首次读数',
    ),
  };
}

String warmupSubtext(
  WarmupStatus status, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (status.phase) {
    WarmupPhase.warming => _localized(language, 'Warming up', '预热中'),
    WarmupPhase.waiting => _localized(language, 'Warmup complete', '预热完成'),
  };
}

String warmupStageLabel(
  WarmupStatus status, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (status.phase) {
    WarmupPhase.warming => _localized(language, 'Warmup', '预热'),
    WarmupPhase.waiting => _localized(language, 'Waiting', '等待中'),
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
  AppLanguage language = AppLanguage.english,
}) {
  if (sessionStart == null) {
    return _localized(language, 'Life remaining unavailable', '无法获取剩余使用时间');
  }
  final effectiveNow = now ?? DateTime.now();
  final remaining = kSensorLifeDuration - effectiveNow.difference(sessionStart);
  if (remaining <= Duration.zero) {
    return _localized(language, 'Sensor expired', '传感器已到期');
  }
  if (remaining < const Duration(days: 1)) {
    final hours = remaining.inHours <= 0 ? 1 : remaining.inHours;
    return language == AppLanguage.simplifiedChinese
        ? '还剩 $hours 小时'
        : '$hours ${hours == 1 ? 'hour' : 'hours'} left';
  }
  // Round up so a freshly-started 15-day sensor reads "15 days left" rather
  // than "14" (a partial first day still counts as a day of life).
  final days = (remaining.inHours / 24).ceil();
  return language == AppLanguage.simplifiedChinese
      ? '还剩 $days 天'
      : '$days ${days == 1 ? 'day' : 'days'} left';
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
  const totalLife = kSensorLifeDuration;

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
String compactDurationText(
  Duration duration, {
  AppLanguage language = AppLanguage.english,
}) {
  if (duration <= Duration.zero) {
    return language == AppLanguage.simplifiedChinese ? '0小时' : '0h';
  }
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  if (language == AppLanguage.simplifiedChinese) {
    if (days > 0) {
      return hours > 0 ? '$days天$hours小时' : '$days天';
    }
    if (hours > 0) {
      return minutes > 0 ? '$hours小时$minutes分钟' : '$hours小时';
    }
    return '$minutes分钟';
  }
  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  return '${minutes}m';
}

/// "Last synced 2 min ago" style relative text for the most recent reading.
String lastSyncText(
  DateTime? lastSyncAt, {
  DateTime? now,
  AppLanguage language = AppLanguage.english,
}) {
  if (lastSyncAt == null) {
    return _localized(language, 'Not synced yet', '尚未同步');
  }
  final effectiveNow = now ?? DateTime.now();
  final delta = effectiveNow.difference(lastSyncAt.toLocal());
  if (delta.isNegative || delta < const Duration(seconds: 45)) {
    return _localized(language, 'Synced just now', '刚刚同步');
  }
  if (delta < const Duration(hours: 1)) {
    final mins = delta.inMinutes;
    return language == AppLanguage.simplifiedChinese
        ? '$mins 分钟前已同步'
        : 'Synced $mins min ago';
  }
  if (delta < const Duration(days: 1)) {
    final hours = delta.inHours;
    return language == AppLanguage.simplifiedChinese
        ? '$hours 小时前已同步'
        : 'Synced $hours ${hours == 1 ? 'hour' : 'hours'} ago';
  }
  final days = delta.inDays;
  return language == AppLanguage.simplifiedChinese
      ? '$days 天前已同步'
      : 'Synced $days ${days == 1 ? 'day' : 'days'} ago';
}

int? historySyncPercent(CgmHistorySyncState historySync) {
  if (!historySync.inProgress || historySync.totalAvailable <= 0) {
    return null;
  }
  final ratio = historySync.storedCount / historySync.totalAvailable;
  return (ratio * 100).clamp(0, 100).round();
}

String stageLabelForSnapshot(
  CgmSessionSnapshot snapshot, {
  AppLanguage language = AppLanguage.english,
}) {
  final hasData = snapshot.latestReading != null || snapshot.history.isNotEmpty;

  if (snapshot.stage == CgmSyncStage.error) {
    return _localized(language, 'Error', '出错');
  }
  if (snapshot.stage == CgmSyncStage.disconnected) {
    return hasData
        ? _localized(language, 'Reconnecting', '正在重新连接')
        : _localized(language, 'Disconnected', '已断开连接');
  }
  if (snapshot.stage == CgmSyncStage.ready) {
    if (snapshot.historySync.inProgress && !hasData) {
      return _localized(language, 'Setting up', '正在设置');
    }
    return _localized(language, 'Connected', '已连接');
  }
  if (snapshot.stage == CgmSyncStage.connecting ||
      snapshot.stage == CgmSyncStage.bonding ||
      snapshot.stage == CgmSyncStage.pairing ||
      snapshot.stage == CgmSyncStage.activating ||
      snapshot.stage == CgmSyncStage.syncing) {
    return hasData
        ? _localized(language, 'Reconnecting', '正在重新连接')
        : _localized(language, 'Connecting', '正在连接');
  }
  return _localized(language, 'Connecting', '正在连接');
}

String stageCodeForSnapshot(CgmSessionSnapshot snapshot) {
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

/// Returns an actionable, localized fallback for an app-owned operation.
///
/// [operation] is an internal stable identifier. It is deliberately not
/// included in the returned text: platform exceptions can contain native
/// details, identifiers, or implementation names that do not belong in the
/// normal UI.
String safeOperationFailureText(
  String operation, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (operation) {
    'Sensor scan' => _localized(
      language,
      'Sensor scan could not be completed. Check Bluetooth and try again.',
      '无法完成传感器扫描。请检查蓝牙后重试。',
    ),
    'Connection' => _localized(
      language,
      'The sensor could not be connected. Check Bluetooth, keep the phone '
          'close, and try again.',
      '无法连接传感器。请检查蓝牙，将手机靠近传感器后重试。',
    ),
    'Refresh' => _localized(
      language,
      'Could not refresh sensor data. Keep the phone close and try again.',
      '无法刷新传感器数据。请将手机靠近传感器后重试。',
    ),
    'Sync' => _localized(
      language,
      'Could not update sensor data. Keep the phone close and try again.',
      '无法更新传感器数据。请将手机靠近传感器后重试。',
    ),
    'History refresh' => _localized(
      language,
      'Could not update sensor history. Keep the phone close and try again.',
      '无法更新传感器历史记录。请将手机靠近传感器后重试。',
    ),
    'Diagnostics refresh' || 'Calibration load' => _localized(
      language,
      'Could not load sensor details. Try again.',
      '无法加载传感器详情。请重试。',
    ),
    'Sensor transfer check' => _localized(
      language,
      'The sensor move could not be checked safely. Review Bluetooth '
          'settings before trying again.',
      '无法安全检查传感器迁移。请先检查蓝牙设置，再重试。',
    ),
    'Sensor transfer' => _localized(
      language,
      'The sensor move stopped. Do not retry until you review Bluetooth '
          'settings.',
      '传感器迁移已停止。请先检查蓝牙设置，暂勿重试。',
    ),
    'Disconnecting sensor session' => _localized(
      language,
      'The sensor disconnected, but the app could not finish local cleanup. '
          'Review Settings before trying again.',
      '传感器已断开连接，但应用未能完成本地清理。请检查设置后再试。',
    ),
    'Cleaning active history' || 'Clearing stored history' => _localized(
      language,
      'Could not update local sensor history. Try again.',
      '无法更新本地传感器历史记录。请重试。',
    ),
    'Clearing the selected sensor' => _localized(
      language,
      'The selected sensor could not be cleared safely. Try again.',
      '无法安全清除所选传感器。请重试。',
    ),
    'Clearing sensor transfer state' => _localized(
      language,
      'Could not clear the sensor move state. Review Settings and try again.',
      '无法清除传感器迁移状态。请检查设置后重试。',
    ),
    'Updating lock-screen privacy' ||
    'Reading lock-screen privacy' => _localized(
      language,
      'Could not update lock-screen privacy. Sensitive values remain '
          'hidden.',
      '无法更新锁定屏幕隐私设置。敏感数值仍会保持隐藏。',
    ),
    'Updating private lock-screen state' => _localized(
      language,
      'Could not update the lock-screen display. Sensitive values remain '
          'hidden.',
      '无法更新锁定屏幕显示。敏感数值仍会保持隐藏。',
    ),
    'Saving verified sensor selection' => _localized(
      language,
      'Could not save this sensor on the phone. Keep the app open and try '
          'again.',
      '无法将此传感器保存在手机上。请保持应用打开后重试。',
    ),
    'Saving history' => _localized(
      language,
      'Could not save the latest sensor data on this phone. It will be '
          'retried.',
      '无法将最新传感器数据保存在手机上。应用将稍后重试。',
    ),
    'Clearing private background state' => _localized(
      language,
      'Could not clear the private lock-screen state. Try again from '
          'Settings.',
      '无法清除锁定屏幕上的私密状态。请在设置中重试。',
    ),
    _ => _localized(
      language,
      'The app could not complete this action. Try again.',
      '应用无法完成此操作。请重试。',
    ),
  };
}

/// Returns a localized, identifier-free message for the explicit sensor move
/// flow. This intentionally maps the closed failure kind instead of exposing
/// driver-provided diagnostic text, so the app remains localized even if that
/// text changes.
String userMessageForBondTransferFailure(
  CgmBondTransferException failure, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (failure.kind) {
    CgmBondTransferFailureKind.unsupportedPlatform => _localized(
      language,
      'Moving a sensor is available only on Android.',
      '只有 Android 设备可以将传感器移至另一部手机。',
    ),
    CgmBondTransferFailureKind.sessionNotReady => _localized(
      language,
      'Connect this phone to the sensor before moving it.',
      '请先将这部手机连接到传感器，再迁移传感器。',
    ),
    CgmBondTransferFailureKind.linkNotAuthenticated => _localized(
      language,
      'The sensor connection is not authenticated.',
      '传感器连接尚未完成身份验证。',
    ),
    CgmBondTransferFailureKind.localBondMissing => _localized(
      language,
      'This phone does not own the active sensor bond.',
      '这部手机不持有传感器的有效蓝牙绑定。',
    ),
    CgmBondTransferFailureKind.bondStateUnavailable => _localized(
      language,
      'Android could not confirm the sensor bond.',
      'Android 无法确认传感器的蓝牙绑定。',
    ),
    CgmBondTransferFailureKind.serviceUnavailable ||
    CgmBondTransferFailureKind.featureUnavailable ||
    CgmBondTransferFailureKind.featureMalformed ||
    CgmBondTransferFailureKind.procedureUnsupported => _localized(
      language,
      'This sensor does not advertise a safe phone-transfer procedure.',
      '该传感器未提供安全的手机迁移流程。',
    ),
    CgmBondTransferFailureKind.authorizationCodeRequired => _localized(
      language,
      'This sensor requires an authorization code that the app does not '
          'have.',
      '该传感器需要应用当前没有的授权码。',
    ),
    CgmBondTransferFailureKind.featureChanged => _localized(
      language,
      'The sensor transfer capability changed. Reopen Settings and try '
          'again.',
      '传感器迁移功能已改变。请重新打开设置后再试。',
    ),
    CgmBondTransferFailureKind.statePersistenceFailed => _localized(
      language,
      'The app could not save the transfer state safely. Do not retry.',
      '应用无法安全保存迁移状态。请勿重试。',
    ),
    CgmBondTransferFailureKind.sensorResponseUnknown => _localized(
      language,
      'The sensor response is unknown. Do not retry. Check Bluetooth '
          'settings.',
      '传感器的响应未知。请勿重试。请检查蓝牙设置。',
    ),
    CgmBondTransferFailureKind.sensorRejected => _localized(
      language,
      'The sensor did not accept the transfer request.',
      '传感器未接受迁移请求。',
    ),
    CgmBondTransferFailureKind.disconnectUnconfirmed => _localized(
      language,
      'The sensor accepted the request, but disconnection was not confirmed. '
          'Do not retry.',
      '传感器已接受请求，但未确认已断开连接。请勿重试。',
    ),
    CgmBondTransferFailureKind.localBondRemovalFailed ||
    CgmBondTransferFailureKind.localBondRemovalUnconfirmed => _localized(
      language,
      'The sensor accepted the request, but Android still has the old bond. '
          'Forget the sensor in Android Bluetooth settings. Do not retry.',
      '传感器已接受请求，但 Android 仍保留旧的绑定。请在 Android 蓝牙设置中忽略此传感器。请勿重试。',
    ),
  };
}

/// Returns the safety-critical, localized message for a persisted interrupted
/// sensor move. [state] is intentionally a closed value written by the app or
/// driver; unknown values receive a cautious generic message.
String interruptedBondTransferText(
  String? state, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (state) {
    'unknown' || 'outcome-unknown' => _localized(
      language,
      'The sensor response to the move is unknown. Do not reconnect, forget '
          'the Android bond, disconnect, or retry. Contact support for a '
          'reviewed recovery.',
      '传感器对迁移的响应未知。请勿重新连接、忽略 Android 绑定、断开连接或重试。请联系支持人员进行审核后的恢复。',
    ),
    'sensor-accepted' => _localized(
      language,
      'The sensor accepted the move, but app cleanup was interrupted. Do not '
          'retry. Check Android Bluetooth settings and forget the old bond if '
          'it is still listed. Then review the move in Settings.',
      '传感器已接受迁移，但应用清理被中断。请勿重试。请检查 Android 蓝牙设置；如仍列出旧绑定，请将其忽略。然后在设置中检查迁移。',
    ),
    _ => _localized(
      language,
      'The sensor move needs review. Do not retry until you check Android '
          'Bluetooth settings.',
      '传感器迁移需要检查。请先检查 Android 蓝牙设置，暂勿重试。',
    ),
  };
}

String? _bondTransferMessageForSnapshot(
  CgmSessionSnapshot snapshot, {
  required AppLanguage language,
}) {
  final diagnostic = snapshot.metadata[cgmBondTransferDiagnosticMetadataKey];
  final failure = switch (diagnostic) {
    'cgm.bond-transfer.android-required' => const CgmBondTransferException(
      CgmBondTransferFailureKind.unsupportedPlatform,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.session-not-ready' => const CgmBondTransferException(
      CgmBondTransferFailureKind.sessionNotReady,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.link-not-authenticated' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.linkNotAuthenticated,
        outcome: CgmBondTransferOutcome.notStarted,
      ),
    'cgm.bond-transfer.local-bond-missing' => const CgmBondTransferException(
      CgmBondTransferFailureKind.localBondMissing,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.bond-state-unavailable' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.bondStateUnavailable,
        outcome: CgmBondTransferOutcome.notStarted,
      ),
    'cgm.bond-transfer.service-unavailable' => const CgmBondTransferException(
      CgmBondTransferFailureKind.serviceUnavailable,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.feature-unavailable' => const CgmBondTransferException(
      CgmBondTransferFailureKind.featureUnavailable,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.feature-malformed' => const CgmBondTransferException(
      CgmBondTransferFailureKind.featureMalformed,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.authorization-code-required' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.authorizationCodeRequired,
        outcome: CgmBondTransferOutcome.notStarted,
      ),
    'cgm.bond-transfer.procedure-unsupported' => const CgmBondTransferException(
      CgmBondTransferFailureKind.procedureUnsupported,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.feature-changed' => const CgmBondTransferException(
      CgmBondTransferFailureKind.featureChanged,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.state-persistence-failed' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.statePersistenceFailed,
        outcome: CgmBondTransferOutcome.notStarted,
      ),
    'cgm.bond-transfer.sensor-response-unknown' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.sensorResponseUnknown,
        outcome: CgmBondTransferOutcome.unknown,
      ),
    'cgm.bond-transfer.sensor-rejected' => const CgmBondTransferException(
      CgmBondTransferFailureKind.sensorRejected,
      outcome: CgmBondTransferOutcome.notStarted,
    ),
    'cgm.bond-transfer.disconnect-unconfirmed' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.disconnectUnconfirmed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      ),
    'cgm.bond-transfer.local-bond-removal-failed' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondRemovalFailed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      ),
    'cgm.bond-transfer.local-bond-removal-unconfirmed' =>
      const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondRemovalUnconfirmed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      ),
    _ => null,
  };
  if (failure != null) {
    return userMessageForBondTransferFailure(failure, language: language);
  }
  if (snapshot.metadata.containsKey(cgmBondTransferStateMetadataKey)) {
    return interruptedBondTransferText(
      snapshot.metadata[cgmBondTransferStateMetadataKey],
      language: language,
    );
  }
  return null;
}

String? primaryErrorTextForSnapshot(
  CgmSessionSnapshot snapshot, {
  AppLanguage language = AppLanguage.english,
}) {
  if (!shouldShowPrimaryError(snapshot)) {
    return null;
  }
  final bleFailure = BleFailure.fromMetadata(snapshot.metadata);
  if (bleFailure != null) {
    return userMessageForBleFailure(bleFailure, language: language);
  }
  return _bondTransferMessageForSnapshot(snapshot, language: language) ??
      safeOperationFailureText('Connection', language: language);
}

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

String? userMessageForBleError(
  Object error, {
  AppLanguage language = AppLanguage.english,
}) {
  return error is BleFailure
      ? userMessageForBleFailure(error, language: language)
      : null;
}

String userMessageForBleFailure(
  BleFailure failure, {
  AppLanguage language = AppLanguage.english,
}) {
  return switch (failure.kind) {
    BleFailureKind.permissionRequired => _localized(
      language,
      'OpenGlucose needs Bluetooth access. In your phone settings, allow '
          'Bluetooth and any nearby-device permissions requested by the app. '
          'Some phones also require Location to be allowed and turned on for '
          'scanning. Then try again.',
      'OpenGlucose 需要蓝牙访问权限。请在手机设置中允许蓝牙及应用请求的附近设备权限。部分手机还需要允许并开启定位服务才能扫描。然后重试。',
    ),
    BleFailureKind.bluetoothOff => _localized(
      language,
      "Bluetooth is off. Turn it on in your phone's quick settings or "
          'Settings, then try scanning again.',
      '蓝牙已关闭。请在手机快捷设置或设置中打开蓝牙，然后重新扫描。',
    ),
    BleFailureKind.bluetoothUnavailable => _localized(
      language,
      'Bluetooth is not available on this phone right now. Restart Bluetooth '
          'or the phone, then try again.',
      '此手机当前无法使用蓝牙。请重启蓝牙或手机后再试。',
    ),
    BleFailureKind.bondRejected => _localized(
      language,
      'The phone did not complete pairing. Keep it close and accept the '
          'pairing prompt. If this sensor is already bonded or connected to '
          'another phone, stop that connection before trying again. Do not '
          'reset an active sensor.',
      '手机未完成配对。请将手机靠近传感器，并接受系统配对提示。若此传感器已与另一部手机绑定或连接，'
          '请先停止另一部手机上的连接，再重试。请勿重置正在使用的传感器。',
    ),
    BleFailureKind.bondTimedOut => _localized(
      language,
      'Pairing timed out. Keep the phone close and accept the system pairing '
          'prompt. If another phone is using this sensor, stop that connection '
          'before trying again.',
      '配对超时。请将手机靠近传感器，并接受系统配对提示。如果另一部手机正在使用此传感器，'
          '请先停止该连接后再试。',
    ),
    BleFailureKind.sensorPossiblyInUse => _localized(
      language,
      'The sensor became unavailable during setup. It may be out of range or '
          'already bonded or connected to another phone. Keep it close and '
          'stop the other connection, if applicable, before trying again. Do '
          'not reset an active sensor.',
      '传感器在设置过程中变得不可用。它可能超出范围，或已与另一部手机绑定或连接。请将手机靠近传感器，'
          '如有需要请停止另一部手机上的连接后再试。请勿重置正在使用的传感器。',
    ),
    BleFailureKind.deviceDisconnected => _localized(
      language,
      'The sensor disconnected. Keep the phone close and try again.',
      '传感器已断开连接。请将手机靠近传感器，然后重试。',
    ),
    BleFailureKind.operationTimedOut => _localized(
      language,
      'Bluetooth setup timed out. Keep the phone close and try again.',
      '蓝牙设置超时。请将手机靠近传感器，然后重试。',
    ),
    BleFailureKind.unexpected => _localized(
      language,
      'Bluetooth setup could not be completed. Restart Bluetooth and try '
          'again.',
      '无法完成蓝牙设置。请重启蓝牙后再试。',
    ),
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
