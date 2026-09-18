import 'package:cgm_core/cgm_core.dart';

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

CgmDriver buildDefaultDriver() => platform.buildPlatformDriver();

/// The display gate the app's scan window uses on this platform.
DisplayAwakeGate buildDefaultDisplayAwakeGate() =>
    platform.buildPlatformDisplayAwakeGate();
