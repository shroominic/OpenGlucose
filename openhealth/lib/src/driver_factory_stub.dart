import 'package:cgm_core/cgm_core.dart';

import 'demo_driver.dart';
import 'display_awake_gate.dart';
import 'mock_scenarios.dart';

/// Initial mock scenario for web/demo builds, e.g.
/// `--dart-define=OG_SCENARIO=activeHigh`. Unknown/empty values fall back to
/// [MockScenario.activeNormal].
const String kOgScenario = String.fromEnvironment('OG_SCENARIO');

Future<void> configurePlatformPrivacyDefaults() async {}

Future<void> stopPlatformProtocolCapture() async {}

bool get platformProtocolCaptureEnabled => false;

bool get platformLibreGen1StreamingEnabled => false;

Future<DiscoveredSensor?> preparePlatformLibreGen1Connection() async => null;

CgmDriver buildPlatformDriver() =>
    DemoCgmDriver(initialScenario: MockScenario.fromId(kOgScenario));

/// Web/demo builds have no display to hold and no unfiltered scan to protect.
DisplayAwakeGate buildPlatformDisplayAwakeGate() =>
    const NoopDisplayAwakeGate();
