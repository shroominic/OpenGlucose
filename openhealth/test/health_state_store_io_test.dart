import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store_io.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _fileName = 'restricted-health-state.json';
const _productDirectoryName = 'OpenGlucose';
const _storageDirectoryName = 'RestrictedHealthState';
const _historyDirectoryName = 'HistoryBlobs';
const _historyBlobExtension = '.blob';
const _lastSensorKey = 'openHealth.lastSensor';
const _bondTransferKey = 'openHealth.bondTransfer.serial:SENSOR-1';
const _healthExportLastSyncedKey = 'openHealth.healthExport.lastSyncedMs';
const _healthExportWatermarkKey = 'openHealth.healthExport.watermarkMs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migrates restricted preferences into a versioned excluded file',
    () async {
      final directory = await _temporaryDirectory('migration');
      SharedPreferences.setMockInitialValues(<String, Object>{
        _lastSensorKey: '{"deviceId":"sensor-1"}',
        _bondTransferKey: 'outcome-unknown',
        'openHealth.history.sensor-1': '[{"valueMgdl":100}]',
        'openHealth.displayPreferences': '{"unit":"mgdl"}',
      });
      final preferences = await SharedPreferences.getInstance();
      final excludedPaths = <String>[];
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async => excludedPaths.add(path),
      );

      await store.initialize();

      expect(store.getString(_lastSensorKey), contains('sensor-1'));
      expect(store.getString(_bondTransferKey), 'outcome-unknown');
      expect(
        store.getString('openHealth.history.sensor-1'),
        contains('valueMgdl'),
      );
      expect(preferences.containsKey(_lastSensorKey), isFalse);
      expect(preferences.containsKey(_bondTransferKey), isFalse);
      expect(preferences.containsKey('openHealth.history.sensor-1'), isFalse);
      expect(preferences.containsKey('openHealth.displayPreferences'), isTrue);
      expect(excludedPaths, isNotEmpty);
      expect(
        p.equals(
          excludedPaths.first,
          p.join(
            directory.path,
            _productDirectoryName,
            _storageDirectoryName,
          ),
        ),
        isTrue,
      );
      expect(
        p.equals(
          excludedPaths.last,
          p.join(
            directory.path,
            _productDirectoryName,
            _storageDirectoryName,
            _fileName,
          ),
        ),
        isTrue,
      );

      final envelope = await _readEnvelope(directory);
      expect(envelope['schemaVersion'], 3);
      expect(
        envelope['values'],
        containsPair(_lastSensorKey, '{"deviceId":"sensor-1"}'),
      );
      expect(
        envelope['values'],
        containsPair(_bondTransferKey, 'outcome-unknown'),
      );
      expect(
        envelope['values'] as Map<String, dynamic>,
        isNot(contains('openHealth.history.sensor-1')),
      );
      expect(
        envelope['values'] as Map<String, dynamic>,
        isNot(contains('openHealth.displayPreferences')),
      );
      expect(
        await _historyBlob(
          directory,
          'openHealth.history.sensor-1',
        ).readAsString(),
        '[{"valueMgdl":100}]',
      );
    },
  );

  test(
    'migrates legacy integer export timestamps and restores them from file',
    () async {
      final directory = await _temporaryDirectory('export-migration');
      final lastSyncedAt = DateTime.utc(2026, 6, 22, 12);
      final watermark = lastSyncedAt.subtract(const Duration(minutes: 5));
      SharedPreferences.setMockInitialValues(<String, Object>{
        _healthExportLastSyncedKey: lastSyncedAt.millisecondsSinceEpoch,
        _healthExportWatermarkKey: watermark.millisecondsSinceEpoch,
        'openHealth.healthExport.enabled': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await store.initialize();

      expect(
        store.getString(_healthExportLastSyncedKey),
        lastSyncedAt.millisecondsSinceEpoch.toString(),
      );
      expect(
        store.getString(_healthExportWatermarkKey),
        watermark.millisecondsSinceEpoch.toString(),
      );
      expect(preferences.containsKey(_healthExportLastSyncedKey), isFalse);
      expect(preferences.containsKey(_healthExportWatermarkKey), isFalse);
      expect(preferences.getBool('openHealth.healthExport.enabled'), isTrue);
      final values = (await _readEnvelope(directory))['values'];
      expect(
        values,
        containsPair(
          _healthExportLastSyncedKey,
          lastSyncedAt.millisecondsSinceEpoch.toString(),
        ),
      );
      expect(
        values,
        containsPair(
          _healthExportWatermarkKey,
          watermark.millisecondsSinceEpoch.toString(),
        ),
      );

      final restoredStore = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );
      await restoredStore.initialize();

      expect(
        restoredStore.getString(_healthExportLastSyncedKey),
        lastSyncedAt.millisecondsSinceEpoch.toString(),
      );
      expect(
        restoredStore.getString(_healthExportWatermarkKey),
        watermark.millisecondsSinceEpoch.toString(),
      );
    },
  );

  test('does not remove legacy data when backup exclusion fails', () async {
    final directory = await _temporaryDirectory('exclusion-failure');
    SharedPreferences.setMockInitialValues(<String, Object>{
      _lastSensorKey: '{"deviceId":"sensor-2"}',
    });
    final preferences = await SharedPreferences.getInstance();
    final store = FileHealthStateStore(
      legacyPreferences: preferences,
      directoryProvider: () async => directory,
      requiresBackupExclusion: true,
      backupExclusionMarker: (_) async => throw StateError('denied'),
    );

    await expectLater(store.initialize(), throwsStateError);

    expect(preferences.containsKey(_lastSensorKey), isTrue);
  });

  test('serializes mutations and exposes only committed snapshots', () async {
    final directory = await _temporaryDirectory('concurrency');
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final firstWriteReached = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    var blockWrites = false;
    var activeMarkers = 0;
    var maximumActiveMarkers = 0;
    var blockedOnce = false;
    final store = FileHealthStateStore(
      legacyPreferences: preferences,
      directoryProvider: () async => directory,
      requiresBackupExclusion: true,
      backupExclusionMarker: (path) async {
        if (!blockWrites || !path.endsWith('.next')) {
          return;
        }
        activeMarkers += 1;
        maximumActiveMarkers = activeMarkers > maximumActiveMarkers
            ? activeMarkers
            : maximumActiveMarkers;
        if (!blockedOnce) {
          blockedOnce = true;
          firstWriteReached.complete();
          await releaseFirstWrite.future;
        }
        activeMarkers -= 1;
      },
    );
    await store.initialize();
    blockWrites = true;

    final first = store.setString(_lastSensorKey, 'sensor-a');
    await firstWriteReached.future;
    final second = store.setString('openHealth.history.sensor-a', 'history-a');

    expect(store.getString(_lastSensorKey), isNull);
    expect(store.getString('openHealth.history.sensor-a'), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(maximumActiveMarkers, 1);

    releaseFirstWrite.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(store.getString(_lastSensorKey), 'sensor-a');
    expect(store.getString('openHealth.history.sensor-a'), 'history-a');
    expect(maximumActiveMarkers, 1);
    final values = (await _readEnvelope(directory))['values'];
    expect(values, containsPair(_lastSensorKey, 'sensor-a'));
    expect(values, isNot(contains('openHealth.history.sensor-a')));
    expect(
      await _historyBlob(
        directory,
        'openHealth.history.sensor-a',
      ).readAsString(),
      'history-a',
    );
  });

  test(
    'rolls back a post-rename failure and does not poison the queue',
    () async {
      final directory = await _temporaryDirectory('rollback');
      SharedPreferences.setMockInitialValues(<String, Object>{
        _lastSensorKey: 'committed-sensor',
      });
      final preferences = await SharedPreferences.getInstance();
      var failNextFinalVerification = false;
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async {
          if (failNextFinalVerification && path.endsWith(_fileName)) {
            failNextFinalVerification = false;
            throw StateError('verification denied');
          }
        },
      );
      await store.initialize();
      failNextFinalVerification = true;

      final failed = store.setString(_lastSensorKey, 'uncommitted-sensor');
      final queued = store.setString(
        'openHealth.history.committed-sensor',
        'queued-history',
      );

      await expectLater(failed, throwsStateError);
      await queued;

      expect(store.getString(_lastSensorKey), 'committed-sensor');
      expect(
        store.getString('openHealth.history.committed-sensor'),
        'queued-history',
      );
      final values = (await _readEnvelope(directory))['values'];
      expect(values, containsPair(_lastSensorKey, 'committed-sensor'));
      expect(values, isNot(containsPair(_lastSensorKey, 'uncommitted-sensor')));
      expect(
        await _historyBlob(
          directory,
          'openHealth.history.committed-sensor',
        ).readAsString(),
        'queued-history',
      );
      expect(_transactionFile(directory, '.previous').existsSync(), isFalse);
      expect(_transactionFile(directory, '.next').existsSync(), isFalse);
    },
  );

  test(
    'migration is idempotent across repeated store initialization',
    () async {
      final directory = await _temporaryDirectory('idempotent');
      SharedPreferences.setMockInitialValues(<String, Object>{
        _lastSensorKey: 'legacy-sensor',
      });
      final preferences = await SharedPreferences.getInstance();
      final firstStore = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );
      await firstStore.initialize();
      final firstContents = await _stateFile(directory).readAsString();

      final secondStore = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );
      await secondStore.initialize();
      await secondStore.initialize();

      expect(secondStore.getString(_lastSensorKey), 'legacy-sensor');
      expect(await _stateFile(directory).readAsString(), firstContents);
      expect(preferences.containsKey(_lastSensorKey), isFalse);
    },
  );

  test(
    'recovers the previous snapshot after an interrupted pre-rename commit',
    () async {
      final directory = await _temporaryDirectory('pre-rename');
      await _transactionFile(directory, '.previous').writeAsString(
        _encodedEnvelope(<String, String>{_lastSensorKey: 'previous-sensor'}),
      );
      await _transactionFile(directory, '.next').writeAsString(
        _encodedEnvelope(<String, String>{
          _lastSensorKey: 'uncommitted-sensor',
        }),
      );
      final store = await _initializeEmptyStore(directory);

      expect(store.getString(_lastSensorKey), 'previous-sensor');
      expect(_transactionFile(directory, '.next').existsSync(), isFalse);
      expect(_transactionFile(directory, '.previous').existsSync(), isFalse);
    },
  );

  test(
    'accepts the new snapshot after an interrupted post-rename commit',
    () async {
      final directory = await _temporaryDirectory('post-rename');
      await _stateFile(directory).writeAsString(
        _encodedEnvelope(<String, String>{_lastSensorKey: 'new-sensor'}),
      );
      await _transactionFile(directory, '.previous').writeAsString(
        _encodedEnvelope(<String, String>{_lastSensorKey: 'old-sensor'}),
      );
      final store = await _initializeEmptyStore(directory);

      expect(store.getString(_lastSensorKey), 'new-sensor');
      expect(_transactionFile(directory, '.previous').existsSync(), isFalse);
    },
  );

  test(
    'rewrites the unversioned legacy file as schema version three',
    () async {
      final directory = await _temporaryDirectory('legacy-file');
      await _stateFile(directory).writeAsString(
        jsonEncode(<String, String>{_lastSensorKey: 'flat-file-sensor'}),
      );
      final store = await _initializeEmptyStore(directory);

      expect(store.getString(_lastSensorKey), 'flat-file-sensor');
      expect((await _readEnvelope(directory))['schemaVersion'], 3);
    },
  );

  test(
    'keeps each history in an independent blob without rewriting metadata',
    () async {
      final directory = await _temporaryDirectory('independent-blobs');
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final markedPaths = <String>[];
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async => markedPaths.add(path),
      );
      await store.initialize();
      await store.setString(
        'openHealth.sensorArchive',
        '[{"id":"archive-1"}]',
      );
      final metadataBefore = await _stateFile(directory).readAsString();
      markedPaths.clear();

      const archivedKey = 'openHealth.history.archive.archive-1';
      const activeKey = 'openHealth.history.sensor-active';
      const archivedHistory = '[{"valueMgdl":95}]';
      await store.setString(archivedKey, archivedHistory);
      await store.setString(activeKey, '[{"valueMgdl":101}]');
      final archivedBlobBefore = await _historyBlob(
        directory,
        archivedKey,
      ).readAsString();
      await store.setString(activeKey, '[{"valueMgdl":102}]');

      expect(await _stateFile(directory).readAsString(), metadataBefore);
      expect(
        await _historyBlob(directory, archivedKey).readAsString(),
        archivedBlobBefore,
      );
      expect(archivedBlobBefore, archivedHistory);
      expect(
        await _historyBlob(directory, activeKey).readAsString(),
        '[{"valueMgdl":102}]',
      );
      expect(
        markedPaths.where((path) => path.endsWith(_fileName)),
        isEmpty,
      );
      expect(
        markedPaths.where((path) => path.endsWith(_historyBlobExtension)),
        hasLength(3),
      );
      final values = (await _readEnvelope(directory))['values'];
      expect(values, contains('openHealth.sensorArchive'));
      expect(values, isNot(contains(archivedKey)));
      expect(values, isNot(contains(activeKey)));
    },
  );

  test(
    'uses deterministic history filenames that do not encode the key',
    () async {
      final directory = await _temporaryDirectory('private-history-filename');
      final store = await _initializeEmptyStore(directory);
      const key = 'openHealth.history.serial:SENSOR-PRIVATE-42';

      await store.setString(key, 'private-history');

      final blob = _historyBlob(directory, key);
      final fileName = blob.uri.pathSegments.last;
      final reversibleName = base64Url.encode(utf8.encode(key));
      expect(fileName, matches(RegExp(r'^history-[0-9a-f]{64}\.blob$')));
      expect(fileName, isNot(contains('SENSOR-PRIVATE-42')));
      expect(fileName, isNot(contains(reversibleName)));
      expect(await blob.readAsString(), 'private-history');
    },
  );

  test('migrates schema-two reversible history filenames', () async {
    final directory = await _temporaryDirectory('history-name-migration');
    const key = 'openHealth.history.serial:LEGACY-SENSOR-1';
    final legacyBlob = _legacyHistoryBlob(directory, key);
    await _stateFile(directory).writeAsString(
      _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
    );
    await legacyBlob.writeAsString('legacy-history');

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(key), 'legacy-history');
    expect(legacyBlob.existsSync(), isFalse);
    expect(await _historyBlob(directory, key).readAsString(), 'legacy-history');
    expect((await _readEnvelope(directory))['schemaVersion'], 3);
  });

  test('recovers a legacy history transaction before renaming it', () async {
    final directory = await _temporaryDirectory('legacy-name-transaction');
    const key = 'openHealth.history.serial:LEGACY-SENSOR-2';
    final legacyBlob = _legacyHistoryBlob(directory, key);
    await _stateFile(directory).writeAsString(
      _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
    );
    await File('${legacyBlob.path}.previous').writeAsString(
      'committed-history',
    );
    await File('${legacyBlob.path}.next').writeAsString('uncommitted-history');

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(key), 'committed-history');
    expect(legacyBlob.existsSync(), isFalse);
    expect(
      await _historyBlob(directory, key).readAsString(),
      'committed-history',
    );
    expect(File('${legacyBlob.path}.previous').existsSync(), isFalse);
    expect(File('${legacyBlob.path}.next').existsSync(), isFalse);
  });

  test('resumes after a history rename precedes the schema rewrite', () async {
    final directory = await _temporaryDirectory('history-name-resume');
    const key = 'openHealth.history.serial:LEGACY-SENSOR-3';
    await _stateFile(directory).writeAsString(
      _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
    );
    await _historyBlob(directory, key).writeAsString('renamed-history');

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(key), 'renamed-history');
    expect((await _readEnvelope(directory))['schemaVersion'], 3);
  });

  test(
    'removes an identical legacy copy after an interrupted rename',
    () async {
      final directory = await _temporaryDirectory('history-name-duplicate');
      const key = 'openHealth.history.serial:LEGACY-SENSOR-DUPLICATE';
      final legacyBlob = _legacyHistoryBlob(directory, key);
      final migratedBlob = _historyBlob(directory, key);
      await _stateFile(directory).writeAsString(
        _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
      );
      await legacyBlob.writeAsString('same-preserved-history');
      await migratedBlob.writeAsString('same-preserved-history');

      final store = await _initializeEmptyStore(directory);

      expect(store.getString(key), 'same-preserved-history');
      expect(legacyBlob.existsSync(), isFalse);
      expect(await migratedBlob.readAsString(), 'same-preserved-history');
      expect((await _readEnvelope(directory))['schemaVersion'], 3);
    },
  );

  test('retries backup verification after the history rename', () async {
    final directory = await _temporaryDirectory('history-name-exclusion');
    const key = 'openHealth.history.serial:LEGACY-SENSOR-4';
    final legacyBlob = _legacyHistoryBlob(directory, key);
    final migratedBlob = _historyBlob(directory, key);
    await _stateFile(directory).writeAsString(
      _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
    );
    await legacyBlob.writeAsString('preserved-history');
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    var migratedBlobVerificationAttempted = false;
    final failingStore = FileHealthStateStore(
      legacyPreferences: preferences,
      directoryProvider: () async => directory,
      requiresBackupExclusion: true,
      backupExclusionMarker: (path) async {
        if (p.equals(path, migratedBlob.path)) {
          migratedBlobVerificationAttempted = true;
          throw StateError('verification denied');
        }
      },
    );

    await expectLater(failingStore.initialize(), throwsStateError);

    expect(migratedBlobVerificationAttempted, isTrue);
    expect(legacyBlob.existsSync(), isFalse);
    expect(await migratedBlob.readAsString(), 'preserved-history');
    expect((await _readEnvelope(directory))['schemaVersion'], 2);

    final recoveredStore = await _initializeEmptyStore(directory);
    expect(recoveredStore.getString(key), 'preserved-history');
    expect((await _readEnvelope(directory))['schemaVersion'], 3);
  });

  test(
    'fails closed without discarding conflicting migration copies',
    () async {
      final directory = await _temporaryDirectory('history-name-conflict');
      const key = 'openHealth.history.serial:LEGACY-SENSOR-5';
      final legacyBlob = _legacyHistoryBlob(directory, key);
      final migratedBlob = _historyBlob(directory, key);
      await _stateFile(directory).writeAsString(
        _encodedEnvelope(const <String, String>{}, schemaVersion: 2),
      );
      await legacyBlob.writeAsString('legacy-history');
      await migratedBlob.writeAsString('different-migrated-history');
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await expectLater(store.initialize(), throwsStateError);

      expect(await legacyBlob.readAsString(), 'legacy-history');
      expect(await migratedBlob.readAsString(), 'different-migrated-history');
      expect((await _readEnvelope(directory))['schemaVersion'], 2);
    },
  );

  test('migrates schema-one embedded histories into blobs', () async {
    final directory = await _temporaryDirectory('schema-one-history');
    const activeKey = 'openHealth.history.sensor-legacy';
    const archivedKey = 'openHealth.history.archive.legacy-session';
    await _stateFile(directory).writeAsString(
      _encodedEnvelope(<String, String>{
        _lastSensorKey: 'legacy-sensor',
        activeKey: 'active-history',
        archivedKey: 'archived-history',
      }),
    );

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(activeKey), 'active-history');
    expect(store.getString(archivedKey), 'archived-history');
    final envelope = await _readEnvelope(directory);
    expect(envelope['schemaVersion'], 3);
    expect(envelope['values'], <String, String>{
      _lastSensorKey: 'legacy-sensor',
    });
    expect(
      await _historyBlob(directory, activeKey).readAsString(),
      'active-history',
    );
    expect(
      await _historyBlob(directory, archivedKey).readAsString(),
      'archived-history',
    );

    final restoredStore = await _initializeEmptyStore(directory);
    expect(restoredStore.getString(activeKey), 'active-history');
    expect(restoredStore.getString(archivedKey), 'archived-history');
  });

  test(
    'prefers a committed blob when schema-one migration was interrupted',
    () async {
      final directory = await _temporaryDirectory('interrupted-migration');
      const key = 'openHealth.history.sensor-migrating';
      await _stateFile(directory).writeAsString(
        _encodedEnvelope(<String, String>{key: 'stale-embedded-history'}),
      );
      await _historyBlob(
        directory,
        key,
      ).writeAsString('committed-blob-history');

      final store = await _initializeEmptyStore(directory);

      expect(store.getString(key), 'committed-blob-history');
      expect(
        (await _readEnvelope(directory))['values'],
        isNot(contains(key)),
      );
      expect(
        await _historyBlob(directory, key).readAsString(),
        'committed-blob-history',
      );
    },
  );

  test('recovers an interrupted history replacement', () async {
    final directory = await _temporaryDirectory('history-rollback');
    const key = 'openHealth.history.sensor-recovering';
    final blob = _historyBlob(directory, key);
    await File('${blob.path}.previous').writeAsString('committed-history');
    await File('${blob.path}.next').writeAsString('uncommitted-history');

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(key), 'committed-history');
    expect(await blob.readAsString(), 'committed-history');
    expect(File('${blob.path}.previous').existsSync(), isFalse);
    expect(File('${blob.path}.next').existsSync(), isFalse);
  });

  test(
    'rolls back a failed history replacement and continues queued writes',
    () async {
      final directory = await _temporaryDirectory('history-write-rollback');
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      const firstKey = 'openHealth.history.sensor-first';
      const secondKey = 'openHealth.history.sensor-second';
      var failNextFinalVerification = false;
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async {
          if (failNextFinalVerification &&
              path.endsWith(_historyBlobExtension)) {
            failNextFinalVerification = false;
            throw StateError('history verification denied');
          }
        },
      );
      await store.initialize();
      await store.setString(firstKey, 'committed-history');
      failNextFinalVerification = true;

      final failed = store.setString(firstKey, 'uncommitted-history');
      final queued = store.setString(secondKey, 'queued-history');

      await expectLater(failed, throwsStateError);
      await queued;
      expect(store.getString(firstKey), 'committed-history');
      expect(store.getString(secondKey), 'queued-history');
      expect(
        await _historyBlob(directory, firstKey).readAsString(),
        'committed-history',
      );
      expect(
        await _historyBlob(directory, secondKey).readAsString(),
        'queued-history',
      );
      expect(
        File('${_historyBlob(directory, firstKey).path}.previous').existsSync(),
        isFalse,
      );
      expect(
        File('${_historyBlob(directory, firstKey).path}.next').existsSync(),
        isFalse,
      );
    },
  );

  test('finishes an interrupted history removal', () async {
    final directory = await _temporaryDirectory('history-removal');
    const key = 'openHealth.history.sensor-removed';
    final blob = _historyBlob(directory, key);
    await File('${blob.path}.deleted').writeAsString('removed-history');

    final store = await _initializeEmptyStore(directory);

    expect(store.getString(key), isNull);
    expect(blob.existsSync(), isFalse);
    expect(File('${blob.path}.deleted').existsSync(), isFalse);
  });

  test(
    'keeps legacy history when its backup-excluded blob cannot commit',
    () async {
      final directory = await _temporaryDirectory('blob-exclusion-failure');
      const key = 'openHealth.history.sensor-private';
      SharedPreferences.setMockInitialValues(<String, Object>{
        key: 'legacy-private-history',
      });
      final preferences = await SharedPreferences.getInstance();
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async {
          if (path.endsWith('$_historyBlobExtension.next')) {
            throw StateError('blob exclusion denied');
          }
        },
      );

      await expectLater(store.initialize(), throwsStateError);

      expect(preferences.getString(key), 'legacy-private-history');
      expect(_historyBlob(directory, key).existsSync(), isFalse);
    },
  );

  test('preserves a corrupt file and reports a format error', () async {
    final directory = await _temporaryDirectory('corrupt');
    const corruptContents = '{not-json';
    await _stateFile(directory).writeAsString(corruptContents);
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = FileHealthStateStore(
      legacyPreferences: preferences,
      directoryProvider: () async => directory,
      requiresBackupExclusion: false,
    );

    await expectLater(store.initialize(), throwsFormatException);

    expect(await _stateFile(directory).readAsString(), corruptContents);
  });

  test(
    'preserves an unsupported-version file and refuses to downgrade it',
    () async {
      final directory = await _temporaryDirectory('unsupported');
      const futureHistoryKey = 'openHealth.history.serial:FUTURE-SENSOR';
      final legacyBlob = _legacyHistoryBlob(directory, futureHistoryKey);
      final futureNext = File('${legacyBlob.path}.next');
      final futurePrevious = File('${legacyBlob.path}.previous');
      final futureDeleted = File('${legacyBlob.path}.deleted');
      final unsupportedContents = jsonEncode(<String, Object>{
        'schemaVersion': 99,
        'values': <String, String>{_lastSensorKey: 'future-sensor'},
      });
      await _stateFile(directory).writeAsString(unsupportedContents);
      await legacyBlob.writeAsString('future-history');
      await futureNext.writeAsString('future-next');
      await futurePrevious.writeAsString('future-previous');
      await futureDeleted.writeAsString('future-deleted');
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await expectLater(store.initialize(), throwsA(isA<UnsupportedError>()));

      expect(await _stateFile(directory).readAsString(), unsupportedContents);
      expect(await legacyBlob.readAsString(), 'future-history');
      expect(await futureNext.readAsString(), 'future-next');
      expect(await futurePrevious.readAsString(), 'future-previous');
      expect(await futureDeleted.readAsString(), 'future-deleted');
      expect(_historyBlob(directory, futureHistoryKey).existsSync(), isFalse);
    },
  );
}

Future<Directory> _temporaryDirectory(String suffix) async {
  final directory = await Directory.systemTemp.createTemp(
    'openglucose-health-state-$suffix-',
  );
  addTearDown(() async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });
  return directory;
}

File _stateFile(Directory directory) {
  final storageDirectory = Directory(
    p.join(
      directory.path,
      _productDirectoryName,
      _storageDirectoryName,
    ),
  )..createSync(recursive: true);
  return File(p.join(storageDirectory.path, _fileName));
}

File _transactionFile(Directory directory, String suffix) =>
    File('${_stateFile(directory).path}$suffix');

File _historyBlob(Directory directory, String key) {
  final historyDirectory = Directory(
    p.join(
      directory.path,
      _productDirectoryName,
      _storageDirectoryName,
      _historyDirectoryName,
    ),
  )..createSync(recursive: true);
  final digest = crypto.sha256.convert(utf8.encode(key));
  return File(
    p.join(historyDirectory.path, 'history-$digest$_historyBlobExtension'),
  );
}

File _legacyHistoryBlob(Directory directory, String key) {
  final historyDirectory = Directory(
    p.join(
      directory.path,
      _productDirectoryName,
      _storageDirectoryName,
      _historyDirectoryName,
    ),
  )..createSync(recursive: true);
  final encodedKey = base64Url.encode(utf8.encode(key));
  return File(
    p.join(historyDirectory.path, '$encodedKey$_historyBlobExtension'),
  );
}

Future<Map<String, dynamic>> _readEnvelope(Directory directory) async {
  return jsonDecode(await _stateFile(directory).readAsString())
      as Map<String, dynamic>;
}

String _encodedEnvelope(
  Map<String, String> values, {
  int schemaVersion = 1,
}) {
  return jsonEncode(<String, Object>{
    'schemaVersion': schemaVersion,
    'values': values,
  });
}

Future<FileHealthStateStore> _initializeEmptyStore(Directory directory) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  final store = FileHealthStateStore(
    legacyPreferences: preferences,
    directoryProvider: () async => directory,
    requiresBackupExclusion: false,
  );
  await store.initialize();
  return store;
}
