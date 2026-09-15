import 'package:cgm_core/cgm_core.dart';

import 'libre_nfc_history.dart';
import 'sensor_archive.dart';

/// Immutable, isolate-sendable export input, not storage or sensor authority.
///
/// Legacy data keeps the existing interchange format. Acquisition-bearing
/// archives retain each reading and its evidence as one entry. The repository
/// must first validate the exact manifest reference and its stored envelope;
/// this value's consistency checks do not establish that ownership.
final class ArchivedSensorExportData {
  ArchivedSensorExportData.legacy({
    required ArchivedSensorSession session,
    required List<CgmReading> readings,
  }) : session = _copySession(session),
       readings = List<CgmReading>.unmodifiable(readings.map(_copyReading)),
       _acquisitionEntries = null;

  factory ArchivedSensorExportData.libreHistory({
    required ArchivedSensorSession session,
    required List<LibreHistoryEntry> entries,
  }) {
    final retainedSession = _copySession(session);
    final retained = List<LibreHistoryEntry>.unmodifiable([
      for (final entry in entries)
        LibreHistoryEntry(
          reading: _copyReading(entry.reading),
          origin: entry.origin,
          firstReceivedAt: entry.firstReceivedAt,
          timestampBasis: entry.timestampBasis,
        ),
    ]);
    if (retainedSession.driverId != 'libre2-gen1' ||
        retainedSession.readingCount != retained.length) {
      _invalidEvidence();
    }
    final identities = <String>{};
    for (final entry in retained) {
      _validateEntry(entry);
      final reading = entry.reading;
      final identity = reading.sensorMinute == null
          ? 'time:${reading.recordedAt?.toUtc().toIso8601String()}:${reading.source.name}'
          : 'minute:${reading.sensorMinute}:${reading.source.name}';
      if (!identities.add(identity)) _invalidEvidence();
    }
    return ArchivedSensorExportData._libre(retainedSession, retained);
  }

  ArchivedSensorExportData._libre(this.session, this._acquisitionEntries)
    : readings = List<CgmReading>.unmodifiable(
        _acquisitionEntries!.map((entry) => entry.reading),
      );

  final ArchivedSensorSession session;
  final List<CgmReading> readings;
  final List<LibreHistoryEntry>? _acquisitionEntries;

  bool get hasAcquisitionEvidence => _acquisitionEntries != null;

  /// Null means the legacy interchange format, not failed provenance parsing.
  /// Sort these entries as units; do not join evidence to [readings] by index.
  List<LibreHistoryEntry>? get acquisitionEntries => _acquisitionEntries;

  @override
  String toString() => 'ArchivedSensorExportData(data: <redacted>)';
}

void _validateEntry(LibreHistoryEntry entry) {
  final reading = entry.reading;
  final minute = reading.sensorMinute;
  final recordedAt = reading.recordedAt;
  final receipt = entry.firstReceivedAt;
  if (!reading.valueMgdl.isFinite ||
      reading.valueMgdl <= 0 ||
      (minute != null && (minute < 0 || minute > 0xffff))) {
    _invalidEvidence();
  }
  switch (entry.origin) {
    case LibreHistoryOrigin.legacyUnknown:
      if (entry.timestampBasis != LibreHistoryTimestampBasis.legacyUnknown ||
          receipt != null) {
        _invalidEvidence();
      }
    case LibreHistoryOrigin.bleLive:
      if (entry.timestampBasis != LibreHistoryTimestampBasis.phoneReceipt ||
          receipt == null ||
          recordedAt == null ||
          minute == null ||
          !recordedAt.isAtSameMomentAs(receipt)) {
        _invalidEvidence();
      }
    case LibreHistoryOrigin.nfcTrend:
    case LibreHistoryOrigin.nfcHistory:
    case LibreHistoryOrigin.bleTrend:
    case LibreHistoryOrigin.bleHistory:
      if (entry.timestampBasis != LibreHistoryTimestampBasis.sensorRelative ||
          receipt == null ||
          recordedAt == null ||
          minute == null ||
          recordedAt.isAfter(receipt) ||
          reading.source != CgmRecordSource.vendor ||
          !reading.isDisplayProvisional) {
        _invalidEvidence();
      }
      final offset = receipt.difference(recordedAt).inMicroseconds;
      if (offset % Duration.microsecondsPerMinute != 0 ||
          minute + offset ~/ Duration.microsecondsPerMinute > 0xffff) {
        _invalidEvidence();
      }
      if (entry.origin == LibreHistoryOrigin.bleTrend ||
          entry.origin == LibreHistoryOrigin.bleHistory) {
        final delta = offset ~/ Duration.microsecondsPerMinute;
        final packetMinute = minute + delta;
        // Historical BLE slots use the original packet receipt, not a new
        // export receipt. Their two-minute history delay differs from NFC.
        if (minute < 60) _invalidEvidence();
        if (entry.origin == LibreHistoryOrigin.bleTrend) {
          if (!const {2, 4, 6, 7, 12, 15}.contains(delta)) {
            _invalidEvidence();
          }
        } else {
          final newest = ((packetMinute - 2) ~/ 15) * 15;
          if (minute % 15 != 0 ||
              !const {0, 15, 30}.contains(newest - minute)) {
            _invalidEvidence();
          }
        }
      }
  }
}

Never _invalidEvidence() =>
    throw StateError('Archived sensor acquisition evidence is unavailable.');

CgmReading _copyReading(CgmReading reading) => CgmReading(
  valueMgdl: reading.valueMgdl,
  source: reading.source,
  sensorMinute: reading.sensorMinute,
  recordedAt: reading.recordedAt,
  rawValue: reading.rawValue,
  qualifier: reading.qualifier,
  isDisplayProvisional: reading.isDisplayProvisional,
);

ArchivedSensorSession _copySession(ArchivedSensorSession session) =>
    ArchivedSensorSession(
      id: session.id,
      historyKey: session.historyKey,
      storageKey: session.storageKey,
      driverId: session.driverId,
      deviceId: session.deviceId,
      displayName: session.displayName,
      reason: session.reason,
      readingCount: session.readingCount,
      warmupMinutes: session.warmupMinutes,
      serial: session.serial,
      model: session.model,
      firmware: session.firmware,
      sensorVariant: session.sensorVariant,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      lastReadingAt: session.lastReadingAt,
    );
