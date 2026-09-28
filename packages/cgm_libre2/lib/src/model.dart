/// The audited reference family associated with a UUID or GATT topology.
///
/// A family match is not evidence that a retail target is compatible.
enum LibreReferenceFamily { abbottSas, abbottGks, unknown }

/// The security branch selected by evidence outside this package.
///
/// Gen1 and Gen2 use the same observed SAS UUIDs. UUID or topology matching
/// must never be used to select this value.
enum LibreSecurityGeneration { gen1, gen2, unknown }

/// Libre 2-family models accepted by the strict Gen1 metadata parser.
///
/// A parsed model remains reference-verified and target-unverified. It is not
/// a retail compatibility claim.
enum LibreGen1Model { libre2, libre2Plus }

/// Closed integrity regions used by the offline Gen1 decryptors.
enum LibreIntegrityRegion { framHeader, framBody, framFooter, blePayload }

/// Evidence status for every state produced by this offline core.
enum LibreEvidenceStatus { referenceVerifiedTargetUnverified }

/// Closed state set for the offline Gen1/Gen2 sequence classifier.
enum LibreProtocolPhase {
  disconnected,
  awaitingTopology,
  awaitingGen1ExternalAuthorization,
  awaitingLoginSubscription,
  awaitingChallengeRequestRecord,
  awaitingChallenge,
  awaitingAuthenticatedRequestRecord,
  awaitingSessionInformation,
  awaitingExternalSessionVerification,
  awaitingDataSubscription,
  streaming,
  failed,
}

/// Known offline fragment profiles.
enum LibreAssemblyKind { gen2SessionInformation, encryptedComposite }

/// Roles for UUIDs verified only in the audited reference material.
enum LibreUuidRole {
  sasService,
  sasLoginCharacteristic,
  sasDataCharacteristic,
  gksDataService,
  gksPatchControlCharacteristic,
  gksStatusCharacteristic,
  gksRealtimeGlucoseCharacteristic,
  gksHistoricGlucoseCharacteristic,
  gksClinicalDataCharacteristic,
  gksEventDataCharacteristic,
  gksFactoryDataCharacteristic,
  gksSecurityService,
  gksSecurityCommandCharacteristic,
  gksChallengeCharacteristic,
  gksCertificateCharacteristic,
  unknown,
}
