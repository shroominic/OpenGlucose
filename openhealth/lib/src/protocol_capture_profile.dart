/// Compile-time profile for the debug-only passive protocol recorder.
///
/// A profile configures only the physical advertisement scan. It does not
/// select or register a production sensor driver and it does not authorize a
/// connection, GATT write, bond operation, or NFC transmission.
enum ProtocolCaptureProfile {
  libre(
    id: 'libre',
    physicalServiceUuids: <String>[
      '0000fde3-0000-1000-8000-00805f9b34fb',
    ],
  ),
  yuwellAnytimePassive(
    id: 'yuwell_anytime_passive',
    physicalServiceUuids: <String>[],
    usesUnfilteredScan: true,
  )
  ;

  const ProtocolCaptureProfile({
    required this.id,
    required this.physicalServiceUuids,
    this.usesUnfilteredScan = false,
  });

  final String id;
  final List<String> physicalServiceUuids;
  final bool usesUnfilteredScan;

  static ProtocolCaptureProfile parse(String value) => switch (value) {
    'libre' => ProtocolCaptureProfile.libre,
    'yuwell_anytime_passive' => ProtocolCaptureProfile.yuwellAnytimePassive,
    _ => throw UnsupportedError(
      'Unknown OG_PROTOCOL_CAPTURE_PROFILE. Protocol capture is disabled.',
    ),
  };
}

/// The existing Libre profile remains the explicit default.
///
/// The Yuwell profile must be selected in an Android debug build with:
/// `--dart-define=OG_PROTOCOL_CAPTURE_PROFILE=yuwell_anytime_passive`.
const String kOgProtocolCaptureProfile = String.fromEnvironment(
  'OG_PROTOCOL_CAPTURE_PROFILE',
  defaultValue: 'libre',
);

ProtocolCaptureProfile selectedProtocolCaptureProfile() =>
    ProtocolCaptureProfile.parse(kOgProtocolCaptureProfile);
