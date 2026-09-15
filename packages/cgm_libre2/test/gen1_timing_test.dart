import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

import 'support/gen1_timing_fixtures.dart';

void main() {
  final core = LibreGen1OfflineCore(
    uid: LibreGen1Uid.algorithmOrder([0, 17, 34, 51, 68, 85, 102, 119]),
    patchInfo: LibreGen1PatchInfo([0x9d, 8, 0x30, 1, 0x34, 0x12]),
  );

  for (final minute in [0, 1, 59, 60, 255, 256, 20160, 0xffff]) {
    test('BLE reports exact unsigned little-endian age $minute', () {
      final timing = parseLibreGen1BleTiming(
        core.decryptBle(blePacketAtMinute(minute)),
      );
      expect(timing.elapsedMinutes, minute);
      expect(timing.toString(), 'LibreGen1BleTiming(data: <redacted>)');
    });
  }

  test('CRC-invalid timing cannot enter the typed parser', () {
    final packet = blePacketAtMinute(61)..[42] ^= 1;
    expect(
      () => parseLibreGen1BleTiming(core.decryptBle(packet)),
      throwsA(isA<LibreProtocolError>()),
    );
  });
}
