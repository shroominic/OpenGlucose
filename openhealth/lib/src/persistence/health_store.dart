import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'sqflite_health_repository.dart';

export 'sqflite_health_repository.dart';

/// Default on-disk filename for the local health database.
const String kHealthDbFileName = 'openhealth_health.db';

/// Supplies the platform Application Support directory.
typedef HealthDatabaseDirectoryProvider = Future<Directory> Function();

/// Prepares and verifies an iOS database directory before SQLite opens it.
typedef HealthDatabasePrivacyPreparer =
    Future<void> Function({
      required String directoryPath,
      required String databasePath,
    });

const _privacyStorageChannel = MethodChannel(
  'com.openglucose.app/privacy_storage',
);
const _databaseDirectoryName = 'HealthDatabase';
const _productDirectoryName = 'OpenGlucose';

/// Opens the app's local-first [HealthRepository], backed by sqflite in the
/// platform Application Support directory.
///
/// On iOS, a native privacy gate applies complete file protection and verified
/// iCloud-backup exclusion to the dedicated directory, database, and SQLite
/// sidecar files before sqflite is allowed to open the database. Any failure
/// aborts initialization so sensitive records are never written to an
/// unverified location.
Future<HealthRepository> openHealthRepository({
  String fileName = kHealthDbFileName,
  HealthDatabaseDirectoryProvider? directoryProvider,
  HealthDatabasePrivacyPreparer? privacyPreparer,
  DatabaseFactory? databaseFactory,
  bool? requiresIosPrivacyPreparation,
}) async {
  _validateDatabaseFileName(fileName);

  final applicationSupport =
      await (directoryProvider ?? getApplicationSupportDirectory)();
  final directory = Directory(
    p.join(
      applicationSupport.path,
      _productDirectoryName,
      _databaseDirectoryName,
    ),
  );
  final databasePath = p.join(directory.path, fileName);
  final requiresPrivacyPreparation =
      requiresIosPrivacyPreparation ?? Platform.isIOS;

  if (requiresPrivacyPreparation) {
    await (privacyPreparer ?? _prepareProtectedIosDatabase)(
      directoryPath: directory.path,
      databasePath: databasePath,
    );
  } else {
    await directory.create(recursive: true);
  }

  final repo = SqfliteHealthRepository(
    path: databasePath,
    databaseFactory: databaseFactory,
  );
  await repo.init();
  return repo;
}

void _validateDatabaseFileName(String fileName) {
  if (fileName.isEmpty ||
      p.isAbsolute(fileName) ||
      p.basename(fileName) != fileName ||
      fileName == '.' ||
      fileName == '..') {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'Expected a plain database filename without path components.',
    );
  }
}

Future<void> _prepareProtectedIosDatabase({
  required String directoryPath,
  required String databasePath,
}) async {
  final prepared = await _privacyStorageChannel.invokeMethod<bool>(
    'prepareProtectedDatabase',
    <String, Object>{
      'directoryPath': directoryPath,
      'databasePath': databasePath,
    },
  );
  if (prepared != true) {
    throw StateError(
      'iOS did not confirm protected, backup-excluded database storage.',
    );
  }
}
