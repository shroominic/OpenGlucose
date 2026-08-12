import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'health_state_store.dart';

typedef HealthStateDirectoryProvider = Future<Directory> Function();
typedef BackupExclusionMarker = Future<void> Function(String path);

/// Native restricted-state store backed by one explicitly backup-excluded file.
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

  static const _schemaVersion = 1;
  static const _fileName = 'restricted-health-state.json';
  static const _storageDirectoryName = 'RestrictedHealthState';
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _historyPrefix = 'openHealth.history.';
  static const _privacyChannel = MethodChannel(
    'com.openglucose.app/privacy_storage',
  );

  final SharedPreferences _legacyPreferences;
  final HealthStateDirectoryProvider _directoryProvider;
  final BackupExclusionMarker _backupExclusionMarker;
  final bool _requiresBackupExclusion;

  Map<String, String> _values = const <String, String>{};
  Future<void> _mutationTail = Future<void>.value();
  Future<void>? _initializationFuture;
  File? _file;
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
    final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
    _file = file;

    await _restoreInterruptedCommit(file);

    var nextValues = const <String, String>{};
    var needsRewrite = false;
    if (await file.exists()) {
      final decoded = _decodeSnapshot(await file.readAsString());
      nextValues = decoded.values;
      needsRewrite = decoded.isLegacy;
      await _excludeFromBackup(file.path);
      await _discardTransactionArtifacts(file);
    } else {
      await _discardIfPresent(File('${file.path}.next'));
      needsRewrite = true;
    }

    final migratedKeys =
        _legacyPreferences
            .getKeys()
            .where(_isRestrictedKey)
            .toList(growable: false)
          ..sort();
    final mergedValues = Map<String, String>.of(nextValues);
    for (final key in migratedKeys) {
      final value = _legacyPreferences.getString(key);
      if (value != null && !mergedValues.containsKey(key)) {
        mergedValues[key] = value;
        needsRewrite = true;
      }
    }
    final committedValues = Map<String, String>.unmodifiable(mergedValues);
    if (needsRewrite) {
      await _persistSnapshot(committedValues);
    }

    // Remove backup-eligible legacy values only after the replacement is
    // durable and, on iOS, its backup-exclusion attribute has been verified.
    for (final key in migratedKeys) {
      final removed = await _legacyPreferences.remove(key);
      if (!removed && _legacyPreferences.containsKey(key)) {
        throw StateError('Could not remove migrated restricted state: $key');
      }
    }

    _values = committedValues;
    _initialized = true;
  }

  @override
  String? getString(String key) {
    _requireInitialized();
    _requireRestrictedKey(key);
    return _values[key];
  }

  @override
  Future<void> setString(String key, String value) {
    _requireInitialized();
    _requireRestrictedKey(key);
    return _serializeMutation(() async {
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
    if (await file.exists()) {
      return;
    }
    final previous = File('${file.path}.previous');
    if (await previous.exists()) {
      await previous.rename(file.path);
    }
  }

  Future<void> _discardTransactionArtifacts(File file) async {
    await _discardIfPresent(File('${file.path}.next'));
    await _discardIfPresent(File('${file.path}.previous'));
  }

  Future<void> _discardIfPresent(File file) async {
    try {
      if (await file.exists()) {
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

    final next = File('${file.path}.next');
    final previous = File('${file.path}.previous');
    if (await next.exists()) {
      await next.delete();
    }
    if (await previous.exists()) {
      await previous.delete();
    }

    final sortedKeys = values.keys.toList(growable: false)..sort();
    final sortedValues = <String, String>{
      for (final key in sortedKeys) key: values[key]!,
    };
    final envelope = <String, Object>{
      'schemaVersion': _schemaVersion,
      'values': sortedValues,
    };
    try {
      await next.writeAsString(jsonEncode(envelope), flush: true);
      await _excludeFromBackup(next.path);
    } catch (error, stackTrace) {
      try {
        if (await next.exists()) {
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
      if (await file.exists()) {
        await file.rename(previous.path);
        movedPrevious = true;
      }
      await next.rename(file.path);
      installedNext = true;
      await _excludeFromBackup(file.path);
    } catch (error, stackTrace) {
      try {
        if (installedNext && await file.exists()) {
          await file.delete();
        }
        if (movedPrevious && await previous.exists()) {
          await previous.rename(file.path);
        }
        if (await next.exists()) {
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
      if (version != _schemaVersion) {
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
      return _DecodedSnapshot(_decodeValues(encodedValues), isLegacy: false);
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
    return key == _lastSensorKey || key.startsWith(_historyPrefix);
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
