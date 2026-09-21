import 'dart:async';
import 'dart:collection';

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('YuwellRecordStoreKey', () {
    test('derives the exact domain-separated generation-aware digest', () {
      final key = _storeKey();

      expect(
        key.digest,
        '36ebc3e2a9c2d52adae131f5b90d003cce7273d09ed586d144b0d039edfeb2dc',
      );
      expect(key.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(key.toString(), isNot(contains('yuwell:')));
      expect(key.toString(), isNot(contains('b' * 32)));
    });

    test('uses a distinct namespace for each local generation', () {
      final first = _storeKey();
      final second = YuwellRecordStoreKey.forGeneration(
        sensorStorageKey: 'yuwell:${'a' * 64}',
        historyGeneration: 'c' * 32,
      );

      expect(second.digest, isNot(first.digest));
    });

    test('rejects malformed and out-of-bound namespace inputs', () {
      for (final sensorStorageKey in <String>[
        '',
        'aidex:${'a' * 64}',
        'yuwell:${'a' * 122}',
      ]) {
        expect(
          () => YuwellRecordStoreKey.forGeneration(
            sensorStorageKey: sensorStorageKey,
            historyGeneration: 'b' * 32,
          ),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
      for (final generation in <String>['B' * 32, 'b' * 31]) {
        expect(
          () => YuwellRecordStoreKey.forGeneration(
            sensorStorageKey: 'yuwell:${'a' * 64}',
            historyGeneration: generation,
          ),
          throwsA(isA<YuwellProtocolFormatException>()),
        );
      }
    });
  });

  group('YuwellRecordStateOwner', () {
    test('restores a missing value as a clean empty state', () async {
      final store = _MemoryRecordStore();

      final owner = await _restore(store);

      expect(owner.state.nextIndex, 0);
      expect(owner.revision, 0);
      expect(owner.durableRevision, 0);
      expect(owner.isDirty, isFalse);
      expect(store.reads, 1);
      expect(store.writes, 0);
      expect(store.deletes, 0);
    });

    test('restores an exact matching durable prefix', () async {
      final store = _MemoryRecordStore();
      final state = YuwellRecordState.empty(
        binding: _binding(),
      ).appendBatch(_emptyBatch(start: 0, count: 3));
      store.values[_storeKey().digest] = state.encode();

      final owner = await _restore(store);

      expect(owner.state.encode(), state.encode());
      expect(owner.state.nextIndex, 3);
      expect(owner.revision, 0);
      expect(owner.durableRevision, 0);
      expect(owner.isDirty, isFalse);
    });

    test('rejects malformed and foreign state without mutation', () async {
      final malformedStore = _MemoryRecordStore()
        ..values[_storeKey().digest] = '{';
      await expectLater(
        _restore(malformedStore),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(malformedStore.writes, 0);
      expect(malformedStore.deletes, 0);
      expect(malformedStore.values[_storeKey().digest], '{');

      final foreignStore = _MemoryRecordStore();
      foreignStore.values[_storeKey().digest] = YuwellRecordState.empty(
        binding: _binding(firmware: 'V1151'),
      ).encode();
      await expectLater(
        _restore(foreignStore),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(foreignStore.writes, 0);
      expect(foreignStore.deletes, 0);
    });

    test('keeps fewer than 16 new slots dirty until a boundary', () async {
      final store = _MemoryRecordStore();
      final owner = await _restore(store);

      await owner.acceptBatch(_emptyBatch(start: 0, count: 15));

      expect(owner.state.nextIndex, 15);
      expect(owner.revision, 1);
      expect(owner.durableRevision, 0);
      expect(owner.isDirty, isTrue);
      expect(store.writes, 0);
    });

    test('flushes once after 16 newly consumed slots', () async {
      final store = _MemoryRecordStore();
      final owner = await _restore(store);

      await owner.acceptBatch(_emptyBatch(start: 0, count: 16));

      expect(store.writes, 1);
      expect(owner.revision, 1);
      expect(owner.durableRevision, 1);
      expect(owner.isDirty, isFalse);
      expect(
        YuwellRecordState.decode(store.values[_storeKey().digest]!).nextIndex,
        16,
      );
    });

    test('flushes a dirty suffix at cycle completion and drain', () async {
      final store = _MemoryRecordStore();
      final owner = await _restore(store);

      await owner.acceptBatch(_emptyBatch(start: 0, count: 2));
      await owner.completeHistoryCycle();
      expect(store.writes, 1);
      expect(owner.isDirty, isFalse);

      await owner.acceptBatch(_emptyBatch(start: 2, count: 1));
      await owner.drain();
      expect(store.writes, 2);
      expect(owner.isDirty, isFalse);
      expect(owner.durableRevision, owner.revision);
    });

    test('serializes writes and commits their immutable snapshots', () async {
      final store = _MemoryRecordStore();
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      store.writeGates.addAll(<Completer<void>>[firstGate, secondGate]);
      final owner = await _restore(store);

      final first = owner.acceptBatch(_emptyBatch(start: 0, count: 16));
      await _turn();
      expect(store.startedWrites, 1);

      final second = owner.acceptBatch(_emptyBatch(start: 16, count: 16));
      await _turn();
      expect(store.startedWrites, 1);

      firstGate.complete();
      await first;
      await _turn();
      expect(store.startedWrites, 2);
      expect(
        YuwellRecordState.decode(store.completedEnvelopes.single).nextIndex,
        16,
      );

      secondGate.complete();
      await second;
      expect(
        YuwellRecordState.decode(store.values[_storeKey().digest]!).nextIndex,
        32,
      );
      expect(owner.durableRevision, 2);
    });

    test('retains dirty state after failure and drain retries it', () async {
      final store = _MemoryRecordStore()..failWrites = true;
      final owner = await _restore(store);

      await expectLater(
        owner.acceptBatch(_emptyBatch(start: 0, count: 16)),
        throwsA(isA<StateError>()),
      );

      expect(owner.state.nextIndex, 16);
      expect(owner.revision, 1);
      expect(owner.durableRevision, 0);
      expect(owner.isDirty, isTrue);
      expect(store.values, isEmpty);
      expect(store.deletes, 0);

      await expectLater(
        owner.acceptBatch(_emptyBatch(start: 16, count: 1)),
        throwsA(isA<StateError>()),
      );
      expect(owner.state.nextIndex, 16);
      expect(owner.revision, 1);

      store.failWrites = false;
      await owner.drain();
      expect(owner.isDirty, isFalse);
      expect(owner.durableRevision, 1);
      expect(store.writes, 2);
    });

    test('restored exact duplicate is idempotent but conflict fails', () async {
      final store = _MemoryRecordStore();
      final first = await _restore(store);
      final durableBatch = YuwellRecordBatch(
        startIndex: 0,
        consumedSlots: 16,
        records: <YuwellIndexedHistoryRecord>[_record(0, seed: 3)],
      );
      await first.acceptBatch(durableBatch);

      final restored = await _restore(store);
      await restored.acceptBatch(durableBatch);

      expect(restored.revision, 0);
      expect(restored.isDirty, isFalse);
      expect(store.writes, 1);
      expect(
        () => restored.acceptBatch(
          YuwellRecordBatch(
            startIndex: 0,
            consumedSlots: 1,
            records: <YuwellIndexedHistoryRecord>[_record(0, seed: 4)],
          ),
        ),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
      expect(store.writes, 1);
      expect(store.deletes, 0);
    });
  });
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

YuwellRecordStoreKey _storeKey() => YuwellRecordStoreKey.forGeneration(
  sensorStorageKey: 'yuwell:${'a' * 64}',
  historyGeneration: 'b' * 32,
);

YuwellRecordBinding _binding({String firmware = 'V1150'}) =>
    YuwellRecordBinding(
      sensorBinding: 'a' * 64,
      historyGeneration: 'b' * 32,
      firmware: firmware,
      historyOpcode: YuwellCt5Commands.alternateHistoryCommand,
      layout: YuwellHistoryRecordLayout.alert17,
    );

Future<YuwellRecordStateOwner> _restore(_MemoryRecordStore store) =>
    YuwellRecordStateOwner.restore(
      store: store,
      key: _storeKey(),
      binding: _binding(),
    );

YuwellRecordBatch _emptyBatch({required int start, required int count}) =>
    YuwellRecordBatch(
      startIndex: start,
      consumedSlots: count,
      records: const <YuwellIndexedHistoryRecord>[],
    );

YuwellIndexedHistoryRecord _record(int index, {required int seed}) =>
    YuwellIndexedHistoryRecord(
      index: index,
      record: YuwellHistoryRecord.parse(
        List<int>.generate(17, (offset) => seed + offset),
      ),
    );

final class _MemoryRecordStore implements YuwellRecordStore {
  final Map<String, String> values = <String, String>{};
  final Queue<Completer<void>> writeGates = Queue<Completer<void>>();
  final List<String> completedEnvelopes = <String>[];
  bool failWrites = false;
  int reads = 0;
  int writes = 0;
  int deletes = 0;
  int startedWrites = 0;

  @override
  Future<String?> read(YuwellRecordStoreKey key) async {
    reads++;
    return values[key.digest];
  }

  @override
  Future<void> write(YuwellRecordStoreKey key, String envelope) async {
    writes++;
    startedWrites++;
    if (failWrites) throw StateError('synthetic write failure');
    if (writeGates.isNotEmpty) await writeGates.removeFirst().future;
    values[key.digest] = envelope;
    completedEnvelopes.add(envelope);
  }

  @override
  Future<void> delete(YuwellRecordStoreKey key) async {
    deletes++;
    values.remove(key.digest);
  }
}
