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
    this.warmupMinutes,
    this.serial = '',
    this.model = '',
    this.firmware = '',
    this.sensorVariant,
    this.startedAt,
    this.endedAt,
    this.lastReadingAt,
  });

  /// Stable identity for one retained archive entry. Ordinary drivers include
  /// physical-session timing. Libre entries are immutable observation segments
  /// within one bootstrap; their opaque collision discriminator does not prove
  /// activation time or a new physical sensor session.
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

  /// Historical identification only; this does not authorize a new connection.
  final CgmSensorVariant? sensorVariant;
  final SensorArchiveReason reason;
  final int readingCount;

  /// Reported warmup for this archived segment, retained without a live driver.
  /// Null denotes an older record; the app resolves its compatibility profile.
  final int? warmupMinutes;
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
    if (sensorVariant != null) 'sensorVariant': sensorVariant!.toJson(),
    'reason': reason.name,
    'readingCount': readingCount,
    if (warmupMinutes != null) 'warmupMinutes': warmupMinutes,
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
      sensorVariant: switch (json['sensorVariant']) {
        final Map<String, Object?> value => CgmSensorVariant.fromJson(value),
        _ => null,
      },
      reason: SensorArchiveReason.fromJson(json['reason']),
      readingCount: (json['readingCount'] as num?)?.toInt() ?? 0,
      warmupMinutes: switch (json['warmupMinutes']) {
        final int value when value >= 0 => value,
        _ => null,
      },
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
