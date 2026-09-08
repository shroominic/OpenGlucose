import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';

const int _maximumArtifactBytes = 16 * 1024;
const int _successExitCode = 0;
const int _usageExitCode = 64;
const int _dataExitCode = 65;
const int _inputExitCode = 66;
const String _artifactFileName = 'nfc-gen1-fram-capture.json';

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

final RegExp _sessionToken = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
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

/// Runs the offline validator and returns `(exitCode, oneJsonOutputLine)`.
///
/// The returned line contains only closed values. It never contains input
/// bytes, identifiers, hashes, paths, parser messages, or stack traces.
Future<(int, String)> runGen1FramCaptureValidator(
  List<String> arguments, {
  void Function()? afterSecureOpenForTest,
}) async {
  try {
    if (arguments.length != 1) {
      return _failure(_usageExitCode, _ValidationError.argumentCount);
    }

    final path = arguments.single;
    if (path.isEmpty ||
        path.contains('\u0000') ||
        File(path).uri.pathSegments.last != _artifactFileName) {
      return _failure(_inputExitCode, _ValidationError.invalidPath);
    }

    final read = _readDescriptorBound(
      path,
      afterSecureOpenForTest: afterSecureOpenForTest,
    );
    if (read.error != null) {
      return _failure(_inputExitCode, read.error!);
    }
    final bytes = read.bytes!;

    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return _failure(_dataExitCode, _ValidationError.invalidJson);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return _failure(_dataExitCode, _ValidationError.invalidJson);
    }
    if (decoded is! Map<String, Object?> ||
        !_hasExactSchema(decoded, source) ||
        !_hasValidFieldTypesAndClosedValues(decoded)) {
      return _failure(_dataExitCode, _ValidationError.invalidSchema);
    }

    final algorithmUid = _decodeHex(decoded['algorithmOrderUidHex']! as String);
    final patchInfoBytes = _decodeHex(decoded['patchInfoHex']! as String);
    final encryptedFram = _decodeHex(decoded['encryptedFramHex']! as String);

    if (_sha256(algorithmUid) != decoded['targetUidSha256']) {
      return _failure(_dataExitCode, _ValidationError.uidHashMismatch);
    }
    final manufacturerPrefix = _encodeHex(<int>[
      algorithmUid[7],
      algorithmUid[6],
    ]);
    if (manufacturerPrefix != decoded['iso15693ManufacturerPrefix']) {
      return _failure(
        _dataExitCode,
        _ValidationError.manufacturerPrefixMismatch,
      );
    }
    if (_sha256(patchInfoBytes) != decoded['patchInfoSha256']) {
      return _failure(_dataExitCode, _ValidationError.patchHashMismatch);
    }

    final LibreGen1PatchInfo patchInfo;
    try {
      patchInfo = LibreGen1PatchInfo(patchInfoBytes);
    } on LibreProtocolError {
      return _failure(_dataExitCode, _ValidationError.unsupportedPatchInfo);
    }
    if (patchInfo.model.name != decoded['model']) {
      return _failure(_dataExitCode, _ValidationError.modelMismatch);
    }

    final LibreGen1DecryptedFram clearFram;
    try {
      clearFram = LibreGen1OfflineCore(
        uid: LibreGen1Uid.algorithmOrder(algorithmUid),
        patchInfo: patchInfo,
      ).decryptFram(encryptedFram);
    } on LibreProtocolError {
      return _failure(_dataExitCode, _ValidationError.framIntegrityFailed);
    }
    final lifecycle = parseLibreGen1Lifecycle(clearFram);

    return (
      _successExitCode,
      jsonEncode(<String, Object>{
        'validated': true,
        'model': patchInfo.model.name,
        'lifecycle': lifecycle.state.name,
        'length': clearFram.value.length,
        'evidenceStatus': lifecycle.evidenceStatus.name,
      }),
    );
  } catch (_) {
    return _failure(_dataExitCode, _ValidationError.internalFailure);
  }
}

({List<int>? bytes, _ValidationError? error}) _readDescriptorBound(
  String path, {
  void Function()? afterSecureOpenForTest,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
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
      } else if (_permissionFailure(before.mode) case final failure?) {
        error = failure;
      } else if (before.size > _maximumArtifactBytes) {
        error = _ValidationError.oversizedFile;
      } else {
        buffer = calloc<ffi.Uint8>(_maximumArtifactBytes + 1);
        var total = 0;
        while (total <= _maximumArtifactBytes) {
          final count = functions.read(
            descriptor,
            (buffer + total).cast(),
            _maximumArtifactBytes + 1 - total,
          );
          if (count < 0) {
            error = _ValidationError.readFailed;
            break;
          }
          if (count == 0) break;
          total += count;
        }
        if (error == null && total > _maximumArtifactBytes) {
          error = _ValidationError.oversizedFile;
        }
        if (error == null) {
          final after = FileStat.statSync(descriptorPath);
          if (after.type != FileSystemEntityType.file ||
              _permissionFailure(after.mode) != null ||
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
    errnoLocation = library.lookupFunction<_ErrnoNative, _ErrnoDart>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );
  }

  late final _OpenDart open;
  late final _ReadDart read;
  late final _CloseDart close;
  late final _ErrnoDart errnoLocation;

  int get currentErrno => errnoLocation().value;
}

typedef _OpenNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _OpenDart = int Function(ffi.Pointer<ffi.Char>, int);
typedef _ReadNative =
    ffi.IntPtr Function(ffi.Int32, ffi.Pointer<ffi.Void>, ffi.UintPtr);
typedef _ReadDart = int Function(int, ffi.Pointer<ffi.Void>, int);
typedef _CloseNative = ffi.Int32 Function(ffi.Int32);
typedef _CloseDart = int Function(int);
typedef _ErrnoNative = ffi.Pointer<ffi.Int32> Function();
typedef _ErrnoDart = ffi.Pointer<ffi.Int32> Function();

_ValidationError? _permissionFailure(int mode) {
  const ownerRead = 0x100;
  const groupAndWorldPermissions = 0x03f;
  if ((mode & ownerRead) == 0 || (mode & groupAndWorldPermissions) != 0) {
    return _ValidationError.insecurePermissions;
  }
  return null;
}

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
  // Explicit reads are accepted only after the protected collector binds them
  // to a host session. The original app-owned v2 source has a null session.
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
      captureSession is! String ||
      !_captureSessionToken.hasMatch(captureSession) ||
      targetHash is! String ||
      !_sha256Hex.hasMatch(targetHash) ||
      patchHash is! String ||
      !_sha256Hex.hasMatch(patchHash) ||
      model is! String ||
      (model != 'libre2' && model != 'libre2Plus') ||
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

  final parsedTime = DateTime.tryParse(observedAt);
  return parsedTime != null && parsedTime.isUtc;
}

List<int> _decodeHex(String value) => <int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
];

String _encodeHex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

(int, String) _failure(int exitCode, _ValidationError error) => (
  exitCode,
  jsonEncode(<String, Object>{'validated': false, 'error': error.code}),
);

enum _ValidationError {
  argumentCount('argument_count'),
  invalidPath('invalid_path'),
  symlinkForbidden('symlink_forbidden'),
  notRegularFile('not_regular_file'),
  insecurePermissions('insecure_permissions'),
  oversizedFile('oversized_file'),
  readFailed('read_failed'),
  unsupportedPlatform('unsupported_platform'),
  invalidJson('invalid_json'),
  invalidSchema('invalid_schema'),
  uidHashMismatch('uid_hash_mismatch'),
  manufacturerPrefixMismatch('manufacturer_prefix_mismatch'),
  patchHashMismatch('patch_hash_mismatch'),
  modelMismatch('model_mismatch'),
  unsupportedPatchInfo('unsupported_patch_info'),
  framIntegrityFailed('fram_integrity_failed'),
  internalFailure('internal_failure');

  const _ValidationError(this.code);

  final String code;
}

Future<void> main(List<String> arguments) async {
  final result = await runGen1FramCaptureValidator(arguments);
  stdout.writeln(result.$2);
  exitCode = result.$1;
}
