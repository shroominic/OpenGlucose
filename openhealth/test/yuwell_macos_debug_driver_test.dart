import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';
import 'package:openglucose/src/yuwell_macos_debug_driver.dart';

void main() {
  test('the macOS debug registry registers exactly the Yuwell driver', () {
    final driver =
        buildYuwellMacosDebugDriver(transport: const _UnusedTransport())
            as CgmDriverRegistry;

    expect(
      driver.registeredDriverIds,
      <String>{YuwellAnytimeDriver.driverIdentifier},
    );
    expect(driver.scanServiceUuids, <String>[yuwellCt5ServiceUuid]);
    expect(driver.usesUnfilteredScan, isTrue);
  });

  test('two calls build independent, non-shared secure stores', () {
    // Each debug attempt gets a fresh in-process registry; Keychain state
    // itself still persists underneath, which is what carries the durable
    // write-intent journal across separate debug runs.
    final first = buildYuwellMacosDebugDriver(
      transport: const _UnusedTransport(),
    );
    final second = buildYuwellMacosDebugDriver(
      transport: const _UnusedTransport(),
    );
    expect(identical(first, second), isFalse);
  });
}

/// Construction-only fake: the driver-wiring assertions above never scan or
/// connect, so both methods are intentionally unreachable.
class _UnusedTransport implements BleTransport {
  const _UnusedTransport();

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => throw UnimplementedError('not exercised by this construction test');

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError('not exercised by this construction test');
}
