import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/apple_health_context_import_state.dart';
import 'package:openglucose/src/apple_health_context_import_state_store_io.dart';

void main() {
  test(
    'writes deterministic versioned import state to backup-excluded artifacts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openglucose-health-import-state-',
      );
      final excludedPaths = <String>[];
      try {
        final store = FileAppleHealthContextImportStateStore(
          directoryProvider: () async => directory,
          requiresBackupExclusion: true,
          backupExclusionMarker: (path) async {
            excludedPaths.add(path);
          },
        );
        await store.initialize();
        final syncedAt = DateTime.utc(2026, 8, 24, 12);
        await store.save(
          AppleHealthContextImportState(
            lastSyncedAt: syncedAt,
            anchors: const <String, String>{
              'workout': 'workout-anchor',
              'heartRate': 'heart-rate-anchor',
              'sleep': 'sleep-anchor',
            },
          ),
        );
        await store.save(
          AppleHealthContextImportState(
            lastSyncedAt: syncedAt,
            anchors: const <String, String>{'sleep': 'replacement-anchor'},
          ),
        );

        final file = File(
          '${directory.path}${Platform.pathSeparator}OpenGlucose'
          '${Platform.pathSeparator}AppleHealthContextImport'
          '${Platform.pathSeparator}import-state.json',
        );
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(decoded['schemaVersion'], 1);
        expect(decoded['lastSyncedMs'], syncedAt.millisecondsSinceEpoch);
        expect(decoded['anchors'], <String, dynamic>{
          'sleep': 'replacement-anchor',
        });
        expect(excludedPaths, contains(file.path));
        expect(excludedPaths, contains('${file.path}.next'));
        expect(excludedPaths, contains('${file.path}.previous'));
        expect(
          excludedPaths,
          contains(
            '${directory.path}${Platform.pathSeparator}OpenGlucose'
            '${Platform.pathSeparator}AppleHealthContextImport',
          ),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'a downgraded app rejects a future import-state schema without rewriting it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openglucose-health-import-future-',
      );
      try {
        final stateDirectory = Directory(
          '${directory.path}${Platform.pathSeparator}OpenGlucose'
          '${Platform.pathSeparator}AppleHealthContextImport',
        );
        await stateDirectory.create(recursive: true);
        final file = File(
          '${stateDirectory.path}${Platform.pathSeparator}import-state.json',
        );
        const futureState = '{"schemaVersion":2,"lastSyncedMs":1,"anchors":{}}';
        await file.writeAsString(futureState, flush: true);
        final store = FileAppleHealthContextImportStateStore(
          directoryProvider: () async => directory,
          requiresBackupExclusion: false,
        );

        await expectLater(store.initialize(), throwsA(isA<UnsupportedError>()));

        expect(await file.readAsString(), futureState);
        expect(File('${file.path}.next').existsSync(), isFalse);
        expect(File('${file.path}.previous').existsSync(), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
