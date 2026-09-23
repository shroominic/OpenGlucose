import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  group('Gen2 live handshake planner', () {
    test('plans only the exact reviewed handshake order', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.gen2),
      );

      final connect = _onlyAction<LibreConnectAction>(planner.begin());
      final discover = _onlyAction<LibreDiscoverTopologyAction>(
        planner.recordConnected(operationId: connect.operationId),
      );
      final loginSubscription = _onlyAction<LibreSubscribeAction>(
        planner.recordTopology(
          operationId: discover.operationId,
          services: _sasServices(),
        ),
      );
      expect(loginSubscription.characteristicUuid, LibreUuids.sasLogin);

      final challengeWrite = _onlyAction<LibreWriteAction>(
        planner.recordSubscriptionEnabled(
          operationId: loginSubscription.operationId,
        ),
      );
      expect(challengeWrite.characteristicUuid, LibreUuids.sasLogin);
      expect(challengeWrite.value.bytes, const <int>[0x20]);
      expect(
        challengeWrite.purpose,
        LibreLiveWritePurpose.gen2ChallengeRequest,
      );
      expect(
        challengeWrite.writeModeEvidence,
        LibreWriteModeEvidence.unresolvedForTarget,
      );
      expect(challengeWrite.toString(), isNot(contains('0x20')));

      final waitingForChallenge = planner.recordWriteCompleted(
        operationId: challengeWrite.operationId,
      );
      expect(waitingForChallenge.actions, isEmpty);
      expect(planner.phase, LibreProtocolPhase.awaitingChallenge);

      final challenge = List<int>.generate(14, (index) => index);
      final createRequest =
          _onlyAction<LibreCreateGen2AuthenticatedRequestAction>(
            planner.recordNotification(
              LibreLiveNotification(
                characteristicUuid: 'f001',
                value: challenge,
                observedAt: Duration.zero,
              ),
            ),
          );
      expect(createRequest.challenge.bytes, challenge);
      expect(createRequest.toString(), isNot(contains('[0, 1')));

      final authenticatedRequest = LibreGen2AuthenticatedRequest(
        List<int>.generate(19, (index) => 0x80 + index),
      );
      final authenticatedWrite = _onlyAction<LibreWriteAction>(
        planner.provideGen2AuthenticatedRequest(
          operationId: createRequest.operationId,
          request: authenticatedRequest,
        ),
      );
      expect(
        authenticatedWrite.purpose,
        LibreLiveWritePurpose.gen2AuthenticatedRequest,
      );
      expect(authenticatedWrite.value.length, 19);

      final waitingForSession = planner.recordWriteCompleted(
        operationId: authenticatedWrite.operationId,
      );
      expect(waitingForSession.actions, isEmpty);
      expect(planner.phase, LibreProtocolPhase.awaitingSessionInformation);

      final firstSessionFragment = planner.recordNotification(
        LibreLiveNotification(
          characteristicUuid: LibreUuids.sasLogin,
          value: List<int>.generate(7, (index) => index),
          observedAt: const Duration(seconds: 1),
        ),
      );
      expect(firstSessionFragment.actions, isEmpty);

      final verifySession = _onlyAction<LibreVerifyGen2SessionAction>(
        planner.recordNotification(
          LibreLiveNotification(
            characteristicUuid: LibreUuids.sasLogin,
            value: List<int>.generate(18, (index) => index + 7),
            observedAt: const Duration(seconds: 2),
          ),
        ),
      );
      expect(verifySession.sessionInformation.length, 25);

      const session = _Session();
      final dataSubscription = _onlyAction<LibreSubscribeAction>(
        planner.acceptVerifiedGen2Session(
          operationId: verifySession.operationId,
          session: session,
        ),
      );
      expect(dataSubscription.characteristicUuid, LibreUuids.sasData);
      expect(planner.verifiedSession, same(session));

      final ready = _onlyAction<LibreStreamingReadyAction>(
        planner.recordSubscriptionEnabled(
          operationId: dataSubscription.operationId,
        ),
      );
      expect(ready.evidenceStatus, _targetUnverified);
      expect(planner.phase, LibreProtocolPhase.streaming);
    });

    test('emits encrypted composites without decrypting or parsing them', () {
      final planner = _streamingGen2Planner();
      final packet = List<int>.generate(46, (index) => index);

      planner.recordNotification(
        LibreLiveNotification(
          characteristicUuid: LibreUuids.sasData,
          value: packet.sublist(0, 20),
          observedAt: const Duration(seconds: 3),
        ),
      );
      planner.recordNotification(
        LibreLiveNotification(
          characteristicUuid: LibreUuids.sasData,
          value: packet.sublist(20, 38),
          observedAt: const Duration(seconds: 4),
        ),
      );
      final complete = planner.recordNotification(
        LibreLiveNotification(
          characteristicUuid: LibreUuids.sasData,
          value: packet.sublist(38),
          observedAt: const Duration(seconds: 5),
        ),
      );

      final composite = complete.events
          .whereType<LibreEncryptedCompositeEvent>()
          .single;
      expect(composite.value.bytes, packet);
      expect(composite.toString(), isNot(contains('[0, 1')));
      expect(complete.actions, isEmpty);
    });
  });

  group('Gen1 live handshake planner', () {
    test('requires externally constructed authorization before any write', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.gen1),
      );
      final connect = _onlyAction<LibreConnectAction>(planner.begin());
      final discover = _onlyAction<LibreDiscoverTopologyAction>(
        planner.recordConnected(operationId: connect.operationId),
      );
      final authorize = _onlyAction<LibreCreateGen1AuthorizationAction>(
        planner.recordTopology(
          operationId: discover.operationId,
          services: _sasServices(),
        ),
      );

      expect(
        planner.phase,
        LibreProtocolPhase.awaitingGen1ExternalAuthorization,
      );
      expect(planner.pendingAction, isNot(isA<LibreWriteAction>()));

      final write = _onlyAction<LibreWriteAction>(
        planner.provideGen1Authorization(
          operationId: authorize.operationId,
          request: LibreGen1AuthorizationRequest(const <int>[1, 2, 3]),
        ),
      );
      expect(write.purpose, LibreLiveWritePurpose.gen1Authorization);
      expect(write.characteristicUuid, LibreUuids.sasLogin);

      final subscribe = _onlyAction<LibreSubscribeAction>(
        planner.recordWriteCompleted(operationId: write.operationId),
      );
      expect(subscribe.characteristicUuid, LibreUuids.sasData);
    });
  });

  group('fail-closed boundaries', () {
    test('rejects unknown generation before connection', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.unknown),
      );

      final update = planner.begin();

      expect(update.actions, isEmpty);
      expect(planner.isFailed, isTrue);
      expect(
        update.events.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.unsupportedSecurityGeneration,
      );
    });

    test('rejects GKS topology without producing a write', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.gen2),
      );
      final connect = _onlyAction<LibreConnectAction>(planner.begin());
      final discover = _onlyAction<LibreDiscoverTopologyAction>(
        planner.recordConnected(operationId: connect.operationId),
      );

      final update = planner.recordTopology(
        operationId: discover.operationId,
        services: <LibreGattServiceSnapshot>[
          LibreGattServiceSnapshot(uuid: LibreUuids.gksDataService),
        ],
      );

      expect(update.actions, isEmpty);
      expect(planner.isFailed, isTrue);
      expect(
        update.events.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.unsupportedTopology,
      );
    });

    test('rejects a non-19-byte authenticated request', () {
      expect(
        () => LibreGen2AuthenticatedRequest(List<int>.filled(18, 0)),
        throwsA(
          isA<LibreProtocolError>()
              .having(
                (error) => error.kind,
                'kind',
                LibreProtocolErrorKind.payloadLengthMismatch,
              )
              .having((error) => error.expectedLength, 'expectedLength', 19),
        ),
      );
    });

    test('stale acknowledgement fails closed and never retries', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.gen2),
      );
      final connect = _onlyAction<LibreConnectAction>(planner.begin());

      final update = planner.recordConnected(
        operationId: connect.operationId + 1,
      );

      expect(update.actions, isEmpty);
      expect(planner.isFailed, isTrue);
      expect(
        update.events.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.invalidTransition,
      );
    });

    test('disconnect clears pending security state without reconnecting', () {
      final planner = LibreLiveHandshakePlanner(
        bootstrap: const _Bootstrap(LibreSecurityGeneration.gen2),
      );
      final connect = _onlyAction<LibreConnectAction>(planner.begin());
      planner.recordConnected(operationId: connect.operationId);

      final update = planner.recordDisconnected();

      expect(update.actions, isEmpty);
      expect(planner.pendingAction, isNull);
      expect(planner.verifiedSession, isNull);
      expect(planner.phase, LibreProtocolPhase.disconnected);
      expect(update.events.whereType<LibreDisconnectedEvent>(), hasLength(1));
    });
  });

  test('opaque boundary types redact all protocol values', () {
    final gen1 = LibreGen1AuthorizationRequest(const <int>[222, 173]);
    final gen2 = LibreGen2AuthenticatedRequest(List<int>.filled(19, 171));
    final notification = LibreLiveNotification(
      characteristicUuid: LibreUuids.sasLogin,
      value: const <int>[222, 173],
      observedAt: Duration.zero,
    );

    expect(gen1.toString(), isNot(contains('222')));
    expect(gen2.toString(), isNot(contains('171')));
    expect(notification.toString(), isNot(contains('222')));
  });
}

const LibreEvidenceStatus _targetUnverified =
    LibreEvidenceStatus.referenceVerifiedTargetUnverified;

final class _Bootstrap implements LibreStreamingBootstrapContext {
  const _Bootstrap(this.generation);

  @override
  final LibreSecurityGeneration generation;
}

final class _Session implements LibreVerifiedSessionContext {
  const _Session();
}

List<LibreGattServiceSnapshot> _sasServices() {
  return <LibreGattServiceSnapshot>[
    LibreGattServiceSnapshot(
      uuid: LibreUuids.sasService,
      characteristicUuids: const <String>[
        LibreUuids.sasLogin,
        LibreUuids.sasData,
      ],
    ),
  ];
}

T _onlyAction<T extends LibreLiveAction>(LibreLivePlanUpdate update) {
  expect(update.actions, hasLength(1));
  return update.actions.single as T;
}

LibreLiveHandshakePlanner _streamingGen2Planner() {
  final planner = LibreLiveHandshakePlanner(
    bootstrap: const _Bootstrap(LibreSecurityGeneration.gen2),
  );
  final connect = _onlyAction<LibreConnectAction>(planner.begin());
  final discover = _onlyAction<LibreDiscoverTopologyAction>(
    planner.recordConnected(operationId: connect.operationId),
  );
  final loginSubscription = _onlyAction<LibreSubscribeAction>(
    planner.recordTopology(
      operationId: discover.operationId,
      services: _sasServices(),
    ),
  );
  final challengeWrite = _onlyAction<LibreWriteAction>(
    planner.recordSubscriptionEnabled(
      operationId: loginSubscription.operationId,
    ),
  );
  planner.recordWriteCompleted(operationId: challengeWrite.operationId);
  final createRequest = _onlyAction<LibreCreateGen2AuthenticatedRequestAction>(
    planner.recordNotification(
      LibreLiveNotification(
        characteristicUuid: LibreUuids.sasLogin,
        value: List<int>.filled(14, 1),
        observedAt: Duration.zero,
      ),
    ),
  );
  final authenticatedWrite = _onlyAction<LibreWriteAction>(
    planner.provideGen2AuthenticatedRequest(
      operationId: createRequest.operationId,
      request: LibreGen2AuthenticatedRequest(List<int>.filled(19, 2)),
    ),
  );
  planner.recordWriteCompleted(operationId: authenticatedWrite.operationId);
  planner.recordNotification(
    LibreLiveNotification(
      characteristicUuid: LibreUuids.sasLogin,
      value: List<int>.filled(7, 3),
      observedAt: const Duration(seconds: 1),
    ),
  );
  final verify = _onlyAction<LibreVerifyGen2SessionAction>(
    planner.recordNotification(
      LibreLiveNotification(
        characteristicUuid: LibreUuids.sasLogin,
        value: List<int>.filled(18, 4),
        observedAt: const Duration(seconds: 2),
      ),
    ),
  );
  final dataSubscription = _onlyAction<LibreSubscribeAction>(
    planner.acceptVerifiedGen2Session(
      operationId: verify.operationId,
      session: const _Session(),
    ),
  );
  planner.recordSubscriptionEnabled(operationId: dataSubscription.operationId);
  return planner;
}
