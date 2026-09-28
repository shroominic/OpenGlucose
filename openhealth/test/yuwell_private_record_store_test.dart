import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/yuwell_private_record_store.dart';

void main() {
  const firstGeneration = '0123456789abcdef0123456789abcdef';
  const secondGeneration = 'fedcba9876543210fedcba9876543210';
  const sensorStorageKey = 'yuwell:private-sensor-key';

  YuwellRecordStoreKey key(String generation) =>
      YuwellRecordStoreKey.forGeneration(
        sensorStorageKey: sensorStorageKey,
        historyGeneration: generation,
      );

  test(
    'delegates each operation once under the digest-only logical key',
    () async {
      final healthStore = _RecordingHealthStateStore();
      final store = YuwellHealthRecordStore(healthStore);
      final recordKey = key(firstGeneration);

      await store.write(recordKey, 'opaque-envelope');
      expect(await store.read(recordKey), 'opaque-envelope');
      await store.delete(recordKey);

      final logicalKey =
          'openHealth.history.yuwell.records.v1.${recordKey.digest}';
      expect(healthStore.calls, <String>[
        'set:$logicalKey',
        'get:$logicalKey',
        'remove:$logicalKey',
      ]);
      expect(logicalKey, isNot(contains(sensorStorageKey)));
      expect(logicalKey, isNot(contains(firstGeneration)));
    },
  );

  test(
    'new generations select distinct blobs and leave old data readable',
    () async {
      final healthStore = _RecordingHealthStateStore();
      final store = YuwellHealthRecordStore(healthStore);
      final first = key(firstGeneration);
      final second = key(secondGeneration);

      await store.write(first, 'old-envelope');
      await store.write(second, 'new-envelope');

      expect(await store.read(first), 'old-envelope');
      expect(await store.read(second), 'new-envelope');
      expect(first.digest, isNot(second.digest));
      expect(healthStore.values, hasLength(2));
    },
  );

  test(
    'redacts adapter text and wraps a throwing store without fallback delete',
    () async {
      final healthStore = _RecordingHealthStateStore()
        ..writeError = StateError('leaked opaque-envelope');
      final store = YuwellHealthRecordStore(healthStore);
      final recordKey = key(firstGeneration);

      Object? error;
      try {
        await store.write(recordKey, 'opaque-envelope');
      } catch (caught) {
        error = caught;
      }

      expect(error, isNotNull);
      expect(error.toString(), isNot(contains('opaque-envelope')));
      expect(error.toString(), isNot(contains(recordKey.digest)));
      expect(store.toString(), 'YuwellHealthRecordStore(<redacted>)');
      expect(store.toString(), isNot(contains(sensorStorageKey)));
      expect(store.toString(), isNot(contains(firstGeneration)));
      expect(healthStore.calls, hasLength(1));
      expect(healthStore.calls.single, startsWith('set:'));
    },
  );
}

final class _RecordingHealthStateStore implements HealthStateStore {
  final Map<String, String> values = <String, String>{};
  final List<String> calls = <String>[];
  Error? writeError;

  @override
  String? getString(String key) {
    calls.add('get:$key');
    return values[key];
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> remove(String key) async {
    calls.add('remove:$key');
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    calls.add('set:$key');
    final error = writeError;
    if (error != null) throw error;
    values[key] = value;
  }
}
