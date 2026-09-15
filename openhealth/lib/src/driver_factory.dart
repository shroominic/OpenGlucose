import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'app_controller.dart';
import 'libre_nfc_history_tools.dart';
import 'sensor_history_repository.dart';

import 'driver_factory_stub.dart'
    if (dart.library.io) 'driver_factory_io.dart'
    as platform;

Future<void> configurePlatformPrivacyDefaults() =>
    platform.configurePlatformPrivacyDefaults();

Future<void> configurePlatformSensorHistory(
  LibreGen1ObservationStore observationStore,
) => platform.configurePlatformSensorHistory(observationStore);

Future<void> stopPlatformProtocolCapture() =>
    platform.stopPlatformProtocolCapture();

bool get isPlatformProtocolCaptureEnabled =>
    platform.platformProtocolCaptureEnabled;

bool get isPlatformLibreGen1StreamingEnabled =>
    platform.platformLibreGen1StreamingEnabled;

bool get isPlatformLibreGen1ReceiverRestoreEnabled =>
    platform.platformLibreGen1ReceiverRestoreEnabled;

Future<DiscoveredSensor?> preparePlatformLibreGen1Connection() =>
    platform.preparePlatformLibreGen1Connection();

CgmDriver buildDefaultDriver() => platform.buildPlatformDriver();

LibreNfcHistoryTools? createPlatformLibreNfcHistoryTools({
  required CgmAppController controller,
  required SensorHistoryRepository repository,
}) => platform.createPlatformLibreNfcHistoryTools(
  controller: controller,
  repository: repository,
);
