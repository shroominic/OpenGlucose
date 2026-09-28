import 'dart:convert';

import 'cbio_full_record_state.dart';

/// One private acquisition boundary. Predecessor bytes stay at original keys;
/// digest references are not evidence of continuity with the fresh observations.
final class CbioRecoveryState {
  static const maxMetadataBytes = 4096;
  static const maxBytes = CbioFullRecordState.maxBytes + maxMetadataBytes;

  CbioRecoveryState({
    required this.sensorKey,
    required this.predecessorFullSha256,
    required this.predecessorLegacySha256,
    required this.active,
  }) {
    if (sensorKey.isEmpty ||
        !_digest(predecessorFullSha256) ||
        (predecessorLegacySha256 != null &&
            !_digest(predecessorLegacySha256!)) ||
        active.sensorKey != sensorKey ||
        active.bootstrapCheckpoint != null ||
        active.legacyDigest != null) {
      throw _invalid();
    }
    _bound(jsonEncode(_metadata()), maxMetadataBytes);
  }

  final String sensorKey;
  final String predecessorFullSha256;
  final String? predecessorLegacySha256;
  final CbioFullRecordState active;

  factory CbioRecoveryState.decode(
    String encoded, {
    required String sensorKey,
  }) {
    try {
      _bound(encoded, maxBytes);
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      const keys = {
        'schemaVersion',
        'driverId',
        'profile',
        'sensorKey',
        'reason',
        'predecessorFullSha256',
        'predecessorLegacySha256',
        'active',
      };
      if (json.length != keys.length ||
          !json.keys.every(keys.contains) ||
          json['schemaVersion'] is! int ||
          json['schemaVersion'] != 1 ||
          json['driverId'] != 'cbio' ||
          json['profile'] != 'raw08-recovery' ||
          json['sensorKey'] != sensorKey ||
          json['reason'] != 'witness-time-mismatch') {
        throw _invalid();
      }
      _bound(jsonEncode(Map.of(json)..remove('active')), maxMetadataBytes);
      return CbioRecoveryState(
        sensorKey: sensorKey,
        predecessorFullSha256: json['predecessorFullSha256'] as String,
        predecessorLegacySha256: json['predecessorLegacySha256'] as String?,
        active: CbioFullRecordState.decode(
          jsonEncode(json['active']),
          sensorKey: sensorKey,
        ),
      );
    } on Object {
      throw _invalid();
    }
  }

  void validatePredecessors({
    required String full,
    required String? legacy,
    required String Function(String) digest,
  }) {
    final predecessor = CbioFullRecordState.decode(full, sensorKey: sensorKey);
    if (predecessor.captureId == active.captureId ||
        digest(full) != predecessorFullSha256 ||
        (legacy == null ? null : digest(legacy)) != predecessorLegacySha256) {
      throw _invalid();
    }
  }

  CbioRecoveryState withActive(CbioFullRecordState value) {
    if (value.captureId != active.captureId) throw _invalid();
    // Enforce the immutable observed prefix even when a caller bypasses owner.
    if (!value.isPending) {
      active.observing(
        records: value.records,
        currentCheckpoint: value.currentCheckpoint!,
      );
    } else if (!active.isPending) {
      throw _invalid();
    }
    return CbioRecoveryState(
      sensorKey: sensorKey,
      predecessorFullSha256: predecessorFullSha256,
      predecessorLegacySha256: predecessorLegacySha256,
      active: value,
    );
  }

  Map<String, Object?> _metadata() => {
    'schemaVersion': 1,
    'driverId': 'cbio',
    'profile': 'raw08-recovery',
    'sensorKey': sensorKey,
    'reason': 'witness-time-mismatch',
    'predecessorFullSha256': predecessorFullSha256,
    'predecessorLegacySha256': predecessorLegacySha256,
  };

  String encode() {
    final encoded = jsonEncode({
      ..._metadata(),
      'active': jsonDecode(active.encode()),
    });
    _bound(encoded, maxBytes);
    return encoded;
  }

  static bool _digest(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  static void _bound(String value, int limit) {
    if (value.length > limit || utf8.encode(value).length > limit) {
      throw _invalid();
    }
  }

  static FormatException _invalid() =>
      const FormatException('CBIO recovery state is invalid.');
}
