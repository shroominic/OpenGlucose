import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/yuwell_secure_session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(YuwellSecureSessionStore.channelName);
  late _FakeNativeYuwellStore nativeStore;
  late YuwellSecureSessionStore store;

  setUp(() {
    nativeStore = _FakeNativeYuwellStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, nativeStore.handle);
    store = YuwellSecureSessionStore.testing(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  YuwellSessionCredentials credentials() => YuwellSessionCredentials(
    communicationIdentity: YuwellCommunicationIdentity.parse('123456789012'),
    cipher: 0x42,
    k: 1.23,
    r: 4.5,
    transmitterComputed: true,
    phase: YuwellCredentialPhase.active,
    activationStartedAt: DateTime.utc(2026, 9, 2, 3, 4, 5),
  );

  YuwellSessionCredentials credentialsV2() => credentials().copyWith(
    verifiedFirmware: 'V1150',
    historyGeneration: 'b' * 32,
  );

  test('credentials round-trip through the native channel', () async {
    await store.write('private-sensor-identity', credentials());
    final restored = await store.read('private-sensor-identity');

    expect(restored, isNotNull);
    expect(restored!.cipher, 0x42);
    expect(restored.k, 1.23);
    expect(restored.r, 4.5);
    expect(restored.phase, YuwellCredentialPhase.active);
    expect(
      restored.communicationIdentity.serializeForSecureStorage(),
      '123456789012',
    );
    expect(nativeStore.persistedAliases, hasLength(1));
    expect(
      nativeStore.persistedAliases.single,
      isNot(contains('private-sensor-identity')),
    );
  });

  test('v2 history identity round-trips through the native channel', () async {
    await store.write('private-v2-identity', credentialsV2());

    final restored = await store.read('private-v2-identity');

    expect(restored, isNotNull);
    expect(restored!.verifiedFirmware, 'V1150');
    expect(restored.historyGeneration, 'b' * 32);
    expect(restored.canRestoreHistory, isTrue);
  });

  test('credential deletion does not affect another alias', () async {
    await store.write('first', credentials());
    await store.write('second', credentials());

    await store.delete('first');

    expect(await store.read('first'), isNull);
    expect(await store.read('second'), isNotNull);
  });

  test('write journal remains unresolved until confirmed completion', () async {
    final token = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.initialize,
    );

    expect(
      token,
      matches(r'^ct5\.intent\.v2\.[0-9a-f]{64}\.[0-9a-f]{64}$'),
    );
    expect(await store.hasUnresolved('sensor-key'), isTrue);
    final unresolved = await store.readUnresolved('sensor-key');
    expect(unresolved, isNotNull);
    expect(unresolved!.token, token);
    expect(unresolved.operation, YuwellActivationWrite.initialize);
    expect(unresolved.state, YuwellWriteIntentState.prepared);
    await store.markTransmitted(token);
    expect(await store.hasUnresolved('sensor-key'), isTrue);
    await store.markCompleted(token);
    expect(await store.hasUnresolved('sensor-key'), isFalse);
  });

  test('unknown outcome is durable and blocks another prepare', () async {
    final token = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.setCommunicationId,
    );
    await store.markUnknown(token);
    await store.markUnknown(token);

    expect(await store.hasUnresolved('sensor-key'), isTrue);
    await expectLater(
      store.prepare(
        'sensor-key',
        YuwellActivationWrite.setCommunicationId,
      ),
      throwsStateError,
    );
    await expectLater(store.markTransmitted(token), throwsStateError);
    final unresolved = await store.readUnresolved('sensor-key');
    expect(unresolved!.state, YuwellWriteIntentState.unknown);
    await expectLater(store.markCompleted(token), throwsStateError);
    await store.resolveRecovered(
      token,
      expectedOperation: unresolved.operation,
      expectedState: unresolved.state,
    );
    expect(await store.hasUnresolved('sensor-key'), isFalse);
  });

  test('prepared cancellation cannot clear a transmitted write', () async {
    final prepared = await store.prepare(
      'prepared-key',
      YuwellActivationWrite.setDate,
    );
    await store.cancelPrepared(prepared);
    expect(await store.hasUnresolved('prepared-key'), isFalse);

    final transmitted = await store.prepare(
      'transmitted-key',
      YuwellActivationWrite.configure,
    );
    await store.markTransmitted(transmitted);
    await expectLater(store.cancelPrepared(transmitted), throwsStateError);
    expect(await store.hasUnresolved('transmitted-key'), isTrue);
  });

  test('a stale token cannot mutate a newer journal generation', () async {
    final oldToken = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.setDate,
    );
    await store.markTransmitted(oldToken);
    await store.markCompleted(oldToken);

    final currentToken = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.initialize,
    );
    await store.markTransmitted(currentToken);

    expect(currentToken, isNot(oldToken));
    await expectLater(store.markCompleted(oldToken), throwsStateError);
    expect(await store.hasUnresolved('sensor-key'), isTrue);
    await store.markCompleted(currentToken);
  });

  test(
    'a stale prepared snapshot cannot resolve a transitioned intent',
    () async {
      final token = await store.prepare(
        'sensor-key',
        YuwellActivationWrite.setDate,
      );
      final prepared = (await store.readUnresolved('sensor-key'))!;

      await store.markTransmitted(token);
      await expectLater(
        store.resolveRecovered(
          token,
          expectedOperation: prepared.operation,
          expectedState: prepared.state,
        ),
        throwsStateError,
      );
      await expectLater(
        store.resolveRecovered(
          token,
          expectedOperation: YuwellActivationWrite.configure,
          expectedState: YuwellWriteIntentState.transmitted,
        ),
        throwsStateError,
      );
      expect(
        (await store.readUnresolved('sensor-key'))!.state,
        YuwellWriteIntentState.transmitted,
      );

      await store.markUnknown(token);
      await expectLater(
        store.resolveRecovered(
          token,
          expectedOperation: prepared.operation,
          expectedState: prepared.state,
        ),
        throwsStateError,
      );
      expect(
        (await store.readUnresolved('sensor-key'))!.state,
        YuwellWriteIntentState.unknown,
      );
    },
  );

  test('recovered set-ID replacement is atomic and scoped', () async {
    final oldToken = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.setCommunicationId,
    );
    await store.markUnknown(oldToken);
    final recovered = (await store.readUnresolved('sensor-key'))!;

    await expectLater(
      store.replaceRecoveredWithPrepared(
        oldToken,
        'another-key',
        YuwellActivationWrite.setCommunicationId,
        expectedOperation: recovered.operation,
        expectedState: recovered.state,
      ),
      throwsStateError,
    );
    await expectLater(
      store.replaceRecoveredWithPrepared(
        oldToken,
        'sensor-key',
        YuwellActivationWrite.configure,
        expectedOperation: recovered.operation,
        expectedState: recovered.state,
      ),
      throwsStateError,
    );

    nativeStore.failReplacementCommit = true;
    await expectLater(
      store.replaceRecoveredWithPrepared(
        oldToken,
        'sensor-key',
        YuwellActivationWrite.setCommunicationId,
        expectedOperation: recovered.operation,
        expectedState: recovered.state,
      ),
      throwsStateError,
    );
    expect((await store.readUnresolved('sensor-key'))!.token, oldToken);

    final replacement = await store.replaceRecoveredWithPrepared(
      oldToken,
      'sensor-key',
      YuwellActivationWrite.setCommunicationId,
      expectedOperation: recovered.operation,
      expectedState: recovered.state,
    );
    expect(replacement, isNot(oldToken));
    final current = await store.readUnresolved('sensor-key');
    expect(current, isNotNull);
    expect(current!.token, replacement);
    expect(current.operation, YuwellActivationWrite.setCommunicationId);
    expect(current.state, YuwellWriteIntentState.prepared);
    await expectLater(
      store.replaceRecoveredWithPrepared(
        oldToken,
        'sensor-key',
        YuwellActivationWrite.setCommunicationId,
        expectedOperation: recovered.operation,
        expectedState: recovered.state,
      ),
      throwsStateError,
    );
    expect((await store.readUnresolved('sensor-key'))!.token, replacement);
  });

  test('corrupt recovered state blocks atomic replacement', () async {
    final token = await store.prepare(
      'sensor-key',
      YuwellActivationWrite.setCommunicationId,
    );
    final recovered = (await store.readUnresolved('sensor-key'))!;
    nativeStore.corruptIntentState('sensor-key');

    await expectLater(
      store.replaceRecoveredWithPrepared(
        token,
        'sensor-key',
        YuwellActivationWrite.setCommunicationId,
        expectedOperation: recovered.operation,
        expectedState: recovered.state,
      ),
      throwsStateError,
    );
    expect(await store.hasUnresolved('sensor-key'), isTrue);
  });

  test(
    'a stale prepared snapshot cannot replace a transitioned intent',
    () async {
      final token = await store.prepare(
        'sensor-key',
        YuwellActivationWrite.setCommunicationId,
      );
      final prepared = (await store.readUnresolved('sensor-key'))!;

      await store.markTransmitted(token);
      await expectLater(
        store.replaceRecoveredWithPrepared(
          token,
          'sensor-key',
          YuwellActivationWrite.setCommunicationId,
          expectedOperation: prepared.operation,
          expectedState: prepared.state,
        ),
        throwsStateError,
      );
      await expectLater(
        store.replaceRecoveredWithPrepared(
          token,
          'sensor-key',
          YuwellActivationWrite.setCommunicationId,
          expectedOperation: YuwellActivationWrite.configure,
          expectedState: YuwellWriteIntentState.transmitted,
        ),
        throwsStateError,
      );
      expect(
        (await store.readUnresolved('sensor-key'))!.state,
        YuwellWriteIntentState.transmitted,
      );

      await store.markUnknown(token);
      await expectLater(
        store.replaceRecoveredWithPrepared(
          token,
          'sensor-key',
          YuwellActivationWrite.setCommunicationId,
          expectedOperation: prepared.operation,
          expectedState: prepared.state,
        ),
        throwsStateError,
      );
      expect(
        (await store.readUnresolved('sensor-key'))!.state,
        YuwellWriteIntentState.unknown,
      );
    },
  );

  test('concurrent prepares admit only one generation', () async {
    final attempts = <Future<Object>>[
      store
          .prepare('sensor-key', YuwellActivationWrite.configure)
          .then<Object>((value) => value)
          .catchError((Object error) => error),
      store
          .prepare('sensor-key', YuwellActivationWrite.initialize)
          .then<Object>((value) => value)
          .catchError((Object error) => error),
    ];

    final outcomes = await Future.wait(attempts);

    expect(outcomes.whereType<String>(), hasLength(1));
    expect(outcomes.whereType<StateError>(), hasLength(1));
    expect(await store.hasUnresolved('sensor-key'), isTrue);
  });

  test('malformed credential fails closed without deletion', () async {
    await store.write('sensor-key', credentials());
    nativeStore.corruptCredential('sensor-key');

    await expectLater(
      store.read('sensor-key'),
      throwsA(isA<YuwellProtocolFormatException>()),
    );
    expect(nativeStore.hasCredential('sensor-key'), isTrue);
  });

  test('native error details are not propagated', () async {
    const privateValue = 'private-sensor-identity';
    nativeStore.failNext = PlatformException(
      code: 'secure_store_failed',
      message: 'private-sensor-identity',
      details: '123456789012',
    );

    Object? observed;
    try {
      await store.read(privateValue);
    } on Object catch (error) {
      observed = error;
    }

    expect(observed, isA<StateError>());
    expect(observed.toString(), isNot(contains(privateValue)));
    expect(observed.toString(), isNot(contains('123456789012')));
  });

  test(
    'unsupported platforms fail closed without invoking a channel',
    () async {
      final unsupported = YuwellSecureSessionStore.testing(
        channel: channel,
        supported: false,
      );

      await expectLater(
        unsupported.prepare('sensor-key', YuwellActivationWrite.initialize),
        throwsUnsupportedError,
      );
      expect(nativeStore.callCount, 0);
    },
  );

  test('a missing Android bridge fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    await expectLater(store.hasUnresolved('sensor-key'), throwsStateError);
  });
}

final class _FakeNativeYuwellStore {
  final Map<String, String> _aliases = <String, String>{};
  final Map<String, String> _credentials = <String, String>{};
  final Map<String, _FakeIntent> _intents = <String, _FakeIntent>{};
  var _nextAlias = 0;
  var _nextNonce = 0;
  int callCount = 0;
  PlatformException? failNext;
  bool failReplacementCommit = false;

  Iterable<String> get persistedAliases => <String>{
    ..._credentials.keys,
    ..._intents.keys,
  };

  Future<Object?> handle(MethodCall call) async {
    callCount += 1;
    final failure = failNext;
    failNext = null;
    if (failure != null) {
      throw failure;
    }
    final arguments = Map<String, Object?>.from(
      call.arguments! as Map<Object?, Object?>,
    );
    switch (call.method) {
      case 'readCredential':
        return _credentials[_alias(arguments['storageKey']! as String)];
      case 'writeCredential':
        _credentials[_alias(arguments['storageKey']! as String)] =
            arguments['credential']! as String;
        return null;
      case 'deleteCredential':
        _credentials.remove(_alias(arguments['storageKey']! as String));
        return null;
      case 'hasUnresolved':
        return _intents.containsKey(
          _alias(arguments['storageKey']! as String),
        );
      case 'readUnresolved':
        final alias = _alias(arguments['storageKey']! as String);
        final intent = _intents[alias];
        if (intent == null) {
          return null;
        }
        return <String, Object>{
          'token': 'ct5.intent.v2.$alias.${intent.nonce}',
          'operation': intent.operation,
          'state': intent.state,
        };
      case 'prepare':
        final alias = _alias(arguments['storageKey']! as String);
        if (_intents.containsKey(alias)) {
          throw _conflict();
        }
        final nonce = (++_nextNonce).toRadixString(16).padLeft(64, '0');
        _intents[alias] = _FakeIntent(
          operation: arguments['operation']! as String,
          state: 'prepared',
          nonce: nonce,
        );
        return 'ct5.intent.v2.$alias.$nonce';
      case 'markTransmitted':
        _transition(arguments['token']! as String, <String>{
          'prepared',
        }, 'transmitted');
        return null;
      case 'markCompleted':
        final parts = _token(arguments['token']! as String);
        final intent = _matchingIntent(parts);
        if (intent.state != 'transmitted') {
          throw _conflict();
        }
        _intents.remove(parts.alias);
        return null;
      case 'markUnknown':
        _transition(
          arguments['token']! as String,
          <String>{'prepared', 'transmitted', 'unknown'},
          'unknown',
        );
        return null;
      case 'cancelPrepared':
        final parts = _token(arguments['token']! as String);
        final intent = _matchingIntent(parts);
        if (intent.state != 'prepared') {
          throw _conflict();
        }
        _intents.remove(parts.alias);
        return null;
      case 'resolveRecovered':
        final parts = _token(arguments['token']! as String);
        final intent = _matchingIntent(parts);
        if (intent.operation != arguments['expectedOperation'] ||
            intent.state != arguments['expectedState']) {
          throw _conflict();
        }
        _intents.remove(parts.alias);
        return null;
      case 'replaceRecoveredWithPrepared':
        final parts = _token(arguments['token']! as String);
        final alias = _alias(arguments['storageKey']! as String);
        if (parts.alias != alias) {
          throw _conflict();
        }
        final intent = _matchingIntent(parts);
        if (intent.operation != 'setCommunicationId' ||
            arguments['operation'] != 'setCommunicationId' ||
            intent.operation != arguments['expectedOperation'] ||
            intent.state != arguments['expectedState']) {
          throw _conflict();
        }
        if (!<String>{
          'prepared',
          'transmitted',
          'unknown',
        }.contains(intent.state)) {
          throw PlatformException(code: 'secure_store_failed');
        }
        if (failReplacementCommit) {
          failReplacementCommit = false;
          throw PlatformException(code: 'secure_store_failed');
        }
        final nonce = (++_nextNonce).toRadixString(16).padLeft(64, '0');
        _intents[alias] = _FakeIntent(
          operation: 'setCommunicationId',
          state: 'prepared',
          nonce: nonce,
        );
        return 'ct5.intent.v2.$alias.$nonce';
    }
    throw MissingPluginException();
  }

  void corruptCredential(String storageKey) {
    _credentials[_alias(storageKey)] = '{broken';
  }

  void corruptIntentState(String storageKey) {
    final alias = _alias(storageKey);
    final current = _intents[alias]!;
    _intents[alias] = _FakeIntent(
      operation: current.operation,
      state: 'corrupt',
      nonce: current.nonce,
    );
  }

  bool hasCredential(String storageKey) =>
      _credentials.containsKey(_alias(storageKey));

  String _alias(String storageKey) => _aliases.putIfAbsent(
    storageKey,
    () => (++_nextAlias).toRadixString(16).padLeft(64, '0'),
  );

  void _transition(
    String token,
    Set<String> allowed,
    String nextState,
  ) {
    final parts = _token(token);
    final intent = _matchingIntent(parts);
    if (!allowed.contains(intent.state)) {
      throw _conflict();
    }
    _intents[parts.alias] = _FakeIntent(
      operation: intent.operation,
      state: nextState,
      nonce: intent.nonce,
    );
  }

  _FakeIntent _matchingIntent(_FakeToken parts) {
    final intent = _intents[parts.alias];
    if (intent == null || intent.nonce != parts.nonce) {
      throw _conflict();
    }
    return intent;
  }

  _FakeToken _token(String token) {
    final match = RegExp(
      r'^ct5\.intent\.v2\.([0-9a-f]{64})\.([0-9a-f]{64})$',
    ).firstMatch(token);
    if (match == null) {
      throw PlatformException(code: 'bad_args');
    }
    return _FakeToken(match.group(1)!, match.group(2)!);
  }

  PlatformException _conflict() => PlatformException(code: 'conflict');
}

final class _FakeIntent {
  const _FakeIntent({
    required this.operation,
    required this.state,
    required this.nonce,
  });

  final String operation;
  final String state;
  final String nonce;
}

final class _FakeToken {
  const _FakeToken(this.alias, this.nonce);

  final String alias;
  final String nonce;
}
