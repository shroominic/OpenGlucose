import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

import 'health_state_store.dart';

const _yuwellRecordPrefix = 'openHealth.history.yuwell.records.v1.';

/// Restricted-state adapter for Yuwell's private raw record envelopes.
final class YuwellHealthRecordStore implements YuwellRecordStore {
  const YuwellHealthRecordStore(this._healthStateStore);

  final HealthStateStore _healthStateStore;

  @override
  Future<String?> read(YuwellRecordStoreKey key) async {
    try {
      return _healthStateStore.getString(_logicalKey(key));
    } catch (_) {
      throw StateError('Yuwell private record storage failed.');
    }
  }

  @override
  Future<void> write(YuwellRecordStoreKey key, String envelope) async {
    try {
      await _healthStateStore.setString(_logicalKey(key), envelope);
    } catch (_) {
      throw StateError('Yuwell private record storage failed.');
    }
  }

  @override
  Future<void> delete(YuwellRecordStoreKey key) async {
    try {
      await _healthStateStore.remove(_logicalKey(key));
    } catch (_) {
      throw StateError('Yuwell private record storage failed.');
    }
  }

  String _logicalKey(YuwellRecordStoreKey key) =>
      '$_yuwellRecordPrefix${key.digest}';

  @override
  String toString() => 'YuwellHealthRecordStore(<redacted>)';
}
