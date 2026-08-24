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

  test(
    'restores the previous durable state when final backup verification fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openglucose-health-import-queue-recovery-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}OpenGlucose'
        '${Platform.pathSeparator}AppleHealthContextImport'
        '${Platform.pathSeparator}import-state.json',
      );
      var failFinalVerification = false;
      try {
        final store = FileAppleHealthContextImportStateStore(
          directoryProvider: () async => directory,
          requiresBackupExclusion: true,
          backupExclusionMarker: (path) async {
            if (failFinalVerification && path == file.path) {
              throw StateError('Synthetic final backup verification failure.');
            }
          },
        );
        await store.initialize();
        await store.save(
          AppleHealthContextImportState(
            anchors: const <String, String>{'sleep': 'durable-anchor'},
          ),
        );

        failFinalVerification = true;
        await expectLater(
          store.save(
            AppleHealthContextImportState(
              anchors: const <String, String>{'sleep': 'rejected-anchor'},
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(store.state.anchors, <String, String>{
          'sleep': 'durable-anchor',
        });
        expect(File('${file.path}.next').existsSync(), isFalse);
        expect(File('${file.path}.previous').existsSync(), isFalse);

        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(decoded['anchors'], <String, dynamic>{
          'sleep': 'durable-anchor',
        });
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'does not poison a queued save after final backup verification fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openglucose-health-import-queue-recovery-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}OpenGlucose'
        '${Platform.pathSeparator}AppleHealthContextImport'
        '${Platform.pathSeparator}import-state.json',
      );
      var failFinalVerification = false;
      try {
        final store = FileAppleHealthContextImportStateStore(
          directoryProvider: () async => directory,
          requiresBackupExclusion: true,
          backupExclusionMarker: (path) async {
            if (failFinalVerification && path == file.path) {
              failFinalVerification = false;
              throw StateError('Synthetic final backup verification failure.');
            }
          },
        );
        await store.initialize();
        await store.save(
          AppleHealthContextImportState(
            anchors: const <String, String>{'sleep': 'durable-anchor'},
          ),
        );

        failFinalVerification = true;
        final failed = store.save(
          AppleHealthContextImportState(
            anchors: const <String, String>{'sleep': 'rejected-anchor'},
          ),
        );
        final queued = store.save(
          AppleHealthContextImportState(
            anchors: const <String, String>{'sleep': 'recovered-anchor'},
          ),
        );

        await expectLater(failed, throwsA(isA<StateError>()));
        await queued;

        expect(
          store.state.anchors,
          <String, String>{'sleep': 'recovered-anchor'},
        );
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(
          decoded['anchors'],
          <String, dynamic>{'sleep': 'recovered-anchor'},
        );
        expect(File('${file.path}.next').existsSync(), isFalse);
        expect(File('${file.path}.previous').existsSync(), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('restores an interrupted replacement from .previous', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openglucose-health-import-previous-recovery-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}OpenGlucose'
      '${Platform.pathSeparator}AppleHealthContextImport'
      '${Platform.pathSeparator}import-state.json',
    );
    const previousState =
        '{"schemaVersion":1,"lastSyncedMs":1,"anchors":{"sleep":"previous-anchor"}}';
    final excludedPaths = <String>[];
    try {
      await file.parent.create(recursive: true);
      await File('${file.path}.previous').writeAsString(
        previousState,
        flush: true,
      );
      await File('${file.path}.next').writeAsString(
        '{"schemaVersion":1,"lastSyncedMs":2,"anchors":{"sleep":"next-anchor"}}',
        flush: true,
      );
      final store = FileAppleHealthContextImportStateStore(
        directoryProvider: () async => directory,
        requiresBackupExclusion: true,
        backupExclusionMarker: (path) async => excludedPaths.add(path),
      );

      await store.initialize();

      expect(store.state.anchors, <String, String>{'sleep': 'previous-anchor'});
      expect(
        store.state.lastSyncedAt,
        DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
      );
      expect(await file.readAsString(), previousState);
      expect(excludedPaths, contains(file.path));
      expect(File('${file.path}.previous').existsSync(), isFalse);
      expect(File('${file.path}.next').existsSync(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('keeps primary state after an interrupted post-rename commit', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openglucose-health-import-post-rename-recovery-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}OpenGlucose'
      '${Platform.pathSeparator}AppleHealthContextImport'
      '${Platform.pathSeparator}import-state.json',
    );
    const primaryState =
        '{"schemaVersion":1,"lastSyncedMs":3,"anchors":{"heartRate":"primary-anchor"}}';
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(primaryState, flush: true);
      await File('${file.path}.previous').writeAsString(
        '{"schemaVersion":1,"lastSyncedMs":2,"anchors":{"heartRate":"previous-anchor"}}',
        flush: true,
      );
      await File('${file.path}.next').writeAsString(
        '{"schemaVersion":1,"lastSyncedMs":4,"anchors":{"heartRate":"next-anchor"}}',
        flush: true,
      );
      final store = FileAppleHealthContextImportStateStore(
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await store.initialize();

      expect(store.state.anchors, <String, String>{
        'heartRate': 'primary-anchor',
      });
      expect(await file.readAsString(), primaryState);
      expect(File('${file.path}.previous').existsSync(), isFalse);
      expect(File('${file.path}.next').existsSync(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('restores an interrupted first write from .next', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openglucose-health-import-next-recovery-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}OpenGlucose'
      '${Platform.pathSeparator}AppleHealthContextImport'
      '${Platform.pathSeparator}import-state.json',
    );
    try {
      await file.parent.create(recursive: true);
      await File('${file.path}.next').writeAsString(
        '{"schemaVersion":1,"lastSyncedMs":2,"anchors":{"workout":"next-anchor"}}',
        flush: true,
      );
      final store = FileAppleHealthContextImportStateStore(
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await store.initialize();

      expect(store.state.anchors, <String, String>{'workout': 'next-anchor'});
      expect(
        store.state.lastSyncedAt,
        DateTime.fromMillisecondsSinceEpoch(2, isUtc: true),
      );
      expect(File('${file.path}.previous').existsSync(), isFalse);
      expect(File('${file.path}.next').existsSync(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('preserves a future .next beside .previous for roll-forward', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openglucose-health-import-future-next-recovery-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}OpenGlucose'
      '${Platform.pathSeparator}AppleHealthContextImport'
      '${Platform.pathSeparator}import-state.json',
    );
    const futureNext =
        '{"schemaVersion":2,"lastSyncedMs":2,"anchors":{"sleep":"future-anchor"}}';
    const previousState =
        '{"schemaVersion":1,"lastSyncedMs":1,"anchors":{"sleep":"previous-anchor"}}';
    try {
      await file.parent.create(recursive: true);
      await File('${file.path}.previous').writeAsString(
        previousState,
        flush: true,
      );
      await File('${file.path}.next').writeAsString(futureNext, flush: true);
      final store = FileAppleHealthContextImportStateStore(
        directoryProvider: () async => directory,
        requiresBackupExclusion: false,
      );

      await expectLater(store.initialize(), throwsA(isA<UnsupportedError>()));

      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.previous').existsSync(), isTrue);
      expect(await File('${file.path}.previous').readAsString(), previousState);
      expect(await File('${file.path}.next').readAsString(), futureNext);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
