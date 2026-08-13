import 'package:cgm_core/cgm_core.dart';

import 'driver_factory_stub.dart'
    if (dart.library.io) 'driver_factory_io.dart'
    as platform;

Future<void> configurePlatformPrivacyDefaults() =>
    platform.configurePlatformPrivacyDefaults();

CgmDriver buildDefaultDriver() => platform.buildPlatformDriver();
