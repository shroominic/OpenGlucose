import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';

import 'demo_driver.dart';
import 'mock_scenarios.dart';
import 'app_controller.dart';
import 'libre_nfc_history_tools.dart';
import 'sensor_history_repository.dart';

/// Initial mock scenario for web/demo builds, e.g.
/// `--dart-define=OG_SCENARIO=activeHigh`. Unknown/empty values fall back to
/// [MockScenario.activeNormal].
const String kOgScenario = String.fromEnvironment('OG_SCENARIO');

Future<void> configurePlatformPrivacyDefaults() async {}

Future<void> configurePlatformSensorHistory(
  LibreGen1ObservationStore observationStore,
) async {}

Future<void> stopPlatformProtocolCapture() async {}

bool get platformProtocolCaptureEnabled => false;

bool get platformLibreGen1StreamingEnabled => false;

bool get platformLibreGen1ReceiverRestoreEnabled => false;

Future<DiscoveredSensor?> preparePlatformLibreGen1Connection() async => null;

LibreNfcHistoryTools? createPlatformLibreNfcHistoryTools({
  required CgmAppController controller,
  required SensorHistoryRepository repository,
}) => null;

CgmDriver buildPlatformDriver() =>
    DemoCgmDriver(initialScenario: MockScenario.fromId(kOgScenario));
