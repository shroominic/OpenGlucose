import 'errors.dart';
import 'events.dart';
import 'model.dart';
import 'state_machine.dart';
import 'topology.dart';
import 'uuid.dart';

/// Opaque NFC bootstrap context produced outside this package.
///
/// A concrete implementation owns all patch metadata, counters, credentials,
/// and key material. The live planner accepts only a context that a reviewed
/// NFC implementation has declared ready for a streaming handshake. A passive
/// tag detection is not such a context.
abstract interface class LibreStreamingBootstrapContext {
  LibreSecurityGeneration get generation;
}

/// Boundary for a separately reviewed NFC bootstrap implementation.
///
/// This package does not implement this interface. In particular, it does not
/// select or send NFC activation, late-join, enable-streaming, or patch-read
/// commands.
abstract interface class LibreNfcBootstrapProvider {
  Future<LibreStreamingBootstrapContext> acquireStreamingBootstrap();
}

/// Opaque authorization value for the audited Gen1 reference branch.
///
/// The reviewed evidence does not establish its target-specific length or
/// construction. The value is therefore accepted only from an external
/// authorization provider and is always redacted when converted to text.
final class LibreGen1AuthorizationRequest {
  LibreGen1AuthorizationRequest(Iterable<int> value)
    : value = LibreOpaqueBytes(value);

  final LibreOpaqueBytes value;

  @override
  String toString() =>
      'LibreGen1AuthorizationRequest(valueLength: ${value.length}, '
      'data: <redacted>)';
}

/// Exact-length authenticated request for the audited Gen2 reference branch.
final class LibreGen2AuthenticatedRequest {
  LibreGen2AuthenticatedRequest(Iterable<int> value)
    : value = _validateGen2AuthenticatedRequest(value);

  final LibreOpaqueBytes value;

  @override
  String toString() =>
      'LibreGen2AuthenticatedRequest(valueLength: ${value.length}, '
      'data: <redacted>)';
}

LibreOpaqueBytes _validateGen2AuthenticatedRequest(Iterable<int> value) {
  final opaque = LibreOpaqueBytes(value);
  if (opaque.length != 19) {
    throw LibreProtocolError(
      kind: LibreProtocolErrorKind.payloadLengthMismatch,
      expectedLength: 19,
      actualLength: opaque.length,
    );
  }
  return opaque;
}

/// Opaque verified session owned by the external Gen2 authenticator.
///
/// Session keys, IVs, counters, and decryptors stay in the concrete
/// implementation. This package never exposes or derives them.
abstract interface class LibreVerifiedSessionContext {}

/// Isolated Gen1 authorization boundary.
abstract interface class LibreGen1AuthorizationProvider {
  Future<LibreGen1AuthorizationRequest> createAuthorizationRequest({
    required LibreStreamingBootstrapContext bootstrap,
  });
}

/// Isolated Gen2 authentication and session-verification boundary.
abstract interface class LibreGen2AuthenticationProvider {
  Future<LibreGen2AuthenticatedRequest> createAuthenticatedRequest({
    required LibreStreamingBootstrapContext bootstrap,
    required LibreOpaqueBytes challenge,
  });

  Future<LibreVerifiedSessionContext> verifySession({
    required LibreStreamingBootstrapContext bootstrap,
    required LibreOpaqueBytes sessionInformation,
  });
}

/// The semantic purpose of a protocol write.
enum LibreLiveWritePurpose {
  gen1Authorization,
  gen2ChallengeRequest,
  gen2AuthenticatedRequest,
}

/// Evidence for the ATT write-completion mode.
///
/// The reviewed reference establishes the payload ordering, but it does not
/// establish whether the target requires write-with-response or
/// write-without-response. A concrete transport must resolve this from
/// separately reviewed target evidence before it executes a write action.
enum LibreWriteModeEvidence { unresolvedForTarget }

/// BLE write modes that a reviewed platform adapter can select.
///
/// The planner never selects one because the current evidence does not prove
/// which mode the target requires.
enum LibreResolvedWriteMode { withResponse, withoutResponse }

/// One notification received by a concrete BLE transport.
final class LibreLiveNotification {
  LibreLiveNotification({
    required this.characteristicUuid,
    required Iterable<int> value,
    required this.observedAt,
  }) : value = LibreOpaqueBytes(value);

  final String characteristicUuid;
  final LibreOpaqueBytes value;
  final Duration observedAt;

  @override
  String toString() =>
      'LibreLiveNotification(valueLength: ${value.length}, '
      'observedAt: $observedAt, data: <redacted>)';
}

/// A single next step from the pure live-handshake planner.
sealed class LibreLiveAction {
  const LibreLiveAction({required this.operationId});

  final int operationId;

  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;
}

/// An action that a separately reviewed BLE adapter can execute.
sealed class LibreLiveTransportAction extends LibreLiveAction {
  const LibreLiveTransportAction({required super.operationId});
}

final class LibreConnectAction extends LibreLiveTransportAction {
  const LibreConnectAction({required super.operationId});
}

final class LibreDiscoverTopologyAction extends LibreLiveTransportAction {
  const LibreDiscoverTopologyAction({required super.operationId});
}

final class LibreSubscribeAction extends LibreLiveTransportAction {
  const LibreSubscribeAction({
    required super.operationId,
    required this.characteristicUuid,
  });

  final String characteristicUuid;
}

final class LibreWriteAction extends LibreLiveTransportAction {
  const LibreWriteAction({
    required super.operationId,
    required this.characteristicUuid,
    required this.value,
    required this.purpose,
    this.writeModeEvidence = LibreWriteModeEvidence.unresolvedForTarget,
  });

  final String characteristicUuid;
  final LibreOpaqueBytes value;
  final LibreLiveWritePurpose purpose;
  final LibreWriteModeEvidence writeModeEvidence;

  @override
  String toString() =>
      'LibreWriteAction(operationId: $operationId, '
      'purpose: ${purpose.name}, valueLength: ${value.length}, '
      'data: <redacted>)';
}

/// An action that must be completed by an isolated security provider.
sealed class LibreLiveSecurityAction extends LibreLiveAction {
  const LibreLiveSecurityAction({required super.operationId});
}

final class LibreCreateGen1AuthorizationAction extends LibreLiveSecurityAction {
  const LibreCreateGen1AuthorizationAction({required super.operationId});
}

final class LibreCreateGen2AuthenticatedRequestAction
    extends LibreLiveSecurityAction {
  const LibreCreateGen2AuthenticatedRequestAction({
    required super.operationId,
    required this.challenge,
  });

  final LibreOpaqueBytes challenge;

  @override
  String toString() =>
      'LibreCreateGen2AuthenticatedRequestAction('
      'operationId: $operationId, challengeLength: ${challenge.length}, '
      'data: <redacted>)';
}

final class LibreVerifyGen2SessionAction extends LibreLiveSecurityAction {
  const LibreVerifyGen2SessionAction({
    required super.operationId,
    required this.sessionInformation,
  });

  final LibreOpaqueBytes sessionInformation;

  @override
  String toString() =>
      'LibreVerifyGen2SessionAction(operationId: $operationId, '
      'sessionInformationLength: ${sessionInformation.length}, '
      'data: <redacted>)';
}

/// Informational action emitted after F002 subscription completes.
final class LibreStreamingReadyAction extends LibreLiveAction {
  const LibreStreamingReadyAction({required super.operationId});
}

/// Boundary for a concrete BLE adapter.
///
/// The package deliberately provides no implementation or automatic runner.
/// This keeps connection, pairing, subscription, and write side effects under
/// the application-level approval and capture gates. An adapter must resolve
/// [LibreWriteAction.writeModeEvidence] before it transmits a write.
abstract interface class LibreLiveBleTransport {
  Future<void> connect(LibreConnectAction action);

  Future<List<LibreGattServiceSnapshot>> discoverTopology(
    LibreDiscoverTopologyAction action,
  );

  Future<void> subscribe(LibreSubscribeAction action);

  Future<void> write(
    LibreWriteAction action, {
    required LibreResolvedWriteMode mode,
  });

  Stream<LibreLiveNotification> get notifications;

  Future<void> disconnect();
}

/// Immutable result of one planner input.
final class LibreLivePlanUpdate {
  LibreLivePlanUpdate({
    Iterable<LibreProtocolEvent> events = const <LibreProtocolEvent>[],
    Iterable<LibreLiveAction> actions = const <LibreLiveAction>[],
  }) : events = List<LibreProtocolEvent>.unmodifiable(events),
       actions = List<LibreLiveAction>.unmodifiable(actions);

  final List<LibreProtocolEvent> events;
  final List<LibreLiveAction> actions;
}

/// Pure planner for the audited SAS-compatible Gen1 and Gen2 handshake order.
///
/// It performs no I/O and never retries. The caller executes each returned
/// action at most once, then acknowledges it with the matching operation ID.
/// Any stale or out-of-order acknowledgement fails the plan closed. A
/// disconnect clears all pending authentication and requires [begin] again.
final class LibreLiveHandshakePlanner {
  LibreLiveHandshakePlanner({
    required this.bootstrap,
    LibreProtocolTimingProfile timing =
        LibreProtocolTimingProfile.referenceDefaults,
  }) : _machine = LibreProtocolStateMachine(
         generation: bootstrap.generation,
         timing: timing,
       );

  final LibreStreamingBootstrapContext bootstrap;
  final LibreProtocolStateMachine _machine;

  LibreLiveAction? _pendingAction;
  LibreVerifiedSessionContext? _verifiedSession;
  int _nextOperationId = 1;
  bool _started = false;
  bool _failed = false;

  LibreProtocolPhase get phase =>
      _failed ? LibreProtocolPhase.failed : _machine.phase;
  LibreLiveAction? get pendingAction => _pendingAction;
  LibreVerifiedSessionContext? get verifiedSession => _verifiedSession;
  bool get isFailed => _failed;

  LibreLivePlanUpdate begin() {
    if (_started ||
        _pendingAction != null ||
        phase != LibreProtocolPhase.disconnected) {
      return _invalidTransition();
    }
    if (bootstrap.generation == LibreSecurityGeneration.unknown) {
      return _terminalFailure(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.unsupportedSecurityGeneration,
        ),
      );
    }
    _started = true;
    return _nextTransportAction(
      LibreConnectAction(operationId: _allocateOperationId()),
    );
  }

  LibreLivePlanUpdate recordConnected({required int operationId}) {
    if (!_takePending<LibreConnectAction>(operationId)) {
      return _invalidTransition();
    }
    final events = _machine.process(const LibreConnectedObservation());
    return _afterMachine(
      events,
      next: LibreDiscoverTopologyAction(operationId: _allocateOperationId()),
    );
  }

  LibreLivePlanUpdate recordTopology({
    required int operationId,
    required Iterable<LibreGattServiceSnapshot> services,
  }) {
    if (!_takePending<LibreDiscoverTopologyAction>(operationId)) {
      return _invalidTransition();
    }
    final classification = classifyLibreTopology(services);
    final events = _machine.process(LibreTopologyObservation(classification));
    final next = switch (_machine.phase) {
      LibreProtocolPhase.awaitingGen1ExternalAuthorization =>
        LibreCreateGen1AuthorizationAction(operationId: _allocateOperationId()),
      LibreProtocolPhase.awaitingLoginSubscription => LibreSubscribeAction(
        operationId: _allocateOperationId(),
        characteristicUuid: LibreUuids.sasLogin,
      ),
      _ => null,
    };
    return _afterMachine(events, next: next);
  }

  LibreLivePlanUpdate provideGen1Authorization({
    required int operationId,
    required LibreGen1AuthorizationRequest request,
  }) {
    if (!_takePending<LibreCreateGen1AuthorizationAction>(operationId) ||
        _machine.phase !=
            LibreProtocolPhase.awaitingGen1ExternalAuthorization) {
      return _invalidTransition();
    }
    return _nextTransportAction(
      LibreWriteAction(
        operationId: _allocateOperationId(),
        characteristicUuid: LibreUuids.sasLogin,
        value: request.value,
        purpose: LibreLiveWritePurpose.gen1Authorization,
      ),
    );
  }

  LibreLivePlanUpdate recordSubscriptionEnabled({required int operationId}) {
    final pending = _pendingAction;
    if (pending is! LibreSubscribeAction ||
        !_takePending<LibreSubscribeAction>(operationId)) {
      return _invalidTransition();
    }

    if (_machine.phase == LibreProtocolPhase.awaitingLoginSubscription &&
        pending.characteristicUuid == LibreUuids.sasLogin) {
      final events = _machine.process(
        const LibreLoginSubscriptionObservation(),
      );
      return _afterMachine(
        events,
        next: LibreWriteAction(
          operationId: _allocateOperationId(),
          characteristicUuid: LibreUuids.sasLogin,
          value: LibreOpaqueBytes(const <int>[0x20]),
          purpose: LibreLiveWritePurpose.gen2ChallengeRequest,
        ),
      );
    }

    if (_machine.phase == LibreProtocolPhase.awaitingDataSubscription &&
        pending.characteristicUuid == LibreUuids.sasData) {
      final events = _machine.process(const LibreDataSubscriptionObservation());
      return _afterMachine(
        events,
        informational: LibreStreamingReadyAction(
          operationId: _allocateOperationId(),
        ),
      );
    }

    return _invalidTransition();
  }

  LibreLivePlanUpdate recordWriteCompleted({required int operationId}) {
    final pending = _pendingAction;
    if (pending is! LibreWriteAction ||
        !_takePending<LibreWriteAction>(operationId)) {
      return _invalidTransition();
    }

    return switch (pending.purpose) {
      LibreLiveWritePurpose.gen1Authorization => _afterMachine(
        _machine.process(
          const LibreGen1ExternalAuthorizationVerifiedObservation(),
        ),
        next: LibreSubscribeAction(
          operationId: _allocateOperationId(),
          characteristicUuid: LibreUuids.sasData,
        ),
      ),
      LibreLiveWritePurpose.gen2ChallengeRequest => _afterMachine(
        _machine.process(
          LibreGen2ChallengeRequestRecordedObservation(
            encodedLength: pending.value.length,
          ),
        ),
      ),
      LibreLiveWritePurpose.gen2AuthenticatedRequest => _afterMachine(
        _machine.process(
          LibreGen2AuthenticatedRequestRecordedObservation(
            encodedLength: pending.value.length,
          ),
        ),
      ),
    };
  }

  LibreLivePlanUpdate recordNotification(LibreLiveNotification notification) {
    if (_failed ||
        (_pendingAction != null &&
            _machine.phase != LibreProtocolPhase.streaming)) {
      return _invalidTransition();
    }
    final events = _machine.process(
      LibreNotificationObservation(
        characteristicUuid: notification.characteristicUuid,
        value: notification.value.bytes,
        observedAt: notification.observedAt,
      ),
    );

    LibreLiveAction? next;
    for (final event in events) {
      if (event is LibreGen2ChallengeEvent) {
        next = LibreCreateGen2AuthenticatedRequestAction(
          operationId: _allocateOperationId(),
          challenge: event.value,
        );
      } else if (event is LibreGen2SessionInformationEvent) {
        next = LibreVerifyGen2SessionAction(
          operationId: _allocateOperationId(),
          sessionInformation: event.value,
        );
      }
    }
    return _afterMachine(events, next: next);
  }

  LibreLivePlanUpdate provideGen2AuthenticatedRequest({
    required int operationId,
    required LibreGen2AuthenticatedRequest request,
  }) {
    if (!_takePending<LibreCreateGen2AuthenticatedRequestAction>(operationId) ||
        _machine.phase !=
            LibreProtocolPhase.awaitingAuthenticatedRequestRecord) {
      return _invalidTransition();
    }
    return _nextTransportAction(
      LibreWriteAction(
        operationId: _allocateOperationId(),
        characteristicUuid: LibreUuids.sasLogin,
        value: request.value,
        purpose: LibreLiveWritePurpose.gen2AuthenticatedRequest,
      ),
    );
  }

  LibreLivePlanUpdate acceptVerifiedGen2Session({
    required int operationId,
    required LibreVerifiedSessionContext session,
  }) {
    if (!_takePending<LibreVerifyGen2SessionAction>(operationId) ||
        _machine.phase !=
            LibreProtocolPhase.awaitingExternalSessionVerification) {
      return _invalidTransition();
    }
    _verifiedSession = session;
    final events = _machine.process(
      const LibreGen2ExternalSessionVerifiedObservation(),
    );
    return _afterMachine(
      events,
      next: LibreSubscribeAction(
        operationId: _allocateOperationId(),
        characteristicUuid: LibreUuids.sasData,
      ),
    );
  }

  LibreLivePlanUpdate tick(Duration observedAt) {
    if (_failed || _pendingAction != null) {
      return _invalidTransition();
    }
    return _afterMachine(_machine.process(LibreTickObservation(observedAt)));
  }

  LibreLivePlanUpdate recordDisconnected() {
    _pendingAction = null;
    _verifiedSession = null;
    _started = false;
    _failed = false;
    return LibreLivePlanUpdate(
      events: _machine.process(const LibreDisconnectedObservation()),
    );
  }

  int _allocateOperationId() => _nextOperationId++;

  bool _takePending<T extends LibreLiveAction>(int operationId) {
    final action = _pendingAction;
    if (action is! T || action.operationId != operationId) {
      return false;
    }
    _pendingAction = null;
    return true;
  }

  LibreLivePlanUpdate _nextTransportAction(LibreLiveAction action) {
    _pendingAction = action;
    return LibreLivePlanUpdate(actions: <LibreLiveAction>[action]);
  }

  LibreLivePlanUpdate _afterMachine(
    List<LibreProtocolEvent> events, {
    LibreLiveAction? next,
    LibreLiveAction? informational,
  }) {
    final failure = events.whereType<LibreProtocolFailureEvent>().firstOrNull;
    if (failure != null && failure.error.isConnectionTerminal) {
      _failed = true;
      _pendingAction = null;
      return LibreLivePlanUpdate(events: events);
    }
    if (next != null) {
      _pendingAction = next;
    }
    return LibreLivePlanUpdate(
      events: events,
      actions: <LibreLiveAction>[?next, ?informational],
    );
  }

  LibreLivePlanUpdate _invalidTransition() {
    return _terminalFailure(
      const LibreProtocolError(kind: LibreProtocolErrorKind.invalidTransition),
    );
  }

  LibreLivePlanUpdate _terminalFailure(LibreProtocolError error) {
    final contextual = error.withContext(
      phase: _machine.phase,
      generation: bootstrap.generation,
    );
    _failed = true;
    _pendingAction = null;
    return LibreLivePlanUpdate(
      events: <LibreProtocolEvent>[LibreProtocolFailureEvent(contextual)],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
