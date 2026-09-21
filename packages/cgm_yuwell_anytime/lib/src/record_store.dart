import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'record_state.dart';

const _storeKeyDomain = 'openhealth.yuwell.records.v1';
const _flushSlotThreshold = 16;
final _generationPattern = RegExp(r'^[0-9a-f]{32}$');

final class YuwellRecordStoreKey {
  YuwellRecordStoreKey._(this.digest);

  factory YuwellRecordStoreKey.forGeneration({
    required String sensorStorageKey,
    required String historyGeneration,
  }) {
    final storageKeyBytes = utf8.encode(sensorStorageKey);
    final generationBytes = utf8.encode(historyGeneration);
    if (storageKeyBytes.isEmpty ||
        storageKeyBytes.length > 128 ||
        !sensorStorageKey.startsWith('yuwell:') ||
        !_generationPattern.hasMatch(historyGeneration)) {
      throw const YuwellProtocolFormatException(
        'record store namespace has an unsupported shape',
      );
    }
    final input = BytesBuilder(copy: false)
      ..add(utf8.encode(_storeKeyDomain))
      ..addByte(0)
      ..add(<int>[storageKeyBytes.length >> 8, storageKeyBytes.length & 0xff])
      ..add(storageKeyBytes)
      ..add(<int>[generationBytes.length >> 8, generationBytes.length & 0xff])
      ..add(generationBytes);
    return YuwellRecordStoreKey._(sha256.convert(input.takeBytes()).toString());
  }

  final String digest;

  @override
  String toString() => 'YuwellRecordStoreKey(<redacted>)';
}

abstract interface class YuwellRecordStore {
  Future<String?> read(YuwellRecordStoreKey key);

  Future<void> write(YuwellRecordStoreKey key, String envelope);

  Future<void> delete(YuwellRecordStoreKey key);
}

final class YuwellRecordStateOwner {
  YuwellRecordStateOwner._({
    required YuwellRecordStore store,
    required YuwellRecordStoreKey key,
    required YuwellRecordState state,
  }) : _store = store,
       _key = key,
       _state = state,
       _durableNextIndex = state.nextIndex;

  static Future<YuwellRecordStateOwner> restore({
    required YuwellRecordStore store,
    required YuwellRecordStoreKey key,
    required YuwellRecordBinding binding,
  }) async {
    final encoded = await store.read(key);
    final state = encoded == null
        ? YuwellRecordState.empty(binding: binding)
        : YuwellRecordState.decode(encoded);
    state.requireBinding(binding);
    return YuwellRecordStateOwner._(store: store, key: key, state: state);
  }

  final YuwellRecordStore _store;
  final YuwellRecordStoreKey _key;
  YuwellRecordState _state;
  Future<void> _writeTail = Future<void>.value();
  int _revision = 0;
  int _durableRevision = 0;
  int _durableNextIndex;
  bool _writeBlocked = false;

  YuwellRecordState get state => _state;
  int get revision => _revision;
  int get durableRevision => _durableRevision;
  bool get isDirty => _durableRevision != _revision;

  Future<void> acceptBatch(YuwellRecordBatch batch) async {
    if (_writeBlocked) {
      throw StateError('Yuwell record persistence is awaiting retry.');
    }
    final next = _state.appendBatch(batch);
    if (next.nextIndex == _state.nextIndex) return;
    _state = next;
    _revision++;
    if (_state.nextIndex - _durableNextIndex >= _flushSlotThreshold) {
      await _flush(allowRetry: false);
    }
  }

  Future<void> completeHistoryCycle() async {
    if (isDirty) await _flush(allowRetry: false);
  }

  Future<void> drain() async {
    await _writeTail;
    if (isDirty) await _flush(allowRetry: true);
  }

  Future<void> _flush({required bool allowRetry}) {
    final snapshot = _state;
    final targetRevision = _revision;
    final previous = _writeTail;
    final operation = () async {
      await previous;
      if (_writeBlocked && !allowRetry) {
        throw StateError('Yuwell record persistence is awaiting retry.');
      }
      if (allowRetry) _writeBlocked = false;
      try {
        await _store.write(_key, snapshot.encode());
      } catch (_) {
        _writeBlocked = true;
        rethrow;
      }
      if (targetRevision > _durableRevision) {
        _durableRevision = targetRevision;
        _durableNextIndex = snapshot.nextIndex;
      }
    }();
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  String toString() => 'YuwellRecordStateOwner(<redacted>)';
}
