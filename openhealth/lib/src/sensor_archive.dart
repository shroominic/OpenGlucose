import 'package:cgm_core/cgm_core.dart';

/// Why a sensor stopped being the active sensor.
enum SensorArchiveReason {
  expired,
  replaced,
  disconnected
  ;

  static SensorArchiveReason fromJson(Object? value) {
    return SensorArchiveReason.values.firstWhere(
      (reason) => reason.name == value,
      orElse: () => SensorArchiveReason.disconnected,
    );
  }
}

/// Durable metadata for a previous sensor session.
///
/// Reading values remain in the restricted per-sensor history record. This
/// manifest only makes those records discoverable after the active sensor has
/// been cleared or replaced.
class ArchivedSensorSession {
  const ArchivedSensorSession({
    required this.id,
    required this.historyKey,
    required this.storageKey,
    required this.driverId,
    required this.deviceId,
    required this.displayName,
    required this.reason,
    required this.readingCount,
    this.serial = '',
    this.model = '',
    this.firmware = '',
    this.startedAt,
    this.endedAt,
    this.lastReadingAt,
  });

  /// Stable identity for one physical sensor session. This deliberately
  /// includes session timing so two sessions using the same hardware/storage
  /// key remain separate archive entries.
  final String id;

  /// Restricted-state key containing the immutable reading snapshot for this
  /// archived session.
  final String historyKey;
  final String storageKey;
  final String driverId;
  final String deviceId;
  final String displayName;
  final String serial;
  final String model;
  final String firmware;
  final SensorArchiveReason reason;
  final int readingCount;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final DateTime? lastReadingAt;

  bool get hasReadings => readingCount > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'historyKey': historyKey,
    'storageKey': storageKey,
    'driverId': driverId,
    'deviceId': deviceId,
    'displayName': displayName,
    'serial': serial,
    'model': model,
    'firmware': firmware,
    'reason': reason.name,
    'readingCount': readingCount,
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'lastReadingAt': lastReadingAt?.toUtc().toIso8601String(),
  };

  factory ArchivedSensorSession.fromJson(Map<String, Object?> json) {
    final storageKey = json['storageKey'] as String? ?? '';
    final startedAt = _date(json['startedAt']);
    final endedAt = _date(json['endedAt']);
    final lastReadingAt = _date(json['lastReadingAt']);
    final legacyIdentityAt = startedAt ?? lastReadingAt ?? endedAt;
    return ArchivedSensorSession(
      id:
          json['id'] as String? ??
          'legacy:$storageKey:${legacyIdentityAt?.toUtc().millisecondsSinceEpoch ?? 0}',
      historyKey:
          json['historyKey'] as String? ?? 'openHealth.history.$storageKey',
      storageKey: storageKey,
      driverId: json['driverId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'Sensor',
      serial: json['serial'] as String? ?? '',
      model: json['model'] as String? ?? '',
      firmware: json['firmware'] as String? ?? '',
      reason: SensorArchiveReason.fromJson(json['reason']),
      readingCount: (json['readingCount'] as num?)?.toInt() ?? 0,
      startedAt: startedAt,
      endedAt: endedAt,
      lastReadingAt: lastReadingAt,
    );
  }

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value)?.toLocal();
  }
}

/// Best-effort session start reconstruction for data saved before the archive
/// manifest existed. A timestamped reading with a sensor-minute offset gives
/// an exact-enough insertion time for lifecycle/expiry decisions.
DateTime? inferSensorStart(List<CgmReading> readings) {
  for (final reading in readings.reversed) {
    final recordedAt = reading.recordedAt;
    final sensorMinute = reading.sensorMinute;
    if (recordedAt != null && sensorMinute != null && sensorMinute >= 0) {
      return recordedAt.subtract(Duration(minutes: sensorMinute));
    }
  }
  return null;
}

DateTime? latestReadingTime(List<CgmReading> readings) {
  DateTime? latest;
  for (final reading in readings) {
    final at = reading.recordedAt;
    if (at != null && (latest == null || at.isAfter(latest))) {
      latest = at;
    }
  }
  return latest;
}
