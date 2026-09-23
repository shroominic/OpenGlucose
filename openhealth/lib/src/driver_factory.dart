import 'package:cgm_core/cgm_core.dart';

import 'health_state_store.dart';

import 'driver_factory_stub.dart'
    if (dart.library.io) 'driver_factory_io.dart'
    as platform;

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

CgmDriver buildDefaultDriver(HealthStateStore healthStateStore) =>
    platform.buildPlatformDriver(healthStateStore);
