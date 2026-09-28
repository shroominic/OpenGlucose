import 'gen1_security.dart';
import 'model.dart';

/// Closed lifecycle states from the audited Gen1 FRAM reference.
enum LibreGen1LifecycleState {
  notActivated,
  warmingUp,
  active,
  expired,
  shutdown,
  failure,
  unknown,
}

/// A lifecycle classification from a CRC-verified decrypted FRAM value.
///
/// This value is read-only evidence. It does not authorize or prove the
/// success of activation, streaming enablement, or another state change.
final class LibreGen1LifecycleEvidence {
  const LibreGen1LifecycleEvidence._(this.state);

  final LibreGen1LifecycleState state;

  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  bool get authorizesStateChange => false;

  @override
  String toString() =>
      'LibreGen1LifecycleEvidence(state: ${state.name}, '
      'evidence: ${evidenceStatus.name}, source: <redacted>)';
}

/// Classifies the lifecycle byte of an already CRC-verified Gen1 FRAM value.
///
/// The private constructor of [LibreGen1DecryptedFram] keeps raw, encrypted,
/// partial, or CRC-invalid input outside this parser. Unknown byte values map
/// to [LibreGen1LifecycleState.unknown] without an exception.
LibreGen1LifecycleEvidence parseLibreGen1Lifecycle(
  LibreGen1DecryptedFram fram,
) {
  final state = switch (fram.value.bytes[4]) {
    0x01 => LibreGen1LifecycleState.notActivated,
    0x02 => LibreGen1LifecycleState.warmingUp,
    0x03 => LibreGen1LifecycleState.active,
    0x04 => LibreGen1LifecycleState.expired,
    0x05 => LibreGen1LifecycleState.shutdown,
    0x06 => LibreGen1LifecycleState.failure,
    _ => LibreGen1LifecycleState.unknown,
  };
  return LibreGen1LifecycleEvidence._(state);
}
