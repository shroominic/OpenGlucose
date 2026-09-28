import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:path_provider/path_provider.dart';

typedef BleTraceDirectoryProvider = Future<Directory> Function();

enum LocalBleTraceSinkState {
  notStarted,
  healthy,
  capacityReached,
  writeError,
  closed,
}

/// Non-sensitive health metadata for the app-private BLE trace sink.
final class LocalBleTraceSinkHealth {
  const LocalBleTraceSinkHealth({
    required this.state,
    required this.sessionToken,
    required this.capacityReached,
    this.segmentFileName,
    this.lastCommittedSequence,
    this.lastCommittedAtUtc,
    this.errorCode,
  });

  final LocalBleTraceSinkState state;
  final String sessionToken;
  final bool capacityReached;
  final String? segmentFileName;
  final int? lastCommittedSequence;
  final DateTime? lastCommittedAtUtc;

  /// A fixed, non-sensitive classification. Native error text is never kept.
  final String? errorCode;
}

/// Writes sensitive protocol traces into app-private storage.
///
/// This sink is used only by an explicitly enabled debug capture build. The
/// files are intentionally not exported or logged. Android backup and device
/// transfer are disabled for the app, and the capture harness retrieves them
/// with `run-as` into a restricted local directory.
final class LocalBleTraceSink implements BleTraceSink {
  factory LocalBleTraceSink({
    BleTraceDirectoryProvider? directoryProvider,
    String? sessionToken,
    int maxSegmentBytes = 16 * 1024 * 1024,
    int maxSegmentCount = 8,
    int maxRetainedSessionCount = 4,
  }) {
    return LocalBleTraceSink._(
      directoryProvider: directoryProvider ?? _defaultTraceDirectoryProvider,
      sessionToken: sessionToken ?? _newSessionToken(),
      maxSegmentBytes: maxSegmentBytes,
      maxSegmentCount: maxSegmentCount,
      maxRetainedSessionCount: maxRetainedSessionCount,
    );
  }

  LocalBleTraceSink._({
    required BleTraceDirectoryProvider directoryProvider,
    required String sessionToken,
    required this.maxSegmentBytes,
    required this.maxSegmentCount,
    required this.maxRetainedSessionCount,
  }) : _directoryProvider = directoryProvider,
       _sessionToken = sessionToken,
       _health = LocalBleTraceSinkHealth(
         state: LocalBleTraceSinkState.notStarted,
         sessionToken: sessionToken,
         capacityReached: false,
       ) {
    if (maxSegmentBytes < 1) {
      throw ArgumentError.value(
        maxSegmentBytes,
        'maxSegmentBytes',
        'must be positive',
      );
    }
    if (maxSegmentCount < 1) {
      throw ArgumentError.value(
        maxSegmentCount,
        'maxSegmentCount',
        'must be positive',
      );
    }
    if (maxRetainedSessionCount < 1) {
      throw ArgumentError.value(
        maxRetainedSessionCount,
        'maxRetainedSessionCount',
        'must be positive',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(_sessionToken)) {
      throw ArgumentError.value(
        _sessionToken,
        'sessionToken',
        'must contain only filename-safe characters',
      );
    }
  }

  final BleTraceDirectoryProvider _directoryProvider;
  final String _sessionToken;
  final int maxSegmentBytes;
  final int maxSegmentCount;
  final int maxRetainedSessionCount;
  final StreamController<LocalBleTraceSinkHealth> _healthChanges =
      StreamController<LocalBleTraceSinkHealth>.broadcast(sync: true);

  Future<void> _tail = Future<void>.value();
  LocalBleTraceSinkHealth _health;
  Directory? _directory;
  File? _file;
  var _segmentIndex = 0;
  var _segmentBytes = 0;
  var _capacityReached = false;
  var _accepting = true;
  var _terminalFailure = false;
  var _closed = false;

  String get sessionToken => _sessionToken;
  LocalBleTraceSinkHealth get health => _health;
  Stream<LocalBleTraceSinkHealth> get healthChanges => _healthChanges.stream;

  @override
  Future<void> append(BleTraceEvent event) {
    if (!_accepting) {
      return Future<void>.error(StateError('The BLE trace sink is closed.'));
    }
    final operation = _tail.then((_) async {
      try {
        await _appendEvent(event);
      } catch (error, stackTrace) {
        _accepting = false;
        _terminalFailure = true;
        _setHealth(
          state: LocalBleTraceSinkState.writeError,
          errorCode: 'write_failed',
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
    _tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  /// Drains queued writes and stops accepting new trace events.
  Future<void> close() async {
    if (_closed) {
      await _tail;
      return;
    }
    _accepting = false;
    await _tail;
    _closed = true;
    if (!_terminalFailure) {
      _setHealth(state: LocalBleTraceSinkState.closed);
    }
    await _healthChanges.close();
  }

  Future<void> _appendEvent(BleTraceEvent event) async {
    if (_capacityReached) {
      return;
    }
    if (_terminalFailure) {
      throw StateError('The BLE trace sink has a terminal write failure.');
    }

    final line = '${jsonEncode(event.toSensitiveJson())}\n';
    final encodedBytes = utf8.encode(line).length;
    if (encodedBytes > maxSegmentBytes) {
      _capacityReached = true;
      _accepting = false;
      _terminalFailure = true;
      _setHealth(
        state: LocalBleTraceSinkState.capacityReached,
        capacityReached: true,
        errorCode: 'event_exceeds_segment_capacity',
      );
      return;
    }
    if (_file == null || _segmentBytes + encodedBytes > maxSegmentBytes) {
      if (_file != null) {
        _segmentIndex += 1;
      }
      if (_segmentIndex >= maxSegmentCount) {
        _capacityReached = true;
        _accepting = false;
        _terminalFailure = true;
        _setHealth(
          state: LocalBleTraceSinkState.capacityReached,
          capacityReached: true,
          errorCode: 'capacity_reached',
        );
        return;
      }
      await _openSegment();
    }

    await _file!.writeAsString(line, mode: FileMode.append, flush: true);
    _segmentBytes += encodedBytes;
    _setHealth(
      state: LocalBleTraceSinkState.healthy,
      segmentFileName: _fileName(_file!),
      lastCommittedSequence: event.sequence,
      lastCommittedAtUtc: event.recordedAtUtc,
    );
  }

  Future<void> _openSegment() async {
    var directory = _directory;
    if (directory == null) {
      directory = await _directoryProvider();
      await directory.create(recursive: true);
      await _purgeExpiredBleSessions(directory);
      _directory = directory;
    }
    final segment = _segmentIndex.toString().padLeft(2, '0');
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'ble-$_sessionToken-$segment.jsonl',
    );
    await file.create(exclusive: true);
    _file = file;
    _segmentBytes = 0;
  }

  Future<void> _purgeExpiredBleSessions(Directory directory) async {
    final files = await directory
        .list(followLinks: false)
        .where((entity) => entity is File && _isBleSegment(entity.path))
        .cast<File>()
        .toList();
    final sessions = <String, List<File>>{};
    for (final file in files) {
      final session = _sessionFromFile(file);
      if (session == null || session == _sessionToken) {
        continue;
      }
      sessions.putIfAbsent(session, () => <File>[]).add(file);
    }
    if (sessions.length < maxRetainedSessionCount) {
      return;
    }

    final ordered = <({String session, DateTime modified})>[];
    for (final entry in sessions.entries) {
      var modified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      for (final file in entry.value) {
        final candidate = file.statSync().modified;
        if (candidate.isAfter(modified)) {
          modified = candidate;
        }
      }
      ordered.add((session: entry.key, modified: modified));
    }
    ordered.sort((left, right) => right.modified.compareTo(left.modified));
    final keepExisting = maxRetainedSessionCount - 1;
    for (final expired in ordered.skip(keepExisting)) {
      for (final file in sessions[expired.session]!) {
        await file.delete();
      }
    }
  }

  void _setHealth({
    required LocalBleTraceSinkState state,
    bool? capacityReached,
    String? segmentFileName,
    int? lastCommittedSequence,
    DateTime? lastCommittedAtUtc,
    String? errorCode,
  }) {
    _health = LocalBleTraceSinkHealth(
      state: state,
      sessionToken: _sessionToken,
      capacityReached: capacityReached ?? _health.capacityReached,
      segmentFileName: segmentFileName ?? _health.segmentFileName,
      lastCommittedSequence:
          lastCommittedSequence ?? _health.lastCommittedSequence,
      lastCommittedAtUtc:
          lastCommittedAtUtc?.toUtc() ?? _health.lastCommittedAtUtc,
      errorCode: errorCode,
    );
    if (!_healthChanges.isClosed) {
      _healthChanges.add(_health);
    }
  }

  static Future<Directory> _defaultTraceDirectoryProvider() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(
      '${supportDirectory.path}${Platform.pathSeparator}protocol-captures',
    );
  }

  static String _newSessionToken() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final random = Random.secure();
    final suffix = List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '$timestamp-$suffix';
  }
}

final RegExp _bleSegmentPattern = RegExp(r'^ble-(.+)-([0-9]{2})\.jsonl$');

bool _isBleSegment(String path) => _bleSegmentPattern.hasMatch(_baseName(path));

String? _sessionFromFile(File file) =>
    _bleSegmentPattern.firstMatch(_baseName(file.path))?.group(1);

String _fileName(File file) => _baseName(file.path);

String _baseName(String path) => path.split(Platform.pathSeparator).last;
