import 'package:cgm_core/cgm_core.dart';

import 'cbio_history_state.dart';
import 'cbio_private_state.dart';
import 'cbio_history_archive.dart';
import 'cbio_full_record_owner.dart';

/// Closed storage failure; native errors can include private paths or data.
final class CbioPrivateStateFailure implements Exception {
  const CbioPrivateStateFailure();

  @override
  String toString() => 'CBIO private state unavailable';
}

/// Package-internal raw owner. Never projects archive rows into public glucose.
final class CbioPrivateStateOwner {
  CbioPrivateStateOwner._(
    this.sensorKey,
    this._store,
    this._state, [
    this._full,
  ]);

  final String sensorKey;
  final CbioPrivateStateStore _store;
  final CbioHistoryArchive acquisitionArchive = CbioHistoryArchive();
  CbioHistoryState? _state;
  final CbioFullRecordOwner? _full;
  int _revision = 0;
  int _durableRevision = 0;
  Future<void>? _saving;

  CbioHistoryState? get state => _state;
  bool get usesFullRecords => _full != null;
  String? get resumeCheckpoint => _full?.resumeCheckpoint ?? _state?.checkpoint;

  static Future<CbioPrivateStateOwner> load(
    String sensorKey,
    CbioPrivateStateStore store,
  ) async {
    try {
      if (store is CbioFullRecordStore) {
        final full = await CbioFullRecordOwner.load(sensorKey, store);
        return CbioPrivateStateOwner._(sensorKey, store, null, full);
      }
      final encoded = await store.read(sensorKey);
      final state = encoded == null
          ? null
          : CbioHistoryState.decode(encoded, sensorKey: sensorKey);
      return CbioPrivateStateOwner._(sensorKey, store, state);
    } on Object {
      throw const CbioPrivateStateFailure();
    }
  }

  /// Called only after this session confirms its exact input witness.
  void accept(CbioHistoryState incoming) {
    if (_full != null) {
      throw const FormatException('CBIO legacy writes disabled.');
    }
    if (incoming.sensorKey != sensorKey) {
      throw const FormatException('CBIO private binding mismatch.');
    }
    final retained = _state;
    final rows = <int, CgmReading>{
      for (final row in retained?.history ?? const <CgmReading>[])
        row.sensorMinute!: row,
    };
    for (final row in incoming.history) {
      final saved = rows[row.sensorMinute];
      if (saved != null &&
          (saved.rawValue != row.rawValue || saved.source != row.source)) {
        throw const FormatException('CBIO private payload conflict.');
      }
      // Legacy timestamps are retained, never reconstructed from absent fields.
      rows.putIfAbsent(row.sensorMinute!, () => row);
    }
    final history = rows.values.toList()
      ..sort((a, b) => a.sensorMinute!.compareTo(b.sensorMinute!));
    final merged = CbioHistoryState(
      sensorKey: sensorKey,
      checkpoint: incoming.checkpoint,
      history: history,
    );
    if (retained?.encode() == merged.encode()) return;
    _state = merged;
    _revision++;
  }

  /// Serializes writes and drains changes accepted during a pending write.
  /// A failure leaves both the complete state and dirty revision retryable.
  Future<void> flush() {
    if (_full != null) {
      return _full.flush().catchError((Object _) {
        throw const CbioPrivateStateFailure();
      });
    }
    final saving = _saving;
    if (saving != null) return saving;
    final future = _drain();
    _saving = future;
    return future.whenComplete(() => _saving = null);
  }

  Future<void> adoptFullRecords() async {
    try {
      await _full?.adopt();
    } on Object {
      throw const CbioPrivateStateFailure();
    }
  }

  void validateFullObservations(List<CbioRawGlucoseRecord> records) =>
      _full?.validateObservations(records);

  void acceptFullRecords(
    List<CbioRawGlucoseRecord> records, {
    required String admittedInputCheckpoint,
    required String currentCheckpoint,
  }) => _full!.accept(
    records,
    admittedInputCheckpoint: admittedInputCheckpoint,
    currentCheckpoint: currentCheckpoint,
  );

  Future<void> close() async {
    await flush();
    try {
      await _full?.close();
    } on Object {
      throw const CbioPrivateStateFailure();
    }
  }

  Future<void> _drain() async {
    while (_durableRevision != _revision) {
      final revision = _revision;
      final envelope = _state!.encode();
      try {
        await _store.write(sensorKey, envelope);
      } on Object {
        throw const CbioPrivateStateFailure();
      }
      _durableRevision = revision;
    }
  }
}

/// Default driver-lifetime state for integrations without durable storage.
final class CbioMemoryPrivateStateStore implements CbioPrivateStateStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String sensorKey) async => _values[sensorKey];

  @override
  Future<void> write(String sensorKey, String envelope) async {
    _values[sensorKey] = envelope;
  }
}
