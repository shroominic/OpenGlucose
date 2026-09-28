import 'dart:convert';

import 'cbio_history_archive.dart';
import 'cbio_session_checkpoint.dart';

/// Package-private complete raw observations, never normalized glucose.
final class CbioFullRecordState {
  static const maxRows = 65535;
  static const maxBytes = 4194304;
  static const maxHeaderBytes = 4096;

  CbioFullRecordState._({
    required this.sensorKey,
    required this.captureId,
    this.legacyDigest,
    this.bootstrapCheckpoint,
    this.currentCheckpoint,
    this.records = const [],
  });

  factory CbioFullRecordState.pending({
    required String sensorKey,
    required String captureId,
    String? legacyDigest,
    String? bootstrapCheckpoint,
  }) => CbioFullRecordState._checked(
    sensorKey: sensorKey,
    captureId: captureId,
    legacyDigest: legacyDigest,
    bootstrapCheckpoint: bootstrapCheckpoint,
  );

  factory CbioFullRecordState.decode(
    String value, {
    required String sensorKey,
  }) {
    try {
      _requireBytes(value, maxBytes);
      final json = jsonDecode(value) as Map<String, dynamic>;
      final pending = json['state'] == 'pending';
      _requireKeys(json, {
        'schemaVersion',
        'driverId',
        'profile',
        'sensorKey',
        'captureId',
        'state',
        'bootstrap',
        'records',
        if (!pending) 'firstObservation',
        if (!pending) 'currentCheckpoint',
      });
      if (json['schemaVersion'] is! int ||
          json['schemaVersion'] != 1 ||
          json['driverId'] != 'cbio' ||
          json['profile'] != 'raw08-observed' ||
          json['sensorKey'] != sensorKey ||
          (!pending && json['state'] != 'observing')) {
        throw _invalid();
      }
      _requireBytes(
        jsonEncode(Map.of(json)..remove('records')),
        maxHeaderBytes,
      );
      final bootstrap = json['bootstrap'] as Map<String, dynamic>;
      final legacy = bootstrap['kind'] == 'legacy';
      _requireKeys(bootstrap, {
        'kind',
        if (legacy) 'sha256',
        if (legacy) 'checkpoint',
      });
      if (!legacy && bootstrap['kind'] != 'fresh') throw _invalid();
      final rawRows = json['records'] as List;
      if (rawRows.length > maxRows) throw _invalid();
      for (final rawRow in rawRows) {
        if (rawRow is! List) throw _invalid();
        _requireTuple(rawRow);
      }
      final state = CbioFullRecordState._checked(
        sensorKey: sensorKey,
        captureId: json['captureId'] as String,
        legacyDigest: legacy ? bootstrap['sha256'] as String : null,
        bootstrapCheckpoint: legacy ? bootstrap['checkpoint'] as String : null,
        currentCheckpoint: pending ? null : json['currentCheckpoint'] as String,
        records: [
          for (final dynamic row in rawRows)
            CbioRawGlucoseRecord(
              index: row[0] as int,
              rawTime: row[1] as int,
              reindex: row[2] as int,
              rawTemperature: row[3] as int,
              rawDump: row[4] as int,
              rawPayload: row[5] as int,
              rawProcessed: row[6] as int,
            ),
        ],
      );
      if (!pending) {
        final first = json['firstObservation'];
        if (first is! List ||
            first.length != 2 ||
            first.any((dynamic value) => value is! int) ||
            first[0] != state.records.first.index ||
            first[1] != state.records.first.rawTime) {
          throw _invalid();
        }
      }
      return state;
    } on Object {
      throw _invalid();
    }
  }

  factory CbioFullRecordState._checked({
    required String sensorKey,
    required String captureId,
    String? legacyDigest,
    String? bootstrapCheckpoint,
    String? currentCheckpoint,
    List<CbioRawGlucoseRecord> records = const [],
  }) {
    if (records.length > maxRows) throw _invalid();
    final state = CbioFullRecordState._(
      sensorKey: sensorKey,
      captureId: captureId,
      legacyDigest: legacyDigest,
      bootstrapCheckpoint: bootstrapCheckpoint,
      currentCheckpoint: currentCheckpoint,
      records: List.unmodifiable(records),
    );
    state._validate();
    return state;
  }

  final String sensorKey;
  final String captureId;
  final String? legacyDigest;
  final String? bootstrapCheckpoint;
  final String? currentCheckpoint;
  final List<CbioRawGlucoseRecord> records;
  bool get isPending => currentCheckpoint == null;
  String? get resumeCheckpoint => currentCheckpoint ?? bootstrapCheckpoint;

  CbioFullRecordState observing({
    required List<CbioRawGlucoseRecord> records,
    required String currentCheckpoint,
  }) {
    if (records.length < this.records.length) throw _invalid();
    for (var i = 0; i < this.records.length; i++) {
      final old = _tuple(this.records[i]);
      final next = _tuple(records[i]);
      for (var word = 0; word < old.length; word++) {
        if (old[word] != next[word]) throw _invalid();
      }
    }
    return CbioFullRecordState._checked(
      sensorKey: sensorKey,
      captureId: captureId,
      legacyDigest: legacyDigest,
      bootstrapCheckpoint: bootstrapCheckpoint,
      currentCheckpoint: currentCheckpoint,
      records: records,
    );
  }

  void _validate() {
    if (sensorKey.isEmpty ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(captureId) ||
        ((legacyDigest == null) != (bootstrapCheckpoint == null)) ||
        (legacyDigest != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(legacyDigest!))) {
      throw _invalid();
    }
    final bootstrap = bootstrapCheckpoint == null
        ? null
        : CbioSessionCheckpoint.decode(bootstrapCheckpoint!, sensorKey);
    if (bootstrapCheckpoint != null && bootstrap == null) throw _invalid();
    if (isPending) {
      if (records.isNotEmpty) throw _invalid();
    } else {
      if (records.isEmpty) throw _invalid();
      for (var i = 0; i < records.length; i++) {
        _requireTuple(_tuple(records[i]));
        if (i > 0 && records[i].index != records[i - 1].index + 1) {
          throw _invalid();
        }
      }
      final first = records.first;
      if (bootstrap == null
          ? first.index != 1
          : first.index != bootstrap.index ||
                first.rawTime != bootstrap.rawTime) {
        throw _invalid();
      }
      final current = CbioSessionCheckpoint.decode(
        currentCheckpoint!,
        sensorKey,
      );
      if (current == null ||
          current.index != records.last.index ||
          current.rawTime != records.last.rawTime) {
        throw _invalid();
      }
    }
    _requireBytes(jsonEncode(_header()), maxHeaderBytes);
  }

  Map<String, Object> _header() => {
    'schemaVersion': 1,
    'driverId': 'cbio',
    'profile': 'raw08-observed',
    'sensorKey': sensorKey,
    'captureId': captureId,
    'state': isPending ? 'pending' : 'observing',
    'bootstrap': {
      'kind': legacyDigest == null ? 'fresh' : 'legacy',
      'sha256': ?legacyDigest,
      'checkpoint': ?bootstrapCheckpoint,
    },
    if (!isPending)
      'firstObservation': [records.first.index, records.first.rawTime],
    if (!isPending) 'currentCheckpoint': currentCheckpoint!,
  };

  String encode() {
    final value = jsonEncode({
      ..._header(),
      'records': [for (final row in records) _tuple(row)],
    });
    _requireBytes(value, maxBytes);
    return value;
  }

  static void _requireTuple(List<dynamic> row) {
    if (row.length != 7) throw _invalid();
    for (var i = 0; i < row.length; i++) {
      final value = row[i];
      if (value is! int ||
          value < (i == 0 ? 1 : 0) ||
          value > (i == 1 ? 0xffffffff : 0xffff)) {
        throw _invalid();
      }
    }
  }

  static void _requireKeys(Map<String, dynamic> value, Set<String> keys) {
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      throw _invalid();
    }
  }

  static void _requireBytes(String value, int limit) {
    if (value.length > limit || utf8.encode(value).length > limit) {
      throw _invalid();
    }
  }

  static FormatException _invalid() =>
      const FormatException('CBIO full input state is invalid.');

  static List<int> _tuple(CbioRawGlucoseRecord row) => [
    row.index,
    row.rawTime,
    row.reindex,
    row.rawTemperature,
    row.rawDump,
    row.rawPayload,
    row.rawProcessed,
  ];
}
