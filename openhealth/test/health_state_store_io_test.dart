import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fileName = 'restricted-health-state.json';
const _storageDirectory = 'OpenGlucose/RestrictedHealthState';
const _lastSensorKey = 'openHealth.lastSensor';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migrates restricted preferences into a versioned excluded file',
    () async {
      final directory = await _temporaryDirectory('migration');
      SharedPreferences.setMockInitialValues(<String, Object>{
        _lastSensorKey: '{"deviceId":"sensor-1"}',
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
      expect(
        store.getString('openHealth.history.sensor-1'),
        contains('valueMgdl'),
      );
      expect(preferences.containsKey(_lastSensorKey), isFalse);
      expect(preferences.containsKey('openHealth.history.sensor-1'), isFalse);
      expect(preferences.containsKey('openHealth.displayPreferences'), isTrue);
      expect(excludedPaths, isNotEmpty);
      expect(excludedPaths.first, endsWith(_storageDirectory));
      expect(excludedPaths.last, endsWith(_fileName));

      final envelope = await _readEnvelope(directory);
      expect(envelope['schemaVersion'], 1);
      expect(
        envelope['values'],
        containsPair(_lastSensorKey, '{"deviceId":"sensor-1"}'),
      );
      expect(
        (envelope['values'] as Map<String, dynamic>),
        isNot(contains('openHealth.displayPreferences')),
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
    expect(values, containsPair('openHealth.history.sensor-a', 'history-a'));
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

  test('rewrites the unversioned legacy file as schema version one', () async {
    final directory = await _temporaryDirectory('legacy-file');
    await _stateFile(directory).writeAsString(
      jsonEncode(<String, String>{_lastSensorKey: 'flat-file-sensor'}),
    );
    final store = await _initializeEmptyStore(directory);

    expect(store.getString(_lastSensorKey), 'flat-file-sensor');
    expect((await _readEnvelope(directory))['schemaVersion'], 1);
  });

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
      final unsupportedContents = jsonEncode(<String, Object>{
        'schemaVersion': 99,
        'values': <String, String>{_lastSensorKey: 'future-sensor'},
      });
      await _stateFile(directory).writeAsString(unsupportedContents);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = FileHealthStateStore(
        legacyPreferences: preferences,
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await expectLater(store.initialize(), throwsA(isA<UnsupportedError>()));

      expect(await _stateFile(directory).readAsString(), unsupportedContents);
    },
  );
}

Future<Directory> _temporaryDirectory(String suffix) async {
  final directory = await Directory.systemTemp.createTemp(
    'openglucose-health-state-$suffix-',
  );
  addTearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  return directory;
}

File _stateFile(Directory directory) {
  final storageDirectory = Directory('${directory.path}/$_storageDirectory')
    ..createSync(recursive: true);
  return File('${storageDirectory.path}/$_fileName');
}

File _transactionFile(Directory directory, String suffix) =>
    File('${_stateFile(directory).path}$suffix');

Future<Map<String, dynamic>> _readEnvelope(Directory directory) async {
  return jsonDecode(await _stateFile(directory).readAsString())
      as Map<String, dynamic>;
}

String _encodedEnvelope(Map<String, String> values) {
  return jsonEncode(<String, Object>{'schemaVersion': 1, 'values': values});
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
