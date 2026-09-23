import 'dart:convert';

import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:cgm_cbio/src/cbio_history_archive.dart';
import 'package:test/test.dart';

const _capture = '0123456789abcdef0123456789abcdef';
const _checkpoint =
    '{"version":1,"sensorKey":"synthetic","index":1,"rawTime":120}';

void main() {
  test(
    'roundtrip preserves every full observation rather than payload only',
    () {
      final state =
          CbioFullRecordState.pending(
            sensorKey: 'synthetic',
            captureId: _capture,
          ).observing(
            records: const [
              CbioRawGlucoseRecord(
                index: 1,
                rawTime: 120,
                reindex: 9,
                rawTemperature: 321,
                rawDump: 7,
                rawPayload: 432,
                rawProcessed: 5,
              ),
            ],
            currentCheckpoint: _checkpoint,
          );
      final restored = CbioFullRecordState.decode(
        state.encode(),
        sensorKey: 'synthetic',
      );
      expect(restored.records, hasLength(1));
      final row = restored.records.single;
      expect(
        [
          row.index,
          row.rawTime,
          row.reindex,
          row.rawTemperature,
          row.rawDump,
          row.rawPayload,
          row.rawProcessed,
        ],
        [1, 120, 9, 321, 7, 432, 5],
      );
      expect(restored.resumeCheckpoint, _checkpoint);
      expect(restored.isPending, isFalse);
      expect(jsonDecode(state.encode())['records'], [
        [1, 120, 9, 321, 7, 432, 5],
      ]);
    },
  );

  test('pending keeps bootstrap separate and never fabricates full rows', () {
    final state = CbioFullRecordState.pending(
      sensorKey: 'synthetic',
      captureId: _capture,
      legacyDigest: 'a' * 64,
      bootstrapCheckpoint: _checkpoint,
    );
    final restored = CbioFullRecordState.decode(
      state.encode(),
      sensorKey: 'synthetic',
    );
    expect(restored.isPending, isTrue);
    expect(restored.records, isEmpty);
    expect(restored.currentCheckpoint, isNull);
    expect(restored.resumeCheckpoint, _checkpoint);
  });

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'unknown envelope key': (m) => m['extra'] = true,
    'missing profile': (m) => m.remove('profile'),
    'unsupported schema': (m) => m['schemaVersion'] = 2,
    'schema numeric coercion': (m) => m['schemaVersion'] = 1.0,
    'foreign driver': (m) => m['driverId'] = 'aidex',
    'foreign profile': (m) => m['profile'] = 'calibrated',
    'foreign sensor': (m) => m['sensorKey'] = 'other',
    'empty sensor': (m) => m['sensorKey'] = '',
    'uppercase capture': (m) =>
        m['captureId'] = 'ABCDEF0123456789ABCDEF0123456789',
    'short capture': (m) => m['captureId'] = 'a',
    'unknown state': (m) => m['state'] = 'complete',
    'pending contains observations': (m) => m['state'] = 'pending',
    'empty observing': (m) => m['records'] = <dynamic>[],
    'records missing': (m) => m.remove('records'),
    'rows not list': (m) => m['records'] = {},
    'row too short': (m) => (m['records'][0] as List).removeLast(),
    'row too long': (m) => (m['records'][0] as List).add(4),
    'noninteger word': (m) => m['records'][0][3] = 321.0,
    'negative temperature': (m) => m['records'][0][3] = -1,
    'overflow temperature': (m) => m['records'][0][3] = 65536,
    'zero index': (m) => m['records'][0][0] = 0,
    'overflow index': (m) => m['records'][0][0] = 65536,
    'negative time': (m) => m['records'][0][1] = -1,
    'overflow time': (m) => m['records'][0][1] = 4294967296,
    'negative reindex': (m) => m['records'][0][2] = -1,
    'overflow reindex': (m) => m['records'][0][2] = 65536,
    'negative dump': (m) => m['records'][0][4] = -1,
    'overflow dump': (m) => m['records'][0][4] = 65536,
    'negative payload': (m) => m['records'][0][5] = -1,
    'overflow payload': (m) => m['records'][0][5] = 65536,
    'negative processed': (m) => m['records'][0][6] = -1,
    'overflow processed': (m) => m['records'][0][6] = 65536,
    'first observation mismatch': (m) => m['firstObservation'] = [1, 121],
    'checkpoint absent': (m) => m.remove('currentCheckpoint'),
    'checkpoint not final row': (m) =>
        m['currentCheckpoint'] = _checkpointFor(2, 180),
    'checkpoint time differs': (m) =>
        m['currentCheckpoint'] = _checkpointFor(1, 121),
    'checkpoint foreign binding': (m) =>
        m['currentCheckpoint'] = _checkpoint.replaceAll('synthetic', 'foreign'),
    'checkpoint invalid anchor': (m) => m['currentCheckpoint'] =
        '{"version":1,"sensorKey":"synthetic","index":1,"rawTime":120,"anchor":{}}',
    'bootstrap unknown key': (m) => m['bootstrap']['extra'] = 'value',
    'bootstrap unknown kind': (m) => m['bootstrap']['kind'] = 'guess',
    'legacy missing digest': (m) =>
        m['bootstrap'] = {'kind': 'legacy', 'checkpoint': _checkpoint},
    'legacy bad digest': (m) => m['bootstrap'] = {
      'kind': 'legacy',
      'checkpoint': _checkpoint,
      'sha256': 'bad',
    },
    'legacy missing checkpoint': (m) =>
        m['bootstrap'] = {'kind': 'legacy', 'sha256': 'a' * 64},
    'legacy bootstrap differs from first row': (m) => m['bootstrap'] = {
      'kind': 'legacy',
      'sha256': 'a' * 64,
      'checkpoint': _checkpointFor(2, 180),
    },
    'duplicate indices': (m) => m['records'].add([1, 120, 9, 321, 7, 432, 5]),
    'index gap': (m) {
      m['records'].add([3, 240, 0, 300, 7, 432, 5]);
      m['currentCheckpoint'] = _checkpointFor(3, 240);
    },
    'fresh starts mid-session': (m) {
      m['records'][0][0] = 7;
      m['firstObservation'] = [7, 120];
      m['currentCheckpoint'] = _checkpointFor(7, 120);
    },
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} without returning partially decoded state', () {
      final fixture = _observingJson();
      entry.value(fixture);
      expect(
        () => CbioFullRecordState.decode(
          jsonEncode(fixture),
          sensorKey: 'synthetic',
        ),
        throwsFormatException,
      );
    });
  }

  test(
    'construction rejects invalid identity and mismatched bootstrap pair',
    () {
      expect(
        () => CbioFullRecordState.pending(sensorKey: '', captureId: _capture),
        throwsFormatException,
      );
      expect(
        () =>
            CbioFullRecordState.pending(sensorKey: 'synthetic', captureId: 'a'),
        throwsFormatException,
      );
      expect(
        () => CbioFullRecordState.pending(
          sensorKey: 'synthetic',
          captureId: _capture,
          legacyDigest: 'a' * 64,
        ),
        throwsFormatException,
      );
      expect(
        () => CbioFullRecordState.pending(
          sensorKey: 'synthetic',
          captureId: _capture,
          bootstrapCheckpoint: _checkpoint,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'constructed observations enforce the same constraints as decoded rows',
    () {
      final state = CbioFullRecordState.pending(
        sensorKey: 'synthetic',
        captureId: _capture,
      );
      expect(
        () => state.observing(records: [], currentCheckpoint: _checkpoint),
        throwsFormatException,
      );
      expect(
        () => state.observing(
          records: [_row(1, temperature: -1)],
          currentCheckpoint: _checkpoint,
        ),
        throwsFormatException,
      );
      expect(
        () => state.observing(
          records: [_row(1)],
          currentCheckpoint: _checkpointFor(2, 180),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'input-list mutation cannot change a valid observation or encoded bytes',
    () {
      final rows = [_row(1)];
      final state = CbioFullRecordState.pending(
        sensorKey: 'synthetic',
        captureId: _capture,
      ).observing(records: rows, currentCheckpoint: _checkpoint);
      rows.clear();
      expect(state.records, hasLength(1));
      expect(() => state.records.clear(), throwsUnsupportedError);
      final restored = CbioFullRecordState.decode(
        state.encode(),
        sensorKey: 'synthetic',
      );
      expect(() => restored.records.clear(), throwsUnsupportedError);
    },
  );

  test(
    'existing observation lineage cannot shrink or mutate in replacement',
    () {
      final state =
          CbioFullRecordState.pending(
            sensorKey: 'synthetic',
            captureId: _capture,
          ).observing(
            records: [_row(1), _row(2)],
            currentCheckpoint: _checkpointFor(2, 180),
          );
      expect(
        () =>
            state.observing(records: [_row(1)], currentCheckpoint: _checkpoint),
        throwsFormatException,
      );
      expect(
        () => state.observing(
          records: [_row(1, temperature: 322), _row(2)],
          currentCheckpoint: _checkpointFor(2, 180),
        ),
        throwsFormatException,
      );
    },
  );

  test('accepts exact UTF8 envelope cap but rejects one additional byte', () {
    final encoded = jsonEncode(_observingJson());
    final exact = encoded.padRight(4194304);
    expect(
      CbioFullRecordState.decode(exact, sensorKey: 'synthetic').records,
      hasLength(1),
    );
    expect(
      () => CbioFullRecordState.decode('$exact ', sensorKey: 'synthetic'),
      throwsFormatException,
    );
  });

  test('header cap checks UTF8 bytes not merely character count', () {
    final fixture = _pendingJson();
    final header = Map<String, dynamic>.of(fixture)..remove('records');
    header['sensorKey'] = '';
    final overhead = utf8.encode(jsonEncode(header)).length;
    final exactKey = 'x' * (4096 - overhead);
    fixture['sensorKey'] = exactKey;
    expect(
      CbioFullRecordState.decode(
        jsonEncode(fixture),
        sensorKey: exactKey,
      ).isPending,
      isTrue,
    );
    fixture['sensorKey'] = '$exactKeyé';
    expect(
      () => CbioFullRecordState.decode(
        jsonEncode(fixture),
        sensorKey: '$exactKeyé',
      ),
      throwsFormatException,
    );
  });

  test(
    'entire uint16 index domain fits without eviction and overflow is refused',
    () {
      final fixture = _observingJson();
      fixture['records'] = [
        for (var index = 1; index <= 65535; index++)
          [index, index * 60, 65535, 65535, 65535, 65535, 65535],
      ];
      fixture['firstObservation'] = [1, 60];
      fixture['currentCheckpoint'] = _checkpointFor(65535, 3932100);
      final state = CbioFullRecordState.decode(
        jsonEncode(fixture),
        sensorKey: 'synthetic',
      );
      expect(state.records, hasLength(65535));
      expect(state.records.last.index, 65535);
      expect(utf8.encode(state.encode()).length, lessThanOrEqualTo(4194304));
      fixture['records'].add([65535, 3932100, 0, 0, 0, 0, 0]);
      expect(
        () => CbioFullRecordState.decode(
          jsonEncode(fixture),
          sensorKey: 'synthetic',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'all raw word boundaries and uint32 rawTime survive without scaling',
    () {
      final fixture = _observingJson();
      fixture['records'] = [
        [1, 4294967295, 0, 0, 65535, 0, 65535],
      ];
      fixture['firstObservation'] = [1, 4294967295];
      fixture['currentCheckpoint'] = _checkpointFor(1, 4294967295);
      final state = CbioFullRecordState.decode(
        jsonEncode(fixture),
        sensorKey: 'synthetic',
      );
      expect(jsonDecode(state.encode())['records'], [
        [1, 4294967295, 0, 0, 65535, 0, 65535],
      ]);
    },
  );

  test('malformed input errors never contain the private input text', () {
    try {
      CbioFullRecordState.decode(
        'private-invalid-envelope',
        sensorKey: 'synthetic',
      );
      fail('expected rejection');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('private-invalid-envelope')));
      expect(error.source, isNull);
    }
  });
}

String _checkpointFor(int index, int rawTime) =>
    '{"version":1,"sensorKey":"synthetic","index":$index,"rawTime":$rawTime}';

CbioRawGlucoseRecord _row(int index, {int temperature = 321}) =>
    CbioRawGlucoseRecord(
      index: index,
      rawTime: 60 + index * 60,
      reindex: 9,
      rawTemperature: temperature,
      rawDump: 7,
      rawPayload: 432,
      rawProcessed: 5,
    );

Map<String, dynamic> _pendingJson() => {
  'schemaVersion': 1,
  'driverId': 'cbio',
  'profile': 'raw08-observed',
  'sensorKey': 'synthetic',
  'captureId': _capture,
  'state': 'pending',
  'bootstrap': {'kind': 'fresh'},
  'records': <dynamic>[],
};

Map<String, dynamic> _observingJson() => {
  ..._pendingJson(),
  'state': 'observing',
  'firstObservation': [1, 120],
  'currentCheckpoint': _checkpoint,
  'records': <dynamic>[
    <dynamic>[1, 120, 9, 321, 7, 432, 5],
  ],
};
