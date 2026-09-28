import 'errors.dart';
import 'model.dart';
import 'uuid.dart';

/// An offline snapshot of one discovered GATT service.
final class LibreGattServiceSnapshot {
  LibreGattServiceSnapshot({
    required this.uuid,
    Iterable<String> characteristicUuids = const <String>[],
  }) : characteristicUuids = List<String>.unmodifiable(characteristicUuids);

  final String uuid;
  final List<String> characteristicUuids;
}

/// Conservative classification against audited reference topologies.
enum LibreTopologyKind {
  sasReferenceCandidateTargetUnverified,
  incompleteSasReferenceTargetUnverified,
  gksReferenceCandidateTargetUnverified,
  incompleteGksReferenceTargetUnverified,
  ambiguousReferenceTargetUnverified,
  malformed,
  unknown,
}

/// Result of classifying an offline GATT service map.
///
/// Even a complete match remains target-unverified. It does not establish a
/// retail model, firmware, security generation, or safe write sequence.
final class LibreTopologyClassification {
  LibreTopologyClassification._({
    required this.kind,
    required this.family,
    Iterable<String> missingServiceUuids = const <String>[],
    Iterable<String> missingCharacteristicUuids = const <String>[],
    Iterable<LibreProtocolError> errors = const <LibreProtocolError>[],
  }) : missingServiceUuids = List<String>.unmodifiable(missingServiceUuids),
       missingCharacteristicUuids = List<String>.unmodifiable(
         missingCharacteristicUuids,
       ),
       errors = List<LibreProtocolError>.unmodifiable(errors);

  final LibreTopologyKind kind;
  final LibreReferenceFamily family;
  final List<String> missingServiceUuids;
  final List<String> missingCharacteristicUuids;
  final List<LibreProtocolError> errors;

  LibreEvidenceStatus get evidenceStatus =>
      LibreEvidenceStatus.referenceVerifiedTargetUnverified;

  bool get canSequenceSasReferenceOffline =>
      kind == LibreTopologyKind.sasReferenceCandidateTargetUnverified &&
      family == LibreReferenceFamily.abbottSas &&
      missingServiceUuids.isEmpty &&
      missingCharacteristicUuids.isEmpty &&
      errors.isEmpty;

  @override
  String toString() {
    return 'LibreTopologyClassification('
        'kind: ${kind.name}, family: ${family.name}, '
        'missingServices: ${missingServiceUuids.length}, '
        'missingCharacteristics: ${missingCharacteristicUuids.length}, '
        'errors: ${errors.length}, evidence: ${evidenceStatus.name})';
  }
}

/// Classifies service topology without scanning, connecting, or doing I/O.
LibreTopologyClassification classifyLibreTopology(
  Iterable<LibreGattServiceSnapshot> services,
) {
  final normalized = <String, Set<String>>{};
  final errors = <LibreProtocolError>[];

  for (final service in services) {
    late final String serviceUuid;
    try {
      serviceUuid = normalizeLibreUuid(service.uuid);
    } on LibreProtocolError catch (error) {
      errors.add(error);
      continue;
    }
    if (normalized.containsKey(serviceUuid)) {
      errors.add(
        const LibreProtocolError(
          kind: LibreProtocolErrorKind.malformedTopology,
        ),
      );
      continue;
    }

    final characteristics = <String>{};
    for (final value in service.characteristicUuids) {
      try {
        final characteristicUuid = normalizeLibreUuid(value);
        if (!characteristics.add(characteristicUuid)) {
          errors.add(
            const LibreProtocolError(
              kind: LibreProtocolErrorKind.malformedTopology,
            ),
          );
        }
      } on LibreProtocolError catch (error) {
        errors.add(error);
      }
    }
    normalized[serviceUuid] = characteristics;
  }

  if (errors.isNotEmpty) {
    return LibreTopologyClassification._(
      kind: LibreTopologyKind.malformed,
      family: LibreReferenceFamily.unknown,
      errors: errors,
    );
  }

  final sasSeen = normalized.containsKey(LibreUuids.sasService);
  final gksSeen =
      normalized.containsKey(LibreUuids.gksDataService) ||
      normalized.containsKey(LibreUuids.gksSecurityService);
  if (sasSeen && gksSeen) {
    return LibreTopologyClassification._(
      kind: LibreTopologyKind.ambiguousReferenceTargetUnverified,
      family: LibreReferenceFamily.unknown,
    );
  }

  if (sasSeen) {
    final characteristics = normalized[LibreUuids.sasService]!;
    final missing = _missing(characteristics, const <String>[
      LibreUuids.sasLogin,
      LibreUuids.sasData,
    ]);
    return LibreTopologyClassification._(
      kind: missing.isEmpty
          ? LibreTopologyKind.sasReferenceCandidateTargetUnverified
          : LibreTopologyKind.incompleteSasReferenceTargetUnverified,
      family: LibreReferenceFamily.abbottSas,
      missingCharacteristicUuids: missing,
    );
  }

  if (gksSeen) {
    final missingServices = _missing(normalized.keys.toSet(), const <String>[
      LibreUuids.gksDataService,
      LibreUuids.gksSecurityService,
    ]);
    final missingCharacteristics = <String>[
      ..._missing(
        normalized[LibreUuids.gksDataService] ?? const <String>{},
        _gksDataCharacteristics,
      ),
      ..._missing(
        normalized[LibreUuids.gksSecurityService] ?? const <String>{},
        _gksSecurityCharacteristics,
      ),
    ];
    final complete = missingServices.isEmpty && missingCharacteristics.isEmpty;
    return LibreTopologyClassification._(
      kind: complete
          ? LibreTopologyKind.gksReferenceCandidateTargetUnverified
          : LibreTopologyKind.incompleteGksReferenceTargetUnverified,
      family: LibreReferenceFamily.abbottGks,
      missingServiceUuids: missingServices,
      missingCharacteristicUuids: missingCharacteristics,
    );
  }

  return LibreTopologyClassification._(
    kind: LibreTopologyKind.unknown,
    family: LibreReferenceFamily.unknown,
  );
}

List<String> _missing(Set<String> actual, List<String> expected) {
  return <String>[
    for (final value in expected)
      if (!actual.contains(value)) value,
  ];
}

const List<String> _gksDataCharacteristics = <String>[
  LibreUuids.gksPatchControl,
  LibreUuids.gksStatus,
  LibreUuids.gksRealtimeGlucose,
  LibreUuids.gksHistoricGlucose,
  LibreUuids.gksClinicalData,
  LibreUuids.gksEventData,
  LibreUuids.gksFactoryData,
];

const List<String> _gksSecurityCharacteristics = <String>[
  LibreUuids.gksSecurityCommand,
  LibreUuids.gksChallenge,
  LibreUuids.gksCertificate,
];
