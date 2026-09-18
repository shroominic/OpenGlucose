// SPDX-License-Identifier: GPL-3.0-only
// Secure read/schema helpers adapted from the MIT cgm_libre2 offline validator.
// Native-v2 null session shape follows LibreGen1CalibrationEvidence.java.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_libre2_glucose/cgm_libre2_glucose.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';

const Set<String> _schemaKeys = <String>{
  'schemaVersion',
  'nativeCaptureSessionId',
  'processSessionId',
  'captureSessionId',
  'versionCode',
  'lastUpdateTime',
  'targetUidSha256',
  'iso15693ManufacturerPrefix',
  'patchInfoSha256',
  'model',
  'securityGeneration',
  'algorithmOrderUidHex',
  'patchInfoHex',
  'encryptedFramHex',
  'observedAtUtc',
  'observedAtMonotonicElapsedNanos',
};
const Set<String> _explicitSchemaKeys = <String>{
  ..._schemaKeys,
  'sourceKind',
  'explicitAttemptId',
};

final RegExp _sessionToken = RegExp(r'^[A-Za-z0-9_-]{8,120}$');
final RegExp _explicitAttemptToken = RegExp(r'^[A-Za-z0-9_-]{8,120}$');
final RegExp _captureSessionToken = RegExp(
  r'^session-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{1,32}$',
);
final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
final RegExp _uidHex = RegExp(r'^[0-9a-f]{16}$');
final RegExp _patchInfoHex = RegExp(r'^[0-9a-f]{12}$');
final RegExp _encryptedFramHex = RegExp(r'^[0-9a-f]{688}$');
final RegExp _utcTimestamp = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$',
);

/// Whether this process runs on a POSIX ABI whose `struct stat` layout is
/// audited in [_PosixFunctions.securityFailure].
///
/// The descriptor-bound read enforces ownership, mode and file type on the inode
/// the bytes come from, and it does that by parsing `struct stat`. A layout that
/// has not been audited against the platform headers is never guessed: the host
/// fails closed with `unsupported_platform`, which is a closed reason and not a
/// crash. Darwin and Linux x86_64 are audited; other ABIs stay unsupported until
/// someone verifies their offsets on a real host of that ABI.
bool _hasAuditedDescriptorLayout() {
  final abi = ffi.Abi.current();
  if (Platform.isMacOS) {
    return abi == ffi.Abi.macosArm64 || abi == ffi.Abi.macosX64;
  }
  if (Platform.isLinux) {
    return abi == ffi.Abi.linuxX64;
  }
  return false;
}

({List<int>? bytes, _ValidationError? error}) _readDescriptorBound(
  String path, {
  required int maximumBytes,
  void Function()? afterSecureOpenForTest,
}) {
  if (!_hasAuditedDescriptorLayout()) {
    return (bytes: null, error: _ValidationError.unsupportedPlatform);
  }

  final _PosixFunctions functions;
  try {
    functions = _PosixFunctions();
  } on Object {
    return (bytes: null, error: _ValidationError.unsupportedPlatform);
  }

  final nativePath = path.toNativeUtf8(allocator: calloc);
  ffi.Pointer<ffi.Uint8>? buffer;
  var descriptor = -1;
  List<int>? bytes;
  _ValidationError? error;
  try {
    descriptor = functions.open(nativePath.cast(), _secureOpenFlags());
    if (descriptor < 0) {
      error = functions.currentErrno == _symlinkErrno()
          ? _ValidationError.symlinkForbidden
          : _ValidationError.readFailed;
    } else {
      afterSecureOpenForTest?.call();
      final descriptorPath = Platform.isMacOS
          ? '/dev/fd/$descriptor'
          : '/proc/self/fd/$descriptor';
      final before = FileStat.statSync(descriptorPath);
      if (before.type != FileSystemEntityType.file) {
        error = _ValidationError.notRegularFile;
      } else if (functions.securityFailure(descriptor) case final failure?) {
        error = failure;
      } else if (before.size > maximumBytes) {
        error = _ValidationError.oversizedFile;
      } else {
        buffer = calloc<ffi.Uint8>(maximumBytes + 1);
        var total = 0;
        while (total <= maximumBytes) {
          final count = functions.read(
            descriptor,
            (buffer + total).cast(),
            maximumBytes + 1 - total,
          );
          if (count < 0) {
            error = _ValidationError.readFailed;
            break;
          }
          if (count == 0) break;
          total += count;
        }
        if (error == null && total > maximumBytes) {
          error = _ValidationError.oversizedFile;
        }
        if (error == null) {
          final after = FileStat.statSync(descriptorPath);
          if (functions.securityFailure(descriptor) != null ||
              after.type != FileSystemEntityType.file ||
              after.size != before.size ||
              after.size != total ||
              after.modified != before.modified ||
              after.changed != before.changed) {
            error = _ValidationError.readFailed;
          } else {
            bytes = List<int>.of(buffer.asTypedList(total));
          }
        }
      }
    }
  } on Object {
    bytes = null;
    error = _ValidationError.readFailed;
  } finally {
    if (descriptor >= 0 && functions.close(descriptor) != 0) {
      bytes = null;
      error = _ValidationError.readFailed;
    }
    if (buffer != null) calloc.free(buffer);
    calloc.free(nativePath);
  }
  return (bytes: bytes, error: error);
}

int _secureOpenFlags() => Platform.isMacOS
    ? 0x01000000 | 0x00000100 | 0x00000004
    : 0x00080000 | 0x00020000 | 0x00000800;

int _symlinkErrno() => Platform.isMacOS ? 62 : 40;

final class _PosixFunctions {
  _PosixFunctions() {
    final library = ffi.DynamicLibrary.process();
    open = library.lookupFunction<_OpenNative, _OpenDart>('open');
    read = library.lookupFunction<_ReadNative, _ReadDart>('read');
    close = library.lookupFunction<_CloseNative, _CloseDart>('close');
    fstat = library.lookupFunction<_FstatNative, _FstatDart>(
      ffi.Abi.current() == ffi.Abi.macosX64 ? r'fstat$INODE64' : 'fstat',
    );
    geteuid = library.lookupFunction<ffi.Uint32 Function(), int Function()>(
      'geteuid',
    );
    errnoLocation = library.lookupFunction<_ErrnoNative, _ErrnoDart>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );
  }

  late final _FstatDart fstat;
  late final int Function() geteuid;
  _ValidationError? securityFailure(int descriptor) {
    // `struct stat` layouts are ABI-specific, so each one is audited against the
    // platform headers instead of being guessed:
    //
    //   Darwin64 stat64 (macos-arm64, macos-x64)
    //     byte 4  mode_t  (16-bit)   byte 16 uid_t
    //   Linux x86_64 glibc (linux-x64)
    //     byte 24 mode_t  (32-bit)   byte 28 uid_t
    //
    // Reading the low 16 bits of mode_t little-endian serves both layouts.
    final isDarwin = Platform.isMacOS;
    final uidOffset = isDarwin ? 16 : 28;
    final modeOffset = isDarwin ? 4 : 24;
    final stat = calloc<ffi.Uint8>(512);
    try {
      if (fstat(descriptor, stat.cast()) != 0) {
        return _ValidationError.readFailed;
      }
      if ((stat + uidOffset).cast<ffi.Uint32>().value != geteuid()) {
        return _ValidationError.ownerMismatch;
      }
      // /dev/fd FileStat mode describes the open descriptor (read-only), not
      // the underlying file's full permission bits. Use descriptor fstat.
      final mode = (stat + modeOffset).cast<ffi.Uint16>().value;
      if ((mode & 0xf000) != 0x8000) return _ValidationError.notRegularFile;
      if ((mode & 0xfff) != 0x180) return _ValidationError.insecurePermissions;
      return null;
    } finally {
      calloc.free(stat);
    }
  }

  late final _OpenDart open;
  late final _ReadDart read;
  late final _CloseDart close;
  late final _ErrnoDart errnoLocation;

  int get currentErrno => errnoLocation().value;
}

typedef _FstatNative = ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>);
typedef _FstatDart = int Function(int, ffi.Pointer<ffi.Void>);

typedef _OpenNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _OpenDart = int Function(ffi.Pointer<ffi.Char>, int);
typedef _ReadNative =
    ffi.IntPtr Function(ffi.Int32, ffi.Pointer<ffi.Void>, ffi.UintPtr);
typedef _ReadDart = int Function(int, ffi.Pointer<ffi.Void>, int);
typedef _CloseNative = ffi.Int32 Function(ffi.Int32);
typedef _CloseDart = int Function(int);
typedef _ErrnoNative = ffi.Pointer<ffi.Int32> Function();
typedef _ErrnoDart = ffi.Pointer<ffi.Int32> Function();

bool _hasExactSchema(Map<String, Object?> value, String source) {
  final Set<String> expectedKeys;
  switch (value['schemaVersion']) {
    case 1:
      expectedKeys = _schemaKeys;
    case 2:
      expectedKeys = _explicitSchemaKeys;
    default:
      return false;
  }
  final sourceKeys = _topLevelJsonObjectKeys(source);
  if (value.length != expectedKeys.length ||
      value.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(value.keys.toSet()).isNotEmpty ||
      sourceKeys.length != expectedKeys.length ||
      sourceKeys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(sourceKeys.toSet()).isNotEmpty) {
    return false;
  }
  return true;
}

List<String> _topLevelJsonObjectKeys(String source) {
  final keys = <String>[];
  var depth = 0;
  var expectingKey = false;
  for (var index = 0; index < source.length; index += 1) {
    final character = source.codeUnitAt(index);
    if (character == 0x22) {
      final start = index;
      var escaped = false;
      for (index += 1; index < source.length; index += 1) {
        final current = source.codeUnitAt(index);
        if (escaped) {
          escaped = false;
        } else if (current == 0x5c) {
          escaped = true;
        } else if (current == 0x22) {
          break;
        }
      }
      if (depth == 1 && expectingKey) {
        final decodedKey = jsonDecode(source.substring(start, index + 1));
        if (decodedKey is! String) return const <String>[];
        keys.add(decodedKey);
        expectingKey = false;
      }
      continue;
    }
    if (character == 0x7b || character == 0x5b) {
      depth += 1;
      if (depth == 1 && character == 0x7b) expectingKey = true;
    } else if (character == 0x7d || character == 0x5d) {
      depth -= 1;
    } else if (character == 0x2c && depth == 1) {
      expectingKey = true;
    }
  }
  return keys;
}

bool _hasValidFieldTypesAndClosedValues(Map<String, Object?> value) {
  final schemaVersion = value['schemaVersion'];
  final versionCode = value['versionCode'];
  final lastUpdateTime = value['lastUpdateTime'];
  final observedMonotonic = value['observedAtMonotonicElapsedNanos'];
  if (schemaVersion is! int ||
      (schemaVersion != 1 && schemaVersion != 2) ||
      versionCode is! int ||
      versionCode <= 0 ||
      lastUpdateTime is! int ||
      lastUpdateTime <= 0 ||
      observedMonotonic is! int ||
      observedMonotonic <= 0) {
    return false;
  }
  if (schemaVersion == 2) {
    final attemptId = value['explicitAttemptId'];
    if (value['sourceKind'] != 'explicitLibre2Lifecycle' ||
        attemptId is! String ||
        !_explicitAttemptToken.hasMatch(attemptId) ||
        value['model'] != 'libre2') {
      return false;
    }
  }

  final nativeSession = value['nativeCaptureSessionId'];
  final processSession = value['processSessionId'];
  final captureSession = value['captureSessionId'];
  // Match native explicit v2: captureSessionId is null. V1 is host-bound.
  // This is offline historical evidence, never a live-session authorization.
  final targetHash = value['targetUidSha256'];
  final patchHash = value['patchInfoSha256'];
  final model = value['model'];
  final generation = value['securityGeneration'];
  final uid = value['algorithmOrderUidHex'];
  final patch = value['patchInfoHex'];
  final fram = value['encryptedFramHex'];
  final observedAt = value['observedAtUtc'];
  if (nativeSession is! String ||
      !_sessionToken.hasMatch(nativeSession) ||
      processSession is! String ||
      !_sessionToken.hasMatch(processSession) ||
      !(schemaVersion == 2
          ? captureSession == null
          : captureSession is String &&
                _captureSessionToken.hasMatch(captureSession)) ||
      targetHash is! String ||
      !_sha256Hex.hasMatch(targetHash) ||
      patchHash is! String ||
      !_sha256Hex.hasMatch(patchHash) ||
      model is! String ||
      model != 'libre2' ||
      generation != 'gen1' ||
      value['iso15693ManufacturerPrefix'] != 'e007' ||
      uid is! String ||
      !_uidHex.hasMatch(uid) ||
      patch is! String ||
      !_patchInfoHex.hasMatch(patch) ||
      fram is! String ||
      !_encryptedFramHex.hasMatch(fram) ||
      observedAt is! String ||
      !_utcTimestamp.hasMatch(observedAt)) {
    return false;
  }

  return _strictUtc(observedAt) != null;
}

DateTime? _strictUtc(String value) {
  if (!_utcTimestamp.hasMatch(value)) return null;
  final parsed = DateTime.tryParse(value);
  // Dart normalizes overflowing calendar fields; the native Instant parser
  // does not. Do not accept an impossible date by silently changing it.
  if (parsed == null ||
      !parsed.isUtc ||
      parsed.millisecondsSinceEpoch <= 0 ||
      parsed.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
    return null;
  }
  return parsed;
}

List<int> _decodeHex(String value) => <int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
];

String _encodeHex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

enum _ValidationError {
  ownerMismatch('owner_mismatch'),
  symlinkForbidden('symlink_forbidden'),
  notRegularFile('not_regular_file'),
  insecurePermissions('insecure_permissions'),
  oversizedFile('oversized_file'),
  readFailed('read_failed'),
  unsupportedPlatform('unsupported_platform');

  const _ValidationError(this.code);

  final String code;
}

const _traceKeys = <String>{
  'schema_version',
  'sequence',
  'correlation_id',
  'recorded_at_utc',
  'monotonic_elapsed_microseconds',
  'event_type',
  'operation',
  'data',
};
const _notificationKeys = <String>{
  'device_id',
  'service_uuid',
  'characteristic_uuid',
  'properties',
  'bytes',
};
const _properties = <String>{
  'read',
  'write',
  'write_without_response',
  'notify',
  'indicate',
};
const _eventTypes = <String>{
  'captureHeartbeat',
  'operationStarted',
  'operationSucceeded',
  'operationFailed',
  'advertisement',
  'connectionState',
  'notificationData',
  'streamCompleted',
  'streamCancelled',
  'streamCancellationFailed',
  'streamFailed',
};
const _operations = <String>{
  'captureHeartbeat',
  'scan',
  'connect',
  'connectionState',
  'ensureBonded',
  'currentBondState',
  'requestMtu',
  'discoverServices',
  'read',
  'write',
  'setNotify',
  'notifications',
  'removeBond',
  'disconnect',
};

/// Read-only private-file analysis. Output is closed counts/reasons only.
/// This tool creates no files and performs no device, network or process I/O.
Future<(int, String)> runPrivateBenchAnalysis(
  List<String> args, {
  void Function()? afterSecureOpenForTest,
}) async {
  try {
    if (args.length != 4 || args[0] != '--calibration' || args[2] != '--ble') {
      return _closedFailure(64, 'arguments');
    }
    if ([
      args[1],
      args[3],
    ].any((p) => !p.startsWith('/') || p.contains('\u0000'))) {
      return _closedFailure(66, 'input');
    }
    final calibrationRead = _readDescriptorBound(
      args[1],
      maximumBytes: 16384,
      afterSecureOpenForTest: afterSecureOpenForTest,
    );
    final traceRead = _readDescriptorBound(
      args[3],
      maximumBytes: 32 * 1024 * 1024,
      afterSecureOpenForTest: afterSecureOpenForTest,
    );
    if (calibrationRead.error != null || traceRead.error != null) {
      return _closedFailure(
        66,
        (calibrationRead.error ?? traceRead.error)!.code,
      );
    }
    final calibrationSource = utf8.decode(
      calibrationRead.bytes!,
      allowMalformed: false,
    );
    final value = _uniqueJson(calibrationSource);
    if (value is! Map<String, Object?> ||
        !_hasExactSchema(value, calibrationSource) ||
        !_hasValidFieldTypesAndClosedValues(value)) {
      return _closedFailure(65, 'calibrationSchema');
    }
    final uid = _decodeHex(value['algorithmOrderUidHex'] as String);
    final patch = _decodeHex(value['patchInfoHex'] as String);
    if (_sha256(uid) != value['targetUidSha256'] ||
        _sha256(patch) != value['patchInfoSha256'] ||
        _encodeHex([uid[7], uid[6]]) != value['iso15693ManufacturerPrefix']) {
      return _closedFailure(65, 'calibrationBinding');
    }
    final decoder = Libre2Gen1GlucoseDecoder.fromEncryptedFram(
      uid: uid,
      initialPatchInfo: patch,
      encryptedFram: _decodeHex(value['encryptedFramHex'] as String),
    );
    final source = utf8.decode(traceRead.bytes!, allowMalformed: false);
    final notifications = <_Notification>[];
    String? device;
    var sequence = -1;
    var monotonic = -1;
    DateTime? previousUtc;
    var lines = 0;
    for (final line in const LineSplitter().convert(source)) {
      if (++lines > 100000 || line.length > 65536 || line.isEmpty) {
        return _closedFailure(65, 'traceSchema');
      }
      final event = _uniqueJson(line);
      if (event is! Map<String, Object?> ||
          !_keys(event, _traceKeys) ||
          event['schema_version'] is! int ||
          event['schema_version'] != 1 ||
          event['sequence'] is! int ||
          (event['sequence'] as int) <= 0 ||
          (event['sequence'] as int) <= sequence ||
          event['monotonic_elapsed_microseconds'] is! int ||
          (event['monotonic_elapsed_microseconds'] as int) < 0 ||
          (event['monotonic_elapsed_microseconds'] as int) < monotonic ||
          event['correlation_id'] is! String ||
          !(event['correlation_id'] as String).isNotEmpty ||
          (event['correlation_id'] as String).length > 160 ||
          !_eventTypes.contains(event['event_type']) ||
          !_operations.contains(event['operation']) ||
          event['data'] is! Map<String, Object?>) {
        return _closedFailure(65, 'traceSchema');
      }
      final at = event['recorded_at_utc'];
      if (at is! String || !_utcTimestamp.hasMatch(at)) {
        return _closedFailure(65, 'traceSchema');
      }
      final utc = _strictUtc(at);
      if (utc == null ||
          !utc.isUtc ||
          (previousUtc != null && utc.isBefore(previousUtc))) {
        return _closedFailure(65, 'traceClock');
      }
      previousUtc = utc;
      sequence = event['sequence'] as int;
      monotonic = event['monotonic_elapsed_microseconds'] as int;
      final data = event['data'] as Map<String, Object?>;
      if (event['event_type'] != 'notificationData') {
        // An explicit terminal event is a grouping boundary, never proof that
        // fragments from another subscription belong to the same composite.
        if (event['event_type'] == 'connectionState' ||
            event['event_type'] == 'streamCompleted' ||
            event['event_type'] == 'streamCancelled' ||
            event['event_type'] == 'streamCancellationFailed' ||
            event['event_type'] == 'streamFailed') {
          notifications.add(_Notification.boundary());
        }
        continue;
      }
      if (event['operation'] != 'notifications') {
        return _closedFailure(65, 'traceSchema');
      }
      final service = data['service_uuid'];
      final characteristic = data['characteristic_uuid'];
      if (service is! String || characteristic is! String) {
        return _closedFailure(65, 'traceSchema');
      }
      try {
        if (normalizeLibreUuid(service) != LibreUuids.sasService ||
            normalizeLibreUuid(characteristic) != LibreUuids.sasData) {
          continue;
        }
      } on LibreProtocolError {
        return _closedFailure(65, 'traceSchema');
      }
      if (!_keys(data, _notificationKeys) ||
          data['device_id'] is! String ||
          !RegExp(
            r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$',
          ).hasMatch(data['device_id'] as String) ||
          data['properties'] is! Map<String, Object?> ||
          !_keys(data['properties'] as Map<String, Object?>, _properties) ||
          (data['properties'] as Map).values.any((v) => v is! bool) ||
          data['bytes'] is! List ||
          (data['bytes'] as List).any((b) => b is! int || b < 0 || b > 255)) {
        return _closedFailure(65, 'traceSchema');
      }
      final selected = (data['device_id'] as String).toUpperCase();
      if (device != null && device != selected) {
        return _closedFailure(65, 'ambiguousDevice');
      }
      device = selected;
      notifications.add(
        _Notification(
          (event['correlation_id'] as String),
          monotonic,
          utc,
          List<int>.of((data['bytes'] as List).cast<int>()),
        ),
      );
    }
    if (device == null) return _closedFailure(65, 'noMatchingNotifications');
    var complete = 0,
        incomplete = 0,
        acceptedCurrent = 0,
        integrityRejected = 0;
    var notificationCount = 0;
    final currentRejections = <String, int>{};
    final sampleRejections = <String, int>{};
    final packetRejections = <String, int>{};
    final fragments = <_Notification>[];
    for (final event in notifications) {
      if (event.boundary) {
        if (fragments.isNotEmpty) {
          incomplete++;
          fragments.clear();
        }
        continue;
      }
      notificationCount++;
      if (event.bytes.length != const [20, 18, 8][fragments.length]) {
        return _closedFailure(65, 'fragmentSequence');
      }
      if (fragments.isNotEmpty &&
          (event.correlation != fragments.first.correlation ||
              event.monotonic - fragments.first.monotonic > 10000000 ||
              event.utc!.difference(fragments.first.utc!) >
                  const Duration(seconds: 10))) {
        return _closedFailure(65, 'fragmentBinding');
      }
      fragments.add(event);
      if (fragments.length != 3) continue;
      final encrypted = [for (final f in fragments) ...f.bytes];
      fragments.clear();
      complete++;
      try {
        final packet = decoder.decodeEncryptedBle(encrypted);
        if (packet.current.glucoseMgDl != null) {
          acceptedCurrent++;
        }
        if (packet.current.rejection case final reason?) {
          _count(currentRejections, reason.name);
        }
        for (final sample in packet.samples) {
          if (sample.rejection case final reason?) {
            _count(sampleRejections, reason.name);
          }
        }
      } on LibreProtocolError {
        integrityRejected++;
      } on Libre2Gen1GlucoseError catch (error) {
        _count(packetRejections, error.kind.name);
      }
    }
    if (fragments.isNotEmpty) incomplete++;
    return (
      0,
      jsonEncode({
        'analyzed': true,
        'notifications': notificationCount,
        'completeComposites': complete,
        'incompleteComposites': incomplete,
        'acceptedCurrentSamples': acceptedCurrent,
        'integrityRejected': integrityRejected,
        'currentRejections': currentRejections,
        'sampleRejections': sampleRejections,
        'packetRejections': packetRejections,
      }),
    );
  } on Libre2Gen1GlucoseError catch (error) {
    return _closedFailure(65, 'calibration_${error.kind.name}');
  } on LibreProtocolError {
    return _closedFailure(65, 'calibrationIntegrity');
  } catch (_) {
    return _closedFailure(65, 'invalidArtifact');
  }
}

final class _Notification {
  _Notification(this.correlation, this.monotonic, this.utc, this.bytes)
    : boundary = false;
  _Notification.boundary()
    : boundary = true,
      correlation = '',
      monotonic = 0,
      utc = null,
      bytes = const [];
  final bool boundary;
  final String correlation;
  final int monotonic;
  final DateTime? utc;
  final List<int> bytes;
}

void _count(Map<String, int> counts, String reason) =>
    counts[reason] = (counts[reason] ?? 0) + 1;
bool _keys(Map<String, Object?> value, Set<String> keys) =>
    value.length == keys.length && value.keys.every(keys.contains);
(int, String) _closedFailure(int code, String reason) =>
    (code, jsonEncode({'analyzed': false, 'error': reason}));

Object? _uniqueJson(String source) {
  final result = jsonDecode(source);
  final stack = <Set<String>?>[];
  final expecting = <bool>[];
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    if (c == 0x22) {
      final start = i;
      var escaped = false;
      for (i++; i < source.length; i++) {
        final c = source.codeUnitAt(i);
        if (escaped) {
          escaped = false;
        } else if (c == 0x5c) {
          escaped = true;
        } else if (c == 0x22) {
          break;
        }
      }
      if (stack.isNotEmpty && stack.last != null && expecting.last) {
        final key = jsonDecode(source.substring(start, i + 1)) as String;
        if (!stack.last!.add(key)) throw const FormatException();
        expecting[expecting.length - 1] = false;
      }
    } else if (c == 0x7b || c == 0x5b) {
      stack.add(c == 0x7b ? <String>{} : null);
      expecting.add(c == 0x7b);
    } else if (c == 0x7d || c == 0x5d) {
      stack.removeLast();
      expecting.removeLast();
    } else if (c == 0x2c && stack.isNotEmpty && stack.last != null) {
      expecting[expecting.length - 1] = true;
    }
  }
  return result;
}

Future<void> main(List<String> args) async {
  final result = await runPrivateBenchAnalysis(args);
  stdout.writeln(result.$2);
  exitCode = result.$1;
}
