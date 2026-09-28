import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  group('UUID classification', () {
    test('normalizes strict 16-bit and 128-bit UUIDs', () {
      expect(normalizeLibreUuid(' FDE3 '), LibreUuids.sasService);
      expect(
        normalizeLibreUuid('0000F001-0000-1000-8000-00805F9B34FB'),
        LibreUuids.sasLogin,
      );

      final login = classifyLibreUuid('f001');
      expect(login.family, LibreReferenceFamily.abbottSas);
      expect(login.role, LibreUuidRole.sasLoginCharacteristic);
    });

    test('rejects unsupported UUID syntax with a typed redacted error', () {
      expect(
        () => normalizeLibreUuid('not-a-uuid-with-device-data'),
        throwsA(
          isA<LibreProtocolError>().having(
            (error) => error.kind,
            'kind',
            LibreProtocolErrorKind.invalidUuid,
          ),
        ),
      );

      final error = LibreProtocolError(
        kind: LibreProtocolErrorKind.invalidUuid,
      );
      expect(error.toString(), isNot(contains('not-a-uuid')));
      expect(error.diagnosticCode, 'libre.uuid.invalid');
    });

    test('keeps an unknown valid UUID unknown', () {
      final value = classifyLibreUuid('12345678-1234-1234-1234-123456789abc');
      expect(value.family, LibreReferenceFamily.unknown);
      expect(value.role, LibreUuidRole.unknown);
      expect(value.isKnownReferenceUuid, isFalse);
    });
  });

  group('topology classification', () {
    test('classifies complete SAS map as target-unverified candidate', () {
      final classification = _sasTopology();

      expect(
        classification.kind,
        LibreTopologyKind.sasReferenceCandidateTargetUnverified,
      );
      expect(classification.family, LibreReferenceFamily.abbottSas);
      expect(classification.canSequenceSasReferenceOffline, isTrue);
      expect(
        classification.evidenceStatus,
        LibreEvidenceStatus.referenceVerifiedTargetUnverified,
      );
      expect(classification.toString(), contains('TargetUnverified'));
    });

    test('reports an incomplete SAS map without claiming compatibility', () {
      final classification = classifyLibreTopology(<LibreGattServiceSnapshot>[
        LibreGattServiceSnapshot(
          uuid: 'fde3',
          characteristicUuids: const <String>['f001'],
        ),
      ]);

      expect(
        classification.kind,
        LibreTopologyKind.incompleteSasReferenceTargetUnverified,
      );
      expect(classification.canSequenceSasReferenceOffline, isFalse);
      expect(classification.missingCharacteristicUuids, <String>[
        LibreUuids.sasData,
      ]);
      expect(
        () => classification.missingCharacteristicUuids.add('mutation'),
        throwsUnsupportedError,
      );
    });

    test('classifies the complete audited GKS map separately', () {
      final classification = classifyLibreTopology(<LibreGattServiceSnapshot>[
        LibreGattServiceSnapshot(
          uuid: LibreUuids.gksDataService,
          characteristicUuids: const <String>[
            LibreUuids.gksPatchControl,
            LibreUuids.gksStatus,
            LibreUuids.gksRealtimeGlucose,
            LibreUuids.gksHistoricGlucose,
            LibreUuids.gksClinicalData,
            LibreUuids.gksEventData,
            LibreUuids.gksFactoryData,
          ],
        ),
        LibreGattServiceSnapshot(
          uuid: LibreUuids.gksSecurityService,
          characteristicUuids: const <String>[
            LibreUuids.gksSecurityCommand,
            LibreUuids.gksChallenge,
            LibreUuids.gksCertificate,
          ],
        ),
      ]);

      expect(
        classification.kind,
        LibreTopologyKind.gksReferenceCandidateTargetUnverified,
      );
      expect(classification.family, LibreReferenceFamily.abbottGks);
      expect(classification.canSequenceSasReferenceOffline, isFalse);
    });

    test('fails closed for mixed reference families', () {
      final classification = classifyLibreTopology(<LibreGattServiceSnapshot>[
        LibreGattServiceSnapshot(
          uuid: 'fde3',
          characteristicUuids: const <String>['f001', 'f002'],
        ),
        LibreGattServiceSnapshot(uuid: LibreUuids.gksDataService),
      ]);

      expect(
        classification.kind,
        LibreTopologyKind.ambiguousReferenceTargetUnverified,
      );
      expect(classification.family, LibreReferenceFamily.unknown);
      expect(classification.canSequenceSasReferenceOffline, isFalse);
    });

    test('fails closed on invalid or duplicate topology entries', () {
      final invalid = classifyLibreTopology(<LibreGattServiceSnapshot>[
        LibreGattServiceSnapshot(uuid: 'invalid'),
      ]);
      final duplicate = classifyLibreTopology(<LibreGattServiceSnapshot>[
        LibreGattServiceSnapshot(uuid: 'fde3'),
        LibreGattServiceSnapshot(uuid: LibreUuids.sasService),
      ]);

      expect(invalid.kind, LibreTopologyKind.malformed);
      expect(invalid.errors.single.kind, LibreProtocolErrorKind.invalidUuid);
      expect(duplicate.kind, LibreTopologyKind.malformed);
      expect(
        duplicate.errors.single.kind,
        LibreProtocolErrorKind.malformedTopology,
      );
    });
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
