import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/driver_factory.dart' as driver_factory;
import 'package:openglucose/src/driver_factory_stub.dart' as web_factory;
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/sensor_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default and web history tools are absent without any I/O', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = _NoIoHealthStateStore();
    final repository = SensorHistoryRepository(store);
    final controller = CgmAppController(
      preferences: preferences,
      driver: DemoCgmDriver(),
      healthStateStore: store,
      historyRepository: repository,
    );
    addTearDown(controller.dispose);
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'com.openglucose/protocol_capture',
      'com.openglucose/protocol_capture_events',
      'com.openglucose/libre2',
      'com.openglucose/libre2_receiver',
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        throw StateError(
          'History tool construction must not call native code.',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    expect(driver_factory.isPlatformProtocolCaptureEnabled, isFalse);
    expect(driver_factory.isPlatformLibreGen1StreamingEnabled, isFalse);
    expect(
      driver_factory.createPlatformLibreNfcHistoryTools(
        controller: controller,
        repository: repository,
      ),
      isNull,
    );
    expect(
      web_factory.createPlatformLibreNfcHistoryTools(
        controller: controller,
        repository: repository,
      ),
      isNull,
    );
    await Future<void>.value();
    expect(calls, isEmpty);
    expect(store.operations, 0);
  });

  test('normal and recorder-free source graphs contain no glucose decoder', () {
    final dependencies = _localDependencies([
      'lib/main.dart',
      'lib/src/driver_factory.dart',
      'lib/src/driver_factory_io.dart',
      'lib/src/driver_factory_stub.dart',
      'lib/src/libre_gen1_receiver_composition.dart',
    ]);
    expect(dependencies, contains('lib/src/libre_gen1_fresh_nfc_history.dart'));
    expect(dependencies, contains('lib/src/libre_nfc_history_tools.dart'));
    expect(
      dependencies,
      isNot(contains('lib/src/libre_gen1_glucose_adapter.dart')),
    );
    expect(dependencies, isNot(contains('lib/libre_glucose_debug_main.dart')));
    final privateEntry = _compact(_read('lib/libre_glucose_debug_main.dart'));
    expect(
      privateEntry,
      contains("import 'src/libre_gen1_glucose_adapter.dart'"),
    );
    expect(
      privateEntry,
      contains('if (!kDebugMode)'),
    );
    expect(privateEntry, contains('if (kOgProtocolTrace)'));
    expect(
      privateEntry,
      contains('configurePrivateRecorderFreeLibreGlucoseDecoder('),
    );
    expect(
      privateEntry,
      contains(
        'readEvidence: LibreGen1ReceiverStore().readCalibrationEvidence',
      ),
    );
  });

  test(
    'history factory separates private capture and receiver lazy operations',
    () {
      final source = _read('lib/src/driver_factory_io.dart');
      final body = _compact(
        _section(
          source,
          'LibreNfcHistoryTools? createPlatformLibreNfcHistoryTools(',
          'Future<DiscoveredSensor?> preparePlatformLibreGen1Connection()',
        ),
      );
      expect(
        body,
        contains(
          'if (!platformLibreGen1StreamingEnabled || !_protocolCaptureActive || '
          '_protocolLibreDriver == null || decoder == null || '
          'decoder is! LibreGen1NfcHistoryDecoder) { return null; }',
        ),
      );
      expect(body, contains('if (!kOgProtocolTrace && receiver != null)'));
      expect(body, contains('return receiver.createHistoryTools('));
      expect(
        body,
        contains('readBootstrap: LibreGen1SecureStore().readBootstrap,'),
      );
      expect(
        body,
        contains('resumeConnection: controller.resumeLibreHistoryConnection,'),
      );
      expect(body, contains('createSync: () => LibreNfcHistorySync('));
      expect(body, contains('controller: controller, repository: repository,'));
      expect(body, contains('allowActivationProof: false,'));
      expect(body, contains('allowTerminalReadRevocation: true,'));
      expect(body, contains('reader: LibreGen1FreshNfcHistoryReader(),'));
      for (final eagerOperation in [
        '.readBootstrap(',
        '.readDecoded(',
        '.retryConnection(',
        '.start(',
        'invokeMethod',
        'readLibreGen1CalibrationEvidence',
      ]) {
        expect(body, isNot(contains(eagerOperation)));
      }
      expect(
        _compact(source),
        contains('kOgProtocolTrace && kDebugMode && Platform.isAndroid'),
      );
      expect(
        _compact(source),
        contains(
          'platformProtocolCaptureEnabled && kOgProtocolCaptureLiveLibre && '
          'selectedProtocolCaptureProfile() == ProtocolCaptureProfile.libre',
        ),
      );
    },
  );

  test('bootstrap passes one initialized history owner to all consumers', () {
    final bootstrap = _compact(
      _section(
        _read('lib/main.dart'),
        'Future<_BootstrapResult> _bootstrap()',
        'typedef _BootstrapResult',
      ),
    );
    expect(
      RegExp(r'SensorHistoryRepository\(').allMatches(bootstrap),
      hasLength(1),
    );
    expect(
      bootstrap,
      contains(
        'await healthStateStore.initialize(); '
        'final historyRepository = SensorHistoryRepository(healthStateStore); '
        'await configurePlatformSensorHistory( '
        'LibreGen1HistoryObservationStore(historyRepository), );',
      ),
    );
    expect(
      bootstrap,
      contains(
        'healthStateStore: healthStateStore, '
        'historyRepository: historyRepository,',
      ),
    );
    expect(
      bootstrap,
      contains(
        'libreHistoryTools: createPlatformLibreNfcHistoryTools( '
        'controller: controller, repository: historyRepository, ),',
      ),
    );
  });
}

String _read(String path) => File(path).readAsStringSync();
String _compact(String source) => source.replaceAll(RegExp(r'\s+'), ' ');

String _section(String source, String start, String end) {
  final first = source.indexOf(start);
  final last = source.indexOf(end, first + start.length);
  expect(first, greaterThanOrEqualTo(0));
  expect(last, greaterThan(first));
  return source.substring(first, last);
}

/// Follow every local import/export branch, not just this host's selected IO
/// branch. Package decoders must not enter normal code through an indirection.
Set<String> _localDependencies(List<String> roots) {
  final base = Directory.current.uri;
  final pending = roots.map(base.resolve).toList();
  final visited = <Uri>{};
  final directives = RegExp(
    r'^\s*(?:import|export)\s+([^;]+);',
    multiLine: true,
  );
  final quotedUri = RegExp("'([^']+)'");
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!visited.add(current)) continue;
    for (final directive in directives.allMatches(
      File.fromUri(current).readAsStringSync(),
    )) {
      for (final match in quotedUri.allMatches(directive.group(1)!)) {
        final target = match.group(1)!;
        expect(target, isNot(startsWith('package:cgm_libre2_glucose/')));
        if (target.startsWith('package:openglucose/')) {
          pending.add(
            base.resolve(
              'lib/${target.substring('package:openglucose/'.length)}',
            ),
          );
        } else if (!target.contains(':')) {
          pending.add(current.resolve(target));
        }
      }
    }
  }
  return visited
      .map((uri) => uri.toFilePath().substring(base.toFilePath().length))
      .toSet();
}

final class _NoIoHealthStateStore implements HealthStateStore {
  int operations = 0;

  Never _reject() {
    operations++;
    throw StateError(
      'History tool construction must not read or write storage.',
    );
  }

  @override
  Future<void> initialize() async => _reject();
  @override
  String? getString(String key) => _reject();
  @override
  Future<void> setString(String key, String value) async => _reject();
  @override
  Future<void> remove(String key) async => _reject();
}
