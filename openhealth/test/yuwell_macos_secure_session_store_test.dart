import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/yuwell_macos_secure_session_store.dart';

void main() {
  late _FakeKeyValueStore fakeStore;
  late YuwellMacosKeychainSessionStore store;

  setUp(() {
    fakeStore = _FakeKeyValueStore();
    store = YuwellMacosKeychainSessionStore(keyValueStore: fakeStore);
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

  test('credentials round-trip through the Keychain-backed store', () async {
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
    expect(fakeStore.data, isNotEmpty);
    for (final key in fakeStore.data.keys) {
      expect(key, isNot(contains('private-sensor-identity')));
    }
  });

  test('v2 history identity round-trips through the Keychain store', () async {
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

    expect(token, startsWith('ct5.macos.intent.v1.'));
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
      store.prepare('sensor-key', YuwellActivationWrite.setCommunicationId),
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

    fakeStore.failNextWrite = true;
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
  });

  test(
    'the storage key never leaks into a Keychain item name or token',
    () async {
      final token = await store.prepare(
        'sensor-key',
        YuwellActivationWrite.setDate,
      );
      // The encrypted-at-rest journal *value* legitimately carries the storage
      // key (same tier as a credential record's fields). What must never carry
      // it in the clear is a Keychain item *name* (the alias) or the token.
      for (final key in fakeStore.data.keys) {
        expect(key, isNot(contains('sensor-key')));
      }
      expect(token, isNot(contains('sensor-key')));
    },
  );

  test(
    'a read failure fails closed without leaking the underlying error',
    () async {
      // A warmup write on a different key establishes the device secret first,
      // so the injected failure below lands on the credential-alias read
      // itself, not the earlier device-secret bootstrap read (a different
      // catch block, exercised separately below).
      await store.write('warmup', credentials());
      fakeStore.failNextRead = Exception('simulated Keychain read failure');

      await expectLater(
        store.read('sensor-key'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Yuwell macOS secure storage failed closed.',
          ),
        ),
      );
    },
  );

  test(
    'a read failure that is already a protocol exception is not masked '
    'by the generic fail-closed message',
    () async {
      await store.write('warmup', credentials());
      fakeStore.failNextRead = const YuwellProtocolFormatException(
        'synthetic pre-existing diagnosis',
      );

      await expectLater(
        store.read('sensor-key'),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    },
  );

  test('a delete failure fails closed', () async {
    await store.write('sensor-key', credentials());
    fakeStore.failNextDelete = Exception('simulated Keychain delete failure');

    await expectLater(store.delete('sensor-key'), throwsStateError);
  });

  test(
    'a device-secret read failure fails closed on the very first operation',
    () async {
      // No warmup here: this is the bootstrap read itself, a separate catch
      // block (on Object, no type preserved) from the per-alias reads above.
      fakeStore.failNextRead = Exception('simulated Keychain read failure');

      await expectLater(store.read('sensor-key'), throwsStateError);
    },
  );

  test(
    'a corrupted stored record fails closed as a protocol exception, not '
    'a crash',
    () async {
      await store.write('warmup', credentials());
      final before = fakeStore.data.keys.toSet();
      await store.write('sensor-key', credentials());
      final added = fakeStore.data.keys.toSet().difference(before);
      expect(added, hasLength(1));

      fakeStore.data[added.single] = 'not valid json';
      await expectLater(
        store.read('sensor-key'),
        throwsA(isA<YuwellProtocolFormatException>()),
      );

      fakeStore.data[added.single] = '42'; // valid JSON, but not a Map
      await expectLater(
        store.read('sensor-key'),
        throwsA(isA<YuwellProtocolFormatException>()),
      );
    },
  );

  test(
    'a fresh store instance reads what an earlier one wrote, proving the '
    'device secret persists rather than regenerating',
    () async {
      await store.write('sensor-key', credentials());

      final reopened = YuwellMacosKeychainSessionStore(
        keyValueStore: fakeStore,
      );
      final restored = await reopened.read('sensor-key');

      expect(restored, isNotNull);
      expect(restored!.cipher, 0x42);
    },
  );
}

class _FakeKeyValueStore implements YuwellMacosKeyValueStore {
  final Map<String, String> data = {};
  bool failNextWrite = false;
  Exception? failNextRead;
  Exception? failNextDelete;

  @override
  Future<String?> read(String key) async {
    final error = failNextRead;
    if (error != null) {
      failNextRead = null;
      throw error;
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw Exception('simulated Keychain write failure');
    }
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    final error = failNextDelete;
    if (error != null) {
      failNextDelete = null;
      throw error;
    }
    data.remove(key);
  }
}
