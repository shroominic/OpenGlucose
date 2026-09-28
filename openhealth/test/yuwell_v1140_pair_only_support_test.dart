import 'dart:async';

import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/yuwell_v1140_pair_only_support.dart';

const _key = 'synthetic-storage-key';
const _nonce = 'synthetic-run-nonce';
final _now = DateTime.utc(2026, 9, 23, 12);
final _identity = YuwellCommunicationIdentity.parse('123456789012');
final _version = <int>[0x01, 0, 0, 0, 0, 0, 1, 1, 4, 0, 0, 0, 0, 0];
final List<int> _unbound = appendYuwellSum8(<int>[
  0x11,
  ...List<int>.filled(12, 0),
]);
final List<int> _setId = appendYuwellSum8(<int>[0x30, 0, 0, 0, 0, 1, 2, 3, 4]);

Never _raise(Object error) =>
    Error.throwWithStackTrace(error, StackTrace.current);

V1140FreshSelectorSnapshot _selector({
  String nonce = _nonce,
  String expected = _key,
  String selected = _key,
  List<String>? matches,
  DateTime? observed,
}) => V1140FreshSelectorSnapshot(
  runNonce: nonce,
  expectedStorageKey: expected,
  selectedStorageKey: selected,
  matchingStorageKeys: matches ?? <String>[_key],
  observedAtUtc: observed ?? _now,
);

final class _Fixture {
  _Fixture() {
    credentials = _Credentials(events);
    intents = _Intents(events);
    authorization = _Authorization(events);
  }

  final events = <String>[];
  final commands = <int>[];
  late final _Credentials credentials;
  late final _Intents intents;
  late final _Authorization authorization;
  List<int> version = _version;
  List<int> binding = _unbound;
  List<int> setId = _setId;
  Object? exchangeError;
  int? exchangeErrorOpcode;
  int identityCalls = 0;

  V1140PairOnlyCoordinator coordinator() => V1140PairOnlyCoordinator(
    exchange: (command) async {
      final opcode = command.first;
      commands.add(opcode);
      events.add('exchange:$opcode');
      expect(command, isNotEmpty);
      expect(opcode, isIn(<int>{0x01, 0x11, 0x30}));
      if (opcode == 0x30) {
        expect(command, _identity.encodeSetId());
        if (exchangeError != null &&
            (exchangeErrorOpcode == null || exchangeErrorOpcode == opcode)) {
          _raise(exchangeError!);
        }
        return setId;
      }
      if (opcode == 0x01) {
        expect(command, YuwellCt5Commands.readVersion());
        if (exchangeError != null &&
            (exchangeErrorOpcode == null || exchangeErrorOpcode == opcode)) {
          _raise(exchangeError!);
        }
        return version;
      }
      expect(command, YuwellCt5Commands.readBindingStatus());
      if (exchangeError != null &&
          (exchangeErrorOpcode == null || exchangeErrorOpcode == opcode)) {
        _raise(exchangeError!);
      }
      return binding;
    },
    credentialStore: credentials,
    writeIntentStore: intents,
    identityFactory: () {
      identityCalls++;
      events.add('identity');
      return _identity;
    },
    authorization: authorization,
    clock: () => _now,
  );
}

final class _Credentials implements YuwellCredentialStore {
  _Credentials(this.events);
  final List<String> events;
  YuwellSessionCredentials? record;
  Object? readError;
  Object? writeError;
  YuwellSessionCredentials? readOverride;
  bool readOverrideAfterFirst = false;
  bool mismatchAuthenticatedRead = false;
  bool failAuthenticatedWrite = false;
  bool failPreparedWrite = false;
  int? readErrorAt;
  int reads = 0;

  @override
  Future<YuwellSessionCredentials?> read(String storageKey) async {
    expect(storageKey, _key);
    events.add('credentials:read');
    reads++;
    if (readErrorAt == reads) throw StateError('private');
    if (readError != null) _raise(readError!);
    if (mismatchAuthenticatedRead &&
        record?.phase == YuwellCredentialPhase.authenticated) {
      return YuwellSessionCredentials(
        communicationIdentity: record!.communicationIdentity,
        cipher: null,
        k: 0,
        r: 0,
        transmitterComputed: false,
        phase: YuwellCredentialPhase.authenticated,
      );
    }
    if (readOverride != null && (!readOverrideAfterFirst || reads > 1)) {
      return readOverride;
    }
    return record;
  }

  @override
  Future<void> write(String storageKey, YuwellSessionCredentials value) async {
    expect(storageKey, _key);
    events.add('credentials:write:${value.phase.name}');
    if (failPreparedWrite &&
        value.phase == YuwellCredentialPhase.identityPrepared) {
      throw StateError('private');
    }
    if (failAuthenticatedWrite &&
        value.phase == YuwellCredentialPhase.authenticated) {
      throw StateError('private');
    }
    if (writeError != null) _raise(writeError!);
    record = value;
  }

  @override
  Future<void> delete(String storageKey) async {
    events.add('credentials:delete');
    fail('coordinator must not delete credentials');
  }
}

final class _Intents implements YuwellWriteIntentStore {
  _Intents(this.events);
  final List<String> events;
  bool unresolved = false;
  Object? hasError;
  Object? prepareError;
  Object? transmittedError;
  Object? completedError;
  bool removeThenThrow = false;
  int prepared = 0;
  int transmitted = 0;
  int completed = 0;

  @override
  Future<bool> hasUnresolved(String storageKey) async {
    expect(storageKey, _key);
    events.add('intent:has');
    if (hasError != null) _raise(hasError!);
    return unresolved;
  }

  @override
  Future<String> prepare(
    String storageKey,
    YuwellActivationWrite operation,
  ) async {
    expect(storageKey, _key);
    expect(operation, YuwellActivationWrite.setCommunicationId);
    events.add('intent:prepare');
    if (prepareError != null) _raise(prepareError!);
    prepared++;
    unresolved = true;
    return 'synthetic-token';
  }

  @override
  Future<void> markTransmitted(String token) async {
    expect(token, 'synthetic-token');
    events.add('intent:transmitted');
    transmitted++;
    if (transmittedError != null) _raise(transmittedError!);
  }

  @override
  Future<void> markCompleted(String token) async {
    expect(token, 'synthetic-token');
    events.add('intent:completed');
    completed++;
    if (removeThenThrow) unresolved = false;
    if (completedError != null) _raise(completedError!);
    unresolved = false;
  }

  @override
  Future<YuwellUnresolvedWriteIntent?> readUnresolved(
    String storageKey,
  ) async => fail('coordinator must not read recovery journal');
  @override
  Future<void> markUnknown(String token) async =>
      fail('no journal mutation on failure');
  @override
  Future<void> cancelPrepared(String token) async =>
      fail('no journal cancellation');
  @override
  Future<void> resolveRecovered(
    String token, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async => fail('no recovery');
  @override
  Future<String> replaceRecoveredWithPrepared(
    String token,
    String storageKey,
    YuwellActivationWrite operation, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async => fail('no retry');
}

final class _Authorization implements V1140OneShotAuthorization {
  _Authorization(this.events);
  final List<String> events;
  bool allowed = true;
  Object? error;
  int calls = 0;

  @override
  Future<bool> consume({
    required String runNonce,
    required String storageKey,
  }) async {
    expect(runNonce, _nonce);
    expect(storageKey, _key);
    events.add('authorization');
    calls++;
    if (error != null) _raise(error!);
    return allowed;
  }
}

void main() {
  test(
    'durable barriers precede sole set-ID and authenticated readback precedes completion',
    () async {
      final f = _Fixture();
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.pairedCredentialsDurable,
      );
      expect(f.events, <String>[
        'exchange:1',
        'exchange:17',
        'credentials:read',
        'intent:has',
        'authorization',
        'identity',
        'credentials:write:identityPrepared',
        'credentials:read',
        'intent:prepare',
        'intent:transmitted',
        'exchange:48',
        'credentials:write:authenticated',
        'credentials:read',
        'intent:completed',
      ]);
      expect(f.commands, <int>[0x01, 0x11, 0x30]);
      expect(f.identityCalls, 1);
      expect(f.credentials.record!.cipher, 11);
      expect(f.credentials.record!.activationStartedAt, isNull);
      expect(f.credentials.record!.historyGeneration, isNull);
    },
  );

  test('ambiguous stale or mismatched selector prevents all I/O', () async {
    final selectors = <V1140FreshSelectorSnapshot>[
      _selector(matches: <String>[]),
      _selector(matches: <String>[_key, _key]),
      _selector(matches: <String>[_key, 'other']),
      _selector(selected: 'other'),
      _selector(expected: 'other'),
      _selector(nonce: ' '),
      _selector(selected: ' '),
      _selector(observed: _now.subtract(const Duration(seconds: 31))),
      _selector(observed: _now.add(const Duration(microseconds: 1))),
    ];
    for (final selector in selectors) {
      final f = _Fixture();
      expect(
        await f.coordinator().pair(selector),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(f.events, isEmpty);
      expect(f.commands, isEmpty);
    }
  });

  test('one instance is consumed even after a failed preflight', () async {
    final f = _Fixture();
    final coordinator = f.coordinator();
    expect(
      await coordinator.pair(_selector(nonce: ' ')),
      V1140PairOnlyOutcome.preflightRejected,
    );
    expect(
      await coordinator.pair(_selector()),
      V1140PairOnlyOutcome.preflightRejected,
    );
    expect(f.events, isEmpty);
  });

  test('concurrent call cannot start a second exchange', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final f = _Fixture();
    final coordinator = V1140PairOnlyCoordinator(
      exchange: (command) async {
        f.commands.add(command.first);
        if (command.first == 0x01) {
          started.complete();
          await release.future;
          return _version;
        }
        return command.first == 0x11 ? _unbound : _setId;
      },
      credentialStore: f.credentials,
      writeIntentStore: f.intents,
      identityFactory: () => _identity,
      authorization: f.authorization,
      clock: () => _now,
    );
    final first = coordinator.pair(_selector());
    await started.future;
    expect(
      await coordinator.pair(_selector()),
      V1140PairOnlyOutcome.preflightRejected,
    );
    expect(f.commands, <int>[0x01]);
    release.complete();
    expect(await first, V1140PairOnlyOutcome.pairedCredentialsDurable);
    expect(f.commands, <int>[0x01, 0x11, 0x30]);
  });

  test(
    'unsupported or malformed version and bound or malformed status stop before storage',
    () async {
      for (final badVersion in <List<int>>[
        <int>[..._version]..[9] = 1,
        <int>[0x01, 1],
      ]) {
        final f = _Fixture()..version = badVersion;
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.preflightRejected,
        );
        expect(f.commands, <int>[0x01]);
        expect(f.identityCalls, 0);
      }
      for (final badBinding in <List<int>>[
        appendYuwellSum8(<int>[0x11, 0, 1, ...List<int>.filled(10, 0)]),
        <int>[0x11, 0],
      ]) {
        final f = _Fixture()..binding = badBinding;
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.preflightRejected,
        );
        expect(f.commands, <int>[0x01, 0x11]);
        expect(f.events, isNot(contains('credentials:read')));
      }
    },
  );

  test(
    'existing credential unresolved journal or indeterminate reads block identity',
    () async {
      for (var scenario = 0; scenario < 4; scenario++) {
        final f = _Fixture();
        if (scenario == 0) {
          f.credentials.record = YuwellSessionCredentials(
            communicationIdentity: _identity,
            cipher: null,
            k: 0,
            r: 0,
            transmitterComputed: false,
            phase: YuwellCredentialPhase.identityPrepared,
          );
        }
        if (scenario == 1) f.intents.unresolved = true;
        if (scenario == 2) f.credentials.readError = StateError('private');
        if (scenario == 3) f.intents.hasError = StateError('private');
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.preflightRejected,
        );
        expect(f.commands, <int>[0x01, 0x11]);
        expect(f.identityCalls, 0);
        expect(f.authorization.calls, 0);
      }
    },
  );

  test('authorization denial or error stops before identity', () async {
    for (final error in <Object?>[null, StateError('private')]) {
      final f = _Fixture();
      f.authorization
        ..allowed = false
        ..error = error;
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(f.authorization.calls, 1);
      expect(f.identityCalls, 0);
      expect(f.commands, <int>[0x01, 0x11]);
    }
  });

  test(
    'prepared credential mismatch and prepare failure never send set-ID',
    () async {
      final mismatch = _Fixture();
      mismatch.credentials.readOverride = YuwellSessionCredentials(
        communicationIdentity: _identity,
        cipher: 5,
        k: 0,
        r: 0,
        transmitterComputed: false,
        phase: YuwellCredentialPhase.identityPrepared,
      );
      mismatch.credentials.readOverrideAfterFirst = true;
      expect(
        await mismatch.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(mismatch.commands, <int>[0x01, 0x11]);
      final failed = _Fixture()..intents.prepareError = StateError('private');
      expect(
        await failed.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(failed.commands, <int>[0x01, 0x11]);
    },
  );

  test(
    'prepared write and readback errors stop before journal or set-ID',
    () async {
      for (var scenario = 0; scenario < 2; scenario++) {
        final f = _Fixture();
        if (scenario == 0) f.credentials.failPreparedWrite = true;
        if (scenario == 1) f.credentials.readErrorAt = 2;
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.preflightRejected,
        );
        expect(f.commands, <int>[0x01, 0x11]);
        expect(f.intents.prepared, 0);
      }
    },
  );

  test(
    'prepared readback rejects a different identity or unsafe flags',
    () async {
      final wrongIdentity = YuwellCommunicationIdentity.parse('999956789012');
      for (final badRecord in <YuwellSessionCredentials>[
        YuwellSessionCredentials(
          communicationIdentity: wrongIdentity,
          cipher: null,
          k: 0,
          r: 0,
          transmitterComputed: false,
          phase: YuwellCredentialPhase.identityPrepared,
        ),
        YuwellSessionCredentials(
          communicationIdentity: _identity,
          cipher: null,
          k: 0,
          r: 0,
          transmitterComputed: true,
          phase: YuwellCredentialPhase.identityPrepared,
        ),
      ]) {
        final f = _Fixture();
        f.credentials
          ..readOverride = badRecord
          ..readOverrideAfterFirst = true;
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.preflightRejected,
        );
        expect(f.commands, <int>[0x01, 0x11]);
        expect(f.intents.prepared, 0);
      }
    },
  );

  test(
    'ambiguous transmitted commit stays unresolved and does not enter exchange',
    () async {
      final f = _Fixture()..intents.transmittedError = StateError('private');
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.unresolvedWrite,
      );
      expect(f.commands, <int>[0x01, 0x11]);
      expect(f.intents.unresolved, isTrue);
      expect(f.events, isNot(contains('intent:completed')));
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(f.commands, <int>[0x01, 0x11, 0x01, 0x11]);
    },
  );

  test(
    'timeout disconnect malformed and rejected set-ID all stop terminally',
    () async {
      for (final response in <List<int>?>[
        null,
        <int>[],
        appendYuwellSum8(<int>[0x31, 0, 0, 0, 0, 1, 2, 3, 4]),
        <int>[..._setId]..[9] ^= 1,
      ]) {
        final f = _Fixture();
        if (response == null) {
          f.exchangeError = TimeoutException('synthetic timeout');
          f.exchangeErrorOpcode = 0x30;
        } else {
          f.setId = response;
        }
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.unresolvedWrite,
        );
        expect(f.commands, <int>[0x01, 0x11, 0x30]);
        expect(f.intents.unresolved, isTrue);
        expect(f.intents.completed, 0);
      }
      final disconnect = _Fixture()
        ..exchangeError = StateError('synthetic disconnect');
      expect(
        await disconnect.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(disconnect.commands, <int>[0x01]);
      final afterBarrier = _Fixture()
        ..exchangeError = StateError('synthetic disconnect')
        ..exchangeErrorOpcode = 0x30;
      expect(
        await afterBarrier.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.unresolvedWrite,
      );
      expect(afterBarrier.commands, <int>[0x01, 0x11, 0x30]);
      expect(afterBarrier.intents.unresolved, isTrue);
      final noDate = _Fixture()
        ..exchangeError = StateError('synthetic set-ID rejected without date')
        ..exchangeErrorOpcode = 0x30;
      expect(
        await noDate.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.unresolvedWrite,
      );
      expect(noDate.commands, <int>[0x01, 0x11, 0x30]);
    },
  );

  test(
    'authenticated write readback and completion failure remain unresolved',
    () async {
      for (var scenario = 0; scenario < 4; scenario++) {
        final f = _Fixture();
        if (scenario == 0) f.credentials.failAuthenticatedWrite = true;
        if (scenario == 1) f.credentials.mismatchAuthenticatedRead = true;
        if (scenario == 2) f.intents.completedError = StateError('private');
        if (scenario == 3) f.credentials.readErrorAt = 3;
        expect(
          await f.coordinator().pair(_selector()),
          V1140PairOnlyOutcome.unresolvedWrite,
        );
        expect(f.commands, <int>[0x01, 0x11, 0x30]);
        expect(f.intents.unresolved, isTrue);
      }
    },
  );

  test(
    'completion can remove tombstone then throw; saved credential blocks fresh retry',
    () async {
      final f = _Fixture();
      f.intents
        ..removeThenThrow = true
        ..completedError = StateError('private');
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.unresolvedWrite,
      );
      expect(f.intents.unresolved, isFalse);
      expect(f.credentials.record!.phase, YuwellCredentialPhase.authenticated);
      expect(
        await f.coordinator().pair(_selector()),
        V1140PairOnlyOutcome.preflightRejected,
      );
      expect(f.commands, <int>[0x01, 0x11, 0x30, 0x01, 0x11]);
    },
  );

  test('result and value objects reveal no sensitive inputs', () async {
    final f = _Fixture();
    final outcome = await f.coordinator().pair(_selector());
    final rendered =
        '${outcome.toString()} ${_selector().toString()} ${f.events}';
    expect(rendered, isNot(contains(_key)));
    expect(rendered, isNot(contains(_nonce)));
    expect(rendered, isNot(contains(_identity.serializeForSecureStorage())));
  });
}
