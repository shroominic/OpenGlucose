import 'dart:async';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of an attempted Apple Health export so the UI can surface a clear
/// success / failure / skipped state without throwing.
enum HealthExportStatus {
  ok,
  partial,
  notSupported,
  notAuthorized,
  noData,
  failed,
}

class HealthExportResult {
  const HealthExportResult({
    required this.status,
    this.written = 0,
    this.message,
    this.latestReadingAt,
  });

  final HealthExportStatus status;
  final int written;
  final String? message;

  /// Recorded time through which every pending reading was written.
  ///
  /// This is deliberately a contiguous watermark rather than the newest
  /// successful sample. On a partial write it never advances past a failed
  /// timestamp, so the next sync cannot skip data.
  final DateTime? latestReadingAt;

  bool get isSuccess => status == HealthExportStatus.ok;
}

/// Contract for the platform-specific glucose exporter, so the controller can
/// be unit-tested with a fake (the real implementation is iOS/HealthKit-only).
abstract class GlucoseExporter {
  bool get isSupported;
  Future<bool> requestAuthorization();
  Future<HealthExportResult> export(
    List<CgmReading> readings, {
    DateTime? since,
  });
}

/// Exports the app's [CgmReading]s to Apple HealthKit as
/// `HKQuantityTypeIdentifierBloodGlucose` samples.
///
/// Wellness framing only: this writes blood-glucose quantity samples the user
/// has opted into; it makes no medical claims and performs no interpretation.
///
/// HealthKit is iOS-only. On every other platform the methods short-circuit so
/// the Android build is unaffected. The actual write is gated behind explicit
/// user opt-in by the caller (see [HealthExportController]).
class HealthKitExportService implements GlucoseExporter {
  HealthKitExportService({Health? health, bool Function()? supportCheck})
    : _health = health ?? Health(),
      _supportCheck = supportCheck ?? _isRunningOnIOS,
      _configured = false;

  final Health _health;
  final bool Function() _supportCheck;
  bool _configured;

  static const List<HealthDataType> _types = <HealthDataType>[
    HealthDataType.BLOOD_GLUCOSE,
  ];

  static const List<HealthDataAccess> _access = <HealthDataAccess>[
    HealthDataAccess.WRITE,
  ];

  @override
  bool get isSupported => _supportCheck();

  static bool _isRunningOnIOS() => Platform.isIOS;

  Future<void> _ensureConfigured() async {
    if (_configured || !isSupported) {
      return;
    }
    await _health.configure();
    _configured = true;
  }

  /// Triggers the HealthKit authorization sheet (idempotent — Apple only shows
  /// it once per type) and returns whether write access is granted.
  @override
  Future<bool> requestAuthorization() async {
    if (!isSupported) {
      return false;
    }
    await _ensureConfigured();
    final alreadyGranted = await _health.hasPermissions(
      _types,
      permissions: _access,
    );
    if (alreadyGranted ?? false) {
      return true;
    }
    return _health.requestAuthorization(_types, permissions: _access);
  }

  Future<bool> hasAuthorization() async {
    if (!isSupported) {
      return false;
    }
    await _ensureConfigured();
    return (await _health.hasPermissions(_types, permissions: _access)) ??
        false;
  }

  /// Writes [readings] recorded strictly after [since] (if provided) as blood
  /// glucose samples. Readings without a timestamp are skipped, since
  /// HealthKit requires a date for every sample.
  @override
  Future<HealthExportResult> export(
    List<CgmReading> readings, {
    DateTime? since,
  }) async {
    if (!isSupported) {
      return const HealthExportResult(status: HealthExportStatus.notSupported);
    }
    try {
      await _ensureConfigured();
      final authorized = await requestAuthorization();
      if (!authorized) {
        return const HealthExportResult(
          status: HealthExportStatus.notAuthorized,
        );
      }

      final pending = <CgmReading>[];
      for (final reading in readings) {
        final recordedAt = reading.recordedAt;
        if (recordedAt == null) {
          continue;
        }
        if (since != null && !recordedAt.isAfter(since)) {
          continue;
        }
        if (!reading.valueMgdl.isFinite || reading.valueMgdl <= 0) {
          continue;
        }
        pending.add(reading);
      }
      pending.sort(
        (left, right) => left.recordedAt!.compareTo(right.recordedAt!),
      );

      if (pending.isEmpty) {
        return const HealthExportResult(status: HealthExportStatus.noData);
      }

      var written = 0;
      DateTime? contiguousWatermark;
      var index = 0;
      while (index < pending.length) {
        final timestamp = pending[index].recordedAt!;
        var groupEnd = index + 1;
        while (groupEnd < pending.length &&
            pending[groupEnd].recordedAt!.isAtSameMomentAs(timestamp)) {
          groupEnd += 1;
        }

        String? failureMessage;
        for (var groupIndex = index; groupIndex < groupEnd; groupIndex += 1) {
          final reading = pending[groupIndex];
          final recordedAt = reading.recordedAt!.toLocal();
          try {
            // HealthKit blood glucose is stored in mg/dL; the app's canonical
            // value is already mg/dL so no conversion is needed here.
            final ok = await _health.writeHealthData(
              value: reading.valueMgdl,
              type: HealthDataType.BLOOD_GLUCOSE,
              startTime: recordedAt,
              endTime: recordedAt,
              unit: HealthDataUnit.MILLIGRAM_PER_DECILITER,
            );
            if (!ok) {
              failureMessage = 'HealthKit rejected a glucose sample.';
              break;
            }
            written += 1;
          } catch (error, stack) {
            debugPrint('HealthKit export failed: $error\n$stack');
            failureMessage = 'HealthKit write failed: $error';
            break;
          }
        }

        if (failureMessage != null) {
          return HealthExportResult(
            status: written == 0
                ? HealthExportStatus.failed
                : HealthExportStatus.partial,
            written: written,
            latestReadingAt: contiguousWatermark,
            message: failureMessage,
          );
        }

        // Only advance after every reading at this timestamp has succeeded.
        // The persisted cursor has timestamp precision, so advancing midway
        // through a same-time group would silently skip its failed members.
        contiguousWatermark = timestamp;
        index = groupEnd;
      }

      return HealthExportResult(
        status: HealthExportStatus.ok,
        written: written,
        latestReadingAt: contiguousWatermark,
      );
    } catch (error, stack) {
      debugPrint('HealthKit export failed: $error\n$stack');
      return HealthExportResult(
        status: HealthExportStatus.failed,
        message: '$error',
      );
    }
  }
}

/// Persists the user's Apple Health export opt-in and last-sync state, and owns
/// the export flow so the UI stays thin.
class HealthExportController extends ChangeNotifier {
  HealthExportController({
    required SharedPreferences preferences,
    GlucoseExporter? service,
    this.writesAllowed = true,
  }) : _preferences = preferences,
       _service = service ?? HealthKitExportService();

  static const _enabledKey = 'openHealth.healthExport.enabled';
  static const _lastSyncedKey = 'openHealth.healthExport.lastSyncedMs';
  static const _watermarkKey = 'openHealth.healthExport.watermarkMs';

  final SharedPreferences _preferences;
  final GlucoseExporter _service;

  /// Immutable environment gate for builds or drivers that must never write.
  ///
  /// Consent remains a separate, user-controlled gate. Both this flag and the
  /// user's opt-in must be true before authorization or export can occur.
  final bool writesAllowed;

  bool _enabled = false;
  bool _busy = false;
  // Wall-clock time of the last sync attempt (shown in the UI).
  DateTime? _lastSyncedAt;
  // Recorded time of the newest reading already written (incremental cursor).
  DateTime? _watermark;
  String? _statusMessage;

  bool get isSupported => _service.isSupported;
  bool get enabled => _enabled;
  bool get busy => _busy;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get statusMessage => _statusMessage;

  void initialize() {
    _enabled = writesAllowed && (_preferences.getBool(_enabledKey) ?? false);
    final lastMs = _preferences.getInt(_lastSyncedKey);
    if (lastMs != null) {
      _lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }
    final watermarkMs = _preferences.getInt(_watermarkKey);
    if (watermarkMs != null) {
      _watermark = DateTime.fromMillisecondsSinceEpoch(watermarkMs);
    }
  }

  /// Toggles the opt-in. Enabling on iOS triggers the HealthKit auth sheet; if
  /// the user declines, the toggle stays off.
  Future<void> setEnabled({required bool enabled}) async {
    if (_busy) {
      return;
    }
    if (!writesAllowed) {
      _enabled = false;
      _statusMessage = 'Apple Health export is unavailable in this mode.';
      notifyListeners();
      return;
    }
    if (!enabled) {
      _enabled = false;
      _statusMessage = null;
      await _preferences.setBool(_enabledKey, false);
      notifyListeners();
      return;
    }

    if (!_service.isSupported) {
      _statusMessage = 'Apple Health is only available on iOS.';
      notifyListeners();
      return;
    }

    _busy = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final granted = await _service.requestAuthorization();
      _enabled = granted;
      await _preferences.setBool(_enabledKey, granted);
      _statusMessage = granted ? null : 'Apple Health access was not granted.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Runs an export of [readings]. Only writes readings newer than the last
  /// successful sync so repeated taps don't duplicate samples.
  Future<HealthExportResult> syncNow(List<CgmReading> readings) async {
    if (_busy) {
      return const HealthExportResult(status: HealthExportStatus.failed);
    }
    if (!writesAllowed) {
      _statusMessage = 'Apple Health export is unavailable in this mode.';
      notifyListeners();
      return const HealthExportResult(
        status: HealthExportStatus.notAuthorized,
        message: 'Apple Health writes are disabled for this mode.',
      );
    }
    if (!_service.isSupported) {
      _statusMessage = 'Apple Health is only available on iOS.';
      notifyListeners();
      return const HealthExportResult(status: HealthExportStatus.notSupported);
    }
    if (!_enabled) {
      _statusMessage = 'Turn on Apple Health export before syncing.';
      notifyListeners();
      return const HealthExportResult(
        status: HealthExportStatus.notAuthorized,
        message: 'Apple Health export is turned off.',
      );
    }

    _busy = true;
    _statusMessage = null;
    notifyListeners();
    try {
      final result = await _service.export(readings, since: _watermark);
      switch (result.status) {
        case HealthExportStatus.ok:
          _lastSyncedAt = DateTime.now();
          await _persistProgress(result.latestReadingAt);
          _statusMessage = 'Synced ${result.written} reading(s).';
        case HealthExportStatus.partial:
          _lastSyncedAt = DateTime.now();
          await _persistProgress(result.latestReadingAt);
          _statusMessage = result.message == null
              ? 'Synced ${result.written} reading(s), then export stopped.'
              : 'Synced ${result.written} reading(s), then export stopped: '
                    '${result.message}';
        case HealthExportStatus.noData:
          // Nothing new to write counts as an up-to-date sync.
          _lastSyncedAt = DateTime.now();
          await _preferences.setInt(
            _lastSyncedKey,
            _lastSyncedAt!.millisecondsSinceEpoch,
          );
          _statusMessage = 'Already up to date.';
        case HealthExportStatus.notAuthorized:
          _enabled = false;
          await _preferences.setBool(_enabledKey, false);
          _statusMessage = 'Apple Health access was not granted.';
        case HealthExportStatus.notSupported:
          _statusMessage = 'Apple Health is only available on iOS.';
        case HealthExportStatus.failed:
          _statusMessage = result.message ?? 'Export failed.';
      }
      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _persistProgress(DateTime? contiguousWatermark) async {
    if (contiguousWatermark != null) {
      _watermark = contiguousWatermark;
      await _preferences.setInt(
        _watermarkKey,
        _watermark!.millisecondsSinceEpoch,
      );
    }
    await _preferences.setInt(
      _lastSyncedKey,
      _lastSyncedAt!.millisecondsSinceEpoch,
    );
  }
}
