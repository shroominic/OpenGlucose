import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'cgm_driver_registry.dart';

import 'health_state_store.dart';

import 'driver_factory_stub.dart'
    if (dart.library.io) 'driver_factory_io.dart'
    as platform;
import 'display_awake_gate.dart';

Future<void> configurePlatformPrivacyDefaults() =>
    platform.configurePlatformPrivacyDefaults();

Future<void> stopPlatformProtocolCapture() =>
    platform.stopPlatformProtocolCapture();

bool get isPlatformProtocolCaptureEnabled =>
    platform.platformProtocolCaptureEnabled;

bool get isPlatformLibreGen1StreamingEnabled =>
    platform.platformLibreGen1StreamingEnabled;

Future<DiscoveredSensor?> preparePlatformLibreGen1Connection() =>
    platform.preparePlatformLibreGen1Connection();

CgmDriver buildDefaultDriver({
  CbioPrivateStateStore? privateStateStore,
  HealthStateStore? healthStateStore,
}) => platform.buildPlatformDriver(
  privateStateStore: privateStateStore,
  healthStateStore: healthStateStore,
);

CbioSensorDriver? _privateDriver(CgmDriver driver) {
  final candidate = driver is CgmDriverRegistry
      ? driver.driverFor('cbio')
      : driver;
  return candidate is CbioSensorDriver ? candidate : null;
}

Future<void> prepareDefaultDriverTarget(
  CgmDriver driver,
  DiscoveredSensor sensor,
) async {
  if (sensor.driverId == 'cbio') {
    await _privateDriver(driver)?.prepareTarget(sensor);
  }
}

Future<void> flushDefaultDriverPrivateState(CgmDriver driver) async {
  await _privateDriver(driver)?.flushPrivateState();
}

String? defaultDriverHistoryNamespace(DiscoveredSensor sensor) =>
    sensor.driverId == 'cbio' ? 'openHealth.history.normalized.v1.' : null;

/// The display gate the app's scan window uses on this platform.
DisplayAwakeGate buildDefaultDisplayAwakeGate() =>
    platform.buildPlatformDisplayAwakeGate();
