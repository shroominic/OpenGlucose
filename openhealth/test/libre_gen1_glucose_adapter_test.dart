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
      'lib/src/driver_factory.dart',
      'lib/src/driver_factory_io.dart',
      'lib/src/driver_factory_stub.dart',
      'lib/src/libre_gen1_receiver_composition.dart',
      'lib/src/libre_gen1_receiver_history_platform.dart',
      '../packages/cgm_libre2/lib/src/gen1_live_driver.dart',
      '../packages/cgm_libre2/pubspec.yaml',
    ]) {
      expect(
        File(file).readAsStringSync(),
        isNot(contains('cgm_libre2_glucose')),
      );
      expect(
        File(file).readAsStringSync(),
        isNot(contains('libre_gen1_glucose_adapter.dart')),
      );
    }
    final entry = File('lib/libre_glucose_debug_main.dart').readAsStringSync();
    String compact(String source) => source.replaceAll(RegExp(r'\s+'), ' ');
    final privateEntry = compact(entry);
    final factory = compact(
      File('lib/src/driver_factory_io.dart').readAsStringSync(),
    );
    final composition = compact(
      File('lib/src/libre_gen1_receiver_composition.dart').readAsStringSync(),
    );
    expect(entry, contains("import 'src/libre_gen1_glucose_adapter.dart'"));
    expect(
      privateEntry,
      contains('if (!kDebugMode) { throw UnsupportedError('),
    );
    expect(
      privateEntry.indexOf('if (!kDebugMode)'),
      lessThan(privateEntry.indexOf('if (kOgProtocolTrace)')),
    );
    expect(
      privateEntry,
      contains(
        'if (kOgProtocolTrace) { '
        'configurePrivateLibreGlucoseDecoder(PrivateLibreGlucoseDecoderProvider()); '
        '} else { configurePrivateRecorderFreeLibreGlucoseDecoder( '
        'PrivateLibreGlucoseDecoderProvider( '
        'readEvidence: LibreGen1ReceiverStore().readCalibrationEvidence, ), ); } '
        'await app.main();',
      ),
    );
    // Capture keeps its prior Android/debug/profile/trace pre-start gate.
    expect(
      factory,
      contains(
        'if (!platformLibreGen1StreamingEnabled || _protocolCaptureActive) { '
        'throw StateError(',
      ),
    );
    expect(
      factory,
      contains('kOgProtocolTrace && kDebugMode && Platform.isAndroid'),
    );
    expect(
      factory,
      contains(
        'platformProtocolCaptureEnabled && kOgProtocolCaptureLiveLibre && '
        'selectedProtocolCaptureProfile() == ProtocolCaptureProfile.libre',
      ),
    );
    // Recorder-free injection is explicit, pre-start, and cannot select demo
    // or any capture mix. Native absence must reject the private entry.
    expect(
      factory,
      contains('supported: kDebugMode && !kIsWeb && Platform.isAndroid'),
    );
    expect(
      factory,
      contains(
        'incompatibleMode: kOgDemo || kOgProtocolTrace || '
        'kOgProtocolCaptureLiveAidex || kOgProtocolCaptureLiveYuwell || '
        'kOgProtocolCaptureLiveLibre || _protocolCaptureActive || '
        '_protocolLibreGlucoseDecoderProvider != null, '
        'configurationStarted: _platformConfigurationStarted,',
      ),
    );
    expect(
      factory,
      contains(
        'if (!supported || incompatibleMode || configurationStarted || '
        '_provider != null) { throw StateError(',
      ),
    );
    expect(
      factory,
      contains(
        'requireAvailable: _privateRecorderFreeDecoder.provider != null',
      ),
    );
    expect(
      factory,
      contains(
        'if (_privateRecorderFreeDecoder.provider != null && '
        '_recorderFreeLibreReceiver == null) { throw StateError(',
      ),
    );
    expect(composition, contains('bool requireAvailable = false'));
    expect(composition, contains('if (requireAvailable) _unavailable();'));
    expect(composition, contains('glucoseDecoderProvider: decoderProvider'));
    expect(entry, contains('await app.main()'));
    expect(entry, isNot(contains('protocol_capture_main')));
    final main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('!controller.isMockDriver && !isPlatformProtocolCaptureEnabled'),
    );
  });

  test(
    'Android release workflow never opts into the private Libre decoder',
    () {
      final workflow = File(
        '../.github/workflows/release-android.yml',
      ).readAsStringSync();
      expect(workflow, contains('flutter build apk --release'));
      expect(workflow, isNot(contains('OG_PROTOCOL_CAPTURE_LIVE_LIBRE')));
      expect(workflow, isNot(contains('libre_glucose_debug_main.dart')));
      expect(workflow, isNot(contains('OG_PROTOCOL_TRACE')));
    },
  );
}
