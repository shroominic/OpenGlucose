import 'dart:convert';
import 'dart:io';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

import '../tool/validate_gen1_fram_capture.dart';

const String _fileName = 'nfc-gen1-fram-capture.json';
// Pinned LibreTools Example2 at revision
// d54b0883959420e5941ed293ec6b9ef2474b7ed3, Libre2.swift lines 542-591.
const String _uidHex = 'df20be0000a407e0';
const String _patchHex = '9d0830017625';
const String _encryptedFramHex =
    '520bf344dca04321cc7dd74e29e282e3e704c9cf6c572c7d'
    'a88210aad73219b3c79f395fe37a4508b709bc6efada3407b'
    '46568607ea504e665654813f89ca7c870a74d9d523586f202'
    'cc9b9b7432ffc5bfe9781f46c2c70b0fb0c85423e20d4497'
    '44368fac12ae4a6ce137e2462b5c741b7afe674fccdd95177'
    '3b325e9aba65e70e46cce568db9e5feaa503652d2c522243'
    '9d863086204adfa89001072cfa9f3474bf57096f28acaffef'
    'a39e1aec9f4a2fe8a9cae6c8744698b2a29e8df0af09c15b'
    '52597e00d33f59417b33eedb4051b23d9482f3b2e4caad3c'
    'd8c0d7d74c51caa3ad2624ab10ba6135e17f3d3fecb4cfe3'
    'a2316ae7d73618215b435a9c757c89e2496cb1716a476e8ae'
    '5b2c537e9e5ddb31237957ad01f73ebb815f1e65d51fb1688'
    'a69c17b0400ebbd7ca9dcd8b60888854fc657143e751e218e'
    'a631d5baad1d3d708b7ed87c4b42431e7a0e6595193fda3e'
    '6bfe1f209';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'libre-gen1-validator-',
    );
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  group('closed output contract', () {
    test('validates the mode-600 pinned Example2 artifact', () async {
      final file = _writeArtifact(temporaryDirectory, _validArtifact());

      final result = await runGen1FramCaptureValidator(<String>[file.path]);

      expect(result.$1, 0);
      expect(jsonDecode(result.$2), <String, Object>{
        'validated': true,
        'model': 'libre2',
        'lifecycle': 'active',
        'length': 344,
        'evidenceStatus': 'referenceVerifiedTargetUnverified',
      });
      expect(result.$2, isNot(contains(_uidHex)));
      expect(result.$2, isNot(contains(_patchHex)));
      expect(result.$2, isNot(contains(file.path)));
      expect(result.$2.toLowerCase(), isNot(contains('glucose')));
    });

    test('CLI writes exactly one success line and no diagnostics', () async {
      final file = _writeArtifact(temporaryDirectory, _validArtifact());

      final process = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/validate_gen1_fram_capture.dart',
        file.path,
      ], workingDirectory: Directory.current.path);

      expect(process.exitCode, 0);
      expect(process.stderr, isEmpty);
      final lines = LineSplitter.split(process.stdout as String).toList();
      expect(lines, hasLength(1));
      expect(jsonDecode(lines.single), <String, Object>{
        'validated': true,
        'model': 'libre2',
        'lifecycle': 'active',
        'length': 344,
        'evidenceStatus': 'referenceVerifiedTargetUnverified',
      });
    });

    test('requires exactly one explicit artifact argument', () async {
      final noArgument = await runGen1FramCaptureValidator(const <String>[]);
      final twoArguments = await runGen1FramCaptureValidator(const <String>[
        'first',
        'second',
      ]);

      _expectFailure(noArgument, 'argument_count');
      _expectFailure(twoArguments, 'argument_count');
    });

    test('requires the explicit capture artifact filename', () async {
      final file = _writeArtifact(
        temporaryDirectory,
        _validArtifact(),
        fileName: 'renamed.json',
      );

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'invalid_path',
      );
    });

    test('rejects embedded NUL before native path conversion', () async {
      _expectFailure(
        await runGen1FramCaptureValidator(<String>[
          '${temporaryDirectory.path}/$_fileName\u0000ignored',
        ]),
        'invalid_path',
      );
    });

    test('CLI writes one closed failure line and exits nonzero', () async {
      final file = _writeText(temporaryDirectory, '{malformed');

      final process = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'tool/validate_gen1_fram_capture.dart',
        file.path,
      ], workingDirectory: Directory.current.path);

      expect(process.exitCode, isNonZero);
      expect(process.stderr, isEmpty);
      final lines = LineSplitter.split(process.stdout as String).toList();
      expect(lines, hasLength(1));
      expect(jsonDecode(lines.single), <String, Object>{
        'validated': false,
        'error': 'invalid_json',
      });
      expect(process.stdout, isNot(contains(file.path)));
      expect(process.stdout, isNot(contains('FormatException')));
    });
  });

  group('rebound explicit lifecycle schema', () {
    test('validates v2 through the same closed cryptographic output', () async {
      final artifact = _validExplicitArtifact();
      final file = _writeArtifact(temporaryDirectory, artifact);

      final result = await runGen1FramCaptureValidator(<String>[file.path]);

      expect(result.$1, 0);
      expect(jsonDecode(result.$2), <String, Object>{
        'validated': true,
        'model': 'libre2',
        'lifecycle': 'active',
        'length': 344,
        'evidenceStatus': 'referenceVerifiedTargetUnverified',
      });
      _expectRedacted(result.$2, artifact, file.path);
      expect(result.$2, isNot(contains(artifact['explicitAttemptId'])));
    });

    test('requires an exact bound v2 envelope and keeps v1 strict', () async {
      final valid = jsonEncode(_validExplicitArtifact());
      final mutations = <String, String>{
        'missing-source': jsonEncode(
          _validExplicitArtifact()..remove('sourceKind'),
        ),
        'missing-attempt': jsonEncode(
          _validExplicitArtifact()..remove('explicitAttemptId'),
        ),
        'wrong-source': jsonEncode(
          _validExplicitArtifact()..['sourceKind'] = 'other',
        ),
        'numeric-attempt': jsonEncode(
          _validExplicitArtifact()..['explicitAttemptId'] = 1,
        ),
        'short-attempt': jsonEncode(
          _validExplicitArtifact()..['explicitAttemptId'] = 'short',
        ),
        'long-attempt': jsonEncode(
          _validExplicitArtifact()..['explicitAttemptId'] = 'a' * 121,
        ),
        'unsafe-attempt': jsonEncode(
          _validExplicitArtifact()..['explicitAttemptId'] = 'attempt/path',
        ),
        'unbound': valid.replaceFirst(
          RegExp(r'"captureSessionId":"[^"]+"'),
          '"captureSessionId":null',
        ),
        'invalid-host': jsonEncode(
          _validExplicitArtifact()..['captureSessionId'] = 'not-a-host-session',
        ),
        'unknown-field': jsonEncode(
          _validExplicitArtifact()..['unknown'] = true,
        ),
        'raw-field': jsonEncode(
          _validExplicitArtifact()..['rawResponse'] = 'synthetic',
        ),
        'duplicate-source': valid.replaceFirst(
          '{',
          '{"sourceKind":"explicitLibre2Lifecycle",',
        ),
        'duplicate-attempt': valid.replaceFirst(
          '{',
          '{"explicitAttemptId":"synthetic-attempt",',
        ),
        'duplicate-schema': valid.replaceFirst('{', '{"schemaVersion":2,'),
        'escaped-duplicate-source': valid.replaceFirst(
          '{',
          r'{"\u0073ourceKind":"explicitLibre2Lifecycle",',
        ),
        'escaped-duplicate-attempt': valid.replaceFirst(
          '{',
          r'{"\u0065xplicitAttemptId":"synthetic-attempt",',
        ),
        'escaped-duplicate-schema': valid.replaceFirst(
          '{',
          r'{"\u0073chemaVersion":2,',
        ),
        'future-schema': jsonEncode(
          _validExplicitArtifact()..['schemaVersion'] = 3,
        ),
        'v1-extra-fields': jsonEncode(
          _validExplicitArtifact()..['schemaVersion'] = 1,
        ),
        'v2-missing-fields': jsonEncode(
          _validArtifact()..['schemaVersion'] = 2,
        ),
        'wrong-model': jsonEncode(
          _validExplicitArtifact()..['model'] = 'libre2Plus',
        ),
      };
      for (final mutation in mutations.entries) {
        final directory = Directory(
          '${temporaryDirectory.path}/${mutation.key}',
        )..createSync();
        final file = _writeText(directory, mutation.value);
        _expectFailure(
          await runGen1FramCaptureValidator(<String>[file.path]),
          'invalid_schema',
        );
      }
    });

    for (final field in <String>['targetUidSha256', 'patchInfoSha256']) {
      test('v2 still verifies $field', () async {
        final artifact = _validExplicitArtifact()..[field] = '0' * 64;
        final file = _writeArtifact(temporaryDirectory, artifact);
        final result = await runGen1FramCaptureValidator(<String>[file.path]);
        _expectFailure(
          result,
          field == 'targetUidSha256'
              ? 'uid_hash_mismatch'
              : 'patch_hash_mismatch',
        );
        _expectRedacted(result.$2, artifact, file.path);
      });
    }

    for (final region in <(String, int)>[
      ('header', 10),
      ('body', 100),
      ('footer', 330),
    ]) {
      test('v2 still verifies ${region.$1} CRC', () async {
        final encrypted = _hex(_encryptedFramHex)..[region.$2] ^= 1;
        final artifact = _validExplicitArtifact()
          ..['encryptedFramHex'] = _encodeHex(encrypted);
        final file = _writeArtifact(temporaryDirectory, artifact);
        final result = await runGen1FramCaptureValidator(<String>[file.path]);
        _expectFailure(result, 'fram_integrity_failed');
        _expectRedacted(result.$2, artifact, file.path);
      });
    }
  });

  group('filesystem boundary', () {
    test('refuses a symbolic link', () async {
      final targetDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}target',
      )..createSync();
      final target = _writeArtifact(
        targetDirectory,
        _validArtifact(),
        fileName: 'private-target.json',
      );
      final link = Link(
        '${temporaryDirectory.path}${Platform.pathSeparator}$_fileName',
      )..createSync(target.path);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[link.path]),
        'symlink_forbidden',
      );
    });

    test('refuses a non-regular entity', () async {
      final directory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}$_fileName',
      )..createSync();

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[directory.path]),
        'not_regular_file',
      );
    });

    test('refuses group- or world-accessible permissions', () async {
      final file = _writeArtifact(temporaryDirectory, _validArtifact());
      _setMode(file, '0644');

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'insecure_permissions',
      );
    });

    test('refuses an oversized file before JSON parsing', () async {
      final file = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}$_fileName',
      )..writeAsBytesSync(List<int>.filled(16 * 1024 + 1, 0x20));
      _makeOwnerPrivate(file);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'oversized_file',
      );
    });

    test(
      'keeps the opened descriptor when the pathname becomes a link',
      () async {
        final file = _writeArtifact(temporaryDirectory, _validArtifact());
        final replacement = _writeText(
          temporaryDirectory,
          '{malformed',
          fileName: 'replacement.json',
        );
        final heldPath =
            '${temporaryDirectory.path}${Platform.pathSeparator}held.json';

        final result = await runGen1FramCaptureValidator(
          <String>[file.path],
          afterSecureOpenForTest: () {
            file.renameSync(heldPath);
            Link(file.path).createSync(replacement.path);
          },
        );

        expect(result.$1, 0);
        expect(jsonDecode(result.$2), containsPair('validated', true));
      },
    );
  });

  group('strict schema', () {
    test('refuses malformed JSON', () async {
      final file = _writeText(temporaryDirectory, '{invalid');

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'invalid_json',
      );
    });

    test('refuses missing, extra, duplicate, and mistyped fields', () async {
      final mutations = <String, String>{
        'missing': jsonEncode(_validArtifact()..remove('captureSessionId')),
        'extra': jsonEncode(_validArtifact()..['extra'] = true),
        'mistyped': jsonEncode(_validArtifact()..['versionCode'] = '1'),
        'duplicate': _duplicateSchemaVersionJson(),
        'escaped_duplicate': _escapedDuplicateSchemaVersionJson(),
      };

      for (final mutation in mutations.entries) {
        final directory = Directory(
          '${temporaryDirectory.path}${Platform.pathSeparator}${mutation.key}',
        )..createSync();
        final file = _writeText(directory, mutation.value);

        _expectFailure(
          await runGen1FramCaptureValidator(<String>[file.path]),
          'invalid_schema',
        );
      }
    });

    test('refuses 343-byte and 345-byte FRAM encodings', () async {
      for (final entry in <(String, String)>[
        ('short', _encryptedFramHex.substring(0, 686)),
        ('long', '${_encryptedFramHex}00'),
      ]) {
        final directory = Directory(
          '${temporaryDirectory.path}${Platform.pathSeparator}${entry.$1}',
        )..createSync();
        final artifact = _validArtifact()..['encryptedFramHex'] = entry.$2;
        final file = _writeArtifact(directory, artifact);

        _expectFailure(
          await runGen1FramCaptureValidator(<String>[file.path]),
          'invalid_schema',
        );
      }
    });

    test(
      'refuses values outside the closed model and generation sets',
      () async {
        for (final entry in <(String, Map<String, Object>)>[
          ('model', _validArtifact()..['model'] = 'other'),
          ('generation', _validArtifact()..['securityGeneration'] = 'gen2'),
        ]) {
          final directory = Directory(
            '${temporaryDirectory.path}${Platform.pathSeparator}${entry.$1}',
          )..createSync();
          final file = _writeArtifact(directory, entry.$2);

          _expectFailure(
            await runGen1FramCaptureValidator(<String>[file.path]),
            'invalid_schema',
          );
        }
      },
    );
  });

  group('identity and metadata binding', () {
    test('requires the direct algorithm-order UID hash', () async {
      final artifact = _validArtifact()..['targetUidSha256'] = '0' * 64;
      final file = _writeArtifact(temporaryDirectory, artifact);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'uid_hash_mismatch',
      );
    });

    test('binds the e007 manufacturer prefix to UID bytes 7 and 6', () async {
      final changedUid = _hex(_uidHex)..[7] = 0xe1;
      final artifact = _validArtifact()
        ..['algorithmOrderUidHex'] = _encodeHex(changedUid)
        ..['targetUidSha256'] = _digestHex(changedUid);
      final file = _writeArtifact(temporaryDirectory, artifact);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'manufacturer_prefix_mismatch',
      );
    });

    test('Example2 direct UID passes CRCs and reversed UID fails', () {
      final uid = _hex(_uidHex);
      final patch = LibreGen1PatchInfo(_hex(_patchHex));
      final directCore = LibreGen1OfflineCore(
        uid: LibreGen1Uid.algorithmOrder(uid),
        patchInfo: patch,
      );

      final direct = directCore.decryptFram(_hex(_encryptedFramHex));

      expect(direct.value.length, 344);
      expect(
        () => LibreGen1OfflineCore(
          uid: LibreGen1Uid.algorithmOrder(uid.reversed),
          patchInfo: patch,
        ).decryptFram(_hex(_encryptedFramHex)),
        throwsA(
          isA<LibreProtocolError>().having(
            (error) => error.kind,
            'kind',
            LibreProtocolErrorKind.integrityCheckFailed,
          ),
        ),
      );
    });

    test('requires the exact six-byte patch-information hash', () async {
      final artifact = _validArtifact()..['patchInfoSha256'] = 'f' * 64;
      final file = _writeArtifact(temporaryDirectory, artifact);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'patch_hash_mismatch',
      );
    });

    test(
      'requires the classified patch model to match the schema model',
      () async {
        final artifact = _validArtifact()..['model'] = 'libre2Plus';
        final file = _writeArtifact(temporaryDirectory, artifact);

        _expectFailure(
          await runGen1FramCaptureValidator(<String>[file.path]),
          'model_mismatch',
        );
      },
    );

    test('fails closed for an unknown Gen1 patch signature', () async {
      const patch = 'aabb30010000';
      final artifact = _validArtifact()
        ..['patchInfoHex'] = patch
        ..['patchInfoSha256'] = _digestHex(_hex(patch));
      final file = _writeArtifact(temporaryDirectory, artifact);

      _expectFailure(
        await runGen1FramCaptureValidator(<String>[file.path]),
        'unsupported_patch_info',
      );
    });
  });

  group('FRAM integrity and redaction', () {
    for (final entry in <(String, int)>[
      ('header', 10),
      ('body', 100),
      ('footer', 330),
    ]) {
      test('refuses a ${entry.$1} CRC failure', () async {
        final encrypted = _hex(_encryptedFramHex);
        encrypted[entry.$2] ^= 1;
        final artifact = _validArtifact()
          ..['encryptedFramHex'] = _encodeHex(encrypted);
        final file = _writeArtifact(temporaryDirectory, artifact);

        final result = await runGen1FramCaptureValidator(<String>[file.path]);

        _expectFailure(result, 'fram_integrity_failed');
        _expectRedacted(result.$2, artifact, file.path);
      });
    }

    test('every closed failure output excludes restricted input', () async {
      final artifact = _validArtifact()..['targetUidSha256'] = '1' * 64;
      final file = _writeArtifact(temporaryDirectory, artifact);

      final result = await runGen1FramCaptureValidator(<String>[file.path]);

      _expectFailure(result, 'uid_hash_mismatch');
      _expectRedacted(result.$2, artifact, file.path);
      expect(result.$2, isNot(contains('FormatException')));
      expect(result.$2, isNot(contains('FileSystemException')));
    });
  });
}

Map<String, Object> _validArtifact() {
  final algorithmUid = _hex(_uidHex);
  final patchInfo = _hex(_patchHex);
  return <String, Object>{
    'schemaVersion': 1,
    'nativeCaptureSessionId': '1700000000000-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'processSessionId': '1700000000000000-bbbbbbbbbbbbbbbbbbbbbbbb',
    'captureSessionId': 'session-20300101T000000Z-SYNTHETIC',
    'versionCode': 1,
    'lastUpdateTime': 1700000000000,
    'targetUidSha256': _digestHex(algorithmUid),
    'iso15693ManufacturerPrefix': 'e007',
    'patchInfoSha256': _digestHex(patchInfo),
    'model': 'libre2',
    'securityGeneration': 'gen1',
    'algorithmOrderUidHex': _uidHex,
    'patchInfoHex': _patchHex,
    'encryptedFramHex': _encryptedFramHex,
    'observedAtUtc': '2030-01-01T00:00:00Z',
    'observedAtMonotonicElapsedNanos': 1000000000,
  };
}

Map<String, Object> _validExplicitArtifact() => _validArtifact()
  ..['schemaVersion'] = 2
  ..['sourceKind'] = 'explicitLibre2Lifecycle'
  ..['explicitAttemptId'] = 'synthetic-libre2-attempt';

File _writeArtifact(
  Directory directory,
  Map<String, Object> artifact, {
  String fileName = _fileName,
}) => _writeText(directory, jsonEncode(artifact), fileName: fileName);

File _writeText(
  Directory directory,
  String value, {
  String fileName = _fileName,
}) {
  final file = File('${directory.path}${Platform.pathSeparator}$fileName')
    ..writeAsStringSync(value);
  _makeOwnerPrivate(file);
  return file;
}

void _makeOwnerPrivate(File file) {
  _setMode(file, '0600');
  expect(file.statSync().mode & 0x1ff, 0x180);
}

void _setMode(File file, String mode) {
  final result = Process.runSync('chmod', <String>[mode, file.path]);
  expect(result.exitCode, 0);
}

String _duplicateSchemaVersionJson() {
  final source = jsonEncode(_validArtifact());
  return source.replaceFirst('{', '{"schemaVersion":1,');
}

String _escapedDuplicateSchemaVersionJson() {
  final source = jsonEncode(_validArtifact());
  return source.replaceFirst('{', '{"\\u0073chemaVersion":1,');
}

void _expectFailure((int, String) result, String error) {
  expect(result.$1, isNonZero);
  expect(jsonDecode(result.$2), <String, Object>{
    'validated': false,
    'error': error,
  });
  expect(LineSplitter.split(result.$2), hasLength(1));
}

void _expectRedacted(String output, Map<String, Object> artifact, String path) {
  for (final sensitive in <String>[
    artifact['nativeCaptureSessionId']! as String,
    artifact['processSessionId']! as String,
    artifact['captureSessionId']! as String,
    artifact['targetUidSha256']! as String,
    artifact['patchInfoSha256']! as String,
    artifact['algorithmOrderUidHex']! as String,
    artifact['patchInfoHex']! as String,
    artifact['encryptedFramHex']! as String,
    path,
  ]) {
    expect(output, isNot(contains(sensitive)));
  }
  expect(output.toLowerCase(), isNot(contains('glucose')));
}

List<int> _hex(String value) => <int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
];

String _encodeHex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _digestHex(List<int> value) => crypto.sha256.convert(value).toString();
