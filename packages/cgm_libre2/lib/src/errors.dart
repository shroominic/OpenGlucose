import 'model.dart';

/// Machine-readable protocol failure categories.
enum LibreProtocolErrorKind {
  invalidUuid,
  malformedTopology,
  unsupportedTopology,
  unsupportedSecurityGeneration,
  invalidTransition,
  unexpectedCharacteristic,
  invalidPayloadByte,
  payloadLengthMismatch,
  unsupportedPatchInfo,
  invalidNumericRange,
  integrityCheckFailed,
  fragmentLengthMismatch,
  fragmentTimeout,
  invalidObservationTime,
  nonMonotonicObservation,
}

/// A typed, payload-free protocol error.
///
/// [toString] contains only closed enum names and byte counts. It never
/// includes a payload, device identifier, address, or native error message.
final class LibreProtocolError implements Exception {
  const LibreProtocolError({
    required this.kind,
    this.phase,
    this.generation,
    this.assemblyKind,
    this.expectedLength,
    this.actualLength,
    this.fragmentIndex,
    this.integrityRegion,
  });

  final LibreProtocolErrorKind kind;
  final LibreProtocolPhase? phase;
  final LibreSecurityGeneration? generation;
  final LibreAssemblyKind? assemblyKind;
  final int? expectedLength;
  final int? actualLength;
  final int? fragmentIndex;
  final LibreIntegrityRegion? integrityRegion;

  String get diagnosticCode => switch (kind) {
    LibreProtocolErrorKind.invalidUuid => 'libre.uuid.invalid',
    LibreProtocolErrorKind.malformedTopology => 'libre.topology.malformed',
    LibreProtocolErrorKind.unsupportedTopology => 'libre.topology.unsupported',
    LibreProtocolErrorKind.unsupportedSecurityGeneration =>
      'libre.generation.unsupported',
    LibreProtocolErrorKind.invalidTransition =>
      'libre.state.invalid_transition',
    LibreProtocolErrorKind.unexpectedCharacteristic =>
      'libre.notification.unexpected_characteristic',
    LibreProtocolErrorKind.invalidPayloadByte => 'libre.payload.invalid_byte',
    LibreProtocolErrorKind.payloadLengthMismatch =>
      'libre.payload.length_mismatch',
    LibreProtocolErrorKind.unsupportedPatchInfo =>
      'libre.patch_info.unsupported',
    LibreProtocolErrorKind.invalidNumericRange => 'libre.numeric.invalid_range',
    LibreProtocolErrorKind.integrityCheckFailed =>
      'libre.integrity.invalid_crc',
    LibreProtocolErrorKind.fragmentLengthMismatch =>
      'libre.fragment.length_mismatch',
    LibreProtocolErrorKind.fragmentTimeout => 'libre.fragment.timeout',
    LibreProtocolErrorKind.invalidObservationTime =>
      'libre.time.invalid_observation',
    LibreProtocolErrorKind.nonMonotonicObservation =>
      'libre.time.non_monotonic',
  };

  /// Whether a fresh connection boundary is required before more input.
  bool get isConnectionTerminal {
    final isCompositeAssembly =
        assemblyKind == LibreAssemblyKind.encryptedComposite;
    if (isCompositeAssembly &&
        (kind == LibreProtocolErrorKind.fragmentLengthMismatch ||
            kind == LibreProtocolErrorKind.fragmentTimeout ||
            kind == LibreProtocolErrorKind.invalidPayloadByte ||
            kind == LibreProtocolErrorKind.invalidObservationTime ||
            kind == LibreProtocolErrorKind.nonMonotonicObservation)) {
      return false;
    }
    return true;
  }

  LibreProtocolError withContext({
    LibreProtocolPhase? phase,
    LibreSecurityGeneration? generation,
    LibreAssemblyKind? assemblyKind,
  }) {
    return LibreProtocolError(
      kind: kind,
      phase: phase ?? this.phase,
      generation: generation ?? this.generation,
      assemblyKind: assemblyKind ?? this.assemblyKind,
      expectedLength: expectedLength,
      actualLength: actualLength,
      fragmentIndex: fragmentIndex,
      integrityRegion: integrityRegion,
    );
  }

  @override
  String toString() {
    return 'LibreProtocolError('
        'code: $diagnosticCode, '
        'phase: ${phase?.name ?? 'none'}, '
        'generation: ${generation?.name ?? 'none'}, '
        'assembly: ${assemblyKind?.name ?? 'none'}, '
        'expectedLength: ${expectedLength ?? -1}, '
        'actualLength: ${actualLength ?? -1}, '
        'fragmentIndex: ${fragmentIndex ?? -1}, '
        'integrityRegion: ${integrityRegion?.name ?? 'none'})';
  }
}
