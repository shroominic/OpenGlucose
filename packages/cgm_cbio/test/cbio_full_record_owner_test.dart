import 'dart:async';
import 'dart:convert';

import 'package:cgm_cbio/src/cbio_full_record_owner.dart';
import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:cgm_cbio/src/cbio_private_state.dart';
import 'package:cgm_cbio/src/cbio_history_archive.dart';
import 'package:test/test.dart';

void main() {
  group('one-capsule recovery', () {
    for (final step in ['read', 'write', 'committed-write']) {
      test(
        'close releases clean lease after failed in-flight recovery $step',
        () async {
          final store = _RecoveryStore()..legacy = _legacy;
          final owner = await CbioFullRecordOwner.load('synthetic', store);
          await owner.adopt();
          final original = store.full;
          final gate = Completer<void>();
          store.recoveryStarted = Completer<void>();
          if (step == 'read') {
            store.readRecoveryHold = gate;
          } else {
            store.writeRecoveryHold = gate;
          }
          store.commitThenFail = step == 'committed-write';
          final recoveryFailed = expectLater(
            owner.recoverWitnessMismatch(),
            _storageFailure,
          );
          await store.recoveryStarted!.future;
          final closeFailed = expectLater(owner.close(), _storageFailure);
          if (step == 'committed-write') {
            gate.complete();
          } else {
            gate.completeError(StateError('synthetic transition failure'));
          }
          await recoveryFailed;
          await closeFailed;
          store.readRecoveryHold = store.writeRecoveryHold = null;
          store.commitThenFail = false;
          final selected = store.recovery;
          final replacement = await CbioFullRecordOwner.load(
            'synthetic',
            store,
          );
          await replacement.adopt();
          expect(
            replacement.resumeCheckpoint,
            step == 'committed-write' ? isNull : _checkpoint(3),
          );
          expect(store.recovery, selected);
          expect(store.full, original);
          expect(store.legacy, _legacy);
          await replacement.close();
        },
      );
    }

    test(
      'close retains lease and dirty rows until failed drain can be retried',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        owner.accept(
          [_row(3), _row(4)],
          admittedInputCheckpoint: _checkpoint(3),
          currentCheckpoint: _checkpoint(4),
        );
        final original = store.full;
        store.hold = Completer<void>();
        store.started = Completer<void>();
        store.failWrite = true;
        final recoveryFailed = expectLater(
          owner.recoverWitnessMismatch(),
          _storageFailure,
        );
        await store.started!.future;
        final closeFailed = expectLater(owner.close(), _storageFailure);
        store.hold!.complete();
        await recoveryFailed;
        await closeFailed;
        final replacement = await CbioFullRecordOwner.load('synthetic', store);
        await expectLater(replacement.adopt(), _storageFailure);
        expect(store.full, original);
        expect(store.recovery, isNull);
        store.failWrite = false;
        store.hold = null;
        await owner.close();
        await replacement.adopt();
        expect(replacement.resumeCheckpoint, _checkpoint(4));
        expect(_saved(store).records.map((row) => row.index), [3, 4]);
        expect(store.legacy, _legacy);
        await replacement.close();
      },
    );

    test(
      'stale prepared owner adopts committed recovery rather than overwrite it',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final stale = await CbioFullRecordOwner.load('synthetic', store);
        final first = await CbioFullRecordOwner.load('synthetic', store);
        await first.adopt();
        await expectLater(stale.adopt(), _storageFailure);
        await first.recoverWitnessMismatch();
        final selected = store.recovery;
        await first.close();
        await stale.adopt();
        expect(stale.resumeCheckpoint, isNull);
        expect(stale.canRecoverWitnessMismatch, isFalse);
        expect(store.recovery, selected);
        await stale.close();
      },
    );

    test(
      'commit then reported failure still consumes durable recovery budget',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        final original = store.full;
        store.commitThenFail = true;
        await expectLater(owner.recoverWitnessMismatch(), _storageFailure);
        final selected = store.recovery;
        expect(selected, isNotNull);
        store.commitThenFail = false;
        await expectLater(owner.recoverWitnessMismatch(), _storageFailure);
        await owner.close();
        final restored = await CbioFullRecordOwner.load('synthetic', store);
        await restored.adopt();
        expect(restored.canRecoverWitnessMismatch, isFalse);
        expect(restored.resumeCheckpoint, isNull);
        expect(store.recovery, selected);
        expect(store.full, original);
        await restored.close();
      },
    );

    test('changed legacy bytes before transition forbid recovery', () async {
      final store = _RecoveryStore()..legacy = _legacy;
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      final original = store.full;
      store.legacy = '$_legacy ';
      await expectLater(owner.recoverWitnessMismatch(), _storageFailure);
      expect(store.recovery, isNull);
      expect(store.full, original);
      await owner.close();
    });

    test(
      'existing observing inputs remain frozen and fresh capture never inherits them',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        owner.accept(
          [_row(3), _row(4)],
          admittedInputCheckpoint: _checkpoint(3),
          currentCheckpoint: _checkpoint(4),
        );
        await owner.flush();
        final original = store.full;
        await owner.recoverWitnessMismatch();
        expect(owner.resumeCheckpoint, isNull);
        expect(
          () => owner.accept(
            [_row(2)],
            admittedInputCheckpoint: '',
            currentCheckpoint: _checkpoint(2),
          ),
          throwsFormatException,
        );
        owner.accept(
          [_row(1)],
          admittedInputCheckpoint: '',
          currentCheckpoint: _checkpoint(1),
        );
        await owner.close();
        expect(store.full, original);
        expect(store.legacy, _legacy);
      },
    );

    test(
      'pending selection retains originals and consumes budget across restart',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        final original = store.full;
        expect(owner.canRecoverWitnessMismatch, isTrue);
        await owner.recoverWitnessMismatch();
        final pending = store.recovery;
        expect(pending, isNotNull);
        expect(store.full, original);
        expect(store.legacy, _legacy);
        expect(owner.resumeCheckpoint, isNull);
        expect(owner.canRecoverWitnessMismatch, isFalse);
        await owner.close();
        final restored = await CbioFullRecordOwner.load('synthetic', store);
        await restored.adopt();
        expect(store.recovery, pending);
        expect(restored.resumeCheckpoint, isNull);
        await expectLater(restored.recoverWitnessMismatch(), _storageFailure);
        restored.accept(
          [_row(1), _row(2)],
          admittedInputCheckpoint: '',
          currentCheckpoint: _checkpoint(2),
        );
        await restored.close();
        expect(store.full, original);
        expect(store.legacy, _legacy);
        final capsule = jsonDecode(store.recovery!) as Map<String, dynamic>;
        expect(capsule['predecessorFullSha256'], store.legacySha256(original!));
        expect(capsule['predecessorLegacySha256'], store.legacySha256(_legacy));
        expect(capsule.containsKey('predecessorFull'), isFalse);
        expect(capsule.containsKey('predecessorLegacy'), isFalse);
        final fresh = CbioFullRecordState.decode(
          jsonEncode(capsule['active']),
          sensorKey: 'synthetic',
        );
        expect(fresh.records.map((row) => row.index), [1, 2]);
        expect(fresh.bootstrapCheckpoint, isNull);
        expect(fresh.legacyDigest, isNull);
        final resumed = await CbioFullRecordOwner.load('synthetic', store);
        expect(resumed.resumeCheckpoint, _checkpoint(2));
      },
    );

    test(
      'failed recovery write preserves original authority and can be retried',
      () async {
        final store = _RecoveryStore()..legacy = _legacy;
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        final original = store.full;
        store.failRecovery = true;
        await expectLater(owner.recoverWitnessMismatch(), _storageFailure);
        expect(store.recovery, isNull);
        expect(store.full, original);
        expect(owner.resumeCheckpoint, _checkpoint(3));
        store.failRecovery = false;
        await owner.recoverWitnessMismatch();
        await owner.close();
      },
    );

    for (final altered in ['legacy', 'full', 'capsule']) {
      test(
        'altered $altered fails closed without replacing evidence',
        () async {
          final store = _RecoveryStore()..legacy = _legacy;
          final owner = await CbioFullRecordOwner.load('synthetic', store);
          await owner.adopt();
          await owner.recoverWitnessMismatch();
          await owner.close();
          if (altered == 'legacy') store.legacy = '$_legacy ';
          if (altered == 'full') store.full = '${store.full} ';
          if (altered == 'capsule') store.recovery = '{}';
          final original = [store.legacy, store.full, store.recovery];
          await expectLater(
            CbioFullRecordOwner.load('synthetic', store),
            _storageFailure,
          );
          expect([store.legacy, store.full, store.recovery], original);
        },
      );
    }

    test('legacy full-only store cannot allocate recovery', () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      expect(owner.canRecoverWitnessMismatch, isFalse);
      await expectLater(owner.recoverWitnessMismatch(), _storageFailure);
      await owner.close();
    });
  });

  test(
    'load is read-only and adoption durably reserves private pending state',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      expect(store.full, isNull);
      await owner.adopt();
      expect(store.full, isNotNull);
      final saved = CbioFullRecordState.decode(
        store.full!,
        sensorKey: 'synthetic',
      );
      expect(saved.isPending, isTrue);
      expect(saved.records, isEmpty);
      expect(store.legacy, isNull);
      expect(store.legacyWrites, 0);
      await owner.close();
    },
  );

  test(
    'admission retains full inputs across restart and never writes legacy',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      owner.accept(
        [_row(1), _row(2, temperature: 325)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(2),
      );
      expect(owner.resumeCheckpoint, isNull);
      await owner.flush();
      expect(owner.resumeCheckpoint, _checkpoint(2));
      await owner.close();
      final restored = await CbioFullRecordOwner.load('synthetic', store);
      expect(restored.resumeCheckpoint, _checkpoint(2));
      final saved = _saved(store);
      expect(saved.records.map((r) => r.rawTemperature), [321, 325]);
      expect(saved.records.map((r) => r.rawPayload), [432, 432]);
      expect(store.legacyWrites, 0);
    },
  );

  test(
    'legacy bootstrap adopts exact original checkpoint without recreating missing rows',
    () async {
      final store = _Store()..legacy = _legacy;
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      expect(owner.resumeCheckpoint, _checkpoint(3));
      await owner.adopt();
      expect(_saved(store).legacyDigest, 'a' * 64);
      owner.accept(
        [_row(3), _row(4)],
        admittedInputCheckpoint: _checkpoint(3),
        currentCheckpoint: _checkpoint(4),
      );
      await owner.flush();
      expect(_saved(store).records.map((r) => r.index), [3, 4]);
      expect(owner.resumeCheckpoint, _checkpoint(4));
      expect(store.legacy, _legacy);
      expect(store.legacyWrites, 0);
      await owner.close();
    },
  );

  test(
    'observing current checkpoint remains authoritative over legacy source',
    () async {
      final store = _Store()..legacy = _legacy;
      final first = await CbioFullRecordOwner.load('synthetic', store);
      await first.adopt();
      first.accept(
        [_row(3), _row(4)],
        admittedInputCheckpoint: _checkpoint(3),
        currentCheckpoint: _checkpoint(4),
      );
      await first.close();
      store.legacy = '{unreadable-original';
      final second = await CbioFullRecordOwner.load('synthetic', store);
      expect(second.resumeCheckpoint, _checkpoint(4));
      await second.adopt();
      expect(second.resumeCheckpoint, _checkpoint(4));
      expect(store.legacy, '{unreadable-original');
      await second.close();
    },
  );

  test(
    'pending legacy change fails closed without replacing either blob',
    () async {
      final store = _Store()..legacy = _legacy;
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      await owner.close();
      final original = store.full;
      store.legacy = '$_legacy ';
      await expectLater(
        CbioFullRecordOwner.load('synthetic', store),
        _storageFailure,
      );
      expect(store.full, original);
      expect(store.legacy, '$_legacy ');
    },
  );

  test('fresh pending rejects a newly appeared legacy binding', () async {
    final store = _Store();
    final first = await CbioFullRecordOwner.load('synthetic', store);
    await first.adopt();
    await first.close();
    store.legacy = _legacy;
    await expectLater(
      CbioFullRecordOwner.load('synthetic', store),
      _storageFailure,
    );
    expect(_saved(store).isPending, isTrue);
  });

  for (final malformed in ['{private-invalid', '{}']) {
    test('present malformed full state never falls back: $malformed', () async {
      final store = _Store()
        ..full = malformed
        ..legacy = _legacy;
      await expectLater(
        CbioFullRecordOwner.load('synthetic', store),
        _storageFailure,
      );
      expect(store.full, malformed);
      expect(store.legacyWrites, 0);
    });
  }

  test('invalid legacy cannot be adopted when full slot is absent', () async {
    final store = _Store()..legacy = '{bad';
    await expectLater(
      CbioFullRecordOwner.load('synthetic', store),
      _storageFailure,
    );
    expect(store.full, isNull);
  });

  test('host digest must be lowercase64hex before pending write', () async {
    final store = _Store()
      ..legacy = _legacy
      ..invalidDigest = true;
    final owner = await CbioFullRecordOwner.load('synthetic', store);
    await expectLater(owner.adopt(), _storageFailure);
    expect(store.full, isNull);
    expect(store.legacy, _legacy);
  });

  test('second live writer is refused until prior drain and close', () async {
    final store = _Store();
    final first = await CbioFullRecordOwner.load('synthetic', store);
    final second = await CbioFullRecordOwner.load('synthetic', store);
    await first.adopt();
    final original = store.full;
    await expectLater(second.adopt(), _storageFailure);
    expect(store.full, original);
    await first.close();
    await second.adopt();
    expect(store.full, original);
    await second.close();
  });

  test(
    'stale prepared owner revalidates durable state after acquiring lease',
    () async {
      final store = _Store();
      final stale = await CbioFullRecordOwner.load('synthetic', store);
      final active = await CbioFullRecordOwner.load('synthetic', store);
      await active.adopt();
      active.accept(
        [_row(1), _row(2)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(2),
      );
      await active.close();
      final original = store.full;
      await stale.adopt();
      expect(store.full, original);
      expect(stale.resumeCheckpoint, _checkpoint(2));
      await stale.close();
    },
  );

  test(
    'failed pending commit releases lease but never falls back to old writer',
    () async {
      final store = _Store()..failWrite = true;
      final first = await CbioFullRecordOwner.load('synthetic', store);
      await expectLater(first.adopt(), _storageFailure);
      expect(store.full, isNull);
      store.failWrite = false;
      final second = await CbioFullRecordOwner.load('synthetic', store);
      await second.adopt();
      expect(store.legacyWrites, 0);
      await second.close();
    },
  );

  test(
    'candidate checkpoint advances only with its complete durable write',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      final pending = store.full;
      store.hold = Completer<void>();
      store.started = Completer<void>();
      owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      final saving = owner.flush();
      await store.started!.future;
      expect(store.full, pending);
      expect(owner.resumeCheckpoint, isNull);
      owner.accept(
        [_row(1), _row(2)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(2),
      );
      final draining = owner.flush();
      store.hold!.complete();
      await Future.wait([saving, draining]);
      expect(owner.resumeCheckpoint, _checkpoint(2));
      expect(_saved(store).records, hasLength(2));
      expect(store.maximumWrites, 1);
      await owner.close();
    },
  );

  test(
    'failed write retains checkpoint and dirty data and close retains lease',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      final pending = store.full;
      owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      store.failWrite = true;
      await expectLater(owner.close(), _storageFailure);
      expect(store.full, pending);
      expect(owner.resumeCheckpoint, isNull);
      final second = await CbioFullRecordOwner.load('synthetic', store);
      await expectLater(second.adopt(), _storageFailure);
      store.failWrite = false;
      await owner.close();
      await second.adopt();
      expect(second.resumeCheckpoint, _checkpoint(1));
      await second.close();
    },
  );

  test(
    'closing freezes new observations while its last write is draining',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      store.hold = Completer<void>();
      store.started = Completer<void>();
      final closing = owner.close();
      await store.started!.future;
      expect(
        () => owner.accept(
          [_row(2)],
          admittedInputCheckpoint: '',
          currentCheckpoint: _checkpoint(2),
        ),
        throwsFormatException,
      );
      store.hold!.complete();
      await closing;
      expect(_saved(store).records.map((r) => r.index), [1]);
    },
  );

  test('unadopted and closed owners cannot accept observations', () async {
    final store = _Store();
    final owner = await CbioFullRecordOwner.load('synthetic', store);
    expect(
      () => owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      ),
      throwsFormatException,
    );
    await owner.adopt();
    await owner.close();
    expect(
      () => owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      ),
      throwsFormatException,
    );
  });

  test('foreign admission checkpoint cannot advance retained state', () async {
    final store = _Store()..legacy = _legacy;
    final owner = await CbioFullRecordOwner.load('synthetic', store);
    await owner.adopt();
    final pending = store.full;
    expect(
      () => owner.accept(
        [_row(3)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(3),
      ),
      throwsFormatException,
    );
    await owner.flush();
    expect(store.full, pending);
    await owner.close();
  });

  for (final field in [
    'rawTime',
    'temperature',
    'dump',
    'payload',
    'processed',
  ]) {
    test(
      'pre-dedup check rejects changed $field without replacing observed inputs',
      () async {
        final store = _Store();
        final owner = await CbioFullRecordOwner.load('synthetic', store);
        await owner.adopt();
        owner.accept(
          [_row(1)],
          admittedInputCheckpoint: '',
          currentCheckpoint: _checkpoint(1),
        );
        await owner.flush();
        final original = store.full;
        final changed = _row(
          1,
          time: field == 'rawTime' ? 121 : null,
          temperature: field == 'temperature' ? 322 : 321,
          dump: field == 'dump' ? 8 : 7,
          payload: field == 'payload' ? 433 : 432,
          processed: field == 'processed' ? 6 : 5,
        );
        expect(
          () => owner.validateObservations([changed]),
          throwsFormatException,
        );
        expect(
          () => owner.accept(
            [changed],
            admittedInputCheckpoint: '',
            currentCheckpoint: _checkpoint(1),
          ),
          throwsFormatException,
        );
        await owner.flush();
        expect(store.full, original);
        await owner.close();
      },
    );
  }

  test(
    'changed duplicate before first coalesced candidate is still refused',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      owner.validateObservations([_row(1)]);
      expect(
        () => owner.validateObservations([_row(1, temperature: 322)]),
        throwsFormatException,
      );
      await owner.close();
    },
  );

  test(
    'first observed reindex survives validation before candidate acceptance',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      owner.validateObservations([_row(1, reindex: 9)]);
      owner.accept(
        [_row(1, reindex: 0)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      await owner.close();
      expect(_saved(store).records.single.reindex, 9);
    },
  );

  test(
    'reindex-only repeat keeps first observation and is idempotent',
    () async {
      final store = _Store();
      final owner = await CbioFullRecordOwner.load('synthetic', store);
      await owner.adopt();
      owner.accept(
        [_row(1)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      await owner.flush();
      final original = store.full;
      owner.validateObservations([_row(1, reindex: 0)]);
      owner.accept(
        [_row(1, reindex: 0)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(1),
      );
      await owner.flush();
      expect(store.full, original);
      expect(_saved(store).records.single.reindex, 9);
      await owner.close();
    },
  );

  test('gap cannot advance checkpoint or erase already durable rows', () async {
    final store = _Store();
    final owner = await CbioFullRecordOwner.load('synthetic', store);
    await owner.adopt();
    owner.accept(
      [_row(1)],
      admittedInputCheckpoint: '',
      currentCheckpoint: _checkpoint(1),
    );
    await owner.flush();
    final original = store.full;
    expect(
      () => owner.accept(
        [_row(3)],
        admittedInputCheckpoint: '',
        currentCheckpoint: _checkpoint(3),
      ),
      throwsFormatException,
    );
    await owner.flush();
    expect(store.full, original);
    await owner.close();
  });
}

final _storageFailure = throwsA(isA<CbioFullRecordFailure>());
String _checkpoint(int index) =>
    '{"version":1,"sensorKey":"synthetic","index":$index,"rawTime":${60 + index * 60}}';
final _legacy = jsonEncode({
  'schemaVersion': 1,
  'driverId': 'cbio',
  'storageKey': 'synthetic',
  'checkpoint': _checkpoint(3),
  'history': [
    {
      'valueMgdl': 43.2,
      'rawValue': 432,
      'sensorMinute': 3,
      'source': 'raw',
      'isDisplayProvisional': true,
    },
  ],
});
CbioFullRecordState _saved(_Store store) =>
    CbioFullRecordState.decode(store.full!, sensorKey: 'synthetic');
CbioRawGlucoseRecord _row(
  int index, {
  int? time,
  int temperature = 321,
  int reindex = 9,
  int dump = 7,
  int payload = 432,
  int processed = 5,
}) => CbioRawGlucoseRecord(
  index: index,
  rawTime: time ?? 60 + index * 60,
  reindex: reindex,
  rawTemperature: temperature,
  rawDump: dump,
  rawPayload: payload,
  rawProcessed: processed,
);

final class _Store implements CbioFullRecordStore {
  String? legacy;
  String? full;
  int legacyWrites = 0;
  bool invalidDigest = false;
  bool failWrite = false;
  Completer<void>? hold;
  Completer<void>? started;
  int activeWrites = 0;
  int maximumWrites = 0;

  @override
  Future<String?> read(String sensorKey) async => legacy;
  @override
  Future<void> write(String sensorKey, String envelope) async {
    legacyWrites++;
    legacy = envelope;
  }

  @override
  Future<String?> readFullRecords(String sensorKey) async => full;
  @override
  Future<void> writeFullRecords(String sensorKey, String envelope) async {
    activeWrites++;
    if (activeWrites > maximumWrites) maximumWrites = activeWrites;
    if (started?.isCompleted == false) started!.complete();
    try {
      await hold?.future;
      if (failWrite) throw StateError('private-file-details');
      full = envelope;
    } finally {
      activeWrites--;
    }
  }

  @override
  String legacySha256(String legacyEnvelope) {
    if (invalidDigest) return 'INVALID';
    if (legacyEnvelope == _legacy) return 'a' * 64;
    if (legacyEnvelope == '$_legacy ') return 'b' * 64;
    throw StateError('Unexpected synthetic digest input');
  }
}

final class _RecoveryStore extends _Store implements CbioRecoveryStore {
  String? recovery;
  bool failRecovery = false;
  bool commitThenFail = false;
  Completer<void>? readRecoveryHold;
  Completer<void>? writeRecoveryHold;
  Completer<void>? recoveryStarted;
  final _digests = <String, String>{};
  @override
  String legacySha256(String value) => _digests.putIfAbsent(
    value,
    () => (_digests.length + 1).toRadixString(16).padLeft(64, '0'),
  );
  @override
  Future<String?> readRecovery(String sensorKey) async {
    if (readRecoveryHold != null) {
      if (recoveryStarted?.isCompleted == false) recoveryStarted!.complete();
      await readRecoveryHold!.future;
    }
    return recovery;
  }

  @override
  Future<void> writeRecovery(String sensorKey, String value) async {
    if (writeRecoveryHold != null) {
      if (recoveryStarted?.isCompleted == false) recoveryStarted!.complete();
      await writeRecoveryHold!.future;
    }
    if (failRecovery) throw StateError('private recovery path');
    recovery = value;
    if (commitThenFail) throw StateError('synthetic commit interruption');
  }
}
