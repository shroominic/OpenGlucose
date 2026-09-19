import 'dart:math';

import 'cbio_full_record_state.dart';
import 'cbio_history_archive.dart';
import 'cbio_history_state.dart';
import 'cbio_private_state.dart';

final class CbioFullRecordFailure implements Exception {
  const CbioFullRecordFailure();
  @override
  String toString() => 'CBIO full input state unavailable';
}

/// Restricted, driver-owned full observations. Never exported to app consumers.
final class CbioFullRecordOwner {
  CbioFullRecordOwner._(this.sensorKey, this._store);

  final String sensorKey;
  final CbioFullRecordStore _store;
  static final _leases = Expando<Set<String>>();
  CbioFullRecordState? _durable;
  CbioFullRecordState? _candidate;
  String? _legacy;
  String? _legacyCheckpoint;
  String? _admissionCheckpoint;
  Future<void>? _adopting;
  Future<void>? _saving;
  bool _leased = false;
  bool _closed = false;
  bool _closing = false;
  Map<int, CbioRawGlucoseRecord> _observed = {};

  static Future<CbioFullRecordOwner> load(
    String sensorKey,
    CbioFullRecordStore store,
  ) async {
    final owner = CbioFullRecordOwner._(sensorKey, store);
    await owner._reload();
    return owner;
  }

  Future<void> _reload() async {
    try {
      if (sensorKey.isEmpty) throw const CbioFullRecordFailure();
      final encoded = await _store.readFullRecords(sensorKey);
      final full = encoded == null
          ? null
          : CbioFullRecordState.decode(encoded, sensorKey: sensorKey);
      String? legacy;
      String? checkpoint;
      if (full == null || full.isPending) {
        legacy = await _store.read(sensorKey);
        checkpoint = legacy == null
            ? null
            : CbioHistoryState.decode(legacy, sensorKey: sensorKey).checkpoint;
        if (full != null &&
            ((legacy == null) != (full.legacyDigest == null) ||
                (legacy != null &&
                    (_digest(legacy) != full.legacyDigest ||
                        checkpoint != full.bootstrapCheckpoint)))) {
          throw const CbioFullRecordFailure();
        }
      }
      _durable = full;
      _candidate = full;
      _observed = {
        for (final row in full?.records ?? const <CbioRawGlucoseRecord>[])
          row.index: row,
      };
      _legacy = legacy;
      _legacyCheckpoint = checkpoint;
    } on Object {
      throw const CbioFullRecordFailure();
    }
  }

  String _digest(String original) {
    final digest = _store.legacySha256(original);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const CbioFullRecordFailure();
    }
    return digest;
  }

  Future<void> adopt() {
    if (_closed || _closing) return Future.error(const CbioFullRecordFailure());
    return _adopting ??= _adopt().whenComplete(() => _adopting = null);
  }

  Future<void> _adopt() async {
    if (_leased) return;
    final bindings = _leases[_store] ??= <String>{};
    if (!bindings.add(sensorKey)) throw const CbioFullRecordFailure();
    _leased = true;
    try {
      // Preparation was read-only and may be stale after another owner's drain.
      // Only lease-protected revalidation can select this session's input.
      await _reload();
      if (_durable == null) {
        final random = Random.secure();
        final captureId = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final pending = CbioFullRecordState.pending(
          sensorKey: sensorKey,
          captureId: captureId,
          legacyDigest: _legacy == null ? null : _digest(_legacy!),
          bootstrapCheckpoint: _legacyCheckpoint,
        );
        await _store.writeFullRecords(sensorKey, pending.encode());
        _durable = pending;
        _candidate = pending;
      }
      _admissionCheckpoint = resumeCheckpoint ?? '';
    } on Object {
      _leased = false;
      bindings.remove(sensorKey);
      throw const CbioFullRecordFailure();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    await _adopting;
    await flush();
    if (_leased) _leases[_store]?.remove(sensorKey);
    _leased = false;
    _closed = true;
  }

  String? get resumeCheckpoint =>
      _durable?.resumeCheckpoint ?? _legacyCheckpoint;

  /// Runs before archive deduplication, including for repeated witness batches.
  void validateObservations(List<CbioRawGlucoseRecord> records) {
    _requireActive();
    final additions = <int, CbioRawGlucoseRecord>{};
    for (final row in records) {
      if (row.index < 1 ||
          row.index > 0xffff ||
          row.rawTime < 0 ||
          row.rawTime > 0xffffffff ||
          [
            row.reindex,
            row.rawTemperature,
            row.rawDump,
            row.rawPayload,
            row.rawProcessed,
          ].any((word) => word < 0 || word > 0xffff)) {
        throw const FormatException('CBIO full input observation invalid.');
      }
      final saved = additions[row.index] ?? _observed[row.index];
      if (saved != null && !_sameWords(saved, row)) {
        throw const FormatException('CBIO full input observation conflict.');
      }
      if (saved == null) additions[row.index] = row;
      if (_observed.length + additions.length > CbioFullRecordState.maxRows) {
        throw const FormatException('CBIO full input capacity reached.');
      }
    }
    _observed.addAll(additions);
  }

  void accept(
    List<CbioRawGlucoseRecord> records, {
    required String admittedInputCheckpoint,
    required String currentCheckpoint,
  }) {
    _requireActive();
    if (admittedInputCheckpoint != _admissionCheckpoint) {
      throw const FormatException('CBIO full input witness required.');
    }
    validateObservations(records);
    final merged = <int, CbioRawGlucoseRecord>{
      for (final row in _candidate!.records) row.index: row,
    };
    for (final row in records) {
      merged.putIfAbsent(row.index, () => _observed[row.index]!);
      if (merged.length > CbioFullRecordState.maxRows) {
        throw const FormatException('CBIO full input capacity reached.');
      }
    }
    final ordered = merged.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final candidate = _candidate!.observing(
      records: ordered,
      currentCheckpoint: currentCheckpoint,
    );
    candidate.encode(); // All byte bounds checked before candidate acceptance.
    _candidate = candidate;
  }

  void _requireActive() {
    if (!_leased ||
        _closed ||
        _closing ||
        _candidate == null ||
        _admissionCheckpoint == null) {
      throw const FormatException('CBIO full input owner inactive.');
    }
  }

  static bool _sameWords(CbioRawGlucoseRecord a, CbioRawGlucoseRecord b) =>
      a.rawTime == b.rawTime &&
      a.rawTemperature == b.rawTemperature &&
      a.rawDump == b.rawDump &&
      a.rawPayload == b.rawPayload &&
      a.rawProcessed == b.rawProcessed;

  Future<void> flush() {
    if (!_leased || _closed) return Future.value();
    final pending = _saving;
    if (pending != null) return pending;
    final future = _drain();
    _saving = future;
    return future.whenComplete(() => _saving = null);
  }

  Future<void> _drain() async {
    while (!identical(_candidate, _durable)) {
      final candidate = _candidate!;
      final encoded = candidate.encode();
      if (encoded != _durable!.encode()) {
        try {
          await _store.writeFullRecords(sensorKey, encoded);
        } on Object {
          throw const CbioFullRecordFailure();
        }
      }
      _durable = candidate;
    }
  }
}
