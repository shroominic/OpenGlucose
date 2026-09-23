import 'errors.dart';
import 'events.dart';
import 'fragment_assembler.dart';
import 'model.dart';
import 'topology.dart';
import 'uuid.dart';

/// Timing backed by audited reference evidence.
final class LibreProtocolTimingProfile {
  const LibreProtocolTimingProfile({
    this.encryptedCompositeFragmentTimeout = const Duration(seconds: 10),
    this.gen2SessionInformationFragmentTimeout,
  });

  /// The audited SAS reference discards an incomplete composite after 10 s.
  final Duration encryptedCompositeFragmentTimeout;

  /// No session-information timeout was established in the audited evidence.
  /// It is disabled unless an evidence owner supplies one explicitly.
  final Duration? gen2SessionInformationFragmentTimeout;

  static const referenceDefaults = LibreProtocolTimingProfile();
}

/// Snapshot of a reference-verified, target-unverified machine state.
final class LibreProtocolState {
  const LibreProtocolState({required this.phase, required this.generation});

  final LibreProtocolPhase phase;
  final LibreSecurityGeneration generation;

  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  @override
  String toString() =>
      'LibreProtocolState(phase: ${phase.name}, generation: ${generation.name}, '
      'evidence: ${evidenceStatus.name})';
}

sealed class LibreProtocolObservation {
  const LibreProtocolObservation();
}

/// Records an externally observed connection. It does not initiate one.
final class LibreConnectedObservation extends LibreProtocolObservation {
  const LibreConnectedObservation();
}

/// Records an offline topology classification.
final class LibreTopologyObservation extends LibreProtocolObservation {
  const LibreTopologyObservation(this.classification);

  final LibreTopologyClassification classification;
}

/// Records that a separate, reviewed Gen1 authorization boundary succeeded.
///
/// This contains no unlock bytes and cannot construct or send a write.
final class LibreGen1ExternalAuthorizationVerifiedObservation
    extends LibreProtocolObservation {
  const LibreGen1ExternalAuthorizationVerifiedObservation();
}

/// Records that F001 notifications were enabled by an external capture.
final class LibreLoginSubscriptionObservation extends LibreProtocolObservation {
  const LibreLoginSubscriptionObservation();
}

/// Records completion of the externally performed Gen2 challenge request.
///
/// This package deliberately does not expose the request bytes or a write API.
final class LibreGen2ChallengeRequestRecordedObservation
    extends LibreProtocolObservation {
  const LibreGen2ChallengeRequestRecordedObservation({
    required this.encodedLength,
  });

  final int encodedLength;
}

/// Records a notification already present in an offline capture.
final class LibreNotificationObservation extends LibreProtocolObservation {
  LibreNotificationObservation({
    required this.characteristicUuid,
    required Iterable<int> value,
    required this.observedAt,
  }) : value = List<int>.unmodifiable(value);

  final String characteristicUuid;
  final List<int> value;
  final Duration observedAt;

  @override
  String toString() =>
      'LibreNotificationObservation('
      'valueLength: ${value.length}, observedAt: $observedAt, data: <redacted>)';
}

/// Records only the length of an externally created authenticated request.
///
/// The core validates the reference length. It does not create, authenticate,
/// expose, or transmit the request.
final class LibreGen2AuthenticatedRequestRecordedObservation
    extends LibreProtocolObservation {
  const LibreGen2AuthenticatedRequestRecordedObservation({
    required this.encodedLength,
  });

  final int encodedLength;
}

/// Records that a separate cryptographic verifier accepted the Gen2 session.
///
/// No verifier, key, nonce, counter, or decryption API exists in this package.
final class LibreGen2ExternalSessionVerifiedObservation
    extends LibreProtocolObservation {
  const LibreGen2ExternalSessionVerifiedObservation();
}

/// Records that F002 notifications were enabled by an external capture.
final class LibreDataSubscriptionObservation extends LibreProtocolObservation {
  const LibreDataSubscriptionObservation();
}

/// Advances deterministic timeout checks without creating a timer.
final class LibreTickObservation extends LibreProtocolObservation {
  const LibreTickObservation(this.observedAt);

  final Duration observedAt;
}

/// Records a disconnect. Reconnection is never automatic.
final class LibreDisconnectedObservation extends LibreProtocolObservation {
  const LibreDisconnectedObservation();
}

/// Pure, offline sequence classifier for the audited SAS Gen1/Gen2 paths.
///
/// It consumes observations and emits typed events. It has no BLE transport,
/// NFC, crypto, activation, bonding, scan, connection, or RF write API.
final class LibreProtocolStateMachine {
  LibreProtocolStateMachine({
    required this.generation,
    LibreProtocolTimingProfile timing =
        LibreProtocolTimingProfile.referenceDefaults,
  }) : _sessionInformationAssembler =
           LibreFragmentAssembler.gen2SessionInformation(
             timeout: timing.gen2SessionInformationFragmentTimeout,
           ),
       _compositeAssembler = LibreFragmentAssembler.encryptedComposite(
         timeout: timing.encryptedCompositeFragmentTimeout,
       );

  final LibreSecurityGeneration generation;
  final LibreFragmentAssembler _sessionInformationAssembler;
  final LibreFragmentAssembler _compositeAssembler;

  LibreProtocolPhase _phase = LibreProtocolPhase.disconnected;

  LibreProtocolPhase get phase => _phase;
  LibreProtocolState get state =>
      LibreProtocolState(phase: _phase, generation: generation);
  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  List<LibreProtocolEvent> process(LibreProtocolObservation observation) {
    if (observation is LibreDisconnectedObservation) {
      return _disconnect();
    }
    if (_phase == LibreProtocolPhase.failed) {
      return _fail(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.invalidTransition,
        ),
      );
    }

    return switch (observation) {
      LibreConnectedObservation() => _connect(),
      LibreTopologyObservation(:final classification) => _acceptTopology(
        classification,
      ),
      LibreGen1ExternalAuthorizationVerifiedObservation() =>
        _acceptGen1Authorization(),
      LibreLoginSubscriptionObservation() => _acceptLoginSubscription(),
      LibreGen2ChallengeRequestRecordedObservation(:final encodedLength) =>
        _acceptChallengeRequestRecord(encodedLength),
      LibreNotificationObservation() => _acceptNotification(observation),
      LibreGen2AuthenticatedRequestRecordedObservation(:final encodedLength) =>
        _acceptAuthenticatedRequestRecord(encodedLength),
      LibreGen2ExternalSessionVerifiedObservation() =>
        _acceptExternalSessionVerification(),
      LibreDataSubscriptionObservation() => _acceptDataSubscription(),
      LibreTickObservation(:final observedAt) => _tick(observedAt),
      LibreDisconnectedObservation() => _disconnect(),
    };
  }

  List<LibreProtocolEvent> _connect() {
    if (_phase != LibreProtocolPhase.disconnected) {
      return _invalidTransition();
    }
    return _transition(LibreProtocolPhase.awaitingTopology);
  }

  List<LibreProtocolEvent> _acceptTopology(
    LibreTopologyClassification classification,
  ) {
    if (_phase != LibreProtocolPhase.awaitingTopology) {
      return _invalidTransition();
    }
    if (generation == LibreSecurityGeneration.unknown) {
      return _fail(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.unsupportedSecurityGeneration,
        ),
      );
    }
    if (classification.kind == LibreTopologyKind.malformed) {
      return _fail(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.malformedTopology,
        ),
      );
    }
    if (!classification.canSequenceSasReferenceOffline) {
      return _fail(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.unsupportedTopology,
        ),
      );
    }

    final next = switch (generation) {
      LibreSecurityGeneration.gen1 =>
        LibreProtocolPhase.awaitingGen1ExternalAuthorization,
      LibreSecurityGeneration.gen2 =>
        LibreProtocolPhase.awaitingLoginSubscription,
      LibreSecurityGeneration.unknown => throw StateError('unreachable'),
    };
    return <LibreProtocolEvent>[
      LibreTopologyAcceptedEvent(classification),
      ..._transition(next),
    ];
  }

  List<LibreProtocolEvent> _acceptGen1Authorization() {
    if (generation != LibreSecurityGeneration.gen1 ||
        _phase != LibreProtocolPhase.awaitingGen1ExternalAuthorization) {
      return _invalidTransition();
    }
    return _transition(LibreProtocolPhase.awaitingDataSubscription);
  }

  List<LibreProtocolEvent> _acceptLoginSubscription() {
    if (generation != LibreSecurityGeneration.gen2 ||
        _phase != LibreProtocolPhase.awaitingLoginSubscription) {
      return _invalidTransition();
    }
    return _transition(LibreProtocolPhase.awaitingChallengeRequestRecord);
  }

  List<LibreProtocolEvent> _acceptChallengeRequestRecord(int encodedLength) {
    if (generation != LibreSecurityGeneration.gen2 ||
        _phase != LibreProtocolPhase.awaitingChallengeRequestRecord) {
      return _invalidTransition();
    }
    if (encodedLength != 1) {
      return _fail(
        LibreProtocolError(
          kind: LibreProtocolErrorKind.payloadLengthMismatch,
          expectedLength: 1,
          actualLength: encodedLength,
        ),
      );
    }
    return _transition(LibreProtocolPhase.awaitingChallenge);
  }

  List<LibreProtocolEvent> _acceptAuthenticatedRequestRecord(
    int encodedLength,
  ) {
    if (generation != LibreSecurityGeneration.gen2 ||
        _phase != LibreProtocolPhase.awaitingAuthenticatedRequestRecord) {
      return _invalidTransition();
    }
    if (encodedLength != 19) {
      return _fail(
        LibreProtocolError(
          kind: LibreProtocolErrorKind.payloadLengthMismatch,
          expectedLength: 19,
          actualLength: encodedLength,
        ),
      );
    }
    return _transition(LibreProtocolPhase.awaitingSessionInformation);
  }

  List<LibreProtocolEvent> _acceptExternalSessionVerification() {
    if (generation != LibreSecurityGeneration.gen2 ||
        _phase != LibreProtocolPhase.awaitingExternalSessionVerification) {
      return _invalidTransition();
    }
    return _transition(LibreProtocolPhase.awaitingDataSubscription);
  }

  List<LibreProtocolEvent> _acceptDataSubscription() {
    if (_phase != LibreProtocolPhase.awaitingDataSubscription) {
      return _invalidTransition();
    }
    return _transition(LibreProtocolPhase.streaming);
  }

  List<LibreProtocolEvent> _acceptNotification(
    LibreNotificationObservation observation,
  ) {
    late final String characteristicUuid;
    try {
      characteristicUuid = normalizeLibreUuid(observation.characteristicUuid);
    } on LibreProtocolError catch (error) {
      return _fail(error);
    }

    if (_phase == LibreProtocolPhase.awaitingChallenge) {
      if (characteristicUuid != LibreUuids.sasLogin) {
        return _unexpectedCharacteristic();
      }
      if (observation.value.length != 14) {
        return _fail(
          LibreProtocolError(
            kind: LibreProtocolErrorKind.payloadLengthMismatch,
            expectedLength: 14,
            actualLength: observation.value.length,
          ),
        );
      }
      final value = _opaqueOrFailure(observation.value);
      if (value is LibreProtocolError) {
        return _fail(value);
      }
      return <LibreProtocolEvent>[
        LibreGen2ChallengeEvent(value as LibreOpaqueBytes),
        ..._transition(LibreProtocolPhase.awaitingAuthenticatedRequestRecord),
      ];
    }

    if (_phase == LibreProtocolPhase.awaitingSessionInformation) {
      if (characteristicUuid != LibreUuids.sasLogin) {
        return _unexpectedCharacteristic();
      }
      return _consumeSessionInformation(
        _sessionInformationAssembler.add(
          observation.value,
          observedAt: observation.observedAt,
        ),
      );
    }

    if (_phase == LibreProtocolPhase.streaming) {
      if (characteristicUuid != LibreUuids.sasData) {
        return _unexpectedCharacteristic();
      }
      return _consumeComposite(
        _compositeAssembler.add(
          observation.value,
          observedAt: observation.observedAt,
        ),
      );
    }

    return _invalidTransition();
  }

  List<LibreProtocolEvent> _tick(Duration observedAt) {
    if (_phase == LibreProtocolPhase.awaitingSessionInformation) {
      return _consumeSessionInformation(
        _sessionInformationAssembler.expire(observedAt: observedAt),
      );
    }
    if (_phase == LibreProtocolPhase.streaming) {
      return _consumeComposite(
        _compositeAssembler.expire(observedAt: observedAt),
      );
    }
    return _invalidTransition();
  }

  List<LibreProtocolEvent> _consumeSessionInformation(
    List<LibreAssemblyOutcome> outcomes,
  ) {
    final events = <LibreProtocolEvent>[];
    for (final outcome in outcomes) {
      switch (outcome) {
        case LibreAssemblyProgress():
          events.add(_progressEvent(outcome));
        case LibreAssemblyComplete(:final value):
          events.add(LibreGen2SessionInformationEvent(value));
          events.addAll(
            _transition(LibreProtocolPhase.awaitingExternalSessionVerification),
          );
        case LibreAssemblyFailure(:final error):
          events.addAll(_fail(error));
      }
    }
    return events;
  }

  List<LibreProtocolEvent> _consumeComposite(
    List<LibreAssemblyOutcome> outcomes,
  ) {
    final events = <LibreProtocolEvent>[];
    for (final outcome in outcomes) {
      switch (outcome) {
        case LibreAssemblyProgress():
          events.add(_progressEvent(outcome));
        case LibreAssemblyComplete(:final value):
          events.add(LibreEncryptedCompositeEvent(value));
        case LibreAssemblyFailure(:final error):
          events.addAll(_fail(error));
      }
    }
    return events;
  }

  LibreFragmentAcceptedEvent _progressEvent(LibreAssemblyProgress progress) {
    return LibreFragmentAcceptedEvent(
      kind: progress.kind,
      fragmentIndex: progress.fragmentIndex,
      fragmentLength: progress.fragmentLength,
      receivedLength: progress.receivedLength,
    );
  }

  Object _opaqueOrFailure(Iterable<int> value) {
    try {
      return LibreOpaqueBytes(value);
    } on LibreProtocolError catch (error) {
      return error;
    }
  }

  List<LibreProtocolEvent> _unexpectedCharacteristic() {
    return _fail(
      const LibreProtocolError(
        kind: LibreProtocolErrorKind.unexpectedCharacteristic,
      ),
    );
  }

  List<LibreProtocolEvent> _invalidTransition() {
    return _fail(
      const LibreProtocolError(kind: LibreProtocolErrorKind.invalidTransition),
    );
  }

  List<LibreProtocolEvent> _fail(LibreProtocolError error) {
    final contextual = error.withContext(phase: _phase, generation: generation);
    final events = <LibreProtocolEvent>[LibreProtocolFailureEvent(contextual)];
    if (contextual.isConnectionTerminal &&
        _phase != LibreProtocolPhase.failed) {
      events.addAll(_transition(LibreProtocolPhase.failed));
    }
    return events;
  }

  List<LibreProtocolEvent> _transition(LibreProtocolPhase next) {
    final previous = _phase;
    _phase = next;
    return <LibreProtocolEvent>[
      LibrePhaseChangedEvent(
        previous: previous,
        current: next,
        generation: generation,
      ),
    ];
  }

  List<LibreProtocolEvent> _disconnect() {
    final previous = _phase;
    _sessionInformationAssembler.reset();
    _compositeAssembler.reset();
    final events = <LibreProtocolEvent>[];
    if (_phase != LibreProtocolPhase.disconnected) {
      events.addAll(_transition(LibreProtocolPhase.disconnected));
    }
    events.add(LibreDisconnectedEvent(previousPhase: previous));
    return events;
  }
}
