/// Where a driver obtained descriptive model/version information.
///
/// This is provenance, not authentication or proof of compatible behavior.
enum CgmSensorVariantSource { unknown, deviceInformation, nfcPatchInfo }

/// Descriptive variant information, separate from routing and operation policy.
///
/// Null fields mean unknown, not a wildcard match. Do not derive a region from
/// the phone locale, a serial number, or an unverified product-name mapping.
/// Revision strings are opaque: they are not necessarily semantic versions.
///
/// Drivers publish this after their own identification checks. Reading it from
/// storage does not revalidate a device. It must never select a decoder, grant
/// activation/transfer authority, or replace an explicit compatibility gate.
/// Do not put serials, addresses, UIDs, keys, or raw packets in these fields.
final class CgmSensorVariant {
  const CgmSensorVariant({
    required this.protocolFamily,
    required this.source,
    this.model,
    this.variantCode,
    this.region,
    this.hardwareRevision,
    this.firmwareRevision,
    this.softwareRevision,
    this.securityGeneration,
  });

  /// The implementation's protocol family, not a claim of retail support.
  final String protocolFamily;
  final CgmSensorVariantSource source;
  final String? model;

  /// A reviewed, non-unique model discriminator, never a device identifier.
  final String? variantCode;
  final String? region;
  final String? hardwareRevision;
  final String? firmwareRevision;
  final String? softwareRevision;
  final String? securityGeneration;

  Map<String, Object?> toJson() => <String, Object?>{
    'protocolFamily': protocolFamily,
    'source': source.name,
    if (model != null) 'model': model,
    if (variantCode != null) 'variantCode': variantCode,
    if (region != null) 'region': region,
    if (hardwareRevision != null) 'hardwareRevision': hardwareRevision,
    if (firmwareRevision != null) 'firmwareRevision': firmwareRevision,
    if (softwareRevision != null) 'softwareRevision': softwareRevision,
    if (securityGeneration != null) 'securityGeneration': securityGeneration,
  };

  factory CgmSensorVariant.fromJson(Map<String, Object?> json) =>
      CgmSensorVariant(
        protocolFamily: _text(json['protocolFamily']) ?? 'unknown',
        source: CgmSensorVariantSource.values.firstWhere(
          (value) => value.name == json['source'],
          orElse: () => CgmSensorVariantSource.unknown,
        ),
        model: _text(json['model']),
        variantCode: _text(json['variantCode']),
        region: _text(json['region']),
        hardwareRevision: _text(json['hardwareRevision']),
        firmwareRevision: _text(json['firmwareRevision']),
        softwareRevision: _text(json['softwareRevision']),
        securityGeneration: _text(json['securityGeneration']),
      );

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 128 ||
        trimmed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    return trimmed;
  }

  @override
  String toString() => 'CgmSensorVariant(data: <redacted>)';
}
