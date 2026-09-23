import 'dart:async';

import 'package:cgm_ble_flutter/src/flutter_blue_plus_transport.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
// The plugin's native boundary is transitive; no new runtime dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'consumer cancellation stays bounded while native stop is pending',
    () async {
      final native = _DelayedScanPlatform();
      native.allowStart.complete();
      FlutterBluePlusPlatform.instance = native;
      final subscription = const FlutterBluePlusTransport().scan().listen(
        (_) {},
      );
      await native.startEntered.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(native.radioScanning, isTrue);

      final cancelled = subscription.cancel();
      await native.stopEntered.future.timeout(const Duration(seconds: 6));
      expect(native.radioScanning, isTrue);
      await cancelled.timeout(const Duration(seconds: 6));
      expect(native.radioScanning, isTrue);

      native.allowStop.complete();
      await native.stopFinished.future.timeout(const Duration(seconds: 1));
      expect(native.radioScanning, isFalse);
      expect(native.stopCalls, 1);
    },
  );

  test(
    'deadline closes during native start and late radio is stopped',
    () async {
      final native = _DelayedScanPlatform();
      FlutterBluePlusPlatform.instance = native;
      final done = Completer<void>();
      final subscription = const FlutterBluePlusTransport()
          .scan(timeout: const Duration(milliseconds: 20))
          .listen((_) {}, onDone: done.complete);

      await native.startEntered.future.timeout(const Duration(seconds: 1));
      await done.future.timeout(const Duration(seconds: 2));
      expect(native.radioScanning, isFalse);
      expect(native.stopEntered.isCompleted, isFalse);

      // The real plugin holds its scan mutex until native start returns.
      // Native stop must still reach a radio that becomes active after closure.
      native.allowStart.complete();
      await native.stopEntered.future.timeout(const Duration(seconds: 6));
      expect(native.radioScanning, isTrue);
      expect(fbp.FlutterBluePlus.isScanningNow, isFalse);
      native.allowStop.complete();
      await native.stopFinished.future.timeout(const Duration(seconds: 1));
      await subscription.cancel();
      expect(native.radioScanning, isFalse);
      expect(native.stopCalls, 1);
    },
  );

  test(
    'scan cleanup closes the caller stream when plugin futures never finish',
    () async {
      // A stopped radio can leave plugin futures pending forever. The caller's
      // stream must still end, and cancellation must still return, or the
      // nearby-sensor list hangs on "Looking for supported sensors".
      final controller = StreamController<int>();
      final never = Completer<void>().future;
      var closed = false;
      final subscription = controller.stream.listen(
        (_) {},
        onDone: () => closed = true,
      );

      await closeFlutterBluePlusScanResources(
        cancelResults: () => never,
        cancelScanning: () => never,
        awaitPendingStart: () => never,
        stopScan: () => never,
        closeController: controller.close,
        stepTimeout: const Duration(milliseconds: 50),
      ).timeout(
        const Duration(seconds: 1),
        onTimeout: () => fail('cleanup never returned'),
      );
      await subscription.cancel();

      expect(closed, isTrue);
    },
  );
}

final class _DelayedScanPlatform extends FlutterBluePlusPlatform {
  final startEntered = Completer<void>();
  final allowStart = Completer<void>();
  final stopEntered = Completer<void>();
  final allowStop = Completer<void>();
  final stopFinished = Completer<void>();
  bool radioScanning = false;
  int stopCalls = 0;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  @override
  Future<bool> startScan(BmScanSettings request) async {
    startEntered.complete();
    await allowStart.future;
    radioScanning = true;
    return true;
  }

  @override
  Future<bool> stopScan(BmStopScanRequest request) async {
    stopCalls += 1;
    stopEntered.complete();
    await allowStop.future;
    radioScanning = false;
    stopFinished.complete();
    return true;
  }
}
