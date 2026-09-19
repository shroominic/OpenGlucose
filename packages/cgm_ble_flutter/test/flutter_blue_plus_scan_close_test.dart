import 'dart:async';

import 'package:cgm_ble_flutter/src/flutter_blue_plus_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
