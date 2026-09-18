import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  group('Gen1 offline state machine', () {
    test('sequences external authorization and strict composite framing', () {
      final machine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen1,
      );
      final events = <LibreProtocolEvent>[];

      events.addAll(machine.process(const LibreConnectedObservation()));
      events.addAll(machine.process(LibreTopologyObservation(_sasTopology())));
      expect(
        machine.phase,
        LibreProtocolPhase.awaitingGen1ExternalAuthorization,
      );
      events.addAll(
        machine.process(
          const LibreGen1ExternalAuthorizationVerifiedObservation(),
        ),
      );
      events.addAll(machine.process(const LibreDataSubscriptionObservation()));
      expect(machine.phase, LibreProtocolPhase.streaming);

      final packet = List<int>.generate(46, (index) => index);
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f002',
            value: packet.sublist(0, 20),
            observedAt: Duration.zero,
          ),
        ),
      );
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f002',
            value: packet.sublist(20, 38),
            observedAt: const Duration(seconds: 1),
          ),
        ),
      );
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f002',
            value: packet.sublist(38),
            observedAt: const Duration(seconds: 2),
          ),
        ),
      );

      final complete = events.whereType<LibreEncryptedCompositeEvent>().single;
      expect(complete.value.bytes, packet);
      expect(complete.toString(), isNot(contains('[0, 1')));
      expect(
        events.every(
          (event) =>
              event.evidenceStatus ==
              LibreEvidenceStatus.referenceVerifiedTargetUnverified,
        ),
        isTrue,
      );
    });

    test('does not allow a Gen2 observation in the Gen1 branch', () {
      final machine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen1,
      );
      _connectAndClassify(machine);

      final events = machine.process(const LibreLoginSubscriptionObservation());

      expect(machine.phase, LibreProtocolPhase.failed);
      expect(
        events.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.invalidTransition,
      );
    });
  });

  group('Gen2 offline state machine', () {
    test('sequences challenge, 7+18 session information, and streaming', () {
      final machine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      final events = <LibreProtocolEvent>[];

      events.addAll(machine.process(const LibreConnectedObservation()));
      events.addAll(machine.process(LibreTopologyObservation(_sasTopology())));
      events.addAll(machine.process(const LibreLoginSubscriptionObservation()));
      events.addAll(
        machine.process(
          const LibreGen2ChallengeRequestRecordedObservation(encodedLength: 1),
        ),
      );
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: LibreUuids.sasLogin,
            value: List<int>.generate(14, (index) => index),
            observedAt: Duration.zero,
          ),
        ),
      );
      events.addAll(
        machine.process(
          const LibreGen2AuthenticatedRequestRecordedObservation(
            encodedLength: 19,
          ),
        ),
      );
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f001',
            value: List<int>.generate(7, (index) => index),
            observedAt: const Duration(seconds: 1),
          ),
        ),
      );
      events.addAll(
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f001',
            value: List<int>.generate(18, (index) => index + 7),
            observedAt: const Duration(seconds: 2),
          ),
        ),
      );

      expect(
        machine.phase,
        LibreProtocolPhase.awaitingExternalSessionVerification,
      );
      expect(
        events.whereType<LibreGen2ChallengeEvent>().single.value.length,
        14,
      );
      expect(
        events
            .whereType<LibreGen2SessionInformationEvent>()
            .single
            .value
            .length,
        25,
      );

      events.addAll(
        machine.process(const LibreGen2ExternalSessionVerifiedObservation()),
      );
      events.addAll(machine.process(const LibreDataSubscriptionObservation()));
      expect(machine.phase, LibreProtocolPhase.streaming);
      expect(
        machine.state.evidenceStatus,
        LibreEvidenceStatus.referenceVerifiedTargetUnverified,
      );
    });

    test('fails closed on wrong challenge request or response length', () {
      final challengeRequestMachine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      _connectAndClassify(challengeRequestMachine);
      challengeRequestMachine.process(
        const LibreLoginSubscriptionObservation(),
      );
      final recordedRequestFailure = challengeRequestMachine.process(
        const LibreGen2ChallengeRequestRecordedObservation(encodedLength: 2),
      );
      expect(challengeRequestMachine.phase, LibreProtocolPhase.failed);
      expect(
        recordedRequestFailure
            .whereType<LibreProtocolFailureEvent>()
            .single
            .error
            .expectedLength,
        1,
      );

      final challengeMachine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      _advanceToChallenge(challengeMachine);
      final challengeFailure = challengeMachine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f001',
          value: List<int>.filled(13, 0),
          observedAt: Duration.zero,
        ),
      );
      expect(challengeMachine.phase, LibreProtocolPhase.failed);
      expect(
        challengeFailure
            .whereType<LibreProtocolFailureEvent>()
            .single
            .error
            .expectedLength,
        14,
      );

      final requestMachine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      _advanceToAuthenticatedRequest(requestMachine);
      final requestFailure = requestMachine.process(
        const LibreGen2AuthenticatedRequestRecordedObservation(
          encodedLength: 18,
        ),
      );
      expect(requestMachine.phase, LibreProtocolPhase.failed);
      expect(
        requestFailure
            .whereType<LibreProtocolFailureEvent>()
            .single
            .error
            .expectedLength,
        19,
      );
    });

    test('fails closed on a malformed session-information fragment', () {
      final machine = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      _advanceToSessionInformation(machine);
      machine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f001',
          value: List<int>.filled(7, 0),
          observedAt: Duration.zero,
        ),
      );
      final failure = machine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f001',
          value: List<int>.filled(17, 0),
          observedAt: const Duration(seconds: 1),
        ),
      );

      final error = failure.whereType<LibreProtocolFailureEvent>().single.error;
      expect(error.kind, LibreProtocolErrorKind.fragmentLengthMismatch);
      expect(error.assemblyKind, LibreAssemblyKind.gen2SessionInformation);
      expect(error.isConnectionTerminal, isTrue);
      expect(machine.phase, LibreProtocolPhase.failed);
    });
  });

  group('fail-closed and recovery boundaries', () {
    test('unknown generation and GKS topology cannot enter SAS states', () {
      final unknown = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.unknown,
      );
      unknown.process(const LibreConnectedObservation());
      final unknownEvents = unknown.process(
        LibreTopologyObservation(_sasTopology()),
      );
      expect(unknown.phase, LibreProtocolPhase.failed);
      expect(
        unknownEvents.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.unsupportedSecurityGeneration,
      );

      final gen2 = LibreProtocolStateMachine(
        generation: LibreSecurityGeneration.gen2,
      );
      gen2.process(const LibreConnectedObservation());
      final gksEvents = gen2.process(
        LibreTopologyObservation(
          classifyLibreTopology(<LibreGattServiceSnapshot>[
            LibreGattServiceSnapshot(uuid: LibreUuids.gksDataService),
          ]),
        ),
      );
      expect(gen2.phase, LibreProtocolPhase.failed);
      expect(
        gksEvents.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.unsupportedTopology,
      );
    });

    test('composite mismatch and timeout discard data but stay streaming', () {
      final mismatchMachine = _streamingGen1Machine();
      mismatchMachine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f002',
          value: List<int>.filled(20, 0),
          observedAt: Duration.zero,
        ),
      );
      final mismatch = mismatchMachine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f002',
          value: List<int>.filled(8, 0),
          observedAt: const Duration(seconds: 1),
        ),
      );
      expect(mismatchMachine.phase, LibreProtocolPhase.streaming);
      expect(
        mismatch.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.fragmentLengthMismatch,
      );

      final timeoutMachine = _streamingGen1Machine();
      timeoutMachine.process(
        LibreNotificationObservation(
          characteristicUuid: 'f002',
          value: List<int>.filled(20, 0),
          observedAt: Duration.zero,
        ),
      );
      final timeout = timeoutMachine.process(
        const LibreTickObservation(Duration(seconds: 10)),
      );
      expect(timeoutMachine.phase, LibreProtocolPhase.streaming);
      expect(
        timeout.whereType<LibreProtocolFailureEvent>().single.error.kind,
        LibreProtocolErrorKind.fragmentTimeout,
      );
    });

    test(
      'disconnect clears state and requires an explicit fresh connection',
      () {
        final machine = _streamingGen1Machine();
        machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f002',
            value: List<int>.filled(20, 0),
            observedAt: const Duration(hours: 1),
          ),
        );

        final disconnected = machine.process(
          const LibreDisconnectedObservation(),
        );
        expect(machine.phase, LibreProtocolPhase.disconnected);
        expect(disconnected.whereType<LibreDisconnectedEvent>(), hasLength(1));

        machine.process(const LibreConnectedObservation());
        _classifyConnected(machine);
        machine.process(
          const LibreGen1ExternalAuthorizationVerifiedObservation(),
        );
        machine.process(const LibreDataSubscriptionObservation());
        final fresh = machine.process(
          LibreNotificationObservation(
            characteristicUuid: 'f002',
            value: List<int>.filled(20, 0),
            observedAt: Duration.zero,
          ),
        );
        expect(fresh.single, isA<LibreFragmentAcceptedEvent>());
      },
    );
  });
}

LibreTopologyClassification _sasTopology() {
  return classifyLibreTopology(<LibreGattServiceSnapshot>[
    LibreGattServiceSnapshot(
      uuid: 'fde3',
      characteristicUuids: const <String>['f001', 'f002'],
    ),
  ]);
}

void _connectAndClassify(LibreProtocolStateMachine machine) {
  machine.process(const LibreConnectedObservation());
  _classifyConnected(machine);
}

void _classifyConnected(LibreProtocolStateMachine machine) {
  machine.process(LibreTopologyObservation(_sasTopology()));
}

void _advanceToChallenge(LibreProtocolStateMachine machine) {
  _connectAndClassify(machine);
  machine.process(const LibreLoginSubscriptionObservation());
  machine.process(
    const LibreGen2ChallengeRequestRecordedObservation(encodedLength: 1),
  );
}

void _advanceToAuthenticatedRequest(LibreProtocolStateMachine machine) {
  _advanceToChallenge(machine);
  machine.process(
    LibreNotificationObservation(
      characteristicUuid: 'f001',
      value: List<int>.filled(14, 0),
      observedAt: Duration.zero,
    ),
  );
}

void _advanceToSessionInformation(LibreProtocolStateMachine machine) {
  _advanceToAuthenticatedRequest(machine);
  machine.process(
    const LibreGen2AuthenticatedRequestRecordedObservation(encodedLength: 19),
  );
}

LibreProtocolStateMachine _streamingGen1Machine() {
  final machine = LibreProtocolStateMachine(
    generation: LibreSecurityGeneration.gen1,
  );
  _connectAndClassify(machine);
  machine.process(const LibreGen1ExternalAuthorizationVerifiedObservation());
  machine.process(const LibreDataSubscriptionObservation());
  return machine;
}
