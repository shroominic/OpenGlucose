import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/persistence/health_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'openglucose-health-store-',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('opens the database under Application Support', () async {
    final repository = await openHealthRepository(
      directoryProvider: () async => temporaryDirectory,
      databaseFactory: databaseFactoryFfi,
      requiresIosPrivacyPreparation: false,
    );
    addTearDown(repository.close);

    final database = File(
      p.join(
        temporaryDirectory.path,
        'OpenGlucose',
        'HealthDatabase',
        kHealthDbFileName,
      ),
    );
    expect(database.existsSync(), isTrue);
  });

  test('completes privacy preparation before opening SQLite', () async {
    var preparationCompleted = false;
    late String preparedDirectoryPath;
    late String preparedDatabasePath;

    final repository = await openHealthRepository(
      directoryProvider: () async => temporaryDirectory,
      privacyPreparer:
          ({
            required directoryPath,
            required databasePath,
          }) {
            preparedDirectoryPath = directoryPath;
            preparedDatabasePath = databasePath;
            Directory(directoryPath).createSync(recursive: true);
            expect(File(databasePath).existsSync(), isFalse);
            preparationCompleted = true;
            return Future<void>.value();
          },
      databaseFactory: databaseFactoryFfi,
      requiresIosPrivacyPreparation: true,
    );
    addTearDown(repository.close);

    expect(preparationCompleted, isTrue);
    expect(
      preparedDirectoryPath,
      p.join(temporaryDirectory.path, 'OpenGlucose', 'HealthDatabase'),
    );
    expect(
      preparedDatabasePath,
      p.join(preparedDirectoryPath, kHealthDbFileName),
    );
    expect(File(preparedDatabasePath).existsSync(), isTrue);
  });

  test('fails closed when iOS privacy preparation fails', () async {
    final expectedDatabase = File(
      p.join(
        temporaryDirectory.path,
        'OpenGlucose',
        'HealthDatabase',
        kHealthDbFileName,
      ),
    );

    await expectLater(
      openHealthRepository(
        directoryProvider: () async => temporaryDirectory,
        privacyPreparer:
            ({
              required directoryPath,
              required databasePath,
            }) async {
              throw StateError('privacy verification failed');
            },
        databaseFactory: databaseFactoryFfi,
        requiresIosPrivacyPreparation: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(expectedDatabase.existsSync(), isFalse);
  });

  test('rejects filenames that escape the protected directory', () async {
    await expectLater(
      openHealthRepository(
        fileName: '../health.db',
        directoryProvider: () async => temporaryDirectory,
        databaseFactory: databaseFactoryFfi,
        requiresIosPrivacyPreparation: false,
      ),
      throwsArgumentError,
    );
  });
}
