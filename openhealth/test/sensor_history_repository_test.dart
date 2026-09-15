import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre_gen1_observation_store.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_history_repository.dart';

void main() {
  final now = DateTime.utc(2026, 1, 2);
  final binding = LibreGen1ObservationBinding(
    bootstrapId: 'synthetic-bootstrap',
    sensorBindingDigest: 'a' * 64,
  );
  final sensor = DiscoveredSensor(
    driverId: binding.driverId,
    deviceId: 'synthetic-target',
    storageKey: binding.storageKey,
    displayName: 'Synthetic Libre',
    rssi: -50,
    capabilities: const CgmCapabilities(),
  );
  final key = sensorHistoryKey(sensor);
  late _Store store;
  late SensorHistoryRepository repository;
  late LibreGen1HistoryObservationStore observations;

  CgmReading reading(
    int minute, {
    double value = 100,
    DateTime? at,
    bool provisional = true,
  }) => CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.vendor,
    sensorMinute: minute,
    recordedAt: at ?? now.subtract(const Duration(minutes: 1)),
    rawValue: 500,
    qualifier: 0,
    isDisplayProvisional: provisional,
  );

  Future<LibreGen1ObservationCommit> commit(
    int minute, {
    CgmReading? sample,
  }) => observations.commit(
    binding,
    sensorMinute: minute,
    receivedAt: sample?.recordedAt ?? now,
    reading: sample,
  );

  Map<String, dynamic> envelope() =>
      jsonDecode(store.values[key]!) as Map<String, dynamic>;

  Map<String, Object?> archive(
    int segment,
    List<CgmReading> history, {
    String? driverId,
    String? storageKey,
  }) {
    final driver = driverId ?? binding.driverId;
    final storage = storageKey ?? binding.storageKey;
    final id = base64Url
        .encode(
          utf8.encode(
            '$driver|$storage|${now.millisecondsSinceEpoch + segment}',
          ),
        )
        .replaceAll('=', '');
    final historyKey = 'openHealth.history.archive.$id';
    if (history.isNotEmpty) {
      store.values[historyKey] = jsonEncode(
        history.map((entry) => entry.toJson()).toList(),
      );
    }
    return ArchivedSensorSession(
      id: id,
      historyKey: historyKey,
      storageKey: storage,
      driverId: driver,
      deviceId: 'synthetic-archive-target',
      displayName: 'Synthetic archive',
      reason: SensorArchiveReason.disconnected,
      readingCount: history.length,
      endedAt: now,
      lastReadingAt: history.isEmpty ? null : history.last.recordedAt,
    ).toJson();
  }

  void archiveManifest(List<Map<String, Object?>> entries) {
    store.values['openHealth.sensorArchive'] = jsonEncode(entries);
  }

  setUp(() {
    store = _Store();
    repository = SensorHistoryRepository(store);
    observations = LibreGen1HistoryObservationStore(repository);
  });

  test('history identity preserves existing driver-qualified keys', () {
    final expected = base64Url
        .encode(utf8.encode(jsonEncode([binding.driverId, binding.storageKey])))
        .replaceAll('=', '');
    expect(key, 'openHealth.history.v2.$expected');
    expect(
      sensorHistoryKey(
        const DiscoveredSensor(
          driverId: 'aidex',
          deviceId: 'synthetic-target',
          storageKey: 'synthetic-storage',
          displayName: 'Synthetic',
          rssi: -50,
          capabilities: CgmCapabilities(),
        ),
      ),
      'openHealth.history.synthetic-storage',
    );
  });

  test(
    'ordinary and archive lists keep their previous replacement shape',
    () async {
      for (final ordinaryKey in [
        'openHealth.history.synthetic-aidex',
        'openHealth.history.archive.synthetic',
      ]) {
        await repository.merge(ordinaryKey, [reading(1)]);
        await repository.merge(ordinaryKey, [reading(2)]);
        expect(
          store.values[ordinaryKey],
          jsonEncode([reading(2).toJson()]),
        );
        expect(
          repository.readCommittedHistory(ordinaryKey).single.sensorMinute,
          2,
        );
        expect(repository.retainOnDisconnect(ordinaryKey), isFalse);
        await repository.clear(ordinaryKey);
        expect(store.values.containsKey(ordinaryKey), isFalse);
      }
    },
  );

  test(
    'load establishes an empty bound record but never creates freshness',
    () async {
      final state = await observations.load(binding);
      expect(state.observedMinute, isNull);
      expect(state.history, isEmpty);
      expect(envelope()['frontierProvenance'], 'none');
      expect(repository.retainOnDisconnect(key), isTrue);
      final writes = store.writes;
      await observations.load(binding);
      expect(store.writes, writes);
    },
  );

  test(
    'frontier and optional reading commit in one atomic history write',
    () async {
      final sample = reading(60);
      final result = await commit(60, sample: sample);
      expect(result.advanced, isTrue);
      expect(result.state.observedMinute, 60);
      expect(result.state.history.single.toJson(), sample.toJson());
      expect(store.writes, 1);
      expect(envelope()['frontierProvenance'], 'observed');
      expect(envelope()['observedMinute'], 60);
      expect(
        repository.readCommittedHistory(key).single.toJson(),
        sample.toJson(),
      );
    },
  );

  test(
    'decoder-free observation survives a new repository and rejects replay',
    () async {
      await commit(65);
      final restarted = LibreGen1HistoryObservationStore(
        SensorHistoryRepository(store),
      );
      final loaded = await restarted.load(binding);
      expect(loaded.observedMinute, 65);
      expect(loaded.history, isEmpty);
      final duplicate = await restarted.commit(
        binding,
        sensorMinute: 65,
        receivedAt: reading(65).recordedAt!,
        reading: reading(65),
      );
      expect(duplicate.advanced, isFalse);
      expect(duplicate.state.history, isEmpty);
      expect(store.writes, 1);
    },
  );

  test(
    'duplicate or regressed observations preserve first receipt and quality',
    () async {
      final first = reading(60);
      await commit(60, sample: first);
      final bytes = store.values[key];
      final repeated = reading(60, value: 999, at: now, provisional: false);
      expect((await commit(60, sample: repeated)).advanced, isFalse);
      expect((await commit(59, sample: reading(59))).advanced, isFalse);
      expect(store.values[key], bytes);
      expect(store.writes, 1);
      expect(
        repository.readCommittedHistory(key).single.toJson(),
        first.toJson(),
      );
      expect(
        repository.filterRetainedHistory(key, [repeated]).single.toJson(),
        first.toJson(),
      );
    },
  );

  test(
    'legacy migration retains first samples with a lower-bound frontier',
    () async {
      final first = reading(60);
      store.values[key] = jsonEncode([
        first.toJson(),
        reading(60, value: 999, at: now).toJson(),
        reading(63).toJson(),
      ]);
      final state = await observations.load(binding);
      expect(state.observedMinute, 63);
      expect(state.history, hasLength(2));
      expect(state.history.first.toJson(), first.toJson());
      expect(envelope()['frontierProvenance'], 'legacyLowerBound');
      expect((await commit(63)).advanced, isFalse);
      expect(envelope()['frontierProvenance'], 'legacyLowerBound');
      await commit(64);
      expect(envelope()['frontierProvenance'], 'observed');
      expect(envelope()['observedMinute'], 64);
      expect(repository.readCommittedHistory(key), hasLength(2));
    },
  );

  test('commit can migrate legacy and advance in one write', () async {
    store.values[key] = jsonEncode([reading(60).toJson()]);
    await commit(61, sample: reading(61));
    expect(store.writes, 1);
    expect(envelope()['observedMinute'], 61);
    expect(repository.readCommittedHistory(key), hasLength(2));
  });

  test(
    'absent active history migrates exact-bootstrap archive union once',
    () async {
      final first = reading(60, at: now.subtract(const Duration(minutes: 3)));
      archiveManifest([
        archive(3, [reading(60, value: 999), reading(65)]),
        archive(2, [reading(61)]),
        archive(1, [first, reading(61)]),
      ]);
      final archiveBytes = Map<String, String>.of(store.values);
      expect(store.values.containsKey(key), isFalse);
      final migrated = await observations.load(binding);
      expect(migrated.observedMinute, 65);
      expect(migrated.history, hasLength(3));
      expect(
        migrated.history
            .singleWhere((entry) => entry.sensorMinute == 60)
            .toJson(),
        first.toJson(),
      );
      expect(envelope()['frontierProvenance'], 'legacyLowerBound');
      expect(store.writes, 1);
      for (final entry in archiveBytes.entries) {
        expect(store.values[entry.key], entry.value);
      }
      expect(
        (await commit(65, sample: reading(65, at: now))).advanced,
        isFalse,
      );
      expect(store.writes, 1);
    },
  );

  test(
    'active legacy and archive history both contribute accepted lower bounds',
    () async {
      store.values[key] = jsonEncode([reading(66).toJson()]);
      archiveManifest([
        archive(1, [reading(60), reading(65)]),
      ]);
      final result = await commit(67, sample: reading(67));
      expect(result.advanced, isTrue);
      expect(result.state.observedMinute, 67);
      expect(result.state.history.map((entry) => entry.sensorMinute).toSet(), {
        60,
        65,
        66,
        67,
      });
      expect(store.writes, 1);
    },
  );

  test(
    'different bootstrap or driver archives are not opened or imported',
    () async {
      final differentBootstrap = archive(1, [
        reading(900),
      ], storageKey: 'libre2-gen1:other-bootstrap');
      final differentDriver = archive(2, [reading(800)], driverId: 'aidex');
      archiveManifest([
        differentBootstrap,
        differentDriver,
        archive(3, [reading(60)]),
      ]);
      // These unrelated references are intentionally unreadable. They must not
      // block recovery of the current receiver or supply its replay frontier.
      store.values[differentBootstrap['historyKey']! as String] =
          'unrelated-invalid-json';
      store.values.remove(differentDriver['historyKey']);
      final state = await observations.load(binding);
      expect(state.observedMinute, 60);
      expect(state.history.single.sensorMinute, 60);
    },
  );

  test('bound clear tombstone never reimports archive history', () async {
    archiveManifest([
      archive(1, [reading(60)]),
    ]);
    await observations.load(binding);
    await repository.clear(key);
    final tombstone = store.values[key];
    archiveManifest([
      archive(2, [reading(61), reading(65)]),
    ]);
    final cleared = await observations.load(binding);
    expect(cleared.observedMinute, 60);
    expect(cleared.history, isEmpty);
    expect(store.values[key], tombstone);
    store.values['openHealth.sensorArchive'] = 'unreadable-unrelated-manifest';
    expect((await observations.load(binding)).history, isEmpty);
    await commit(61);
    expect(repository.readCommittedHistory(key), isEmpty);
  });

  test(
    'matching empty archive with no blob is a valid legacy segment',
    () async {
      archiveManifest([
        archive(1, []),
        archive(2, [reading(60)]),
      ]);
      expect((await observations.load(binding)).observedMinute, 60);
      expect(repository.readCommittedHistory(key), hasLength(1));
    },
  );

  test('missing nonempty related archive prevents partial migration', () async {
    final missing = archive(2, [reading(65)]);
    archiveManifest([
      archive(1, [reading(60)]),
      missing,
    ]);
    store.values.remove(missing['historyKey']);
    final before = Map<String, String>.of(store.values);
    await expectLater(observations.load(binding), throwsStateError);
    await expectLater(commit(66), throwsStateError);
    expect(store.values, before);
    expect(store.writes, 0);
  });

  test(
    'related archive reference cannot point at another sensor or key family',
    () async {
      final valid = archive(1, [reading(60)]);
      final other = archive(2, [
        reading(900),
      ], storageKey: 'libre2-gen1:other-bootstrap');
      for (final invalid in [
        <String, Object?>{...valid, 'historyKey': other['historyKey']},
        <String, Object?>{
          ...valid,
          'id': other['id'],
          'historyKey': other['historyKey'],
        },
        <String, Object?>{...valid, 'historyKey': key},
        <String, Object?>{...valid, 'id': '${valid['id']}='},
        <String, Object?>{...valid, 'readingCount': 0},
        <String, Object?>{...valid, 'readingCount': 1.0},
        <String, Object?>{...valid, 'futureReferenceFormat': true},
      ]) {
        archiveManifest([invalid]);
        final before = Map<String, String>.of(store.values);
        await expectLater(observations.load(binding), throwsStateError);
        expect(store.values, before);
      }
      expect(store.writes, 0);
    },
  );

  test('corrupt related archive reading or manifest is preserved', () async {
    final related = archive(1, [reading(60)]);
    archiveManifest([related]);
    store.values[related['historyKey']! as String] = jsonEncode([
      <String, Object?>{...reading(60).toJson(), 'source': 'future-source'},
    ]);
    final before = Map<String, String>.of(store.values);
    await expectLater(observations.load(binding), throwsStateError);
    expect(store.values, before);
    for (final raw in ['invalid-json', '{}', '[{"driverId":"libre2-gen1"}]']) {
      store.values['openHealth.sensorArchive'] = raw;
      await expectLater(observations.load(binding), throwsStateError);
      expect(store.values['openHealth.sensorArchive'], raw);
      expect(store.values.containsKey(key), isFalse);
    }
    expect(store.writes, 0);
  });

  test(
    'valid archived variant roundtrips without changing its fields',
    () async {
      const variant = CgmSensorVariant(
        protocolFamily: 'libre2-gen1',
        source: CgmSensorVariantSource.nfcPatchInfo,
        model: 'Libre 2',
        variantCode: 'synthetic-model',
        region: 'synthetic-region',
        hardwareRevision: '1',
        firmwareRevision: '2',
        softwareRevision: '3',
        securityGeneration: 'gen1',
      );
      final related = archive(1, [reading(60)])
        ..['sensorVariant'] = variant.toJson();
      archiveManifest([related]);
      final before = Map<String, String>.of(store.values);
      expect(
        repository.readLibreArchivedHistoryGroups()[binding.storageKey],
        hasLength(1),
      );
      expect((await observations.load(binding)).history, hasLength(1));
      for (final entry in before.entries) {
        expect(store.values[entry.key], entry.value);
      }
      // Null and absent variants are both legacy-compatible representations.
      archiveManifest([
        <String, Object?>{...related, 'sensorVariant': null},
      ]);
      expect(
        repository.readLibreArchivedHistoryGroups()[binding.storageKey],
        hasLength(1),
      );
      related.remove('sensorVariant');
      archiveManifest([related]);
      expect(
        repository.readLibreArchivedHistoryGroups()[binding.storageKey],
        hasLength(1),
      );
    },
  );

  test(
    'non-lossless archived variants cannot be normalized or rewritten',
    () async {
      final related = archive(1, [reading(60)]);
      const valid = <String, Object?>{
        'protocolFamily': 'libre2-gen1',
        'source': 'nfcPatchInfo',
        'model': 'Libre 2',
      };
      for (final variant in <Object?>[
        'wrong-type',
        <String, Object?>{...valid, 'source': 'future'},
        <String, Object?>{...valid, 'futureField': 'unknown'},
        <String, Object?>{...valid, 'model': 3},
        <String, Object?>{...valid, 'model': null},
        <String, Object?>{...valid, 'model': ' Libre 2 '},
        <String, Object?>{...valid, 'source': false},
        <String, Object?>{...valid, 'protocolFamily': ' libre2-gen1 '},
        <String, Object?>{...valid, 'firmwareRevision': 'x' * 129},
        <String, Object?>{'source': 'nfcPatchInfo'},
      ]) {
        archiveManifest([
          <String, Object?>{...related, 'sensorVariant': variant},
        ]);
        final before = Map<String, String>.of(store.values);
        expect(repository.readLibreArchivedHistoryGroups, throwsStateError);
        await expectLater(observations.load(binding), throwsStateError);
        await expectLater(
          repository.unarchivedLibreReadings(
            sensor: sensor,
            incoming: [reading(61)],
          ),
          throwsStateError,
        );
        await expectLater(repository.clear(key), throwsStateError);
        expect(store.values, before);
      }
      expect(store.writes, 0);
    },
  );

  test('strict archive groups deduplicate within each bootstrap only', () {
    final first = reading(60, at: now.subtract(const Duration(minutes: 3)));
    final unrelated = archive(4, [reading(60)], driverId: 'aidex');
    archiveManifest([
      archive(1, [first, reading(61)]),
      archive(2, [reading(60, value: 999)]),
      archive(3, [reading(60)], storageKey: 'libre2-gen1:another-bootstrap'),
      unrelated,
    ]);
    store.values[unrelated['historyKey']! as String] = 'unreadable-unrelated';
    final before = Map<String, String>.of(store.values);
    final groups = repository.readLibreArchivedHistoryGroups();
    expect(groups, hasLength(2));
    expect(groups[binding.storageKey], hasLength(2));
    expect(
      groups[binding.storageKey]!
          .singleWhere((entry) => entry.sensorMinute == 60)
          .toJson(),
      first.toJson(),
    );
    expect(groups['libre2-gen1:another-bootstrap'], hasLength(1));
    expect(groups.clear, throwsUnsupportedError);
    expect(() => groups[binding.storageKey]!.clear(), throwsUnsupportedError);
    expect(store.values, before);
    expect(store.writes, 0);
  });

  test(
    'legacy archive delta is read-only and does not invent a binding',
    () async {
      archiveManifest([
        archive(1, [reading(60)]),
      ]);
      final before = Map<String, String>.of(store.values);
      final delta = await repository.unarchivedLibreReadings(
        sensor: sensor,
        incoming: [reading(60), reading(61), reading(61)],
      );
      expect(delta.single.sensorMinute, 61);
      expect(store.values, before);
      expect(store.values.containsKey(key), isFalse);
      expect(store.writes, 0);
    },
  );

  test(
    'bound archive delta uses only committed first receipts and clear policy',
    () async {
      archiveManifest([
        archive(1, [reading(60)]),
      ]);
      await observations.load(binding);
      final accepted = reading(61);
      await commit(61, sample: accepted);
      final before = Map<String, String>.of(store.values);
      final delta = await repository.unarchivedLibreReadings(
        sensor: sensor,
        incoming: [
          reading(60),
          reading(61, value: 999, at: now),
          reading(62),
        ],
      );
      expect(delta.single.toJson(), accepted.toJson());
      expect(store.values, before);
      await repository.clear(key);
      expect(
        await repository.unarchivedLibreReadings(
          sensor: sensor,
          incoming: [reading(60), reading(61), reading(62)],
        ),
        isEmpty,
      );
      await commit(62, sample: reading(62));
      expect(
        (await repository.unarchivedLibreReadings(
          sensor: sensor,
          incoming: [reading(60), reading(61), reading(62)],
        )).single.sensorMinute,
        62,
      );
    },
  );

  test(
    'strict archive count and delta reject a malformed related row',
    () async {
      final related = archive(1, [reading(60)]);
      archiveManifest([related]);
      store.values[related['historyKey']! as String] = jsonEncode([
        'malformed',
      ]);
      final before = Map<String, String>.of(store.values);
      expect(repository.readLibreArchivedHistoryGroups, throwsStateError);
      await expectLater(
        repository.unarchivedLibreReadings(
          sensor: sensor,
          incoming: [reading(61)],
        ),
        throwsStateError,
      );
      expect(store.values, before);
      expect(store.writes, 0);
    },
  );

  test('clear cannot erase unbound archive-only replay evidence', () async {
    for (final active in <String?>[null, '[]']) {
      archiveManifest([
        archive(1, [reading(60)]),
      ]);
      if (active == null) {
        store.values.remove(key);
      } else {
        store.values[key] = active;
      }
      final before = Map<String, String>.of(store.values);
      await expectLater(repository.clear(key), throwsStateError);
      expect(store.values, before);
      expect(repository.isQuarantined(key), isFalse);
    }
    expect(store.writes, 0);
  });

  test(
    'clear queued before archive migration fails without hiding retained points',
    () async {
      archiveManifest([
        archive(1, [reading(60)]),
      ]);
      final clear = expectLater(repository.clear(key), throwsStateError);
      final load = observations.load(binding);
      await clear;
      expect((await load).history.single.sensorMinute, 60);
      expect(envelope()['observedMinute'], 60);
      expect(envelope()['clearedThroughMinute'], isNull);
    },
  );

  test(
    'clear queued after migration waits and writes a bound tombstone',
    () async {
      archiveManifest([
        archive(1, [reading(60)]),
      ]);
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final load = observations.load(binding);
      await pumpEventQueue();
      final clear = repository.clear(key);
      var completed = false;
      unawaited(clear.then((_) => completed = true));
      await pumpEventQueue();
      expect(completed, isFalse);
      gate.complete();
      expect((await load).history.single.sensorMinute, 60);
      await clear;
      final afterClear = await observations.load(binding);
      expect(afterClear.history, isEmpty);
      expect(afterClear.observedMinute, 60);
      expect(envelope()['clearedThroughMinute'], 60);
      expect(store.maxActiveWrites, 1);
    },
  );

  test(
    'unrelated archive history does not block empty unbound clear',
    () async {
      archiveManifest([
        archive(1, [reading(60)], storageKey: 'libre2-gen1:another-bootstrap'),
      ]);
      await repository.clear(key);
      expect(store.values.containsKey(key), isFalse);
      final loaded = await observations.load(binding);
      expect(loaded.history, isEmpty);
      expect(loaded.observedMinute, isNull);
    },
  );

  test(
    'declared empty related archive cannot resurrect anything after clear',
    () async {
      archiveManifest([archive(1, [])]);
      store.values[key] = '[]';
      await repository.clear(key);
      expect(store.values.containsKey(key), isFalse);
      expect((await observations.load(binding)).history, isEmpty);
    },
  );

  test(
    'corrupt related archive blocks clear of an empty legacy list',
    () async {
      final related = archive(1, [reading(60)]);
      archiveManifest([related]);
      store.values[key] = '[]';
      store.values[related['historyKey']! as String] = 'corrupt';
      final before = Map<String, String>.of(store.values);
      await expectLater(repository.clear(key), throwsStateError);
      expect(store.values, before);
    },
  );

  test(
    'offset-less legacy receipt preserves its prior interpreted instant',
    () async {
      const localText = '2026-01-01T12:00:00.000';
      final originalInstant = DateTime.parse(localText);
      store.values[key] = jsonEncode([
        <String, Object?>{...reading(60).toJson(), 'recordedAt': localText},
      ]);
      final migrated = await observations.load(binding);
      expect(
        migrated.history.single.recordedAt!.isAtSameMomentAs(originalInstant),
        isTrue,
      );
      expect(migrated.history.single.recordedAt!.isUtc, isTrue);
      expect(
        (await observations.load(binding)).history.single.recordedAt,
        originalInstant.toUtc(),
      );
      final badEnvelope = envelope();
      ((badEnvelope['readings'] as List).first
              as Map<String, dynamic>)['recordedAt'] =
          localText;
      store.values[key] = jsonEncode(badEnvelope);
      await expectLater(observations.load(binding), throwsStateError);
    },
  );

  test(
    'clear retains decoder-free frontier and rejects disk and UI resurrection',
    () async {
      final old = reading(60);
      await commit(60, sample: old);
      await commit(65);
      await repository.clear(key);
      expect(envelope()['observedMinute'], 65);
      expect(envelope()['clearedThroughMinute'], 65);
      expect(repository.readCommittedHistory(key), isEmpty);
      expect(repository.filterRetainedHistory(key, [old]), isEmpty);
      await repository.merge(key, [old]);
      expect(repository.readCommittedHistory(key), isEmpty);
      expect((await commit(65, sample: reading(65))).advanced, isFalse);
      expect((await observations.load(binding)).observedMinute, 65);
      await commit(66, sample: reading(66));
      expect(repository.readCommittedHistory(key).single.sensorMinute, 66);
      expect(
        repository.filterRetainedHistory(key, [old, reading(66)]),
        hasLength(1),
      );
    },
  );

  test(
    'stale controller merge cannot overwrite a newly committed observation',
    () async {
      await commit(60, sample: reading(60));
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final newer = commit(61, sample: reading(61));
      await pumpEventQueue();
      final stale = repository.merge(key, [reading(60)]);
      expect(store.activeWrites, 1);
      expect(repository.readCommittedHistory(key), hasLength(1));
      gate.complete();
      await newer;
      await stale;
      expect(repository.readCommittedHistory(key), hasLength(2));
      expect(envelope()['observedMinute'], 61);
    },
  );

  test(
    'clear waits for pending commit then leaves a durable tombstone',
    () async {
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final pending = commit(60, sample: reading(60));
      await pumpEventQueue();
      final clear = repository.clear(key);
      final stale = repository.merge(key, [reading(60)]);
      var cleared = false;
      unawaited(clear.then((_) => cleared = true));
      await pumpEventQueue();
      expect(cleared, isFalse);
      gate.complete();
      await pending;
      await clear;
      await stale;
      expect(repository.readCommittedHistory(key), isEmpty);
      expect(envelope()['clearedThroughMinute'], 60);
      expect(store.maxActiveWrites, 1);
    },
  );

  test(
    'authoritative load waits behind a pending observation transaction',
    () async {
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final pending = commit(60);
      await pumpEventQueue();
      final loaded = observations.load(binding);
      var completed = false;
      unawaited(loaded.then((_) => completed = true));
      await pumpEventQueue();
      expect(completed, isFalse);
      gate.complete();
      await pending;
      expect((await loaded).observedMinute, 60);
      expect(store.writes, 1);
    },
  );

  test(
    'failed write quarantines that key but not the owner queue for other keys',
    () async {
      await commit(60);
      final before = store.values[key];
      store.failNextWrite = true;
      await expectLater(commit(61, sample: reading(61)), throwsStateError);
      expect(store.values[key], before);
      expect(repository.isQuarantined(key), isTrue);
      await expectLater(observations.load(binding), throwsStateError);
      await expectLater(commit(61, sample: reading(61)), throwsStateError);
      await expectLater(repository.clear(key), throwsStateError);
      await expectLater(repository.merge(key, []), throwsStateError);
      expect(repository.readCommittedHistory(key), isEmpty);
      expect(repository.filterRetainedHistory(key, [reading(61)]), isEmpty);
      await repository.merge('openHealth.history.other', [reading(1)]);
      expect(
        repository.readCommittedHistory('openHealth.history.other'),
        hasLength(1),
      );
    },
  );

  test('failed clear preserves readings and replay frontier', () async {
    await commit(60, sample: reading(60));
    final before = store.values[key];
    store.failNextWrite = true;
    await expectLater(repository.clear(key), throwsStateError);
    expect(store.values[key], before);
    expect(repository.isQuarantined(key), isTrue);
    expect(repository.filterRetainedHistory(key, [reading(60)]), hasLength(1));
  });

  test(
    'local receipt representation is stored as the same UTC instant',
    () async {
      final local = now.subtract(const Duration(minutes: 1)).toLocal();
      await commit(60, sample: reading(60, at: local));
      final retained = (await observations.load(binding)).history.single;
      expect(retained.recordedAt!.isAtSameMomentAs(local), isTrue);
      expect(retained.recordedAt!.isUtc, isTrue);
      expect(retained.isDisplayProvisional, isTrue);
    },
  );

  test(
    'wall-clock rollback does not reject or move saved receipt instants',
    () async {
      final beforeRollback = DateTime.utc(2099, 1, 2);
      final afterRollback = beforeRollback.subtract(const Duration(days: 1));
      await commit(60, sample: reading(60, at: beforeRollback));
      final restarted = LibreGen1HistoryObservationStore(
        SensorHistoryRepository(store),
      );
      expect(
        (await restarted.load(binding)).history.single.recordedAt,
        beforeRollback,
      );
      await restarted.commit(
        binding,
        sensorMinute: 61,
        receivedAt: afterRollback,
        reading: reading(61, at: afterRollback),
      );
      final retained = repository.readCommittedHistory(key);
      expect(
        retained.singleWhere((entry) => entry.sensorMinute == 60).recordedAt,
        beforeRollback,
      );
      expect(
        retained.singleWhere((entry) => entry.sensorMinute == 61).recordedAt,
        afterRollback,
      );
      expect((await restarted.load(binding)).observedMinute, 61);
    },
  );

  test(
    'caller timeout does not release the pending transaction queue',
    () async {
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final pending = commit(60, sample: reading(60));
      await expectLater(
        pending.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      final next = commit(61, sample: reading(61));
      await pumpEventQueue();
      expect(store.activeWrites, 1);
      expect(store.writes, 0);
      gate.complete();
      await pending;
      await next;
      expect(envelope()['observedMinute'], 61);
      expect(repository.readCommittedHistory(key), hasLength(2));
      expect(store.maxActiveWrites, 1);
    },
  );

  test(
    'lost write acknowledgement requires a fresh backing store and owner',
    () async {
      store.failAfterNextWrite = true;
      await expectLater(commit(60, sample: reading(60)), throwsStateError);
      await expectLater(observations.load(binding), throwsStateError);
      expect(repository.readCommittedHistory(key), isEmpty);
      final reloadedStore = _Store()..values.addAll(store.values);
      final restarted = LibreGen1HistoryObservationStore(
        SensorHistoryRepository(reloadedStore),
      );
      expect((await restarted.load(binding)).observedMinute, 60);
      expect(
        (await restarted.commit(
          binding,
          sensorMinute: 60,
          receivedAt: now,
          reading: reading(60, at: now),
        )).advanced,
        isFalse,
      );
      expect(store.writes, 1);
      expect(
        (await restarted.load(binding)).history.single.recordedAt,
        reading(60).recordedAt,
      );
    },
  );

  test(
    'uncertain durable write with stale backend cache cannot lose the frontier',
    () async {
      await commit(60, sample: reading(60));
      final confirmed = store.values[key];
      store.commitWithoutCacheThenFail = true;
      await expectLater(commit(61, sample: reading(61)), throwsStateError);
      final hiddenDurable = store.hiddenDurableWrite;
      expect((jsonDecode(hiddenDurable!) as Map)['observedMinute'], 61);
      expect(store.values[key], confirmed);
      // Even if backend cache is changed after the failure, display reads use
      // only the last repository-confirmed record, not these unknown bytes.
      store.values[key] = hiddenDurable;
      expect(repository.readCommittedHistory(key).single.sensorMinute, 60);
      expect(
        repository
            .filterRetainedHistory(key, [reading(60), reading(61)])
            .single
            .sensorMinute,
        60,
      );
      await expectLater(repository.clear(key), throwsStateError);
      await expectLater(repository.merge(key, []), throwsStateError);
      await expectLater(commit(62), throwsStateError);
      expect(store.hiddenDurableWrite, hiddenDurable);
      expect(store.values[key], hiddenDurable);
    },
  );

  test(
    'exact bootstrap or sensor digest mismatch cannot rewrite history',
    () async {
      await commit(60, sample: reading(60));
      final before = store.values[key];
      final mismatch = LibreGen1ObservationBinding(
        bootstrapId: binding.bootstrapId,
        sensorBindingDigest: 'b' * 64,
      );
      await expectLater(observations.load(mismatch), throwsStateError);
      await expectLater(
        observations.commit(mismatch, sensorMinute: 61, receivedAt: now),
        throwsStateError,
      );
      expect(store.values[key], before);
      final mismatchedRecord = envelope()..['storageKey'] = 'libre2-gen1:other';
      store.values[key] = jsonEncode(mismatchedRecord);
      expect(() => repository.readCommittedHistory(key), throwsStateError);
      await expectLater(repository.clear(key), throwsStateError);
      expect(store.values[key], jsonEncode(mismatchedRecord));
    },
  );

  test(
    'corrupt, future and unknown schema fields fail closed without deletion',
    () async {
      await commit(60, sample: reading(60));
      final valid = envelope();
      for (final bad in <Object?>[
        '{not-json',
        <String, Object?>{...valid, 'schemaVersion': 2},
        <String, Object?>{...valid, 'futureField': true},
        <String, Object?>{...valid, 'observedMinute': 60.5},
        <String, Object?>{...valid, 'observedMinute': 0x10000},
        <String, Object?>{...valid, 'observedMinute': null},
        <String, Object?>{...valid, 'clearedThroughMinute': 61},
        <String, Object?>{...valid, 'clearedThroughMinute': 60},
        <String, Object?>{...valid, 'frontierProvenance': 'guessed'},
        <String, Object?>{
          ...valid,
          'readings': [reading(61).toJson()],
        },
        <String, Object?>{
          ...valid,
          'readings': [reading(60).toJson(), reading(60).toJson()],
        },
      ]) {
        final raw = bad is String ? bad : jsonEncode(bad);
        store.values[key] = raw;
        await expectLater(observations.load(binding), throwsStateError);
        await expectLater(commit(62), throwsStateError);
        await expectLater(repository.merge(key, []), throwsStateError);
        await expectLater(repository.clear(key), throwsStateError);
        expect(() => repository.retainOnDisconnect(key), throwsStateError);
        expect(store.values[key], raw);
      }
    },
  );

  test(
    'malformed legacy readings are not partially migrated or deleted',
    () async {
      for (final bad in <Object?>[
        'invalid-reading',
        <String, Object?>{...reading(60).toJson(), 'source': 'future'},
        <String, Object?>{...reading(60).toJson(), 'sensorMinute': -1},
        <String, Object?>{...reading(60).toJson(), 'valueMgdl': null},
        <String, Object?>{...reading(60).toJson(), 'recordedAt': 'invalid'},
        <String, Object?>{
          ...reading(60).toJson(),
          'isDisplayProvisional': 'false',
        },
        <String, Object?>{...reading(60).toJson(), 'unrecognized': true},
      ]) {
        final raw = jsonEncode([reading(59).toJson(), bad]);
        store.values[key] = raw;
        await expectLater(observations.load(binding), throwsStateError);
        await expectLater(repository.clear(key), throwsStateError);
        expect(store.values[key], raw);
      }
      expect(store.writes, 0);
    },
  );

  test(
    'legacy Libre clear requires a bound migration and keeps bytes on failure',
    () async {
      final raw = jsonEncode([reading(60).toJson()]);
      store.values[key] = raw;
      expect(repository.retainOnDisconnect(key), isFalse);
      await expectLater(repository.clear(key), throwsStateError);
      expect(store.values[key], raw);
      await observations.load(binding);
      await repository.clear(key);
      expect(envelope()['clearedThroughMinute'], 60);
    },
  );

  test(
    'commit rejects invalid minute, time and optional reading binding',
    () async {
      await observations.load(binding);
      final before = store.values[key];
      for (final minute in [-1, 0x10000]) {
        await expectLater(commit(minute), throwsStateError);
      }
      await expectLater(commit(60, sample: reading(61)), throwsStateError);
      await expectLater(
        observations.commit(
          binding,
          sensorMinute: 60,
          receivedAt: now,
          reading: reading(60),
        ),
        throwsStateError,
      );
      await expectLater(
        commit(60, sample: reading(60, value: double.nan)),
        throwsStateError,
      );
      expect(store.values[key], before);
    },
  );

  test(
    'ordinary incoming list is snapshotted before queued encoding',
    () async {
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      final first = repository.merge('openHealth.history.other', [reading(1)]);
      await pumpEventQueue();
      final mutable = [reading(2)];
      final second = repository.merge('openHealth.history.other', mutable);
      mutable.clear();
      gate.complete();
      await first;
      await second;
      expect(
        repository
            .readCommittedHistory('openHealth.history.other')
            .single
            .sensorMinute,
        2,
      );
    },
  );
}

final class _Store implements HealthStateStore {
  final values = <String, String>{};
  int writes = 0;
  int activeWrites = 0;
  int maxActiveWrites = 0;
  Completer<void>? nextWriteGate;
  bool failNextWrite = false;
  bool failAfterNextWrite = false;
  bool commitWithoutCacheThenFail = false;
  String? hiddenDurableWrite;

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async {
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    final gate = nextWriteGate;
    nextWriteGate = null;
    try {
      if (gate != null) await gate.future;
      if (failNextWrite) {
        failNextWrite = false;
        throw StateError('Synthetic write failure.');
      }
      if (commitWithoutCacheThenFail) {
        commitWithoutCacheThenFail = false;
        hiddenDurableWrite = value;
        throw StateError('Synthetic ambiguous rollback failure.');
      }
      values[key] = value;
      writes++;
      if (failAfterNextWrite) {
        failAfterNextWrite = false;
        throw StateError('Synthetic lost write acknowledgement.');
      }
    } finally {
      activeWrites--;
    }
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}
