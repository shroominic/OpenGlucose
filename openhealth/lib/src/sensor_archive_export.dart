import 'package:cgm_core/cgm_core.dart';

import 'sensor_archive.dart';

/// Column names for the stable archived-sensor CSV interchange format.
///
/// Session timing is deliberately repeated on every reading row. A CSV can be
/// filtered or concatenated without exposing stable sensor/device identifiers.
const archivedSensorCsvColumns = <String>[
  'archive_reason',
  'session_started_at_utc',
  'session_ended_at_utc',
  'last_reading_at_utc',
  'archived_reading_count',
  'recorded_at_utc',
  'glucose_mg_dl',
  'glucose_mmol_l',
  'source',
  'sensor_minute',
  'raw_value',
  'qualifier',
  'provisional',
];

/// Builds an RFC 4180 CSV containing one archived sensor session.
///
/// Readings are exported in chronological order. Untimestamped readings are
/// placed last in their original order so no raw sensor record is discarded.
/// An archive with no readings still emits one metadata-only row.
String buildArchivedSensorCsv({
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) {
  final indexedReadings = readings.indexed.toList(growable: false)
    ..sort((left, right) {
      final leftAt = left.$2.recordedAt;
      final rightAt = right.$2.recordedAt;
      if (leftAt == null && rightAt != null) {
        return 1;
      }
      if (leftAt != null && rightAt == null) {
        return -1;
      }
      if (leftAt != null && rightAt != null) {
        final timestampOrder = leftAt.compareTo(rightAt);
        if (timestampOrder != 0) {
          return timestampOrder;
        }
      }
      return left.$1.compareTo(right.$1);
    });

  final rows = <List<String>>[
    archivedSensorCsvColumns,
    if (indexedReadings.isEmpty) _rowFor(session, null),
    for (final indexedReading in indexedReadings)
      _rowFor(session, indexedReading.$2),
  ];
  return '${rows.map(_encodeCsvRow).join('\r\n')}\r\n';
}

/// Returns a neutral filename that reveals no sensor identity or timestamps.
String archivedSensorCsvFilename() => 'openglucose-glucose-data.csv';

List<String> _rowFor(
  ArchivedSensorSession session,
  CgmReading? reading,
) => <String>[
  _safeText(session.reason.name),
  _utcTimestamp(session.startedAt),
  _utcTimestamp(session.endedAt),
  _utcTimestamp(session.lastReadingAt),
  session.readingCount.toString(),
  _utcTimestamp(reading?.recordedAt),
  if (reading == null) '' else _decimal(reading.valueMgdl),
  if (reading == null) '' else (reading.valueMgdl / 18).toStringAsFixed(3),
  _safeText(reading?.source.name ?? ''),
  reading?.sensorMinute?.toString() ?? '',
  reading?.rawValue?.toString() ?? '',
  reading?.qualifier?.toString() ?? '',
  reading?.isDisplayProvisional.toString() ?? '',
];

/// Stops spreadsheet applications from evaluating exported labels as formulas.
/// Numeric measurement columns remain numeric.
String _safeText(String value) {
  if (!RegExp(r'^[\x00-\x20]*[=+\-@]').hasMatch(value)) {
    return value;
  }
  return "'$value";
}

String _utcTimestamp(DateTime? value) => value?.toUtc().toIso8601String() ?? '';

String _decimal(double value) {
  if (!value.isFinite) {
    return value.toString();
  }
  return value == value.truncateToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}

String _encodeCsvRow(List<String> fields) => fields.map(_escapeCsv).join(',');

String _escapeCsv(String value) {
  if (!value.contains(RegExp(r'[,"\r\n]'))) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}
