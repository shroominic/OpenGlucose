import 'dart:convert';

import 'cbio_session_checkpoint.dart';
import 'package:cgm_core/cgm_core.dart';

/// Legacy raw-v1 codec used only by private driver persistence.
/// Its CgmReading representation is compatibility storage, not public glucose.
final class CbioHistoryState {
  CbioHistoryState({
    required this.sensorKey,
    required this.checkpoint,
    required List<CgmReading> history,
  }) : history = List.unmodifiable(history) {
    final witness = CbioSessionCheckpoint.decode(checkpoint, sensorKey);
    if (witness == null ||
        history.map((reading) => reading.sensorMinute).toSet().length !=
            history.length ||
        !history.any((reading) => reading.sensorMinute == witness.index) ||
        history.any(
          (reading) =>
              reading.source != CgmRecordSource.raw ||
              !reading.isDisplayProvisional ||
              reading.rawValue == null ||
              reading.sensorMinute == null ||
              reading.sensorMinute! < 1 ||
              reading.sensorMinute! > 0xffff ||
              !reading.valueMgdl.isFinite,
        )) {
      throw const FormatException('CBIO history state is invalid.');
    }
  }

  final String sensorKey;
  final String checkpoint;
  final List<CgmReading> history;

  String encode() => jsonEncode({
    'schemaVersion': 1,
    'driverId': 'cbio',
    'storageKey': sensorKey,
    'checkpoint': checkpoint,
    'history': history.map((reading) => reading.toJson()).toList(),
  });

  factory CbioHistoryState.decode(String encoded, {required String sensorKey}) {
    try {
      final data = jsonDecode(encoded);
      if (data is! Map<String, dynamic> ||
          data['schemaVersion'] is! int ||
          data['schemaVersion'] != 1 ||
          data['driverId'] != 'cbio' ||
          data['storageKey'] != sensorKey ||
          data['checkpoint'] is! String ||
          data['history'] is! List) {
        throw const FormatException();
      }
      final rows = data['history'] as List;
      final history = <CgmReading>[];
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row['sensorMinute'] is! int ||
            row['rawValue'] is! int ||
            row['valueMgdl'] is! num ||
            (row['recordedAt'] != null &&
                (row['recordedAt'] is! String ||
                    DateTime.tryParse(row['recordedAt'] as String) == null))) {
          throw const FormatException();
        }
        history.add(CgmReading.fromJson(row));
      }
      return CbioHistoryState(
        sensorKey: sensorKey,
        checkpoint: data['checkpoint'] as String,
        history: history,
      );
    } on Object {
      throw const FormatException('CBIO history state is invalid.');
    }
  }

  /// Only the driver can produce witness-confirmed proof. A merely present
  /// checkpoint or coincident index is not enough to merge counter eras.
  static bool acceptsSnapshot(
    Map<String, String> metadata,
    String? inputCheckpoint,
  ) {
    if (inputCheckpoint == null) {
      return metadata[cbioResumeStatusMetadataKey] == CbioResumeStatus.fresh &&
          !metadata.containsKey(cbioConfirmedCheckpointMetadataKey);
    }
    return metadata[cbioResumeStatusMetadataKey] ==
            CbioResumeStatus.confirmed &&
        metadata[cbioConfirmedCheckpointMetadataKey] == inputCheckpoint;
  }
}
