import 'dart:io';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_glucose_adapter.dart';

void main() {
  final bootstrap = LibreGen1StreamingBootstrap(
    bootstrapId: 'synthetic_receiver_1234',
    deviceId: 'AA:BB:CC:DD:EE:FF',
    uid: LibreGen1Uid.algorithmOrder([1, 2, 3, 4, 5, 6, 7, 0xe0]),
    initialPatchInfo: LibreGen1PatchInfo([0x9d, 0x08, 0x30, 0x01, 0, 0]),
    streamingBase: 1,
    lifecycle: LibreGen1LifecycleState.active,
  );

  test('missing calibration does not fabricate a decoder', () async {
    var reads = 0;
    final provider = PrivateLibreGlucoseDecoderProvider(
      readEvidence: (received) async {
        expect(identical(received, bootstrap), isTrue);
        reads++;
        return null;
      },
    );
    expect(await provider.prepare(bootstrap), isNull);
    expect(reads, 1);
  });

  test('native evidence failure is closed and does not escape', () async {
    final provider = PrivateLibreGlucoseDecoderProvider(
      readEvidence: (_) async => throw StateError('synthetic-private-message'),
    );
    expect(await provider.prepare(bootstrap), isNull);
  });

  test('normal entry and MIT driver do not import the GPL implementation', () {
    for (final file in [
      'lib/main.dart',
      'lib/src/driver_factory_io.dart',
      '../packages/cgm_libre2/lib/src/gen1_live_driver.dart',
      '../packages/cgm_libre2/pubspec.yaml',
    ]) {
      expect(
        File(file).readAsStringSync(),
        isNot(contains('cgm_libre2_glucose')),
      );
      expect(
        File(file).readAsStringSync(),
        isNot(contains("import 'src/libre_gen1_glucose_adapter.dart'")),
      );
    }
    final entry = File('lib/libre_glucose_debug_main.dart').readAsStringSync();
    expect(
      entry,
      contains('!kDebugMode || !platformLibreGen1StreamingEnabled'),
    );
    expect(entry, contains('await app.main()'));
    expect(entry, isNot(contains('protocol_capture_main')));
    final main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('!controller.isMockDriver && !isPlatformProtocolCaptureEnabled'),
    );
  });
}
