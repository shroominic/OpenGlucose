import 'dart:async';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/driver_factory_io.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre_gen1_fresh_nfc_history.dart';
import 'package:openglucose/src/libre_gen1_receiver_composition.dart';
import 'package:openglucose/src/libre_gen1_receiver_history_platform.dart';
import 'package:openglucose/src/libre_gen1_receiver_store.dart';
import 'package:openglucose/src/sensor_connection_policy.dart';
import 'package:openglucose/src/sensor_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = '02:00:00:00:00:01';
const _bootstrapId = 'synthetic_bootstrap_1';
const _capabilities = <String, Object?>{
  'schemaVersion': 1,
  'backend': 'receiver',
  'restoreAvailable': true,
  'enrollmentAvailable': false,
  'rawCapture': false,
};
Map<String, Object?> _bootstrap() => {
  'bootstrapId': _bootstrapId,
  'deviceId': _device,
  'uid': [1, 2, 3, 4, 5, 6, 7, 0xe0],
  'initialPatchInfo': [0x9d, 8, 0x30, 1, 0, 0],
  'streamingBase': 0,
  'lifecycle': 'active',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const receiverChannel = MethodChannel(LibreGen1ReceiverStore.channelName);
  const captureChannel = MethodChannel('com.openglucose/protocol_capture');
  const nfcChannel = MethodChannel('com.openglucose/libre2');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<String> order;
  late _Transport transport;
  late Future<Object?> Function(MethodCall) handler;
  late LibreGen1ReceiverStore store;
  late _ObservationStore observationStore;
  var unrelatedCalls = 0;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    order = [];
    unrelatedCalls = 0;
    transport = _Transport(order);
    observationStore = _ObservationStore(order);
    store = LibreGen1ReceiverStore(
      sessionIdFactory: () => 'synthetic_receiver_session',
    );
    handler = (call) async => switch (call.method) {
      'capabilities' => _capabilities,
      'readLibreGen1StreamingBootstrap' => _bootstrap(),
      'acquireLibreGen1Receiver' => 'synthetic_receiver_lease',
      'reserveLibreGen1UnlockCount' => 1,
      _ => null,
    };
    messenger.setMockMethodCallHandler(receiverChannel, (call) {
      calls.add(call);
      order.add(call.method);
      return handler(call);
    });
    for (final channel in [captureChannel, nfcChannel]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        unrelatedCalls++;
        throw StateError('No recorder or NFC fallback is permitted.');
      });
    }
  });

  tearDown(() async {
    for (final channel in [receiverChannel, captureChannel, nfcChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    expect(unrelatedCalls, 0);
    await transport.connection.packets.close();
  });

  Future<LibreGen1ReceiverComposition?> compose({
    bool enabled = true,
    LibreGen1GlucoseDecoderProvider? decoderProvider,
    bool requireAvailable = false,
  }) => LibreGen1ReceiverComposition.tryCreate(
    transport: transport,
    validationEnabled: enabled,
    store: store,
    observationStore: observationStore,
    decoderProvider: decoderProvider,
    requireAvailable: requireAvailable,
  );

  test('private recorder-free configuration is pre-start and single-use', () {
    final provider = _DecoderProvider(store);
    for (final condition in [
      (false, false, false),
      (true, true, false),
      (true, false, true),
    ]) {
      final configuration = PrivateRecorderFreeLibreDecoderConfiguration();
      expect(
        () => configuration.configure(
          provider,
          supported: condition.$1,
          incompatibleMode: condition.$2,
          configurationStarted: condition.$3,
        ),
        throwsStateError,
      );
      expect(configuration.provider, isNull);
    }
    final configuration = PrivateRecorderFreeLibreDecoderConfiguration();
    configuration.configure(
      provider,
      supported: true,
      incompatibleMode: false,
      configurationStarted: false,
    );
    expect(configuration.provider, same(provider));
    expect(
      () => configuration.configure(
        provider,
        supported: true,
        incompatibleMode: false,
        configurationStarted: false,
      ),
      throwsStateError,
    );
    expect(provider.preparations, 0);
    expect(calls, isEmpty);
  });

  test(
    'explicit private receiver rejects unavailable capability without fallback',
    () async {
      final provider = _DecoderProvider(store);
      for (final reply in <Object?>[
        null,
        {..._capabilities, 'rawCapture': true},
      ]) {
        handler = (_) async => reply;
        await expectLater(
          compose(decoderProvider: provider, requireAvailable: true),
          throwsStateError,
        );
      }
      handler = (_) async => throw MissingPluginException();
      await expectLater(
        compose(decoderProvider: provider, requireAvailable: true),
        throwsStateError,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
        compose(decoderProvider: provider, requireAvailable: true),
        throwsStateError,
      );
      expect(calls.every((call) => call.method == 'capabilities'), isTrue);
      expect(provider.preparations, 0);
      expect(transport.connects, 0);
    },
  );

  test(
    'private provider prepares only on connect using receiver calibration channel',
    () async {
      final provider = _DecoderProvider(store);
      final composition = (await compose(
        decoderProvider: provider,
        requireAvailable: true,
      ))!;
      expect(provider.preparations, 0);
      final sensor = (await composition.prepareConnection())!;
      expect(provider.preparations, 0);
      final session = await composition.driver.connect(sensor);
      for (var turn = 0; turn < 40; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(provider.preparations, 1);
      expect(
        calls.where(
          (call) => call.method == 'readLibreGen1CalibrationEvidence',
        ),
        hasLength(1),
      );
      expect(session.currentSnapshot.latestReading, isNull);
      expect(
        buildHardwareDriverRegistry(
          transport,
          libreReceiver: composition,
        ).registeredDriverIds,
        {'aidex', 'libre2-gen1'},
      );
      await session.disconnect();
    },
  );

  testWidgets(
    'explicit private capability timeout fails without late registration',
    (tester) async {
      final reply = Completer<Object?>();
      handler = (_) => reply.future;
      final checked = expectLater(
        compose(
          decoderProvider: _DecoderProvider(store),
          requireAvailable: true,
        ),
        throwsStateError,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await checked;
      reply.complete(_capabilities);
      await tester.pump();
      expect(transport.connects, 0);
      expect(calls.map((call) => call.method), ['capabilities']);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'receiver history tools are absent without provider and lazy with private provider',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final health = _NoIoStore();
      final repository = SensorHistoryRepository(health);
      final controller = CgmAppController(
        preferences: preferences,
        driver: DemoCgmDriver(),
        healthStateStore: health,
        historyRepository: repository,
      );
      addTearDown(controller.dispose);
      final ordinary = (await compose())!;
      expect(
        ordinary.createHistoryTools(
          controller: controller,
          repository: repository,
        ),
        isNull,
      );
      final bleOnly = (await compose(decoderProvider: _BleOnlyProvider()))!;
      expect(
        bleOnly.createHistoryTools(
          controller: controller,
          repository: repository,
        ),
        isNull,
      );
      final provider = _DecoderProvider(store);
      final composition = (await compose(
        decoderProvider: provider,
        requireAvailable: true,
      ))!;
      calls.clear();
      var platforms = 0;
      final tools = composition.createHistoryTools(
        controller: controller,
        repository: repository,
        historyPlatformFactory: () {
          platforms++;
          return LibreGen1ReceiverHistoryPlatform(events: const Stream.empty());
        },
      )!;
      expect(platforms, 0);
      expect(calls, isEmpty);
      expect(provider.preparations, 0);
      final sync = tools.createSync();
      expect(platforms, 1);
      expect(calls, isEmpty);
      await sync.dispose();
      expect(calls, isEmpty);
      expect(health.operations, 0);
      expect(await tools.readBootstrap(), isNotNull);
      expect(calls.map((call) => call.method), [
        'capabilities',
        'readLibreGen1StreamingBootstrap',
      ]);
    },
  );

  test(
    'ordinary and non-Android composition never probes the receiver',
    () async {
      expect(await compose(enabled: false), isNull);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await compose(), isNull);
      expect(calls, isEmpty);
      expect(buildHardwareDriverRegistry(transport).registeredDriverIds, {
        'aidex',
      });
      expect(transport.connects, 0);
      expect(observationStore.loads, 0);
    },
  );

  test(
    'closed capability admits restore only and performs no bootstrap or RF',
    () async {
      final composition = await compose();
      expect(composition, isNotNull);
      expect(calls.map((call) => call.method), ['capabilities']);
      expect(calls.single.arguments, isEmpty);
      final registry = buildHardwareDriverRegistry(
        transport,
        libreReceiver: composition,
      );
      expect(registry.registeredDriverIds, {'aidex', 'libre2-gen1'});
      expect(
        registry.connectionPolicyFor('aidex'),
        SensorConnectionPolicy.explicitConnect,
      );
      expect(
        registry.connectionPolicyFor('libre2-gen1'),
        SensorConnectionPolicy.externalSetupOnly,
      );
      expect(registry.driverFor('libre2-gen1'), same(composition!.driver));
      expect(transport.connects, 0);
    },
  );

  test(
    'missing or malformed capability leaves AiDEX usable with no fallback',
    () async {
      for (final value in <Object?>[
        null,
        {..._capabilities, 'schemaVersion': 1.0},
        {..._capabilities, 'backend': 'readOnly'},
        {..._capabilities, 'restoreAvailable': false},
        {..._capabilities, 'enrollmentAvailable': true},
        {..._capabilities, 'rawCapture': true},
        {..._capabilities, 'extra': true},
      ]) {
        handler = (_) async => value;
        final composition = await compose();
        expect(composition, isNull);
        final registry = buildHardwareDriverRegistry(
          transport,
          libreReceiver: composition,
        );
        expect(registry.registeredDriverIds, {'aidex'});
        final results = await registry.scan().toList();
        expect(results.map((sensor) => sensor.driverId), ['aidex']);
      }
      handler = (_) async => throw MissingPluginException();
      expect(await compose(), isNull);
      expect(calls.every((call) => call.method == 'capabilities'), isTrue);
      expect(transport.connects, 0);
    },
  );

  testWidgets('late capability cannot register a receiver after the deadline', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    handler = (_) => reply.future;
    final pending = compose();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(await pending, isNull);
    reply.complete(_capabilities);
    await tester.pump();
    expect(buildHardwareDriverRegistry(transport).registeredDriverIds, {
      'aidex',
    });
    expect(calls.map((call) => call.method), ['capabilities']);
    expect(transport.connects, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'shared discovery restores exact target without lease or counter writes',
    () async {
      final composition = (await compose())!;
      final registry = buildHardwareDriverRegistry(
        transport,
        libreReceiver: composition,
      );
      final sensors = await registry.scan().toList();
      expect(sensors.map((sensor) => sensor.driverId), [
        'aidex',
        'libre2-gen1',
      ]);
      expect(sensors.last.deviceId, _device);
      expect(transport.scans, 1);
      expect(transport.connects, 0);
      final prepared = await composition.prepareConnection();
      expect(prepared?.storageKey, 'libre2-gen1:$_bootstrapId');
      expect(
        calls.every(
          (call) => const {
            'capabilities',
            'readLibreGen1StreamingBootstrap',
          }.contains(call.method),
        ),
        isTrue,
      );
      final previous = handler;
      handler = (call) => call.method == 'readLibreGen1StreamingBootstrap'
          ? Future<Object?>.error(
              PlatformException(code: 'unresolved_receiver'),
            )
          : previous(call);
      final afterFailure = await registry.scan().toList();
      expect(afterFailure.map((sensor) => sensor.driverId), ['aidex']);
      expect(composition.driver.bootstrappedSensor, isNull);
      expect(transport.connects, 0);
    },
  );

  test(
    'positive absence does not enroll and wrong target cannot acquire',
    () async {
      final composition = (await compose())!;
      final previous = handler;
      handler = (call) => call.method == 'readLibreGen1StreamingBootstrap'
          ? Future<Object?>.value(null)
          : previous(call);
      expect(await composition.prepareConnection(), isNull);
      handler = previous;
      final registry = buildHardwareDriverRegistry(
        transport,
        libreReceiver: composition,
      );
      final prepared = (await composition.prepareConnection())!;
      final wrong = DiscoveredSensor(
        driverId: prepared.driverId,
        deviceId: '02:00:00:00:00:02',
        displayName: 'Synthetic wrong target',
        storageKey: prepared.storageKey,
        rssi: -40,
        capabilities: prepared.capabilities,
      );
      await expectLater(
        registry.connect(wrong),
        throwsA(isA<LibreGen1LiveException>()),
      );
      expect(
        calls.any((call) => call.method == 'acquireLibreGen1Receiver'),
        isFalse,
      );
      expect(transport.connects, 0);
    },
  );

  test(
    'unavailable durable history cannot acquire or connect the receiver',
    () async {
      final composition = (await compose())!;
      final prepared = (await composition.prepareConnection())!;
      observationStore.failLoad = true;
      await expectLater(
        composition.driver.connect(prepared),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (error) => error.kind,
            'kind',
            LibreGen1LiveFailure.observationStorageUnavailable,
          ),
        ),
      );
      expect(observationStore.loads, 1);
      expect(transport.connects, 0);
      expect(
        calls.any((call) => call.method == 'acquireLibreGen1Receiver'),
        isFalse,
      );
    },
  );

  test(
    'factory receiver holds exact native owner through one login and close',
    () async {
      final composition = (await compose())!;
      final registry = buildHardwareDriverRegistry(
        transport,
        libreReceiver: composition,
      );
      final prepared = (await composition.prepareConnection())!;
      expect(transport.connects, 0);
      final session = await registry.connect(prepared);
      for (var turn = 0; turn < 40; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        session.currentSnapshot.metadata['cgm.libre2.phase'],
        'awaitingPacket',
      );
      expect(transport.connects, 1);
      expect(transport.connection.writes, 1);
      expect(observationStore.loads, 1);
      expect(
        order.indexOf('loadObservations'),
        lessThan(order.indexOf('acquireLibreGen1Receiver')),
      );
      expect(
        order.indexOf('acquireLibreGen1Receiver'),
        lessThan(order.indexOf('connectOnce')),
      );
      expect(
        order.indexOf('reserveLibreGen1UnlockCount'),
        lessThan(order.indexOf('write')),
      );
      final counter = calls.singleWhere(
        (call) => call.method == 'reserveLibreGen1UnlockCount',
      );
      expect(counter.arguments, {
        'sessionId': 'synthetic_receiver_session',
        'bootstrapId': _bootstrapId,
        'leaseToken': 'synthetic_receiver_lease',
      });
      expect(
        calls.any((call) => call.method == 'readLibreGen1CalibrationEvidence'),
        isFalse,
      );
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.unsafeAdmin, isNull);
      await session.disconnect();
      expect(transport.connection.closes, 1);
      expect(
        order.indexOf('transportClosed'),
        lessThan(order.indexOf('releaseLibreGen1Receiver')),
      );
      expect(calls.last.method, 'releaseLibreGen1Receiver');
      expect((calls.last.arguments as Map)['transportClosed'], isTrue);
    },
  );

  test('factory keeps release decoder and capture boundaries explicit', () {
    final source = File('lib/src/driver_factory_io.dart').readAsStringSync();
    final composition = File(
      'lib/src/libre_gen1_receiver_composition.dart',
    ).readAsStringSync();
    expect(
      source,
      contains(
        'validationEnabled: kDebugMode && Platform.isAndroid && !kOgDemo',
      ),
    );
    expect(source, contains('if (!kOgProtocolTrace) {'));
    expect(source, contains('libreReceiver: _recorderFreeLibreReceiver'));
    expect(source, contains('if (receiver != null) {'));
    expect(
      source.indexOf(
        'await disableFlutterBluePlusLogs();',
        source.indexOf('Future<void> configurePlatformSensorHistory('),
      ),
      lessThan(source.indexOf('_recorderFreeLibreReceiver = receiver;')),
    );
    expect(composition, contains('!kDebugMode'));
    expect(composition, isNot(contains('protocol_capture')));
    expect(composition, contains('glucoseDecoderProvider: decoderProvider'));
    expect(
      composition,
      contains('LibreGen1GlucoseDecoderProvider? decoderProvider'),
    );
    expect(
      source,
      contains(
        'requireAvailable: _privateRecorderFreeDecoder.provider != null',
      ),
    );
    expect(source, contains('_platformConfigurationStarted = true'));
    expect(
      source,
      contains('supported: kDebugMode && !kIsWeb && Platform.isAndroid'),
    );
    expect(composition, isNot(contains('cgm_libre2_glucose')));
    expect(composition, contains('requireDurableObservations: true'));
    expect(platformLibreGen1StreamingEnabled, isFalse);
  });

  test(
    'bootstrap shares one initialized history owner with both Libre paths',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final factory = File('lib/src/driver_factory_io.dart').readAsStringSync();
      final composition = File(
        'lib/src/libre_gen1_receiver_composition.dart',
      ).readAsStringSync();
      final bootstrapStart = main.indexOf(
        'Future<_BootstrapResult> _bootstrap()',
      );
      final controllerInitialized = main.indexOf(
        'await controller.initialize();',
        bootstrapStart,
      );
      expect(bootstrapStart, greaterThanOrEqualTo(0));
      expect(controllerInitialized, greaterThan(bootstrapStart));
      final bootstrap = main.substring(bootstrapStart, controllerInitialized);
      final orderedSteps = [
        'await healthStateStore.initialize();',
        'final historyRepository = SensorHistoryRepository(healthStateStore);',
        'await configurePlatformSensorHistory(',
        'LibreGen1HistoryObservationStore(historyRepository)',
        'final controller = CgmAppController(',
        'driver: buildDefaultDriver()',
        'historyRepository: historyRepository',
      ];
      var previousStep = -1;
      for (final step in orderedSteps) {
        final at = bootstrap.indexOf(step);
        expect(at, greaterThan(previousStep), reason: step);
        previousStep = at;
      }
      expect('SensorHistoryRepository('.allMatches(bootstrap), hasLength(1));
      expect(
        'LibreGen1HistoryObservationStore('.allMatches(bootstrap),
        hasLength(1),
      );

      final captureStart = factory.indexOf('CgmDriver _buildCaptureRegistry(');
      final captureEnd = factory.indexOf(
        'DebugSharedScanTransport _sharedProtocolTransport()',
        captureStart,
      );
      expect(captureStart, greaterThanOrEqualTo(0));
      expect(captureEnd, greaterThan(captureStart));
      final capture = factory.substring(captureStart, captureEnd);
      expect(capture, contains('observationStore: _libreObservationStore'));
      expect(capture, contains('requireDurableObservations: true'));
      expect(
        composition,
        contains('required LibreGen1ObservationStore observationStore'),
      );
      expect(composition, contains('observationStore: observationStore'));
      expect(composition, contains('requireDurableObservations: true'));
      for (final source in [main, factory, composition]) {
        expect(source, isNot(contains('package:cgm_libre2_glucose')));
        expect(source, isNot(contains('libre_glucose_debug_main.dart')));
      }
    },
  );
}

final class _DecoderProvider
    implements LibreGen1GlucoseDecoderProvider, LibreGen1NfcHistoryDecoder {
  _DecoderProvider(this.store);
  final LibreGen1ReceiverStore store;
  int preparations = 0;
  @override
  Future<LibreGen1GlucoseDecoder?> prepare(
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    preparations++;
    await store.readCalibrationEvidence(bootstrap);
    return null;
  }

  @override
  LibreGen1DecodedNfcHistory decodeFreshNfc(
    LibreGen1FreshNfcEvidence evidence,
  ) => throw StateError('No decoding without an explicit synthetic NFC read.');
}

final class _BleOnlyProvider implements LibreGen1GlucoseDecoderProvider {
  @override
  Future<LibreGen1GlucoseDecoder?> prepare(
    LibreGen1StreamingBootstrap bootstrap,
  ) async => null;
}

final class _NoIoStore implements HealthStateStore {
  int operations = 0;
  Never _reject() {
    operations++;
    throw StateError('Unexpected storage operation.');
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

final class _ObservationStore implements LibreGen1ObservationStore {
  _ObservationStore(this.order);
  final List<String> order;
  int loads = 0;
  bool failLoad = false;
  final _states = <String, LibreGen1ObservationState>{};

  @override
  Future<LibreGen1ObservationState> load(
    LibreGen1ObservationBinding binding,
  ) async {
    expect(binding.bootstrapId, _bootstrapId);
    order.add('loadObservations');
    loads++;
    if (failLoad) throw StateError('Synthetic observation storage failure.');
    return _states.putIfAbsent(
      binding.sensorBindingDigest,
      LibreGen1ObservationState.new,
    );
  }

  @override
  Future<LibreGen1ObservationCommit> commit(
    LibreGen1ObservationBinding binding, {
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  }) async {
    final previous = _states[binding.sensorBindingDigest]!;
    final advanced =
        previous.observedMinute == null ||
        sensorMinute > previous.observedMinute!;
    final next = advanced
        ? LibreGen1ObservationState(
            observedMinute: sensorMinute,
            history: [
              ...previous.history,
              for (final historical in historicalReadings) historical.reading,
              if (reading != null) reading,
            ],
          )
        : previous;
    _states[binding.sensorBindingDigest] = next;
    return LibreGen1ObservationCommit(advanced: advanced, state: next);
  }
}

final class _Transport implements BleSingleAttemptTransport {
  _Transport(this.order) : connection = _Connection(order);
  final List<String> order;
  final _Connection connection;
  int scans = 0;
  int connects = 0;
  @override
  bool get supportsSingleAttemptConnect => true;
  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) async* {
    scans++;
    yield const BleScanResult(
      deviceId: 'synthetic-aidex',
      deviceName: 'AiDEX-2222293Q2E',
      rssi: -40,
    );
    yield BleScanResult(
      deviceId: _device,
      deviceName: '',
      rssi: -40,
      observedAt: DateTime.now(),
      serviceUuids: const ['fde3'],
    );
    yield BleScanResult(
      deviceId: '02:00:00:00:00:02',
      deviceName: 'Libre 2',
      rssi: -40,
      observedAt: DateTime.now(),
      serviceUuids: const ['fde3'],
    );
  }

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    expect(deviceId, _device);
    connects++;
    order.add('connectOnce');
    return connection;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw StateError('No implicit connection retry.');
}

final class _Connection implements BleConnection {
  _Connection(this.order);
  final List<String> order;
  final packets = StreamController<List<int>>.broadcast(sync: true);
  int writes = 0;
  int closes = 0;
  @override
  String get deviceId => _device;
  @override
  Stream<BleConnectionState> get connectionStates => const Stream.empty();
  @override
  bool get supportsBondLifecycle => false;
  @override
  Future<List<BleService>> discoverServices() async => const [
    BleService(
      uuid: 'fde3',
      characteristics: [
        BleCharacteristicRef(
          serviceUuid: 'fde3',
          characteristicUuid: 'f001',
          properties: BleCharacteristicProperties(write: true),
        ),
        BleCharacteristicRef(
          serviceUuid: 'fde3',
          characteristicUuid: 'f002',
          properties: BleCharacteristicProperties(notify: true),
        ),
      ],
    ),
  ];
  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    expect(withoutResponse, isFalse);
    writes++;
    order.add('write');
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {}
  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      packets.stream;
  @override
  Future<void> disconnect() async {
    closes++;
    order.add('transportClosed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
