import 'dart:async';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';
import 'package:openglucose/src/libre_gen1_fresh_nfc_history.dart';
import 'package:openglucose/src/libre_gen1_receiver_history_platform.dart';
import 'package:openglucose/src/libre_nfc_history_sync.dart';

const _capabilities = <String, Object?>{
  'schemaVersion': 1,
  'backend': 'receiverHistory',
  'readAvailable': true,
  'activationAvailable': false,
  'streamingAvailable': false,
  'receiverAvailable': false,
  'rawCapture': false,
};
const _uid = [1, 2, 3, 4, 5, 6, 7, 0xe0];
const _patch = [0x9d, 8, 0x30, 1, 0x34, 0x12];
final _bootstrap = LibreGen1StreamingBootstrap(
  bootstrapId: 'synthetic_saved_receiver',
  deviceId: '02:00:00:00:00:01',
  uid: LibreGen1Uid.algorithmOrder(_uid),
  initialPatchInfo: LibreGen1PatchInfo(_patch),
  streamingBase: 0,
  lifecycle: LibreGen1LifecycleState.active,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synthetic/receiver-history');
  const capture = MethodChannel('com.openglucose/protocol_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Harness h;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    h = _Harness(channel);
    messenger.setMockMethodCallHandler(channel, h.call);
    messenger.setMockMethodCallHandler(capture, (_) async {
      fail('Receiver history must never use capture.');
    });
  });
  tearDown(() async {
    await h.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(capture, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'construction, reader and bound session creation perform no I/O',
    () async {
      h.platform.createFreshReader();
      h.createSession();
      expect(h.calls, isEmpty);
      await h.session!.dispose();
      expect(h.calls, isEmpty);
      expect(await h.platform.readAvailable(), isFalse);
    },
  );

  for (final entry in <String, Object?>{
    'schemaVersion': 2,
    'backend': 'readOnly',
    'readAvailable': false,
    'activationAvailable': true,
    'streamingAvailable': true,
    'receiverAvailable': true,
    'rawCapture': true,
    'extra': 'unknown',
  }.entries) {
    test('capability ${entry.key} mismatch fails closed', () async {
      h.capabilities = {..._capabilities, entry.key: entry.value};
      expect(await h.platform.readAvailable(), isFalse);
      await h.createSession().start();
      expect(
        h.calls.every((call) => call.method == 'historyCapabilities'),
        isTrue,
      );
    });
  }
  test('missing, mistyped and partial capabilities fail closed', () async {
    for (final value in <Object?>[
      null,
      <String, Object?>{},
      {..._capabilities, 'schemaVersion': 1.0},
      {..._capabilities, 'readAvailable': 'true'},
      Map<String, Object?>.of(_capabilities)..remove('rawCapture'),
    ]) {
      h.capabilities = value;
      expect(await h.platform.readAvailable(), isFalse);
    }
    h.capabilities = _capabilities;
    expect(await h.platform.readAvailable(), isTrue);
    expect(h.calls.every((call) => (call.arguments as Map).isEmpty), isTrue);
  });

  test(
    'default non-Android and explicit unsupported routes make no native calls',
    () async {
      for (final target in [
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = target;
        final platform = LibreGen1ReceiverHistoryPlatform(channel: channel);
        expect(await platform.readAvailable(), isFalse);
        final session = platform.createReadSession(_bootstrap);
        await session.start();
        await session.dispose();
      }
      expect(h.calls, isEmpty);
    },
  );

  test('capability timeout cannot later start NFC', () async {
    h.replacePlatform(capability: const Duration(milliseconds: 5));
    h.capabilityGate = Completer<Object?>();
    final session = h.createSession();
    await session.start();
    h.capabilityGate!.complete(_capabilities);
    await _turn();
    expect(h.calls.map((call) => call.method), ['historyCapabilities']);
  });

  test('stop during capability lookup blocks a late native start', () async {
    h.capabilityGate = Completer<Object?>();
    final session = h.createSession();
    final start = session.start();
    await _until(() => h.calls.isNotEmpty);
    await session.stop();
    h.capabilityGate!.complete(_capabilities);
    await start;
    expect(h.calls.map((call) => call.method), ['historyCapabilities']);
  });

  test(
    'platform disposal cancels pending probes without waiting for native',
    () async {
      h.capabilityGate = Completer<Object?>();
      final lookup = h.platform.readAvailable();
      await _turn();
      h.platform.dispose();
      expect(await lookup, isFalse);
      h.capabilityGate!.complete(_capabilities);
      await _turn();
      expect(await h.platform.readAvailable(), isFalse);
      expect(h.platform.createFreshReader, throwsStateError);
    },
  );

  test(
    'bound start and stop translate exact two-field arguments only',
    () async {
      final session = h.createSession();
      await session.start();
      expect(h.attempt, isNotNull);
      await session.stop();
      expect(h.calls.map((call) => call.method), [
        'historyCapabilities',
        'startLibreGen1HistoryRead',
        'stopLibreGen1HistoryRead',
      ]);
      for (final call in h.calls.skip(1)) {
        expect(call.arguments, {
          'attemptId': h.attempt,
          'bootstrapId': _bootstrap.bootstrapId,
        });
      }
      await session.dispose();
      expect(h.calls.last.method, 'discardLibreGen1FreshHistoryEvidence');
    },
  );

  test('one platform cannot create another receiver-bound session', () {
    h.createSession();
    expect(() => h.platform.createReadSession(_bootstrap), throwsStateError);
  });

  test('missing bridge or failed capability has no capture fallback', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await h.platform.readAvailable(), isFalse);
    await h.createSession().start();
    expect(h.calls, isEmpty);
  });

  test(
    'completed read handoff is exact and cannot accept activation proof',
    () async {
      final session = h.createSession();
      final states = <Libre2NfcSetupState>[];
      final listener = session.states.listen(states.add);
      await session.start();
      h.metadata();
      h.events.add({
        'attemptId': h.attempt,
        'event': 'activationVerified',
        'model': 'libre2',
        'status': 'warmingUp',
      });
      await _turn();
      expect(states.last.sensorStatus, Libre2SensorStatus.active);
      expect(states.last.isActivationVerified, isFalse);
      expect(
        (session as Libre2NfcCompletedReadAttemptProvider)
            .completedReadAttemptId,
        h.attempt,
      );
      expect(
        h.calls.where((call) => call.method.contains('Activation')),
        isEmpty,
      );
      await listener.cancel();
    },
  );

  test('terminal native revocation invalidates completed handoff', () async {
    final session = h.createSession();
    await session.start();
    h.metadata();
    h.events.add({
      'attemptId': h.attempt,
      'event': 'failed',
      'reason': 'readFailed',
    });
    expect(
      (session as Libre2NfcCompletedReadAttemptProvider).completedReadAttemptId,
      isNull,
    );
  });

  test(
    'fresh evidence read is one-use, bound, and only after native stop',
    () async {
      final reader = h.platform.createFreshReader();
      final decoder = _Decoder();
      final session = h.createSession();
      await session.start();
      h.metadata();
      await expectLater(
        reader.readDecoded(
          bootstrap: _bootstrap,
          attemptId: h.attempt!,
          decoder: decoder,
        ),
        throwsA(isA<LibreGen1FreshNfcHistoryException>()),
      );
      expect(h.evidenceCalls, 0);
      await session.stop();
      final result = await reader.readDecoded(
        bootstrap: _bootstrap,
        attemptId: h.attempt!,
        decoder: decoder,
      );
      expect(result.samples, isEmpty);
      expect(h.evidenceCalls, 1);
      expect(decoder.calls, 1);
      await expectLater(
        reader.readDecoded(
          bootstrap: _bootstrap,
          attemptId: h.attempt!,
          decoder: decoder,
        ),
        throwsA(isA<LibreGen1FreshNfcHistoryException>()),
      );
      expect(h.evidenceCalls, 1);
    },
  );

  test(
    'wrong returned exact binding rejects fresh evidence before decoding',
    () async {
      final reader = h.platform.createFreshReader();
      final decoder = _Decoder();
      final session = h.createSession();
      await session.start();
      h.metadata();
      await session.stop();
      h.wrongEvidence = true;
      await expectLater(
        reader.readDecoded(
          bootstrap: _bootstrap,
          attemptId: h.attempt!,
          decoder: decoder,
        ),
        throwsA(isA<LibreGen1FreshNfcHistoryException>()),
      );
      expect(decoder.calls, 0);
    },
  );

  test(
    'explicit evidence revocation discards but never substitutes for stop',
    () async {
      final reader = h.platform.createFreshReader();
      final session = h.createSession();
      await session.start();
      h.metadata();
      await (session as LibreNfcHistoryEvidenceRevoker).revokeHistoryEvidence();
      expect(h.calls.last.method, 'discardLibreGen1FreshHistoryEvidence');
      expect(
        h.calls.where((call) => call.method == 'stopLibreGen1HistoryRead'),
        isEmpty,
      );
      expect(
        (session as Libre2NfcCompletedReadAttemptProvider)
            .completedReadAttemptId,
        isNull,
      );
      await session.stop();
      await expectLater(
        reader.readDecoded(
          bootstrap: _bootstrap,
          attemptId: h.attempt!,
          decoder: _Decoder(),
        ),
        throwsA(isA<LibreGen1FreshNfcHistoryException>()),
      );
    },
  );

  test(
    'capability loss or platform disposal cannot skip dispatched cleanup',
    () async {
      final session = h.createSession();
      await session.start();
      h.capabilities = null;
      h.platform.dispose();
      await session.dispose();
      expect(
        h.calls.map((call) => call.method),
        containsAll([
          'stopLibreGen1HistoryRead',
          'discardLibreGen1FreshHistoryEvidence',
        ]),
      );
      expect(
        h.calls.where((call) => call.method == 'historyCapabilities').length,
        1,
      );
    },
  );

  test(
    'stop before delayed start reply requires another stop after settlement',
    () async {
      h.startGate = Completer<Object?>();
      final session = h.createSession();
      final start = session.start();
      await _until(() => h.attempt != null);
      final stopping = session.stop();
      var stopped = false;
      unawaited(stopping.then<void>((_) => stopped = true));
      await _until(() => h.stopCalls == 1);
      expect(stopped, isFalse);
      h.startGate!.complete(null);
      await start;
      await stopping;
      expect(h.stopCalls, 2);
    },
  );

  test(
    'start timeout retains uncertainty and late success is stopped and discarded',
    () async {
      h.replacePlatform(method: const Duration(milliseconds: 10));
      h.startGate = Completer<Object?>();
      final session = h.createSession();
      final start = session.start();
      final settled = start.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await _until(() => h.attempt != null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = h.stopCalls;
      h.startGate!.complete(null);
      await settled;
      await _until(() => h.stopCalls > before && h.discardCalls > 0);
      await expectLater(session.dispose(), throwsStateError);
    },
  );

  for (final method in [
    'startLibreGen1HistoryRead',
    'stopLibreGen1HistoryRead',
    'discardLibreGen1FreshHistoryEvidence',
  ]) {
    test('nonnull $method reply cannot claim successful cleanup', () async {
      final session = h.createSession();
      h.nonNullMethod = method;
      await session.start();
      if (method == 'startLibreGen1HistoryRead') {
        expect(h.stopCalls, greaterThanOrEqualTo(1));
      } else {
        await expectLater(session.dispose(), throwsStateError);
      }
    });
  }

  test(
    'dispose awaits both native stop and discard acknowledgements',
    () async {
      final session = h.createSession();
      await session.start();
      h.stopGate = Completer<Object?>();
      h.discardGate = Completer<Object?>();
      var finished = false;
      final disposal = session.dispose().then<void>((_) => finished = true);
      await _until(() => h.stopCalls == 1 && h.discardCalls == 1);
      h.stopGate!.complete(null);
      await _turn();
      expect(finished, isFalse);
      h.discardGate!.complete(null);
      await disposal;
      expect(await h.platform.readAvailable(), isFalse);
    },
  );

  test('pending evidence delivery is revoked by platform disposal', () async {
    final reader = h.platform.createFreshReader();
    final decoder = _Decoder();
    final session = h.createSession();
    await session.start();
    h.metadata();
    await session.stop();
    h.evidenceGate = Completer<Object?>();
    final read = reader.readDecoded(
      bootstrap: _bootstrap,
      attemptId: h.attempt!,
      decoder: decoder,
    );
    final rejected = expectLater(
      read,
      throwsA(isA<LibreGen1FreshNfcHistoryException>()),
    );
    await _until(() => h.evidenceCalls == 1);
    h.platform.dispose();
    h.evidenceGate!.complete(h.evidence());
    await rejected;
    expect(decoder.calls, 0);
  });
}

final class _Harness {
  _Harness(this.channel) {
    replacePlatform();
  }
  final MethodChannel channel;
  final events = StreamController<Object?>.broadcast(sync: true);
  final calls = <MethodCall>[];
  Object? capabilities = _capabilities;
  late LibreGen1ReceiverHistoryPlatform platform;
  Libre2NfcSetupSession? session;
  String? attempt;
  String? nonNullMethod;
  bool wrongEvidence = false;
  Completer<Object?>? capabilityGate;
  Completer<Object?>? startGate;
  Completer<Object?>? stopGate;
  Completer<Object?>? discardGate;
  Completer<Object?>? evidenceGate;
  int get stopCalls =>
      calls.where((call) => call.method == 'stopLibreGen1HistoryRead').length;
  int get discardCalls => calls
      .where((call) => call.method == 'discardLibreGen1FreshHistoryEvidence')
      .length;
  int get evidenceCalls => calls
      .where((call) => call.method == LibreGen1FreshNfcHistoryReader.methodName)
      .length;
  void replacePlatform({
    Duration capability = const Duration(seconds: 3),
    Duration method = const Duration(seconds: 2),
  }) {
    platform = LibreGen1ReceiverHistoryPlatform(
      channel: channel,
      events: events.stream,
      supported: true,
      capabilityTimeout: capability,
      methodTimeout: method,
    );
  }

  Libre2NfcSetupSession createSession() =>
      session = platform.createReadSession(_bootstrap);
  Future<Object?> call(MethodCall call) async {
    calls.add(call);
    if (call.method == 'historyCapabilities') {
      return capabilityGate?.future ?? capabilities;
    }
    final args = call.arguments as Map;
    expect(args.length, 2);
    expect(args['bootstrapId'], _bootstrap.bootstrapId);
    attempt ??= args['attemptId'] as String;
    expect(args['attemptId'], attempt);
    if (call.method == nonNullMethod) return false;
    return switch (call.method) {
      'startLibreGen1HistoryRead' => startGate?.future,
      'stopLibreGen1HistoryRead' => stopGate?.future,
      'discardLibreGen1FreshHistoryEvidence' => discardGate?.future,
      LibreGen1FreshNfcHistoryReader.methodName =>
        evidenceGate?.future ?? evidence(),
      _ => throw StateError('Unexpected synthetic method.'),
    };
  }

  void metadata() => events.add({
    'attemptId': attempt,
    'event': 'metadataRead',
    'model': 'libre2',
    'status': 'active',
  });
  Map<String, Object?> evidence() => {
    'attemptId': attempt,
    'bootstrapId': wrongEvidence
        ? 'synthetic_wrong_receiver'
        : _bootstrap.bootstrapId,
    'uid': List<int>.of(_uid),
    'receiverInitialPatchInfo': List<int>.of(_patch),
    'currentPatchInfo': [..._patch.take(4), 0x78, 0x56],
    'encryptedFram': List<int>.filled(344, 42),
    'observedAtUtc': DateTime.utc(2026, 1, 2).toIso8601String(),
  };
  Future<void> dispose() async {
    for (final gate in [
      capabilityGate,
      startGate,
      stopGate,
      discardGate,
      evidenceGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete(null);
    }
    try {
      await session?.dispose();
    } catch (_) {
      /* Expected failure cases. */
    }
    platform.dispose();
    await events.close();
  }
}

final class _Decoder implements LibreGen1NfcHistoryDecoder {
  int calls = 0;
  @override
  LibreGen1DecodedNfcHistory decodeFreshNfc(
    LibreGen1FreshNfcEvidence evidence,
  ) {
    calls++;
    return LibreGen1DecodedNfcHistory(
      scanMinute: 120,
      receivedAt: evidence.observedAtUtc,
      samples: const [],
    );
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await _turn();
  }
  expect(ready(), isTrue);
}
