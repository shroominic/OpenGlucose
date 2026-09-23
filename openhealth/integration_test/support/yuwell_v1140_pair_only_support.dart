import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

typedef V1140FrameExchange = Future<List<int>> Function(List<int> command);
typedef V1140IdentityFactory = YuwellCommunicationIdentity Function();
typedef V1140Clock = DateTime Function();

// The explicit interface keeps consent consumption injectable at this seam.
// ignore: one_member_abstracts
abstract interface class V1140OneShotAuthorization {
  Future<bool> consume({required String runNonce, required String storageKey});
}

final class V1140FreshSelectorSnapshot {
  V1140FreshSelectorSnapshot({
    required this.runNonce,
    required this.expectedStorageKey,
    required this.selectedStorageKey,
    required List<String> matchingStorageKeys,
    required this.observedAtUtc,
  }) : matchingStorageKeys = List<String>.unmodifiable(matchingStorageKeys);

  final String runNonce;
  final String expectedStorageKey;
  final String selectedStorageKey;
  final List<String> matchingStorageKeys;
  final DateTime observedAtUtc;
}

enum V1140PairOnlyOutcome {
  preflightRejected,
  unresolvedWrite,
  pairedCredentialsDurable,
}

final class V1140PairOnlyCoordinator {
  V1140PairOnlyCoordinator({
    required V1140FrameExchange exchange,
    required YuwellCredentialStore credentialStore,
    required YuwellWriteIntentStore writeIntentStore,
    required V1140IdentityFactory identityFactory,
    required V1140OneShotAuthorization authorization,
    required V1140Clock clock,
  }) : _exchange = exchange,
       _credentialStore = credentialStore,
       _writeIntentStore = writeIntentStore,
       _identityFactory = identityFactory,
       _authorization = authorization,
       _clock = clock;

  final V1140FrameExchange _exchange;
  final YuwellCredentialStore _credentialStore;
  final YuwellWriteIntentStore _writeIntentStore;
  final V1140IdentityFactory _identityFactory;
  final V1140OneShotAuthorization _authorization;
  final V1140Clock _clock;
  bool _consumed = false;

  Future<V1140PairOnlyOutcome> pair(V1140FreshSelectorSnapshot selector) async {
    if (_consumed) return V1140PairOnlyOutcome.preflightRejected;
    _consumed = true;

    final key = selector.selectedStorageKey;
    try {
      if (!_validSelector(selector)) {
        return V1140PairOnlyOutcome.preflightRejected;
      }

      final version = YuwellCt5Responses.version(
        await _exchange(YuwellCt5Commands.readVersion()),
      );
      if (version[6] != 1 ||
          version[7] != 1 ||
          version[8] != 4 ||
          version[9] != 0) {
        return V1140PairOnlyOutcome.preflightRejected;
      }

      final bound = YuwellCt5Responses.bindingStatus(
        await _exchange(YuwellCt5Commands.readBindingStatus()),
      );
      if (bound ||
          await _credentialStore.read(key) != null ||
          await _writeIntentStore.hasUnresolved(key) ||
          !await _authorization.consume(
            runNonce: selector.runNonce,
            storageKey: key,
          )) {
        return V1140PairOnlyOutcome.preflightRejected;
      }

      final identity = _identityFactory();
      final prepared = YuwellSessionCredentials(
        communicationIdentity: identity,
        cipher: null,
        k: 0,
        r: 0,
        transmitterComputed: false,
        phase: YuwellCredentialPhase.identityPrepared,
      );
      await _credentialStore.write(key, prepared);
      if (!_sameCredentials(await _credentialStore.read(key), prepared)) {
        return V1140PairOnlyOutcome.preflightRejected;
      }

      final token = await _writeIntentStore.prepare(
        key,
        YuwellActivationWrite.setCommunicationId,
      );
      // An error here may mean the durable commit succeeded. Retain the
      // prepared record and journal, and never enter the exchange on error.
      try {
        await _writeIntentStore.markTransmitted(token);
      } catch (_) {
        return V1140PairOnlyOutcome.unresolvedWrite;
      }

      try {
        final response = await _exchange(identity.encodeSetId());
        final cipher = identity.deriveCipherFromSetIdResponse(response);
        final authenticated = YuwellSessionCredentials(
          communicationIdentity: identity,
          cipher: cipher,
          k: 0,
          r: 0,
          transmitterComputed: false,
          phase: YuwellCredentialPhase.authenticated,
        );
        await _credentialStore.write(key, authenticated);
        if (!_sameCredentials(
          await _credentialStore.read(key),
          authenticated,
        )) {
          return V1140PairOnlyOutcome.unresolvedWrite;
        }
        await _writeIntentStore.markCompleted(token);
        return V1140PairOnlyOutcome.pairedCredentialsDurable;
      } catch (_) {
        return V1140PairOnlyOutcome.unresolvedWrite;
      }
    } catch (_) {
      return V1140PairOnlyOutcome.preflightRejected;
    }
  }

  bool _validSelector(V1140FreshSelectorSnapshot selector) {
    if (selector.runNonce.trim().isEmpty ||
        selector.expectedStorageKey.trim().isEmpty ||
        selector.selectedStorageKey.trim().isEmpty ||
        selector.expectedStorageKey != selector.selectedStorageKey ||
        selector.matchingStorageKeys.length != 1 ||
        selector.matchingStorageKeys.single != selector.selectedStorageKey) {
      return false;
    }
    final age = _clock().toUtc().difference(selector.observedAtUtc.toUtc());
    return !age.isNegative && age <= const Duration(seconds: 30);
  }

  bool _sameCredentials(
    YuwellSessionCredentials? stored,
    YuwellSessionCredentials expected,
  ) =>
      stored != null &&
      stored.communicationIdentity.serializeForSecureStorage() ==
          expected.communicationIdentity.serializeForSecureStorage() &&
      stored.phase == expected.phase &&
      stored.cipher == expected.cipher &&
      stored.k == expected.k &&
      stored.r == expected.r &&
      stored.transmitterComputed == expected.transmitterComputed &&
      stored.activationStartedAt == null &&
      stored.verifiedFirmware == null &&
      stored.historyGeneration == null &&
      stored.initializationIndex == expected.initializationIndex;
}
