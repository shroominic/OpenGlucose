import 'errors.dart';
import 'model.dart';

/// UUIDs observed in audited reference implementations.
///
/// These constants are capture classifiers. They are not compatibility claims
/// and must not be used by this package to initiate a scan or connection.
abstract final class LibreUuids {
  static const sasService = '0000fde3-0000-1000-8000-00805f9b34fb';
  static const sasLogin = '0000f001-0000-1000-8000-00805f9b34fb';
  static const sasData = '0000f002-0000-1000-8000-00805f9b34fb';

  static const gksDataService = '089810cc-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksPatchControl = '08981338-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksStatus = '08981482-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksRealtimeGlucose = '0898177a-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksHistoricGlucose = '0898195a-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksClinicalData = '08981ab8-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksEventData = '08981bee-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksFactoryData = '08981d24-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksSecurityService = '0898203a-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksSecurityCommand = '08982198-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksChallenge = '089822ce-ef89-11e9-81b4-2a2ae2dbcce4';
  static const gksCertificate = '089823fa-ef89-11e9-81b4-2a2ae2dbcce4';
}

final RegExp _shortUuidPattern = RegExp(r'^[0-9a-f]{4}$');
final RegExp _fullUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Converts a strict 16-bit or 128-bit UUID to lowercase 128-bit form.
///
/// Unsupported syntax fails with a typed error. It is not silently repaired.
String normalizeLibreUuid(String value) {
  final normalized = value.trim().toLowerCase();
  if (_shortUuidPattern.hasMatch(normalized)) {
    return '0000$normalized-0000-1000-8000-00805f9b34fb';
  }
  if (_fullUuidPattern.hasMatch(normalized)) {
    return normalized;
  }
  throw const LibreProtocolError(kind: LibreProtocolErrorKind.invalidUuid);
}

/// The conservative, audited-reference role of one UUID.
final class LibreUuidClassification {
  const LibreUuidClassification({
    required this.canonicalUuid,
    required this.family,
    required this.role,
  });

  final String canonicalUuid;
  final LibreReferenceFamily family;
  final LibreUuidRole role;

  bool get isKnownReferenceUuid => role != LibreUuidRole.unknown;
}

LibreUuidClassification classifyLibreUuid(String value) {
  final canonical = normalizeLibreUuid(value);
  final role = _knownRoles[canonical] ?? LibreUuidRole.unknown;
  final family = switch (role) {
    LibreUuidRole.sasService ||
    LibreUuidRole.sasLoginCharacteristic ||
    LibreUuidRole.sasDataCharacteristic => LibreReferenceFamily.abbottSas,
    LibreUuidRole.gksDataService ||
    LibreUuidRole.gksPatchControlCharacteristic ||
    LibreUuidRole.gksStatusCharacteristic ||
    LibreUuidRole.gksRealtimeGlucoseCharacteristic ||
    LibreUuidRole.gksHistoricGlucoseCharacteristic ||
    LibreUuidRole.gksClinicalDataCharacteristic ||
    LibreUuidRole.gksEventDataCharacteristic ||
    LibreUuidRole.gksFactoryDataCharacteristic ||
    LibreUuidRole.gksSecurityService ||
    LibreUuidRole.gksSecurityCommandCharacteristic ||
    LibreUuidRole.gksChallengeCharacteristic ||
    LibreUuidRole.gksCertificateCharacteristic =>
      LibreReferenceFamily.abbottGks,
    LibreUuidRole.unknown => LibreReferenceFamily.unknown,
  };
  return LibreUuidClassification(
    canonicalUuid: canonical,
    family: family,
    role: role,
  );
}

const Map<String, LibreUuidRole> _knownRoles = <String, LibreUuidRole>{
  LibreUuids.sasService: LibreUuidRole.sasService,
  LibreUuids.sasLogin: LibreUuidRole.sasLoginCharacteristic,
  LibreUuids.sasData: LibreUuidRole.sasDataCharacteristic,
  LibreUuids.gksDataService: LibreUuidRole.gksDataService,
  LibreUuids.gksPatchControl: LibreUuidRole.gksPatchControlCharacteristic,
  LibreUuids.gksStatus: LibreUuidRole.gksStatusCharacteristic,
  LibreUuids.gksRealtimeGlucose: LibreUuidRole.gksRealtimeGlucoseCharacteristic,
  LibreUuids.gksHistoricGlucose: LibreUuidRole.gksHistoricGlucoseCharacteristic,
  LibreUuids.gksClinicalData: LibreUuidRole.gksClinicalDataCharacteristic,
  LibreUuids.gksEventData: LibreUuidRole.gksEventDataCharacteristic,
  LibreUuids.gksFactoryData: LibreUuidRole.gksFactoryDataCharacteristic,
  LibreUuids.gksSecurityService: LibreUuidRole.gksSecurityService,
  LibreUuids.gksSecurityCommand: LibreUuidRole.gksSecurityCommandCharacteristic,
  LibreUuids.gksChallenge: LibreUuidRole.gksChallengeCharacteristic,
  LibreUuids.gksCertificate: LibreUuidRole.gksCertificateCharacteristic,
};
