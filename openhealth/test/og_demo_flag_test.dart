import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/driver_factory_io.dart';

void main() {
  group('OG_DEMO driver selection', () {
    test('selects DemoCgmDriver when OG_DEMO is set, real driver otherwise', () {
      final CgmDriver driver = buildPlatformDriver();

      // `kOgDemo` is a compile-time constant from --dart-define=OG_DEMO.
      // Run with `flutter test --dart-define=OG_DEMO=true` to exercise the
      // demo branch; without the define, production behavior is asserted.
      if (kOgDemo) {
        expect(driver, isA<DemoCgmDriver>());
      } else {
        expect(driver, isA<AidexSensorDriver>());
        expect(driver, isNot(isA<DemoCgmDriver>()));
      }
    });
  });
}
