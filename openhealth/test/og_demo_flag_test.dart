import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/driver_factory_io.dart';

void main() {
  group('OG_DEMO driver selection', () {
    test(
      'selects DemoCgmDriver when OG_DEMO is set, real driver otherwise',
      () {
        final driver = buildPlatformDriver();

        // `kOgDemo` is a compile-time constant from --dart-define=OG_DEMO.
        // Run with `flutter test --dart-define=OG_DEMO=true` to exercise the
        // demo branch; without the define, production behavior is asserted.
        if (kOgDemo) {
          expect(driver, isA<DemoCgmDriver>());
        } else {
          expect(driver, isA<CgmDriverRegistry>());
          // The GS1 driver is registered only when the build supplied the
          // vendor material its authenticated link needs, so a plain
          // `flutter test` run expects the AiDEX driver alone.
          expect(
            (driver as CgmDriverRegistry).registeredDriverIds,
            cbioCredentials.isConfigured
                ? const <String>{'aidex', 'cbio'}
                : const <String>{'aidex'},
          );
          expect(driver, isNot(isA<DemoCgmDriver>()));
        }
      },
    );
  });
}
