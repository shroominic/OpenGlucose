import 'errors.dart';
import 'model.dart';
import 'topology.dart';

/// Immutable protocol bytes whose string form is always redacted.
final class LibreOpaqueBytes {
  LibreOpaqueBytes(Iterable<int> bytes) : bytes = _validatedBytes(bytes);

  final List<int> bytes;

  int get length => bytes.length;

  @override
  String toString() => 'LibreOpaqueBytes(length: $length, data: <redacted>)';
}

List<int> _validatedBytes(Iterable<int> bytes) {
  final snapshot = List<int>.of(bytes);
  for (final byte in snapshot) {
    if (byte < 0 || byte > 0xff) {
      throw const LibreProtocolError(
        kind: LibreProtocolErrorKind.invalidPayloadByte,
      );
    }
  }
  return List<int>.unmodifiable(snapshot);
}

sealed class LibreProtocolEvent {
  const LibreProtocolEvent();

  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;
}

final class LibrePhaseChangedEvent extends LibreProtocolEvent {
  const LibrePhaseChangedEvent({
    required this.previous,
    required this.current,
    required this.generation,
  });

  final LibreProtocolPhase previous;
  final LibreProtocolPhase current;
  final LibreSecurityGeneration generation;
}

final class LibreTopologyAcceptedEvent extends LibreProtocolEvent {
  const LibreTopologyAcceptedEvent(this.classification);

  final LibreTopologyClassification classification;
}

final class LibreFragmentAcceptedEvent extends LibreProtocolEvent {
  const LibreFragmentAcceptedEvent({
    required this.kind,
    required this.fragmentIndex,
    required this.fragmentLength,
    required this.receivedLength,
  });

  final LibreAssemblyKind kind;
  final int fragmentIndex;
  final int fragmentLength;
  final int receivedLength;
}

final class LibreGen2ChallengeEvent extends LibreProtocolEvent {
  const LibreGen2ChallengeEvent(this.value);

  final LibreOpaqueBytes value;

  @override
  String toString() => 'LibreGen2ChallengeEvent(value: $value)';
}

final class LibreGen2SessionInformationEvent extends LibreProtocolEvent {
  const LibreGen2SessionInformationEvent(this.value);

  final LibreOpaqueBytes value;

  @override
  String toString() => 'LibreGen2SessionInformationEvent(value: $value)';
}

final class LibreEncryptedCompositeEvent extends LibreProtocolEvent {
  const LibreEncryptedCompositeEvent(this.value);

  final LibreOpaqueBytes value;

  @override
  String toString() => 'LibreEncryptedCompositeEvent(value: $value)';
}

final class LibreProtocolFailureEvent extends LibreProtocolEvent {
  const LibreProtocolFailureEvent(this.error);

  final LibreProtocolError error;
}

final class LibreDisconnectedEvent extends LibreProtocolEvent {
  const LibreDisconnectedEvent({required this.previousPhase});

  final LibreProtocolPhase previousPhase;
}
