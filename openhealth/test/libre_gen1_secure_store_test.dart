import 'dart:async';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(LibreGen1SecureStore.channelName);
  late LibreGen1SecureStore store;
  late Future<Object?> Function(MethodCall) handler;

  setUp(() {
    store = LibreGen1SecureStore(channel: channel, supported: true);
    handler = (_) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => handler(call));
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('only confirmed native bootstrap becomes a driver input', () async {
    expect(await store.readBootstrap(), isNull);
    handler = (call) async {
      expect(call.method, 'readLibreGen1StreamingBootstrap');
      return _bootstrap();
    };
    final result = await store.readBootstrap();
    expect(result?.lifecycle, LibreGen1LifecycleState.warmingUp);
    expect(result?.initialPatchInfo.model, LibreGen1Model.libre2);
    expect(result.toString(), isNot(contains('02:00:00:00:00:01')));
    expect(result.toString(), isNot(contains('synthetic_bootstrap_1')));
  });

  test('rejects extra fields, invalid lifecycle and malformed bytes', () async {
    for (final invalid in <Map<String, Object?>>[
      {..._bootstrap(), 'rawPacket': 'unexpected'},
      {..._bootstrap(), 'lifecycle': 'notActivated'},
      {..._bootstrap(), 'lifecycle': 'expired'},
      {..._bootstrap(), 'lifecycle': 'shutdown'},
      {..._bootstrap(), 'lifecycle': 'failure'},
      {..._bootstrap(), 'lifecycle': 'unknown'},
      {
        ..._bootstrap(),
        'uid': <int>[1, 2],
      },
      {
        ..._bootstrap(),
        'uid': <int>[1, 2, 3, 4, 5, 6, 7, 256],
      },
      {
        ..._bootstrap(),
        'initialPatchInfo': <int>[1, 2, 3, 4, 5, 6],
      },
      {..._bootstrap(), 'streamingBase': 1.5},
      {..._bootstrap(), 'streamingBase': 0xffffffff},
      {..._bootstrap(), 'deviceId': 'not-a-device'},
      {..._bootstrap(), 'bootstrapId': 'short'},
    ]) {
      handler = (_) async => invalid;
      await expectLater(
        store.readBootstrap(),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.invalidBootstrap,
          ),
        ),
      );
    }
  });

  test(
    'fresh provider restores only native state without setup writes',
    () async {
      final calls = <String>[];
      handler = (call) async {
        calls.add(call.method);
        expect(call.arguments, isNull);
        return {..._bootstrap(), 'lifecycle': 'active'};
      };
      final beforeRestart = await store.readBootstrap();
      final restoredProvider = LibreGen1SecureStore(
        channel: channel,
        supported: true,
      );
      final restored = await restoredProvider.readBootstrap();
      expect(restored?.bootstrapId, beforeRestart?.bootstrapId);
      expect(restored?.deviceId, beforeRestart?.deviceId);
      expect(restored?.streamingBase, beforeRestart?.streamingBase);
      expect(restored?.lifecycle, LibreGen1LifecycleState.active);
      expect(calls, [
        'readLibreGen1StreamingBootstrap',
        'readLibreGen1StreamingBootstrap',
      ]);
    },
  );

  test(
    'reservation is not returned before native durable completion',
    () async {
      final durableCommit = Completer<Object?>();
      handler = (call) {
        expect(call.method, 'reserveLibreGen1UnlockCount');
        expect(call.arguments, {'bootstrapId': 'synthetic_bootstrap_1'});
        return durableCommit.future;
      };
      var completed = false;
      final reserved = store
          .reserveNextUnlockCount('synthetic_bootstrap_1')
          .then((value) {
            completed = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      durableCommit.complete(1);
      expect(await reserved, 1);
    },
  );

  test('invalid native counter and errors never yield a login count', () async {
    for (final value in <Object?>[null, 0, -1, 65536, 1.0, '1']) {
      handler = (_) async => value;
      await expectLater(
        store.reserveNextUnlockCount('synthetic_bootstrap_1'),
        throwsA(isA<LibreGen1LiveException>()),
      );
    }
    handler = (_) async => throw PlatformException(
      code: 'internal',
      message: 'private-value-sentinel',
    );
    try {
      await store.reserveNextUnlockCount('synthetic_bootstrap_1');
      fail('reservation must fail');
    } catch (error) {
      expect(error, isA<LibreGen1LiveException>());
      expect(error.toString(), isNot(contains('private-value-sentinel')));
    }
  });

  test(
    'outcome writes bind the exact bootstrap and reserved counter',
    () async {
      handler = (call) async {
        expect(call.method, 'markLibreGen1LoginOutcome');
        expect(call.arguments, {
          'bootstrapId': 'synthetic_bootstrap_1',
          'unlockCount': 2,
          'outcome': 'unknown',
        });
        return null;
      };
      await store.markLoginOutcome(
        'synthetic_bootstrap_1',
        2,
        LibreGen1LoginOutcome.unknown,
      );
    },
  );

  test('unsupported host cannot call a native method', () async {
    var calls = 0;
    handler = (_) async {
      calls++;
      return _bootstrap();
    };
    final unsupported = LibreGen1SecureStore(
      channel: channel,
      supported: false,
    );
    await expectLater(
      unsupported.readBootstrap(),
      throwsA(isA<LibreGen1LiveException>()),
    );
    expect(calls, 0);
  });

  test(
    'factory evidence is read-only, exact-bound, immutable and redacted',
    () async {
      handler = (_) async => _bootstrap();
      final bootstrap = (await store.readBootstrap())!;
      final calls = <String>[];
      final source = _calibration();
      handler = (call) async {
        calls.add(call.method);
        expect(call.arguments, {'bootstrapId': bootstrap.bootstrapId});
        return source;
      };
      final evidence = (await store.readCalibrationEvidence(bootstrap))!;
      expect(calls, ['readLibreGen1CalibrationEvidence']);
      expect(evidence.bootstrapId, bootstrap.bootstrapId);
      expect(evidence.uid, bootstrap.uid.value.bytes);
      expect(
        evidence.receiverInitialPatchInfo,
        bootstrap.initialPatchInfo.value.bytes,
      );
      expect(
        evidence.calibrationPatchInfo,
        bootstrap.initialPatchInfo.value.bytes,
      );
      expect(evidence.encryptedFram, hasLength(344));
      expect(evidence.toString(), 'LibreGen1CalibrationEvidence(<redacted>)');
      expect(() => evidence.uid[0] = 2, throwsUnsupportedError);
      expect(
        () => evidence.receiverInitialPatchInfo[0] = 2,
        throwsUnsupportedError,
      );
      expect(
        () => evidence.calibrationPatchInfo[0] = 2,
        throwsUnsupportedError,
      );
      expect(() => evidence.encryptedFram[0] = 2, throwsUnsupportedError);
      (source['encryptedFram']! as List<int>)[0] = 255;
      expect(evidence.encryptedFram.first, 0);
    },
  );

  test(
    'current NFC seed is separate from the frozen receiver credential',
    () async {
      handler = (_) async => _bootstrap();
      final bootstrap = (await store.readBootstrap())!;
      final currentPatch = [0x9d, 8, 0x30, 1, 0x78, 0x56];
      final source = {..._calibration(), 'calibrationPatchInfo': currentPatch};
      handler = (call) async {
        expect(call.method, 'readLibreGen1CalibrationEvidence');
        return source;
      };
      final evidence = (await store.readCalibrationEvidence(bootstrap))!;
      expect(evidence.calibrationPatchInfo, currentPatch);
      expect(
        evidence.receiverInitialPatchInfo,
        bootstrap.initialPatchInfo.value.bytes,
      );
      currentPatch[4] = 0;
      expect(evidence.calibrationPatchInfo[4], 0x78);
      expect(bootstrap.initialPatchInfo.value.bytes, [0x9d, 8, 0x30, 1, 0, 0]);
    },
  );

  test(
    'absent factory evidence does not start NFC or reserve counters',
    () async {
      handler = (_) async => _bootstrap();
      final bootstrap = (await store.readBootstrap())!;
      var calls = 0;
      handler = (call) async {
        expect(call.method, 'readLibreGen1CalibrationEvidence');
        calls++;
        return null;
      };
      expect(await store.readCalibrationEvidence(bootstrap), isNull);
      expect(calls, 1);
    },
  );

  test(
    'rejects stale bindings, unknown fields, invalid lengths and bytes',
    () async {
      handler = (_) async => _bootstrap();
      final bootstrap = (await store.readBootstrap())!;
      for (final invalid in <Object?>[
        'private-value-sentinel',
        {..._calibration(), 'bootstrapId': 'different_bootstrap_2'},
        {..._calibration(), 'rawPacket': 'private-value-sentinel'},
        {..._calibration(), 'lifecycle': 'active'},
        {..._calibration()}..remove('uid'),
        {
          ..._calibration(),
          'uid': <int>[2, 2, 3, 4, 5, 6, 7, 0xe0],
        },
        {
          ..._calibration(),
          'receiverInitialPatchInfo': <int>[0x9d, 8, 0x30, 1, 0, 1],
        },
        {
          ..._calibration(),
          'calibrationPatchInfo': <int>[0x9d, 8, 0x30, 2, 0, 0],
        },
        {
          ..._calibration(),
          'calibrationPatchInfo': <int>[0x9d, 8, 0x31, 1, 0, 0],
        },
        {
          ..._calibration(),
          'calibrationPatchInfo': <int>[0x9d, 8, 0x30, 1, 0],
        },
        {
          ..._calibration(),
          'calibrationPatchInfo': <int>[0x9d, 8, 0x30, 1, 0, 256],
        },
        {..._calibration()}..remove('receiverInitialPatchInfo'),
        {..._calibration()}..remove('calibrationPatchInfo'),
        {
          ..._calibration(),
          'initialPatchInfo': _bootstrap()['initialPatchInfo'],
        },
        {..._calibration(), 'encryptedFram': List<int>.filled(343, 0)},
        {..._calibration(), 'encryptedFram': List<int>.filled(345, 0)},
        {..._calibration(), 'encryptedFram': List<int>.filled(344, -1)},
        {..._calibration(), 'encryptedFram': List<int>.filled(344, 256)},
        {..._calibration(), 'encryptedFram': List<double>.filled(344, 0)},
      ]) {
        handler = (_) async => invalid;
        await expectLater(
          store.readCalibrationEvidence(bootstrap),
          throwsA(
            isA<LibreGen1LiveException>().having(
              (error) => error.toString(),
              'closed error',
              isNot(contains('private-value-sentinel')),
            ),
          ),
        );
      }
    },
  );

  test(
    'native evidence errors and unsupported hosts expose no private cause',
    () async {
      handler = (_) async => _bootstrap();
      final bootstrap = (await store.readBootstrap())!;
      handler = (_) async =>
          throw PlatformException(code: 'private-value-sentinel');
      await expectLater(
        store.readCalibrationEvidence(bootstrap),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (error) => error.toString(),
            'closed error',
            isNot(contains('private-value-sentinel')),
          ),
        ),
      );
      var calls = 0;
      handler = (_) async {
        calls++;
        return _calibration();
      };
      final unsupported = LibreGen1SecureStore(
        channel: channel,
        supported: false,
      );
      await expectLater(
        unsupported.readCalibrationEvidence(bootstrap),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(calls, 0);
    },
  );

  testWidgets('hung evidence read has a closed deadline and no retry', (
    tester,
  ) async {
    handler = (_) async => _bootstrap();
    final bootstrap = (await store.readBootstrap())!;
    var calls = 0;
    final stuck = Completer<Object?>();
    handler = (_) {
      calls++;
      return stuck.future;
    };
    final completion = expectLater(
      store.readCalibrationEvidence(bootstrap),
      throwsA(isA<LibreGen1LiveException>()),
    );
    await tester.pump(const Duration(seconds: 16));
    await completion;
    expect(calls, 1);
    stuck.complete(_calibration());
    await tester.pump();
    expect(calls, 1);
  });
}

Map<String, Object?> _bootstrap() => {
  'bootstrapId': 'synthetic_bootstrap_1',
  'deviceId': '02:00:00:00:00:01',
  'uid': Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 0xe0]),
  'initialPatchInfo': Uint8List.fromList([0x9d, 0x08, 0x30, 1, 0, 0]),
  'streamingBase': 100,
  'lifecycle': 'warmingUp',
};

// Synthetic channel data only. Native CRC validation has its own JVM tests;
// the app adapter checks the closed envelope before the decoder revalidates it.
Map<String, Object?> _calibration() => {
  'bootstrapId': _bootstrap()['bootstrapId'],
  'uid': _bootstrap()['uid'],
  'receiverInitialPatchInfo': _bootstrap()['initialPatchInfo'],
  'calibrationPatchInfo': _bootstrap()['initialPatchInfo'],
  'encryptedFram': List<int>.filled(344, 0),
};
