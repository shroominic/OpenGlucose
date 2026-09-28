/// Versioned, sensor-bound resume evidence. This is restricted device/health
/// state: hosts must persist it atomically with the associated archive, exclude
/// it from backups/logs, and restore it before opening the next session.
library;

import 'dart:convert';

import 'cbio_index_time_anchor.dart';

const String cbioCheckpointMetadataKey = 'cgm.cbio.checkpoint';
const String cbioLifecycleMetadataKey = 'cgm.cbio.lifecycle';
const String cbioResumeStatusMetadataKey = 'cgm.cbio.resume.status';
const String cbioConfirmedCheckpointMetadataKey =
    'cgm.cbio.resume.confirmedCheckpoint';

abstract final class CbioResumeStatus {
  static const fresh = 'fresh';
  static const pending = 'pending';
  static const confirmed = 'confirmed';
  static const failed = 'failed';
}

/// A witness is evidence for one counter era, not an activation timestamp.
/// The session must read this exact position again before accepting a suffix.
final class CbioSessionCheckpoint {
  const CbioSessionCheckpoint({
    required this.sensorKey,
    required this.index,
    required this.rawTime,
    this.anchor,
  });

  final String sensorKey;
  final int index;
  final int rawTime;
  final CbioIndexTimeAnchor? anchor;

  String encode() => jsonEncode({
    'version': 1,
    'sensorKey': sensorKey,
    'index': index,
    'rawTime': rawTime,
    if (anchor != null) 'anchor': anchor!.toMetadata(),
  });

  /// Rejects interrupted, foreign, unsupported, or inconsistent checkpoints.
  /// Never drops bad state and silently begins another counter era.
  static CbioSessionCheckpoint? decode(String encoded, String sensorKey) {
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['version'] is! int ||
          value['version'] != 1 ||
          sensorKey.isEmpty ||
          value['sensorKey'] != sensorKey) {
        return null;
      }
      final index = value['index'];
      final rawTime = value['rawTime'];
      if (index is! int ||
          index < 1 ||
          index > 0xffff ||
          rawTime is! int ||
          rawTime < 0 ||
          rawTime > 0xffffffff) {
        return null;
      }
      CbioIndexTimeAnchor? anchor;
      if (value.containsKey('anchor')) {
        final fields = value['anchor'];
        if (fields is! Map<String, dynamic> ||
            fields.values.any((value) => value is! String)) {
          return null;
        }
        final metadata = fields.cast<String, String>();
        if (metadata[cbioAnchorSourceMetadataKey] !=
            CbioAnchorSource.appSetSensorClock) {
          return null;
        }
        final observed = DateTime.tryParse(
          metadata[cbioAnchorObservedAtMetadataKey] ?? '',
        );
        final from = int.tryParse(
          metadata[cbioAnchorCoveredFromMetadataKey] ?? '',
        );
        final reference = int.tryParse(
          metadata[cbioClockReferenceEpochMetadataKey] ?? '',
        );
        anchor = CbioIndexTimeAnchor.fromMetadata(metadata);
        if (anchor == null ||
            observed == null ||
            !observed.isUtc ||
            from == null ||
            from < 1 ||
            from > anchor.anchorIndex ||
            reference == null ||
            reference <= 0 ||
            reference > 0xffffffff ||
            anchor.source != CbioAnchorSource.appSetSensorClock ||
            anchor.anchorIndex < 1 ||
            anchor.anchorIndex > index ||
            anchor.anchorEpochSeconds <= 0 ||
            anchor.anchorEpochSeconds > 0xffffffff ||
            anchor.timeForIndex(index).millisecondsSinceEpoch ~/ 1000 !=
                rawTime ||
            anchor.clockAgreement.abs() > cbioAnchorTolerance) {
          return null;
        }
      }
      return CbioSessionCheckpoint(
        sensorKey: sensorKey,
        index: index,
        rawTime: rawTime,
        anchor: anchor,
      );
    } on Object {
      return null;
    }
  }
}
