import 'dart:async';
import 'dart:convert';

import 'package:cgm_cbio/src/cbio_history_state.dart';
import 'package:cgm_cbio/src/cbio_private_state_owner.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

final class _Store implements CbioPrivateStateStore {
  String? value;
  bool failWrite = false;
  Completer<void>? heldWrite;
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;
  @override
  Future<String?> read(String sensorKey) async => value;
  @override
  Future<void> write(String sensorKey, String envelope) async {
    concurrentWrites++;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    try {
      await heldWrite?.future;
      if (failWrite) throw StateError('private native detail');
      value = envelope;
    } finally {
      concurrentWrites--;
    }
  }
}

CbioHistoryState _state(int index, int raw) => CbioHistoryState(
  sensorKey: 'synthetic',
  checkpoint: CbioSessionCheckpoint(
    sensorKey: 'synthetic',
    index: index,
    rawTime: 1000 + index * 60,
  ).encode(),
  history: [
    CgmReading(
      valueMgdl: raw / 10,
      rawValue: raw,
      sensorMinute: index,
      source: CgmRecordSource.raw,
      isDisplayProvisional: true,
    ),
  ],
);

void main() {
  for (final field in ['storageKey', 'driverId']) {
    test(
      'foreign $field cannot load or mutate a valid private envelope',
      () async {
        final payload =
            jsonDecode(_state(1, 60).encode()) as Map<String, dynamic>;
        payload[field] = 'foreign';
        final original = jsonEncode(payload);
        final store = _Store()..value = original;
        await expectLater(
          CbioPrivateStateOwner.load('synthetic', store),
          throwsA(isA<CbioPrivateStateFailure>()),
        );
        expect(store.value, original);
      },
    );
  }
  test(
    'flush drains accepted revisions without overlapping durable writes',
    () async {
      final store = _Store()..heldWrite = Completer<void>();
      final owner = await CbioPrivateStateOwner.load('synthetic', store);
      owner.accept(_state(1, 60));
      final first = owner.flush();
      owner.accept(_state(2, 70));
      final second = owner.flush();
      store.heldWrite!.complete();
      await Future.wait([first, second]);
      expect(store.maxConcurrentWrites, 1);
      expect(
        CbioHistoryState.decode(
          store.value!,
          sensorKey: 'synthetic',
        ).history.map((r) => r.rawValue),
        [60, 70],
      );
    },
  );
  test('failed save retains complete dirty state for durable retry', () async {
    final store = _Store()..value = _state(1, 60).encode();
    final owner = await CbioPrivateStateOwner.load('synthetic', store);
    owner.accept(_state(2, 70));
    store.failWrite = true;
    await expectLater(owner.flush(), throwsA(isA<CbioPrivateStateFailure>()));
    expect(
      CbioHistoryState.decode(
        store.value!,
        sensorKey: 'synthetic',
      ).history.map((r) => r.rawValue),
      [60],
    );
    store.failWrite = false;
    await owner.flush();
    expect(
      CbioHistoryState.decode(
        store.value!,
        sensorKey: 'synthetic',
      ).history.map((r) => r.rawValue),
      [60, 70],
    );
  });

  test('conflicting payload cannot replace retained raw bytes', () async {
    final store = _Store()..value = _state(1, 60).encode();
    final original = store.value;
    final owner = await CbioPrivateStateOwner.load('synthetic', store);
    expect(() => owner.accept(_state(1, 61)), throwsFormatException);
    await owner.flush();
    expect(store.value, original);
  });

  test(
    'load validates binding and preserves malformed original bytes',
    () async {
      final store = _Store()..value = '{unrecoverable';
      await expectLater(
        CbioPrivateStateOwner.load('synthetic', store),
        throwsA(isA<CbioPrivateStateFailure>()),
      );
      expect(store.value, '{unrecoverable');
    },
  );
}
