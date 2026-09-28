import 'dart:io';

import 'package:cgm_cbio/src/cbio_full_record_owner.dart';
import 'package:cgm_cbio/src/cbio_history_archive.dart';
import 'package:cgm_cbio/src/cbio_private_state.dart';
import 'package:cgm_cbio/src/cbio_session_checkpoint.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'usage: emit_full_record_fixture.dart <sensor-key> <output.json>',
    );
    exitCode = 64;
    return;
  }

  final sensorKey = arguments[0];
  final output = File(arguments[1]);
  final store = _FixtureStore();
  final owner = await CbioFullRecordOwner.load(sensorKey, store);
  await owner.adopt();
  owner.accept(
    const <CbioRawGlucoseRecord>[
      CbioRawGlucoseRecord(
        index: 1,
        rawTime: 120,
        reindex: 9,
        rawTemperature: 321,
        rawDump: 7,
        rawPayload: 432,
        rawProcessed: 5,
      ),
      CbioRawGlucoseRecord(
        index: 2,
        rawTime: 180,
        reindex: 9,
        rawTemperature: 322,
        rawDump: 8,
        rawPayload: 433,
        rawProcessed: 5,
      ),
      CbioRawGlucoseRecord(
        index: 3,
        rawTime: 240,
        reindex: 9,
        rawTemperature: 323,
        rawDump: 9,
        rawPayload: 434,
        rawProcessed: 5,
      ),
    ],
    admittedInputCheckpoint: '',
    currentCheckpoint: CbioSessionCheckpoint(
      sensorKey: sensorKey,
      index: 3,
      rawTime: 240,
    ).encode(),
  );
  await owner.flush();
  await owner.close();

  final envelope = store.full;
  if (envelope == null) {
    throw StateError('Full-record fixture was not persisted.');
  }
  await output.writeAsString(envelope, flush: true);
}

final class _FixtureStore implements CbioFullRecordStore {
  String? full;

  @override
  Future<String?> read(String sensorKey) async => null;

  @override
  Future<void> write(String sensorKey, String envelope) {
    throw StateError('Legacy fixture writes are forbidden.');
  }

  @override
  Future<String?> readFullRecords(String sensorKey) async => null;

  @override
  Future<void> writeFullRecords(String sensorKey, String envelope) async {
    full = envelope;
  }

  @override
  String legacySha256(String legacyEnvelope) {
    throw StateError('Legacy fixture hashing is forbidden.');
  }
}
