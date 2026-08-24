import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'health_state_store.dart';

typedef HealthStateDirectoryProvider = Future<Directory> Function();
typedef BackupExclusionMarker = Future<void> Function(String path);

/// Native restricted-state store backed by explicitly backup-excluded files.
///
/// Small metadata values live in a versioned snapshot. Each glucose-history
/// key lives in its own atomically replaced blob, so updating the active sensor
/// never rewrites archived sensor histories.
class FileHealthStateStore implements HealthStateStore {
  FileHealthStateStore({
    required SharedPreferences legacyPreferences,
    HealthStateDirectoryProvider? directoryProvider,
    BackupExclusionMarker? backupExclusionMarker,
    bool? requiresBackupExclusion,
  }) : _legacyPreferences = legacyPreferences,
       _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
       _backupExclusionMarker =
           backupExclusionMarker ?? _markExcludedFromBackup,
       _requiresBackupExclusion = requiresBackupExclusion ?? Platform.isIOS;

  static const _schemaVersion = 3;
  static const _embeddedHistorySchemaVersion = 1;
  static const _reversibleHistoryFilenameSchemaVersion = 2;
  static const _fileName = 'restricted-health-state.json';
  static const _storageDirectoryName = 'RestrictedHealthState';
  static const _historyDirectoryName = 'HistoryBlobs';
  static const _historyBlobExtension = '.blob';
  static final _historyBlobFileNamePattern = RegExp(
    r'^history-[0-9a-f]{64}\.blob$',
  );
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _sensorArchiveKey = 'openHealth.sensorArchive';
  static const _historyPrefix = 'openHealth.history.';
  static const _bondTransferPrefix = 'openHealth.bondTransfer.';
  static const _healthExportLastSyncedKey =
      'openHealth.healthExport.lastSyncedMs';
  static const _healthExportWatermarkKey =
      'openHealth.healthExport.watermarkMs';
  static const _appleHealthContextImportLastSyncedKey =
      'openHealth.appleHealthContextImport.lastSyncedMs';
  static const _appleHealthContextImportAnchorSleepKey =
      'openHealth.appleHealthContextImport.anchor.sleep';
  static const _appleHealthContextImportAnchorWorkoutKey =
      'openHealth.appleHealthContextImport.anchor.workout';
  static const _appleHealthContextImportAnchorHeartRateKey =
      'openHealth.appleHealthContextImport.anchor.heartRate';
  static const _privacyChannel = MethodChannel(
    'com.openglucose.app/privacy_storage',
  );

  final SharedPreferences _legacyPreferences;
  final HealthStateDirectoryProvider _directoryProvider;
  final BackupExclusionMarker _backupExclusionMarker;
  final bool _requiresBackupExclusion;

  Map<String, String> _values = const <String, String>{};
  final Map<String, String?> _historyCache = <String, String?>{};
  Future<void> _mutationTail = Future<void>.value();
  Future<void>? _initializationFuture;
  File? _file;
  Directory? _historyDirectory;
  bool _initialized = false;

  @override
  Future<void> initialize() {
    if (_initialized) {
      return Future<void>.value();
    }
    return _initializationFuture ??= _initializeWithRetryReset();
  }

  Future<void> _initializeWithRetryReset() async {
    try {
      await _initialize();
    } finally {
      if (!_initialized) {
        _initializationFuture = null;
      }
    }
  }

  Future<void> _initialize() async {
    final applicationSupport = await _directoryProvider();
    final directory = Directory(
      '${applicationSupport.path}${Platform.pathSeparator}OpenGlucose'
      '${Platform.pathSeparator}$_storageDirectoryName',
    );
    await directory.create(recursive: true);
    // Exclude and verify the dedicated directory before any transaction file
    // can contain sensor identity or glucose history. File-level verification
    // remains in place so every committed artifact is independently checked.
    await _excludeFromBackup(directory.path);
    final historyDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}$_historyDirectoryName',
    );
    await historyDirectory.create(recursive: true);
    await _excludeFromBackup(historyDirectory.path);
    _historyDirectory = historyDirectory;
    final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
    _file = file;

    await _restoreInterruptedCommit(file);

    var metadataValues = <String, String>{};
    var needsRewrite = false;
    if (file.existsSync()) {
      final decoded = _decodeSnapshot(await file.readAsString());
      metadataValues = Map<String, String>.of(decoded.values);
      needsRewrite = decoded.isLegacy;
      await _excludeFromBackup(file.path);
      await _discardTransactionArtifacts(file);
    } else {
      await _discardIfPresent(File('${file.path}.next'));
      needsRewrite = true;
    }

    // Validate the metadata schema before recovering history transactions or
    // changing the persisted blob naming format. Future app versions must
    // remain untouched rather than being partially downgraded by an older
    // binary.
    await _recoverHistoryTransactions(historyDirectory);
    await _migrateLegacyHistoryBlobNames(historyDirectory);
    await _verifyHistoryBlobs(historyDirectory);

    final embeddedHistoryKeys = metadataValues.keys
        .where(_isHistoryKey)
        .toList(growable: false);
    for (final key in embeddedHistoryKeys) {
      final embeddedValue = metadataValues.remove(key)!;
      if (!_historyBlobExists(key)) {
        await _persistHistoryBlob(key, embeddedValue);
      }
      needsRewrite = true;
    }

    final migratedKeys =
        _legacyPreferences
            .getKeys()
            .where(_isRestrictedKey)
            .toList(growable: false)
          ..sort();
    for (final key in migratedKeys) {
      final legacyValue = _legacyRestrictedValue(key);
      if (_isHistoryKey(key)) {
        if (!_historyBlobExists(key)) {
          await _persistHistoryBlob(key, legacyValue);
        }
      } else if (!metadataValues.containsKey(key)) {
        metadataValues[key] = legacyValue;
        needsRewrite = true;
      }
    }
    final committedMetadata = Map<String, String>.unmodifiable(metadataValues);
    if (needsRewrite) {
      await _persistSnapshot(committedMetadata);
    }

    // Remove backup-eligible legacy values only after the replacement is
    // durable and, on iOS, its backup-exclusion attribute has been verified.
    for (final key in migratedKeys) {
      final removed = await _legacyPreferences.remove(key);
      if (!removed && _legacyPreferences.containsKey(key)) {
        throw StateError('Could not remove migrated restricted state: $key');
      }
    }

    _values = committedMetadata;
    _initialized = true;
  }

  @override
  String? getString(String key) {
    _requireInitialized();
    _requireRestrictedKey(key);
    if (_isHistoryKey(key)) {
      if (_historyCache.containsKey(key)) {
        return _historyCache[key];
      }
      final value = _readHistoryBlob(key);
      _historyCache[key] = value;
      return value;
    }
    return _values[key];
  }

  @override
  Future<void> setString(String key, String value) {
    _requireInitialized();
    _requireRestrictedKey(key);
    return _serializeMutation(() async {
      if (_isHistoryKey(key)) {
        await _persistHistoryBlob(key, value);
        _historyCache[key] = value;
        return;
      }
      final nextValues = Map<String, String>.unmodifiable(<String, String>{
        ..._values,
        key: value,
      });
      await _persistSnapshot(nextValues);
      _values = nextValues;
    });
  }

  @override
  Future<void> remove(String key) {
    _requireInitialized();
    _requireRestrictedKey(key);
    return _serializeMutation(() async {
      if (_isHistoryKey(key)) {
        if ((_historyCache.containsKey(key) && _historyCache[key] == null) ||
            !_historyBlobExists(key)) {
          _historyCache[key] = null;
          return;
        }
        await _removeHistoryBlob(key);
        _historyCache[key] = null;
        return;
      }
      if (!_values.containsKey(key)) {
        return;
      }
      final nextValues = Map<String, String>.of(_values)..remove(key);
      final committedValues = Map<String, String>.unmodifiable(nextValues);
      await _persistSnapshot(committedValues);
      _values = committedValues;
    });
  }

  Future<void> _serializeMutation(Future<void> Function() mutation) {
    final predecessor = _mutationTail;
    final completed = Completer<void>();
    _mutationTail = completed.future;

    return () async {
      try {
        await predecessor;
        await mutation();
      } finally {
        if (!completed.isCompleted) {
          completed.complete();
        }
      }
    }();
  }

  Future<void> _restoreInterruptedCommit(File file) async {
    if (file.existsSync()) {
      return;
    }
    final previous = File('${file.path}.previous');
    if (previous.existsSync()) {
      await previous.rename(file.path);
    }
  }

  Future<void> _discardTransactionArtifacts(File file) async {
    await _discardIfPresent(File('${file.path}.next'));
    await _discardIfPresent(File('${file.path}.previous'));
  }

  Future<void> _recoverHistoryTransactions(Directory directory) async {
    final primaryPaths = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final path = entity.path;
      if (path.endsWith(_historyBlobExtension)) {
        primaryPaths.add(path);
      } else if (path.endsWith('$_historyBlobExtension.next')) {
        primaryPaths.add(path.substring(0, path.length - '.next'.length));
      } else if (path.endsWith('$_historyBlobExtension.previous')) {
        primaryPaths.add(path.substring(0, path.length - '.previous'.length));
      } else if (path.endsWith('$_historyBlobExtension.deleted')) {
        primaryPaths.add(path.substring(0, path.length - '.deleted'.length));
      }
    }

    final sortedPaths = primaryPaths.toList(growable: false)..sort();
    for (final path in sortedPaths) {
      final file = File(path);
      final next = File('$path.next');
      final previous = File('$path.previous');
      final deleted = File('$path.deleted');

      if (deleted.existsSync() && !file.existsSync()) {
        // Renaming to `.deleted` is the commit point for removals.
        await _discardIfPresent(next);
        await _discardIfPresent(previous);
        await _discardIfPresent(deleted);
        continue;
      }
      if (!file.existsSync() && previous.existsSync()) {
        await previous.rename(file.path);
      }
      await _discardIfPresent(next);
      if (file.existsSync()) {
        await _discardIfPresent(previous);
        await _discardIfPresent(deleted);
      }
    }
  }

  Future<void> _migrateLegacyHistoryBlobNames(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(_historyBlobExtension)) {
        files.add(entity);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));

    for (final file in files) {
      final fileName = _basename(file.path);
      if (_historyBlobFileNamePattern.hasMatch(fileName)) {
        continue;
      }

      final key = _historyKeyFromLegacyBlob(file);
      final migrated = _historyBlobFile(directory, key);
      if (migrated.existsSync()) {
        await _excludeFromBackup(migrated.path);
        if (!await _filesHaveEqualContents(file, migrated)) {
          throw StateError(
            'Conflicting restricted history files cannot be migrated safely.',
          );
        }
        try {
          await file.delete();
        } on FileSystemException catch (error) {
          throw StateError(
            'Could not remove the redundant restricted history filename: '
            '$error',
          );
        }
        continue;
      }

      await file.rename(migrated.path);
      // A crash before this check leaves the authoritative bytes at the new
      // deterministic path. Initialization retries the exclusion check and
      // schema rewrite on the next launch without recreating the old name.
      await _excludeFromBackup(migrated.path);
    }
  }

  Future<void> _verifyHistoryBlobs(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(_historyBlobExtension)) {
        files.add(entity);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));

    for (final file in files) {
      if (!_historyBlobFileNamePattern.hasMatch(_basename(file.path))) {
        throw const FormatException('Restricted history filename is invalid.');
      }
      await _excludeFromBackup(file.path);
    }
  }

  Future<bool> _filesHaveEqualContents(File left, File right) async {
    final leftLength = await left.length();
    if (leftLength != await right.length()) {
      return false;
    }
    final leftBytes = await left.readAsBytes();
    final rightBytes = await right.readAsBytes();
    for (var index = 0; index < leftBytes.length; index += 1) {
      if (leftBytes[index] != rightBytes[index]) {
        return false;
      }
    }
    return true;
  }

  Future<void> _discardIfPresent(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException {
      // A stale recovery artifact is harmless once the authoritative file is
      // verified. A later transaction retries the strict cleanup.
    }
  }

  Future<void> _persistSnapshot(Map<String, String> values) async {
    final file = _file;
    if (file == null) {
      throw StateError('Restricted health-state store is not initialized.');
    }

    if (values.keys.any(_isHistoryKey)) {
      throw StateError('Glucose history must be stored as a separate blob.');
    }

    final sortedKeys = values.keys.toList(growable: false)..sort();
    final sortedValues = <String, String>{
      for (final key in sortedKeys) key: values[key]!,
    };
    final envelope = <String, Object>{
      'schemaVersion': _schemaVersion,
      'values': sortedValues,
    };
    await _commitFile(file, jsonEncode(envelope));
  }

  Future<void> _persistHistoryBlob(String key, String value) async {
    final directory = _historyDirectory;
    if (directory == null) {
      throw StateError('Restricted health-state store is not initialized.');
    }
    await _commitFile(_historyBlobFile(directory, key), value);
  }

  String? _readHistoryBlob(String key) {
    final directory = _historyDirectory;
    if (directory == null) {
      throw StateError('Restricted health-state store is not initialized.');
    }
    final file = _historyBlobFile(directory, key);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  bool _historyBlobExists(String key) {
    final directory = _historyDirectory;
    if (directory == null) {
      throw StateError('Restricted health-state store is not initialized.');
    }
    return _historyBlobFile(directory, key).existsSync();
  }

  Future<void> _removeHistoryBlob(String key) async {
    final directory = _historyDirectory;
    if (directory == null) {
      throw StateError('Restricted health-state store is not initialized.');
    }
    final file = _historyBlobFile(directory, key);
    if (!file.existsSync()) {
      return;
    }

    final deleted = File('${file.path}.deleted');
    await _discardIfPresent(deleted);
    await file.rename(deleted.path);
    // The rename above is the commit point. Cleanup is best effort, as it is
    // for rollback copies left by a successful write transaction.
    await _discardIfPresent(deleted);
  }

  Future<void> _commitFile(File file, String contents) async {
    final next = File('${file.path}.next');
    final previous = File('${file.path}.previous');
    if (next.existsSync()) {
      await next.delete();
    }
    if (previous.existsSync()) {
      await previous.delete();
    }

    try {
      await next.writeAsString(contents, flush: true);
      await _excludeFromBackup(next.path);
    } catch (error, stackTrace) {
      try {
        if (next.existsSync()) {
          await next.delete();
        }
      } catch (cleanupError) {
        Error.throwWithStackTrace(
          StateError(
            'Restricted health-state staging failed and cleanup failed: '
            '$error; cleanup: $cleanupError',
          ),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    var movedPrevious = false;
    var installedNext = false;
    try {
      if (file.existsSync()) {
        await file.rename(previous.path);
        movedPrevious = true;
      }
      await next.rename(file.path);
      installedNext = true;
      await _excludeFromBackup(file.path);
    } catch (error, stackTrace) {
      try {
        if (installedNext && file.existsSync()) {
          await file.delete();
        }
        if (movedPrevious && previous.existsSync()) {
          await previous.rename(file.path);
        }
        if (next.existsSync()) {
          await next.delete();
        }
      } catch (rollbackError) {
        Error.throwWithStackTrace(
          StateError(
            'Restricted health-state commit failed and rollback failed: '
            '$error; rollback: $rollbackError',
          ),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    // Failure to delete a no-longer-authoritative rollback copy cannot make an
    // already durable commit fail. Initialization removes it on next launch.
    await _discardIfPresent(previous);
  }

  _DecodedSnapshot _decodeSnapshot(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Restricted health-state file is invalid.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Restricted health-state file is invalid.');
    }

    if (decoded.containsKey('schemaVersion')) {
      final version = decoded['schemaVersion'];
      if (version is! int) {
        throw const FormatException(
          'Restricted health-state schema version is invalid.',
        );
      }
      if (version != _schemaVersion &&
          version != _embeddedHistorySchemaVersion &&
          version != _reversibleHistoryFilenameSchemaVersion) {
        throw UnsupportedError(
          'Restricted health-state schema version $version is unsupported.',
        );
      }
      final encodedValues = decoded['values'];
      if (encodedValues is! Map<String, dynamic>) {
        throw const FormatException(
          'Restricted health-state values are invalid.',
        );
      }
      return _DecodedSnapshot(
        _decodeValues(encodedValues),
        isLegacy: version != _schemaVersion,
      );
    }

    // The original implementation stored a flat string map. It is accepted as
    // schema zero exactly once and rewritten to the versioned envelope.
    return _DecodedSnapshot(_decodeValues(decoded), isLegacy: true);
  }

  Map<String, String> _decodeValues(Map<String, dynamic> encodedValues) {
    final values = <String, String>{};
    for (final entry in encodedValues.entries) {
      if (!_isRestrictedKey(entry.key) || entry.value is! String) {
        throw const FormatException(
          'Restricted health-state values are invalid.',
        );
      }
      values[entry.key] = entry.value as String;
    }
    return Map<String, String>.unmodifiable(values);
  }

  File _historyBlobFile(Directory directory, String key) {
    return File(
      '${directory.path}${Platform.pathSeparator}'
      '${_historyBlobFileName(key)}',
    );
  }

  String _historyKeyFromLegacyBlob(File file) {
    final fileName = _basename(file.path);
    final encodedKey = fileName.substring(
      0,
      fileName.length - _historyBlobExtension.length,
    );
    final String key;
    try {
      key = utf8.decode(base64Url.decode(encodedKey));
    } on FormatException {
      throw const FormatException('Restricted history filename is invalid.');
    }
    if (!_isHistoryKey(key) || _legacyHistoryBlobFileName(key) != fileName) {
      throw const FormatException('Restricted history filename is invalid.');
    }
    return key;
  }

  String _historyBlobFileName(String key) {
    final digest = crypto.sha256.convert(utf8.encode(key));
    return 'history-$digest$_historyBlobExtension';
  }

  String _legacyHistoryBlobFileName(String key) =>
      '${base64Url.encode(utf8.encode(key))}$_historyBlobExtension';

  String _basename(String filePath) {
    final separatorIndex = filePath.lastIndexOf(Platform.pathSeparator);
    return filePath.substring(separatorIndex + 1);
  }

  Future<void> _excludeFromBackup(String path) async {
    if (_requiresBackupExclusion) {
      await _backupExclusionMarker(path);
    }
  }

  static Future<void> _markExcludedFromBackup(String path) async {
    final excluded = await _privacyChannel.invokeMethod<bool>(
      'excludeFromBackup',
      <String, Object>{'path': path},
    );
    if (excluded != true) {
      throw StateError('iOS did not confirm health-state backup exclusion.');
    }
  }

  static bool _isRestrictedKey(String key) {
    return key == _lastSensorKey ||
        key == _sensorArchiveKey ||
        key.startsWith(_historyPrefix) ||
        key.startsWith(_bondTransferPrefix) ||
        key == _healthExportLastSyncedKey ||
        key == _healthExportWatermarkKey ||
        key == _appleHealthContextImportLastSyncedKey ||
        key == _appleHealthContextImportAnchorSleepKey ||
        key == _appleHealthContextImportAnchorWorkoutKey ||
        key == _appleHealthContextImportAnchorHeartRateKey;
  }

  static bool _isHistoryKey(String key) => key.startsWith(_historyPrefix);

  String _legacyRestrictedValue(String key) {
    final value = _legacyPreferences.get(key);
    if (value is String) {
      return value;
    }
    if ((key == _healthExportLastSyncedKey ||
            key == _healthExportWatermarkKey ||
            key == _appleHealthContextImportLastSyncedKey) &&
        value is int &&
        value >= 0) {
      return value.toString();
    }
    throw StateError('Restricted legacy state has an invalid value type.');
  }

  void _requireRestrictedKey(String key) {
    if (!_isRestrictedKey(key)) {
      throw ArgumentError.value(key, 'key', 'Key is not restricted state.');
    }
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Restricted health-state store is not initialized.');
    }
  }
}

final class _DecodedSnapshot {
  const _DecodedSnapshot(this.values, {required this.isLegacy});

  final Map<String, String> values;
  final bool isLegacy;
}
