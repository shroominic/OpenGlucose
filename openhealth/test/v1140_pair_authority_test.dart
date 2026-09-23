import 'dart:convert';

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/v1140_pair_authority.dart';
import 'package:openglucose/src/yuwell_secure_session_store.dart';

import '../integration_test/support/yuwell_v1140_pair_only_support.dart';

const _key = 'synthetic-target';
final String _nonce = 'a' * 64;
final String _signer = 'b' * 64;
final String _receipt = 'c' * 64;
final DateTime _observed = DateTime.utc(2026, 9, 23, 12);
final V1140PairBuildBinding _build = V1140PairBuildBinding(
  packageName: 'com.openglucose.app',
  signerSha256: _signer,
  versionCode: 123,
  receiptSha256: _receipt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(YuwellSecureSessionStore.channelName);
  late _Native native;
  late YuwellSecureSessionStore store;

  setUp(() {
    native = _Native();
    store = YuwellSecureSessionStore.testing(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('read identity uses only the read-only native method', () async {
    final identity = await store.readV1140AppIdentity();
    expect(identity.packageName, 'com.openglucose.app');
    expect(identity.signerSha256, _signer);
    expect(identity.versionCode, 123);
    expect(identity.uid, 10001);
    expect(identity.debuggable, false);
    expect(native.calls.map((call) => call.method), <String>[
      'readV1140AppIdentity',
    ]);
    expect(native.calls.single.arguments, <String, Object?>{});
    expect(native.claimed, isEmpty);
  });

  test(
    'claim sends exact build binding and returns native nonce and expiry',
    () async {
      final claim = await store.claimV1140Run(
        storageKey: _key,
        observedAtUtc: _observed,
        build: _build,
      );
      expect(claim.runNonce, _nonce);
      expect(claim.expiresAtUtc, _observed.add(const Duration(seconds: 30)));
      expect(native.calls.single.method, 'claimV1140Run');
      expect(native.calls.single.arguments, <String, Object?>{
        'storageKey': _key,
        'observedAtUtcMillis': _observed.millisecondsSinceEpoch,
        'expectedPackageName': 'com.openglucose.app',
        'expectedSignerSha256': _signer,
        'expectedVersionCode': 123,
        'receiptSha256': _receipt,
      });
    },
  );

  test('two store objects use retained native claim and spent state', () async {
    final second = YuwellSecureSessionStore.testing(channel: channel);
    final claim = await store.claimV1140Run(
      storageKey: _key,
      observedAtUtc: _observed,
      build: _build,
    );
    expect(await second.consume(runNonce: 'd' * 64, storageKey: _key), false);
    expect(
      await second.consume(runNonce: claim.runNonce, storageKey: 'other'),
      false,
    );
    expect(
      await second.consume(runNonce: claim.runNonce, storageKey: _key),
      true,
    );
    expect(
      await store.consume(runNonce: claim.runNonce, storageKey: _key),
      false,
    );
    native.restarted = true;
    expect(
      await second.consume(runNonce: claim.runNonce, storageKey: _key),
      false,
    );
    expect(native.claimed[_key], 'spent');
    final consumeCalls = native.calls
        .where((call) => call.method == 'consumeV1140Run')
        .toList();
    expect(consumeCalls[2].arguments, <String, Object?>{
      'runNonce': claim.runNonce,
      'storageKey': _key,
    });
  });

  test(
    'expired native claim stays claimed through a fresh store and coordinator',
    () async {
      final claim = await store.claimV1140Run(
        storageKey: _key,
        observedAtUtc: _observed,
        build: _build,
      );
      native.now = claim.expiresAtUtc.add(const Duration(milliseconds: 1));
      final freshStore = YuwellSecureSessionStore.testing(channel: channel);
      expect(
        await freshStore.consume(runNonce: claim.runNonce, storageKey: _key),
        false,
      );
      expect(native.claimed[_key], 'claimed');

      final callsBeforeCoordinator = native.calls.length;
      var identityCalls = 0;
      final commands = <int>[];
      final coordinator = V1140PairOnlyCoordinator(
        exchange: (command) async {
          commands.add(command.first);
          if (command.first == 0x01) {
            return <int>[0x01, 0, 0, 0, 0, 0, 1, 1, 4, 0, 0, 0, 0, 0];
          }
          return appendYuwellSum8(<int>[0x11, ...List<int>.filled(12, 0)]);
        },
        credentialStore: freshStore,
        writeIntentStore: freshStore,
        identityFactory: () {
          identityCalls++;
          return YuwellCommunicationIdentity.parse('123456789012');
        },
        authorization: freshStore,
        clock: () => _observed,
      );
      final outcome = await coordinator.pair(
        V1140FreshSelectorSnapshot(
          runNonce: claim.runNonce,
          expectedStorageKey: _key,
          selectedStorageKey: _key,
          matchingStorageKeys: <String>[_key],
          observedAtUtc: _observed,
        ),
      );
      expect(outcome, V1140PairOnlyOutcome.preflightRejected);
      expect(identityCalls, 0);
      expect(commands, <int>[0x01, 0x11]);
      expect(native.claimed[_key], 'claimed');
      expect(native.credential, isNull);
      expect(native.journal, isNull);
      expect(
        native.calls
            .skip(callsBeforeCoordinator)
            .where(
              (call) =>
                  call.method == 'writeCredential' || call.method == 'prepare',
            ),
        isEmpty,
      );
    },
  );

  test('value objects reject malformed bindings without exposing values', () {
    expect(
      () => V1140PairBuildBinding(
        packageName: 'other',
        signerSha256: _signer,
        versionCode: 123,
        receiptSha256: _receipt,
      ),
      throwsArgumentError,
    );
    expect(
      () => V1140PairBuildBinding(
        packageName: 'com.openglucose.app',
        signerSha256: 'SENSITIVE',
        versionCode: 123,
        receiptSha256: _receipt,
      ),
      throwsArgumentError,
    );
    expect(
      () => V1140PairBuildBinding(
        packageName: 'com.openglucose.app',
        signerSha256: _signer,
        versionCode: 0,
        receiptSha256: _receipt,
      ),
      throwsArgumentError,
    );
    expect(
      () => V1140RunClaim(runNonce: 'SENSITIVE', expiresAtUtc: _observed),
      throwsArgumentError,
    );
    expect(
      () => V1140RunClaim(runNonce: _nonce, expiresAtUtc: _observed.toLocal()),
      throwsArgumentError,
    );
  });

  test(
    'strict response maps and bool reject null, extras and wrong types',
    () async {
      for (final bad in <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{
          'packageName': 'com.openglucose.app',
          'signerSha256': _signer,
          'versionCode': 123,
          'uid': 10001,
          'debuggable': false,
          'extra': true,
        },
        <String, Object?>{
          'packageName': 'com.openglucose.app',
          'signerSha256': _signer,
          'versionCode': '123',
          'uid': 10001,
          'debuggable': false,
        },
      ]) {
        native.overrideMethod = 'readV1140AppIdentity';
        native.overrideValue = bad;
        await expectLater(store.readV1140AppIdentity(), throwsStateError);
      }
      native.overrideMethod = 'claimV1140Run';
      for (final bad in <Object?>[
        null,
        <String, Object?>{},
        <String, Object?>{'runNonce': _nonce, 'expiresAtUtcMillis': -1},
        <String, Object?>{
          'runNonce': _nonce,
          'expiresAtUtcMillis': _observed.millisecondsSinceEpoch,
          'extra': 1,
        },
      ]) {
        native.overrideValue = bad;
        await expectLater(
          store.claimV1140Run(
            storageKey: _key,
            observedAtUtc: _observed,
            build: _build,
          ),
          throwsStateError,
        );
      }
      native.overrideMethod = 'consumeV1140Run';
      native.overrideValue = null;
      await expectLater(
        store.consume(runNonce: _nonce, storageKey: _key),
        throwsStateError,
      );
      native.overrideValue = 'true';
      await expectLater(
        store.consume(runNonce: _nonce, storageKey: _key),
        throwsStateError,
      );
    },
  );

  test('unsupported platform makes zero calls', () async {
    final unsupported = YuwellSecureSessionStore.testing(
      channel: channel,
      supported: false,
    );
    await expectLater(
      unsupported.readV1140AppIdentity(),
      throwsUnsupportedError,
    );
    await expectLater(
      unsupported.claimV1140Run(
        storageKey: _key,
        observedAtUtc: _observed,
        build: _build,
      ),
      throwsUnsupportedError,
    );
    await expectLater(
      unsupported.consume(runNonce: _nonce, storageKey: _key),
      throwsUnsupportedError,
    );
    expect(native.calls, isEmpty);
  });

  test('native errors and plugin failures redact private details', () async {
    for (final code in <String>[
      'run_conflict',
      'run_rejected',
      'private_unknown',
    ]) {
      native.errorCode = code;
      try {
        await store.claimV1140Run(
          storageKey: _key,
          observedAtUtc: _observed,
          build: _build,
        );
        fail('native error must fail');
      } catch (error) {
        expect(error.toString(), isNot(contains('SENSITIVE')));
      }
    }
    native.errorCode = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(store.readV1140AppIdentity(), throwsStateError);
  });

  test(
    'existing credential and journal serialized bytes stay unchanged',
    () async {
      final identity = YuwellCommunicationIdentity.parse('123456789012');
      await store.write(
        _key,
        YuwellSessionCredentials(
          communicationIdentity: identity,
          cipher: null,
          k: 0,
          r: 0,
          transmitterComputed: false,
          phase: YuwellCredentialPhase.identityPrepared,
        ),
      );
      await store.prepare(_key, YuwellActivationWrite.setCommunicationId);
      final credentialBytes = native.credential;
      final journalBytes = native.journal;
      await store.readV1140AppIdentity();
      final claim = await store.claimV1140Run(
        storageKey: _key,
        observedAtUtc: _observed,
        build: _build,
      );
      expect(await store.consume(runNonce: 'd' * 64, storageKey: _key), false);
      expect(
        await store.consume(runNonce: claim.runNonce, storageKey: _key),
        true,
      );
      expect(native.credential, credentialBytes);
      expect(native.journal, journalBytes);
      expect(await store.read(_key), isNotNull);
      expect(
        (await store.readUnresolved(_key))!.state,
        YuwellWriteIntentState.prepared,
      );
      expect(
        native.calls.where(
          (call) =>
              call.method == 'deleteCredential' ||
              call.method == 'markCompleted',
        ),
        isEmpty,
      );
    },
  );

  test('coordinator spends natively before identity and sole set-ID', () async {
    final claim = await store.claimV1140Run(
      storageKey: _key,
      observedAtUtc: _observed,
      build: _build,
    );
    final events = native.events;
    final identity = YuwellCommunicationIdentity.parse('123456789012');
    var identityCalls = 0;
    final commands = <int>[];
    V1140PairOnlyCoordinator coordinator() => V1140PairOnlyCoordinator(
      exchange: (command) async {
        commands.add(command.first);
        events.add('exchange:${command.first}');
        if (command.first == 0x01) {
          return <int>[0x01, 0, 0, 0, 0, 0, 1, 1, 4, 0, 0, 0, 0, 0];
        }
        if (command.first == 0x11) {
          return appendYuwellSum8(<int>[0x11, ...List<int>.filled(12, 0)]);
        }
        return appendYuwellSum8(<int>[0x30, 0, 0, 0, 0, 1, 2, 3, 4]);
      },
      credentialStore: store,
      writeIntentStore: store,
      identityFactory: () {
        identityCalls++;
        events.add('identityFactory');
        return identity;
      },
      authorization: store,
      clock: () => _observed,
    );
    V1140FreshSelectorSnapshot selector(String nonce) =>
        V1140FreshSelectorSnapshot(
          runNonce: nonce,
          expectedStorageKey: _key,
          selectedStorageKey: _key,
          matchingStorageKeys: <String>[_key],
          observedAtUtc: _observed,
        );
    native.consumeError = true;
    expect(
      await coordinator().pair(selector(claim.runNonce)),
      V1140PairOnlyOutcome.preflightRejected,
    );
    expect(identityCalls, 0);
    expect(commands.where((value) => value == 0x30), isEmpty);
    native.consumeError = false;
    native.consumeAllowed = false;
    commands.clear();
    events.clear();
    expect(
      await coordinator().pair(selector(claim.runNonce)),
      V1140PairOnlyOutcome.preflightRejected,
    );
    expect(identityCalls, 0);
    expect(commands.where((value) => value == 0x30), isEmpty);
    native.consumeAllowed = true;
    commands.clear();
    events.clear();
    expect(
      await coordinator().pair(selector(claim.runNonce)),
      V1140PairOnlyOutcome.pairedCredentialsDurable,
    );
    expect(identityCalls, 1);
    expect(commands.where((value) => value == 0x30), <int>[0x30]);
    expect(
      events.indexOf('nativeSpentCommit'),
      lessThan(events.indexOf('identityFactory')),
    );
    expect(
      events.indexOf('identityFactory'),
      lessThan(events.indexOf('journalPrepare')),
    );
    expect(
      events.indexOf('journalPrepare'),
      lessThan(events.indexOf('journalTransmitted')),
    );
    expect(
      events.indexOf('journalTransmitted'),
      lessThan(events.indexOf('exchange:48')),
    );
  });
}

final class _Native {
  final calls = <MethodCall>[];
  final events = <String>[];
  final claimed = <String, String>{};
  final claimExpiresAt = <String, DateTime>{};
  String? credential;
  String? journal;
  String? errorCode;
  String? overrideMethod;
  Object? overrideValue;
  bool restarted = false;
  DateTime now = _observed;
  bool consumeError = false;
  bool consumeAllowed = true;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (call.method == overrideMethod) return overrideValue;
    if (errorCode != null) {
      throw PlatformException(
        code: errorCode!,
        message: 'SENSITIVE',
        details: 'SENSITIVE',
      );
    }
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'readV1140AppIdentity':
        return <String, Object?>{
          'packageName': 'com.openglucose.app',
          'signerSha256': _signer,
          'versionCode': 123,
          'uid': 10001,
          'debuggable': false,
        };
      case 'claimV1140Run':
        final key = args['storageKey']! as String;
        if (claimed.containsKey(key)) {
          throw PlatformException(code: 'run_conflict');
        }
        claimed[key] = 'claimed';
        final observedMillis = args['observedAtUtcMillis']! as int;
        claimExpiresAt[key] = DateTime.fromMillisecondsSinceEpoch(
          observedMillis + 30000,
          isUtc: true,
        );
        restarted = false;
        return <String, Object?>{
          'runNonce': _nonce,
          'expiresAtUtcMillis': observedMillis + 30000,
        };
      case 'consumeV1140Run':
        if (consumeError) throw PlatformException(code: 'run_rejected');
        if (!consumeAllowed ||
            restarted ||
            now.isAfter(claimExpiresAt[args['storageKey']] ?? _observed) ||
            args['storageKey'] != _key ||
            args['runNonce'] != _nonce ||
            claimed[_key] != 'claimed') {
          return false;
        }
        claimed[_key] = 'spent';
        events.add('nativeSpentCommit');
        return true;
      case 'writeCredential':
        credential = args['credential']! as String;
        return null;
      case 'readCredential':
        return credential;
      case 'hasUnresolved':
        return journal != null;
      case 'prepare':
        events.add('journalPrepare');
        journal = jsonEncode(<String, Object?>{
          'token': 'synthetic-token',
          'operation': args['operation'],
          'state': 'prepared',
        });
        return 'synthetic-token';
      case 'readUnresolved':
        return journal == null ? null : jsonDecode(journal!);
      case 'markTransmitted':
        events.add('journalTransmitted');
        return null;
      case 'markCompleted':
        journal = null;
        return null;
    }
    throw MissingPluginException();
  }
}
