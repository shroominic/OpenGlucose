import 'dart:convert';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/persistence/cbio_history_state.dart';

void main() {
  const reading = CgmReading(
    valueMgdl: 6,
    source: CgmRecordSource.raw,
    sensorMinute: 2,
    rawValue: 60,
    isDisplayProvisional: true,
  );
  final checkpoint = const CbioSessionCheckpoint(
    sensorKey: 'synthetic',
    index: 2,
    rawTime: 1000,
  ).encode();
  final envelope = <String, Object>{
    'schemaVersion': 1,
    'driverId': 'cbio',
    'storageKey': 'synthetic',
    'checkpoint': checkpoint,
    'history': [reading.toJson()],
  };

  test('atomic state round trip preserves raw data and exact checkpoint', () {
    final state = CbioHistoryState.decode(
      jsonEncode(envelope),
      sensorKey: 'synthetic',
    );
    expect(state.checkpoint, checkpoint);
    expect(state.history.single.rawValue, 60);
    expect(state.history.single.recordedAt, isNull);
    expect(jsonDecode(state.encode()), envelope);
  });

  for (final patch in <Map<String, Object>>[
    {'schemaVersion': 2},
    {'schemaVersion': 1.0},
    {'storageKey': 'foreign'},
    {'driverId': 'aidex'},
    {'checkpoint': '{'},
    {'history': []},
    {
      'history': [reading.toJson(), reading.toJson()],
    },
    {
      'history': [
        {...reading.toJson(), 'isDisplayProvisional': false},
      ],
    },
    {
      'history': [
        {...reading.toJson(), 'sensorMinute': 3},
      ],
    },
    {
      'history': [
        {...reading.toJson(), 'recordedAt': 'bad-date'},
      ],
    },
  ]) {
    test('rejects incompatible archive patch $patch', () {
      expect(
        () => CbioHistoryState.decode(
          jsonEncode({...envelope, ...patch}),
          sensorKey: 'synthetic',
        ),
        throwsFormatException,
      );
    });
  }

  test('only explicit exact driver proof admits a restored suffix', () {
    for (final metadata in <Map<String, String>>[
      {},
      {cbioCheckpointMetadataKey: checkpoint},
      {cbioResumeStatusMetadataKey: CbioResumeStatus.pending},
      {cbioResumeStatusMetadataKey: CbioResumeStatus.fresh},
      {
        cbioResumeStatusMetadataKey: CbioResumeStatus.failed,
        cbioConfirmedCheckpointMetadataKey: checkpoint,
      },
      {
        cbioResumeStatusMetadataKey: CbioResumeStatus.confirmed,
        cbioConfirmedCheckpointMetadataKey: 'another-checkpoint',
      },
    ]) {
      expect(CbioHistoryState.acceptsSnapshot(metadata, checkpoint), isFalse);
    }
    expect(
      CbioHistoryState.acceptsSnapshot({
        cbioResumeStatusMetadataKey: CbioResumeStatus.confirmed,
        cbioConfirmedCheckpointMetadataKey: checkpoint,
      }, checkpoint),
      isTrue,
    );
  });
}
