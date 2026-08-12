import 'package:cgm_core/cgm_core.dart';

import 'demo_driver.dart';
import 'mock_scenarios.dart';

/// Initial mock scenario for web/demo builds, e.g.
/// `--dart-define=OG_SCENARIO=activeHigh`. Unknown/empty values fall back to
/// [MockScenario.activeNormal].
const String kOgScenario = String.fromEnvironment('OG_SCENARIO');

CgmDriver buildPlatformDriver() =>
    DemoCgmDriver(initialScenario: MockScenario.fromId(kOgScenario));
