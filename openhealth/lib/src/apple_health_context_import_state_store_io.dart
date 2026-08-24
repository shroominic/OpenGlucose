import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'apple_health_context_import_state.dart';

typedef AppleHealthContextImportStateDirectoryProvider =
    Future<Directory> Function();
typedef AppleHealthContextImportBackupExclusionMarker =
    Future<void> Function(
      String path,
    );

/// Versioned cursor storage for the Apple Health context importer.
///
/// The state is separate from restricted sensor/glucose state so a binary that
/// predates this importer neither reads nor rewrites anchors. On iOS the
/// directory and every transaction artifact are verified as backup-excluded
/// before they can hold cursor metadata.
class FileAppleHealthContextImportStateStore
    implements AppleHealthContextImportStateStore {
  FileAppleHealthContextImportStateStore({
    AppleHealthContextImportStateDirectoryProvider? directoryProvider,
    AppleHealthContextImportBackupExclusionMarker? backupExclusionMarker,
    bool? requiresBackupExclusion,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
       _backupExclusionMarker =
           backupExclusionMarker ?? _markExcludedFromBackup,
       _requiresBackupExclusion = requiresBackupExclusion ?? Platform.isIOS;

  static const int _schemaVersion = 1;
  static const String _directoryName = 'AppleHealthContextImport';
  static const String _fileName = 'import-state.json';
  static const Set<String> _allowedAnchorTypes = <String>{
    'sleep',
    'workout',
    'heartRate',
  };
  static const MethodChannel _privacyChannel = MethodChannel(
    'com.openglucose.app/privacy_storage',
  );

  final AppleHealthContextImportStateDirectoryProvider _directoryProvider;
  final AppleHealthContextImportBackupExclusionMarker _backupExclusionMarker;
  final bool _requiresBackupExclusion;

  AppleHealthContextImportState _state = AppleHealthContextImportState();
  Future<void>? _initializationFuture;
  Future<void> _mutationTail = Future<void>.value();
  File? _file;
  bool _initialized = false;

  @override
  AppleHealthContextImportState get state {
    _requireInitialized();
    return _state;
  }

  @override
  Future<void> initialize() {
    if (_initialized) {
      return Future<void>.value();
    }
    return _initializationFuture ??= _initializeWithRetry();
  }

  Future<void> _initializeWithRetry() async {
    try {
      final applicationSupport = await _directoryProvider();
      final directory = Directory(
        '${applicationSupport.path}${Platform.pathSeparator}OpenGlucose'
        '${Platform.pathSeparator}$_directoryName',
      );
      await directory.create(recursive: true);
      await _excludeFromBackup(directory.path);

      final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      _file = file;
      await _restoreInterruptedCommit(file);
      if (!file.existsSync()) {
        _state = AppleHealthContextImportState();
        _initialized = true;
        return;
      }

      // Decode before cleaning stale artifacts. A future version must remain
      // byte-for-byte untouched by an older app.
      final restored = _decode(await file.readAsString());
      await _excludeFromBackup(file.path);
      _state = restored;
      _initialized = true;
      await _discardIfPresent(File('${file.path}.next'));
      await _discardIfPresent(File('${file.path}.previous'));
    } finally {
      if (!_initialized) {
        _initializationFuture = null;
      }
    }
  }

  @override
  Future<void> save(AppleHealthContextImportState state) {
    _requireInitialized();
    _validateState(state);
    return _serializeMutation(() async {
      final file = _file;
      if (file == null) {
        throw StateError('Apple Health import state is not initialized.');
      }
      await _commitFile(file, _encode(state));
      _state = AppleHealthContextImportState(
        lastSyncedAt: state.lastSyncedAt,
        anchors: state.anchors,
      );
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
      await _excludeFromBackup(file.path);
      return;
    }
    final next = File('${file.path}.next');
    if (next.existsSync()) {
      // A first-write crash has no previous file to restore. Decode before
      // promoting the staged bytes so an older binary never rewrites an
      // unknown future schema merely because it found a transaction artifact.
      _decode(await next.readAsString());
      await next.rename(file.path);
    }
  }

  Future<void> _commitFile(File file, String contents) async {
    final next = File('${file.path}.next');
    final previous = File('${file.path}.previous');
    await _discardIfPresent(next);
    await _discardIfPresent(previous);

    try {
      await next.writeAsString(contents, flush: true);
      await _excludeFromBackup(next.path);
    } catch (error, stackTrace) {
      await _discardIfPresent(next);
      Error.throwWithStackTrace(error, stackTrace);
    }

    var movedPrevious = false;
    var installedNext = false;
    try {
      if (file.existsSync()) {
        await file.rename(previous.path);
        movedPrevious = true;
        await _excludeFromBackup(previous.path);
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
        await _discardIfPresent(next);
      } catch (rollbackError) {
        Error.throwWithStackTrace(
          StateError(
            'Apple Health import-state commit failed and rollback failed: '
            '$error; rollback: $rollbackError',
          ),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    await _discardIfPresent(previous);
  }

  String _encode(AppleHealthContextImportState state) {
    final sortedAnchors = state.anchors.keys.toList(growable: false)..sort();
    return jsonEncode(<String, Object?>{
      'schemaVersion': _schemaVersion,
      'lastSyncedMs': state.lastSyncedAt?.toUtc().millisecondsSinceEpoch,
      'anchors': <String, String>{
        for (final key in sortedAnchors) key: state.anchors[key]!,
      },
    });
  }

  AppleHealthContextImportState _decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Apple Health import state is invalid.');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.any(
          (key) =>
              key != 'schemaVersion' &&
              key != 'lastSyncedMs' &&
              key != 'anchors',
        ) ||
        decoded['schemaVersion'] is! int) {
      throw const FormatException('Apple Health import state is invalid.');
    }
    final version = decoded['schemaVersion'] as int;
    if (version != _schemaVersion) {
      throw UnsupportedError(
        'Apple Health import state schema version $version is unsupported.',
      );
    }
    final lastSyncedMs = decoded['lastSyncedMs'];
    if (lastSyncedMs != null && (lastSyncedMs is! int || lastSyncedMs < 0)) {
      throw const FormatException('Apple Health import state is invalid.');
    }
    final rawAnchors = decoded['anchors'];
    if (rawAnchors is! Map<String, dynamic>) {
      throw const FormatException('Apple Health import state is invalid.');
    }
    final anchors = <String, String>{};
    for (final entry in rawAnchors.entries) {
      if (!_allowedAnchorTypes.contains(entry.key) || entry.value is! String) {
        throw const FormatException('Apple Health import state is invalid.');
      }
      anchors[entry.key] = entry.value as String;
    }
    final state = AppleHealthContextImportState(
      lastSyncedAt: lastSyncedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              lastSyncedMs as int,
              isUtc: true,
            ),
      anchors: anchors,
    );
    _validateState(state);
    return state;
  }

  void _validateState(AppleHealthContextImportState state) {
    final lastSyncedAt = state.lastSyncedAt;
    if (lastSyncedAt != null && lastSyncedAt.millisecondsSinceEpoch < 0) {
      throw const FormatException('Apple Health import state is invalid.');
    }
    for (final entry in state.anchors.entries) {
      final anchor = entry.value.trim();
      if (!_allowedAnchorTypes.contains(entry.key) ||
          anchor.isEmpty ||
          anchor.length > 32768) {
        throw const FormatException('Apple Health import state is invalid.');
      }
    }
  }

  Future<void> _discardIfPresent(File file) async {
    if (file.existsSync()) {
      await file.delete();
    }
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
      throw StateError(
        'iOS did not confirm Apple Health import-state backup exclusion.',
      );
    }
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Apple Health import state is not initialized.');
    }
  }
}
