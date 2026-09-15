import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';

import 'cgm_driver_registry.dart';
import 'yuwell_macos_secure_session_store.dart';

/// Builds the private macOS BLE debug registry for the Anytime 5P contest
/// path.
///
/// This is NOT part of `buildPlatformDriver` in `driver_factory_io.dart` and
/// is never reachable from a normal app build or from the Android
/// `OG_PROTOCOL_TRACE` capture path; it is wired only from
/// `yuwell_macos_debug_main.dart`. It mirrors the reviewed Android
/// debug-capture composition (`_buildCaptureRegistry`) but swaps the
/// Android-Keystore-only `YuwellSecureSessionStore` for the Keychain-backed
/// [YuwellMacosKeychainSessionStore]. The engineering-provisional output
/// policy is unchanged: only an authenticated, contiguous, post-warmup V1150
/// packed value can surface as a provisional `CgmReading`, and only from this
/// private debug composition.
///
/// [keyValueStore] defaults to the real Keychain. Pass
/// [YuwellMacosInMemoryKeyValueStore] only when this exact build cannot reach
/// the Keychain (e.g. an ad-hoc signature with no Team ID) — see its doc
/// comment for what that trades away.
CgmDriver buildYuwellMacosDebugDriver({
  BleTransport? transport,
  YuwellMacosKeyValueStore? keyValueStore,
}) {
  final resolvedTransport = transport ?? const FlutterBluePlusTransport();
  final secureStore = YuwellMacosKeychainSessionStore(
    keyValueStore: keyValueStore,
  );
  const discovery = YuwellAnytimeDiscovery();
  return CgmDriverRegistry(
    transport: resolvedTransport,
    registrations: <CgmDriverRegistration>[
      CgmDriverRegistration(
        driver: YuwellAnytimeDriver(
          resolvedTransport,
          credentialStore: secureStore,
          writeIntentStore: secureStore,
          glucoseOutputPolicy:
              YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
          discovery: discovery,
        ),
        scanServiceUuids: const <String>[yuwellCt5ServiceUuid],
        discover: discovery.mapScanResult,
        requiresUnfilteredScan: true,
      ),
    ],
  );
}
