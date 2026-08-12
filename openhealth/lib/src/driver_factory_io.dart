import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_core/cgm_core.dart';

import 'demo_driver.dart';

/// When built with `--dart-define=OG_DEMO=true`, native/simulator builds use the
/// in-memory [DemoCgmDriver] instead of the real BLE driver, so the app can be
/// exercised in the iOS simulator (which has no Bluetooth). Defaults to false,
/// so production builds are unchanged and keep using the real Aidex driver.
const bool kOgDemo = bool.fromEnvironment('OG_DEMO', defaultValue: false);

CgmDriver buildPlatformDriver() {
  if (kOgDemo) {
    return DemoCgmDriver();
  }
  return AidexSensorDriver(const FlutterBluePlusTransport());
}
