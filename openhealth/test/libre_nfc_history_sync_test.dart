import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre2_nfc_setup.dart';
import 'package:openglucose/src/libre_gen1_fresh_nfc_history.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/libre_nfc_history_sync.dart';
import 'package:openglucose/src/sensor_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    h = _Harness();
    await h.initialize();
  });
  tearDown(() => h.dispose());

  test('constructor requires exactly one session source', () {
    LibreNfcHistorySync construct({bool both = false}) => LibreNfcHistorySync(
      controller: h.controller,
      repository: h.repository,
      session: both ? h.nfc : null,
      sessionFactory: both ? (_) => h.nfc : null,
      reader: LibreGen1FreshNfcHistoryReader(supported: false),
      decoder: h,
    );
    expect(construct, throwsArgumentError);
    expect(() => construct(both: true), throwsArgumentError);
    expect(h.nfc.starts, 0);
  });

  test(
    'session factory is lazy, exact-bound and disposed after success',
    () async {
      var creations = 0;
      h.replaceSync(
        factory: (bootstrap) {
          expect(identical(bootstrap, h.bootstrap), isTrue);
          creations++;
          return h.nfc;
        },
      );
      expect(creations, 0);
      expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
      expect(creations, 1);
      await h.sync.dispose();
      expect(h.nfc.disposals, 1);
    },
  );

  test(
    'wrong target and pre-disposed sync cannot invoke session factory',
    () async {
      var creations = 0;
      h.replaceSync(
        factory: (_) {
          creations++;
          return h.nfc;
        },
      );
      final wrong = await h.sync.sync(
        sensor: h.sensorFor('wrong'),
        bootstrap: h.bootstrap,
      );
      expect(wrong.failure, LibreNfcHistorySyncFailure.invalidTarget);
      expect(creations, 0);
      expect(h.nfc.stops, 0);
      h.replaceSync(
        factory: (_) {
          creations++;
          return h.nfc;
        },
      );
      await h.sync.dispose();
      expect((await h.run()).failure, LibreNfcHistorySyncFailure.busy);
      expect(creations, 0);
      expect(h.radio.disconnects, 0);
    },
  );

  test('factory throw is closed before pause or native dispatch', () async {
    h.replaceSync(
      factory: (_) => throw StateError('Synthetic private detail.'),
    );
    final result = await h.run();
    expect(result.phase, LibreNfcHistorySyncPhase.failed);
    expect(result.toString(), isNot(contains('private detail')));
    expect(h.nfc.starts, 0);
    expect(h.radio.disconnects, 0);
    expect(h.sync.cleanupUnconfirmed, isFalse);
  });

  test(
    'synchronous factory cancellation cannot start or pause later',
    () async {
      h.replaceSync(
        factory: (_) {
          unawaited(h.sync.cancel());
          return h.nfc;
        },
      );
      expect((await h.run()).phase, LibreNfcHistorySyncPhase.cancelled);
      expect(h.nfc.starts, 0);
      expect(h.radio.disconnects, 0);
      await h.sync.dispose();
      expect(h.nfc.disposals, 1);
    },
  );

  test(
    'receiver cancellation invokes and awaits native evidence discard',
    () async {
      final nfc = _RevocableNfc(h.events)..emitMetadata = false;
      nfc.revocationGate = Completer<void>();
      h.replaceSync(factory: (_) => nfc);
      final result = h.run();
      await _until(() => nfc.starts == 1);
      final cancelling = h.sync.cancel();
      expect(nfc.revocations, 1);
      var completed = false;
      unawaited(cancelling.then<void>((_) => completed = true));
      await _until(() => nfc.stops > 0);
      expect(completed, isFalse);
      nfc.revocationGate!.complete();
      await cancelling;
      expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
      await h.sync.dispose();
      expect(nfc.disposals, 1);
      expect(h.evidenceCalls, 0);
    },
  );

  test(
    'receiver discard failure retains controller cleanup quarantine',
    () async {
      final nfc = _RevocableNfc(h.events)
        ..emitMetadata = false
        ..revocationFails = true;
      h.replaceSync(factory: (_) => nfc);
      final result = h.run();
      await _until(() => nfc.starts == 1);
      await h.sync.cancel();
      expect(
        (await result).failure,
        LibreNfcHistorySyncFailure.cleanupUnconfirmed,
      );
      expect(h.sync.cleanupUnconfirmed, isTrue);
      await h.sync.dispose();
      expect(h.controller.sensorConnectionCleanupUnconfirmed, isTrue);
    },
  );

  test(
    'cancel after native stop still revokes pending evidence before import',
    () async {
      final nfc = _RevocableNfc(h.events);
      h.evidenceGate = Completer<void>();
      h.replaceSync(factory: (_) => nfc);
      final result = h.run();
      await _until(() => h.evidenceCalls == 1);
      final cancellation = h.sync.cancel();
      expect(nfc.revocations, 1);
      h.evidenceGate!.complete();
      await cancellation;
      expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
      expect(h.decodeCalls, 0);
      expect(h.history, hasLength(1));
    },
  );

  test('construction has no I/O and exact read imports history only', () async {
    expect(h.nfc.starts, 0);
    expect(h.nfc.stops, 0);
    expect(h.evidenceCalls, 0);
    final phases = <LibreNfcHistorySyncPhase>[];
    final listener = h.sync.states.listen((state) => phases.add(state.phase));
    final result = await h.run();
    expect(result.phase, LibreNfcHistorySyncPhase.completed);
    expect(result.importedReadingCount, 1);
    expect(h.events, ['disconnect', 'start', 'stop', 'evidence', 'decode']);
    expect(h.nfc.completedReadAttemptId, isNull);
    expect(h.repository.readCommittedHistory(h.key), hasLength(2));
    expect(h.controller.latestReading, isNull);
    expect(h.controller.snapshot?.sensor.storageKey, h.sensor.storageKey);
    expect(h.driver.connects, 1);
    expect(h.controller.sensorConnectionCleanupUnconfirmed, isFalse);
    expect(
      phases,
      containsAllInOrder([
        LibreNfcHistorySyncPhase.pausing,
        LibreNfcHistorySyncPhase.listening,
        LibreNfcHistorySyncPhase.reading,
        LibreNfcHistorySyncPhase.stopping,
        LibreNfcHistorySyncPhase.decoding,
        LibreNfcHistorySyncPhase.importing,
        LibreNfcHistorySyncPhase.completed,
      ]),
    );
    await listener.cancel();
  });

  test(
    'terminal getter becomes valid after synchronous event delivery',
    () async {
      h.nfc.deferAttempt = true;
      expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
      expect(h.evidenceCalls, 1);
    },
  );

  test('second call is rejected without a second pause or start', () async {
    h.nfc.emitMetadata = false;
    final first = h.run();
    await _until(() => h.nfc.starts == 1);
    final second = await h.run();
    expect(second.failure, LibreNfcHistorySyncFailure.busy);
    await h.sync.cancel();
    expect((await first).phase, LibreNfcHistorySyncPhase.cancelled);
    expect(h.nfc.starts, 1);
  });

  test('wrong exact bootstrap target cannot start NFC', () async {
    final result = await h.sync.sync(
      sensor: h.sensorFor('other'),
      bootstrap: h.bootstrap,
    );
    expect(result.failure, LibreNfcHistorySyncFailure.invalidTarget);
    expect(h.nfc.starts, 0);
    expect(h.radio.disconnects, 0);
    expect(h.evidenceCalls, 0);
  });

  for (final metadata in [
    const Libre2NfcSetupState.failed(Libre2NfcFailureKind.tagMoved),
    const Libre2NfcSetupState.activationVerified(),
    const Libre2NfcSetupState.metadataRead(
      model: Libre2SensorModel.libre2Plus,
      sensorStatus: Libre2SensorStatus.active,
    ),
    const Libre2NfcSetupState.metadataRead(
      model: Libre2SensorModel.libre2,
      sensorStatus: Libre2SensorStatus.notActivated,
    ),
    const Libre2NfcSetupState.metadataRead(
      model: Libre2SensorModel.libre2,
      sensorStatus: Libre2SensorStatus.expired,
    ),
  ]) {
    test(
      'non-history terminal ${metadata.phase.name}/${metadata.sensorStatus?.name}/${metadata.model?.name}/${metadata.isActivationVerified} is closed',
      () async {
        h.nfc.metadata = metadata;
        expect((await h.run()).failure, LibreNfcHistorySyncFailure.readFailed);
        expect(h.evidenceCalls, 0);
        expect(h.history, hasLength(1));
        expect(h.controller.sensorConnectionCleanupUnconfirmed, isFalse);
      },
    );
  }

  test('expired read metadata does not fetch evidence', () async {
    h.nfc.metadata = const Libre2NfcSetupState.metadataRead(
      model: Libre2SensorModel.libre2,
      sensorStatus: Libre2SensorStatus.active,
      isReadExpired: true,
    );
    expect((await h.run()).failure, LibreNfcHistorySyncFailure.readExpired);
    expect(h.evidenceCalls, 0);
  });

  test('evidence is never requested before native stop completes', () async {
    h.nfc.stopGate = Completer<void>();
    final result = h.run();
    await _until(() => h.nfc.stops == 1);
    expect(h.evidenceCalls, 0);
    expect(h.history, hasLength(1));
    h.nfc.stopGate!.complete();
    expect((await result).phase, LibreNfcHistorySyncPhase.completed);
  });

  test('cancel during stop waits cleanup and does not read evidence', () async {
    h.nfc.stopGate = Completer<void>();
    final result = h.run();
    await _until(() => h.nfc.stops == 1);
    var cancelled = false;
    final cancel = h.sync.cancel().then((_) => cancelled = true);
    await _tick();
    expect(cancelled, isFalse);
    h.nfc.stopGate!.complete();
    await cancel;
    expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
    expect(h.evidenceCalls, 0);
    expect(h.controller.sensorConnectionCleanupUnconfirmed, isFalse);
  });

  test(
    'cancel delayed start stops both before and after start settles',
    () async {
      h.nfc.startGate = Completer<void>();
      final result = h.run();
      await _until(() => h.nfc.starts == 1);
      final cancel = h.sync.cancel();
      await _until(() => h.nfc.stops == 1);
      h.nfc.startGate!.complete();
      await cancel;
      expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
      expect(h.nfc.stops, 2);
      expect(h.nfc.active, isFalse);
      expect(h.evidenceCalls, 0);
    },
  );

  test('stop failure quarantines the controller and coordinator', () async {
    h.nfc.stopFails = true;
    final result = await h.run();
    expect(result.failure, LibreNfcHistorySyncFailure.cleanupUnconfirmed);
    expect(h.sync.cleanupUnconfirmed, isTrue);
    await h.sync.dispose();
    expect(h.controller.sensorConnectionCleanupUnconfirmed, isTrue);
    expect(h.evidenceCalls, 0);
    expect(h.history, hasLength(1));
    expect(
      (await h.run()).failure,
      LibreNfcHistorySyncFailure.cleanupUnconfirmed,
    );
  });

  test('read deadline with confirmed native cleanup is retryable', () async {
    h.replaceSync(read: const Duration(milliseconds: 5));
    h.nfc.emitMetadata = false;
    expect((await h.run()).failure, LibreNfcHistorySyncFailure.timedOut);
    expect(h.sync.cleanupUnconfirmed, isFalse);
    await h.sync.dispose();
    expect(h.controller.sensorConnectionCleanupUnconfirmed, isFalse);
    expect(h.driver.connects, 1);
  });

  test(
    'pause timeout cannot start NFC and late scope stays quarantined',
    () async {
      h.replaceSync(pause: const Duration(milliseconds: 5));
      h.radio.disconnectGate = Completer<void>();
      final result = await h.run();
      expect(result.failure, LibreNfcHistorySyncFailure.cleanupUnconfirmed);
      expect(h.nfc.starts, 0);
      h.radio.disconnectGate!.complete();
      await _until(() => h.controller.sensorConnectionCleanupUnconfirmed);
      expect(h.nfc.starts, 0);
      expect(h.driver.connects, 1);
    },
  );

  test(
    'start timeout observes late start then stops without new authority',
    () async {
      h.replaceSync(method: const Duration(milliseconds: 5));
      h.nfc.startGate = Completer<void>();
      expect(
        (await h.run()).failure,
        LibreNfcHistorySyncFailure.cleanupUnconfirmed,
      );
      final stoppedBefore = h.nfc.stops;
      h.nfc.startGate!.complete();
      await _until(() => h.nfc.stops > stoppedBefore);
      expect(h.nfc.active, isFalse);
      expect(h.sync.cleanupUnconfirmed, isTrue);
      expect(h.evidenceCalls, 0);
    },
  );

  test('cancel during evidence revokes late result without a write', () async {
    h.evidenceGate = Completer<void>();
    final result = h.run();
    await _until(() => h.evidenceCalls == 1);
    await h.sync.cancel();
    expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
    h.evidenceGate!.complete();
    await _tick();
    expect(h.decodeCalls, 0);
    expect(h.history, hasLength(1));
  });

  test('wrong native evidence is closed and never decoded', () async {
    h.wrongEvidence = true;
    expect((await h.run()).failure, LibreNfcHistorySyncFailure.invalidEvidence);
    expect(h.decodeCalls, 0);
    expect(h.history, hasLength(1));
  });

  test(
    'clear during evidence prevents a pre-clear ticket from importing',
    () async {
      h.evidenceGate = Completer<void>();
      final result = h.run();
      await _until(() => h.evidenceCalls == 1);
      await h.repository.clear(h.key);
      h.evidenceGate!.complete();
      expect((await result).phase, LibreNfcHistorySyncPhase.failed);
      expect(h.history, isEmpty);
      expect(h.sync.cleanupUnconfirmed, isFalse);
      await h.sync.dispose();
      expect(h.controller.sensorConnectionCleanupUnconfirmed, isFalse);
    },
  );

  test(
    'cancel dispatched import waits durability and never reports success',
    () async {
      h.store.gatedKey = h.key;
      h.store.writeGate = Completer<void>();
      final result = h.run();
      await _until(() => h.store.gatedWriteStarted);
      var cancelFinished = false;
      final cancel = h.sync.cancel().then((_) => cancelFinished = true);
      await _tick();
      expect(cancelFinished, isFalse);
      h.store.writeGate!.complete();
      await cancel;
      expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
      expect(
        h.history,
        hasLength(2),
        reason: 'A dispatched atomic import cannot be undone by cancellation.',
      );
      expect(h.controller.latestReading, isNull);
      expect(h.driver.connects, 1);
    },
  );

  test(
    'import timeout holds quarantine even when write later completes',
    () async {
      h.replaceSync(storage: const Duration(milliseconds: 5));
      h.store.gatedKey = h.key;
      h.store.writeGate = Completer<void>();
      final result = await h.run();
      expect(result.failure, LibreNfcHistorySyncFailure.cleanupUnconfirmed);
      await h.sync.dispose();
      expect(h.controller.sensorConnectionCleanupUnconfirmed, isTrue);
      h.store.writeGate!.complete();
      await _tick();
      expect(h.sync.cleanupUnconfirmed, isTrue);
      expect(h.driver.connects, 1);
    },
  );

  test(
    'lost write acknowledgement preserves display and closes ownership',
    () async {
      h.store.loseAcknowledgement = true;
      expect(
        (await h.run()).failure,
        LibreNfcHistorySyncFailure.cleanupUnconfirmed,
      );
      expect(h.repository.isQuarantined(h.key), isTrue);
      expect(h.history, hasLength(1));
      expect(h.controller.snapshot!.history, hasLength(1));
      expect(h.controller.latestReading, isNull);
    },
  );

  test('stale scope after controller disposal cannot import', () async {
    h.evidenceGate = Completer<void>();
    final result = h.run();
    await _until(() => h.evidenceCalls == 1);
    h.disposeController();
    h.evidenceGate!.complete();
    expect((await result).phase, LibreNfcHistorySyncPhase.failed);
    expect(h.history, hasLength(1));
  });

  for (final phase in [
    LibreNfcHistorySyncPhase.pausing,
    LibreNfcHistorySyncPhase.stopping,
    LibreNfcHistorySyncPhase.decoding,
    LibreNfcHistorySyncPhase.importing,
  ]) {
    test(
      'synchronous cancel at ${phase.name} cannot dispatch next operation',
      () async {
        final listener = h.sync.states.listen((state) {
          if (state.phase == phase) unawaited(h.sync.cancel());
        });
        final result = await h.run();
        expect(result.phase, LibreNfcHistorySyncPhase.cancelled);
        expect(h.history, hasLength(1));
        expect(h.nfc.stops, 1);
        if (phase == LibreNfcHistorySyncPhase.pausing) {
          expect(h.radio.disconnects, 0);
          expect(h.nfc.starts, 0);
        }
        if (phase != LibreNfcHistorySyncPhase.importing) {
          expect(h.evidenceCalls, 0);
        }
        expect(h.sync.cleanupUnconfirmed, isFalse);
        await listener.cancel();
      },
    );
  }

  test(
    'synchronous dispose during start callback closes late start exactly',
    () async {
      final listener = h.sync.states.listen((state) {
        if (state.phase == LibreNfcHistorySyncPhase.listening) {
          unawaited(h.sync.dispose());
        }
      });
      expect((await h.run()).phase, LibreNfcHistorySyncPhase.cancelled);
      await h.sync.dispose();
      expect(h.nfc.active, isFalse);
      expect(h.nfc.stops, 2);
      expect(h.evidenceCalls, 0);
      await listener.cancel();
    },
  );

  test(
    'late start during subscription cleanup still gets a post-start stop',
    () async {
      h.replaceSync(method: const Duration(milliseconds: 20));
      h.nfc.startGate = Completer<void>();
      h.nfc.cancelGate = Completer<void>();
      final result = h.run();
      await _until(() => h.nfc.cancelStarted);
      expect(h.nfc.stops, 1);
      h.nfc.startGate!.complete();
      await _until(() => h.nfc.stops == 2);
      expect(h.nfc.active, isFalse);
      h.nfc.cancelGate!.complete();
      expect(
        (await result).failure,
        LibreNfcHistorySyncFailure.cleanupUnconfirmed,
      );
      expect(h.evidenceCalls, 0);
    },
  );

  test(
    'terminal result retains RF reservation through delayed disposal',
    () async {
      expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
      await expectLater(
        h.controller.pauseForLibreHistoryRead(h.sensor),
        throwsStateError,
      );
      h.nfc.disposeGate = Completer<void>();
      final disposal = h.sync.dispose();
      await _until(() => h.nfc.disposals == 1);
      await expectLater(
        h.controller.pauseForLibreHistoryRead(h.sensor),
        throwsStateError,
      );
      h.nfc.disposeGate!.complete();
      await disposal;
      expect(h.sync.cleanupUnconfirmed, isFalse);
      final next = await h.controller.pauseForLibreHistoryRead(h.sensor);
      expect(next.isCurrent, isTrue);
      next.release(cleanupConfirmed: true);
      expect(h.driver.connects, 1);
    },
  );

  test('history resume requires a completed exact-target pause', () async {
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensor),
      throwsStateError,
    );
    expect(h.driver.connects, 1);
    expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
    h.nfc.disposeGate = Completer<void>();
    final disposal = h.sync.dispose();
    await _until(() => h.nfc.disposals == 1);
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensor),
      throwsStateError,
    );
    expect(h.driver.connects, 1);
    h.nfc.disposeGate!.complete();
    await disposal;
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensorFor('wrong')),
      throwsStateError,
    );
    expect(h.driver.connects, 1);
    await h.controller.resumeLibreHistoryConnection(h.sensor);
    expect(h.driver.connects, 2);
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensor),
      throwsStateError,
    );
    expect(h.driver.connects, 2);
  });

  test('history resume cannot bypass uncertain cleanup', () async {
    expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
    h.nfc.disposeFails = true;
    await h.sync.dispose();
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensor),
      throwsStateError,
    );
    expect(h.driver.connects, 1);
  });

  test('history resume cannot restore a removed selection', () async {
    expect((await h.run()).phase, LibreNfcHistorySyncPhase.completed);
    await h.sync.dispose();
    await h.controller.chooseAnotherSensor();
    await expectLater(
      h.controller.resumeLibreHistoryConnection(h.sensor),
      throwsStateError,
    );
    expect(h.driver.connects, 1);
  });

  test(
    'dispose revokes immediately, is idempotent, exposes cleanup error',
    () async {
      h.nfc.emitMetadata = false;
      final result = h.run();
      await _until(() => h.nfc.starts == 1);
      h.nfc.disposeFails = true;
      final first = h.sync.dispose();
      expect(identical(first, h.sync.dispose()), isTrue);
      await first;
      expect((await result).phase, LibreNfcHistorySyncPhase.cancelled);
      expect(h.sync.cleanupUnconfirmed, isTrue);
      expect(h.nfc.disposals, 1);
      expect(h.evidenceCalls, 0);
      expect(h.controller.sensorConnectionCleanupUnconfirmed, isTrue);
    },
  );
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 2));
Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await _tick();
  }
  expect(
    predicate(),
    isTrue,
    reason: 'Expected controlled asynchronous checkpoint.',
  );
}

const _uid = [1, 2, 3, 4, 5, 6, 7, 0xe0];
const _patch = [0x9d, 8, 0x30, 1, 0x34, 0x12];
const _attempt = 'synthetic_history_attempt';

class _Harness implements LibreGen1NfcHistoryDecoder {
  final bootstrap = LibreGen1StreamingBootstrap(
    bootstrapId: 'synthetic_history_receiver',
    deviceId: '02:00:00:00:00:01',
    uid: LibreGen1Uid.algorithmOrder(_uid),
    initialPatchInfo: LibreGen1PatchInfo(_patch),
    streamingBase: 0,
    lifecycle: LibreGen1LifecycleState.active,
  );
  late final binding = LibreGen1ObservationBinding.forSensor(
    bootstrapId: bootstrap.bootstrapId,
    uid: bootstrap.uid,
    initialPatchInfo: bootstrap.initialPatchInfo,
  );
  late final DiscoveredSensor sensor = sensorFor(binding.storageKey);
  DiscoveredSensor sensorFor(String storage) => DiscoveredSensor(
    driverId: 'libre2-gen1',
    deviceId: bootstrap.deviceId,
    displayName: 'Libre 2',
    storageKey: storage,
    rssi: -40,
    capabilities: const CgmCapabilities(),
  );
  final store = _Store();
  late final repository = SensorHistoryRepository(store);
  final events = <String>[];
  late final nfc = _Nfc(events);
  late final radio = _Radio(sensor, events);
  late final driver = _Driver(radio);
  late final CgmAppController controller;
  late LibreNfcHistorySync sync;
  bool controllerDisposed = false;
  Completer<void>? evidenceGate;
  int evidenceCalls = 0;
  int decodeCalls = 0;
  bool wrongEvidence = false;
  String get key => sensorHistoryKey(sensor);
  List<CgmReading> get history => repository.readCommittedHistory(key);

  Future<void> initialize() async {
    await repository.loadLibre(binding);
    final receipt = DateTime.now().toUtc();
    final old = CgmReading(
      valueMgdl: 100,
      source: CgmRecordSource.vendor,
      sensorMinute: 100,
      recordedAt: receipt,
      isDisplayProvisional: true,
    );
    await repository.commitLibre(
      binding,
      sensorMinute: 100,
      receivedAt: receipt,
      reading: old,
    );
    radio.history = [old];
    controller = CgmAppController(
      preferences: await SharedPreferences.getInstance(),
      driver: driver,
      healthStateStore: store,
      historyRepository: repository,
    );
    await controller.initialize();
    await controller.connect(sensor, allowSessionActivation: false);
    replaceSync();
  }

  void replaceSync({
    Libre2NfcSetupSession Function(LibreGen1StreamingBootstrap)? factory,
    Duration pause = const Duration(seconds: 2),
    Duration method = const Duration(seconds: 2),
    Duration read = const Duration(seconds: 2),
    Duration storage = const Duration(seconds: 2),
  }) {
    sync = LibreNfcHistorySync(
      controller: controller,
      repository: repository,
      session: factory == null ? nfc : null,
      sessionFactory: factory,
      reader: LibreGen1FreshNfcHistoryReader(
        supported: true,
        invokeMethod: (method, args) async {
          expect(nfc.active, isFalse);
          expect(args, {
            'attemptId': _attempt,
            'bootstrapId': bootstrap.bootstrapId,
          });
          events.add('evidence');
          evidenceCalls++;
          await evidenceGate?.future;
          return {
            'attemptId': wrongEvidence ? 'wrong' : _attempt,
            'bootstrapId': bootstrap.bootstrapId,
            'uid': List<int>.of(_uid),
            'receiverInitialPatchInfo': List<int>.of(_patch),
            'currentPatchInfo': [..._patch.take(4), 0x78, 0x56],
            'encryptedFram': List<int>.filled(344, 42),
            'observedAtUtc': DateTime.now().toUtc().toIso8601String(),
          };
        },
      ),
      decoder: this,
      pauseTimeout: pause,
      methodTimeout: method,
      readTimeout: read,
      storageTimeout: storage,
    );
  }

  Future<LibreNfcHistorySyncState> run() =>
      sync.sync(sensor: sensor, bootstrap: bootstrap);
  @override
  LibreGen1DecodedNfcHistory decodeFreshNfc(
    LibreGen1FreshNfcEvidence evidence,
  ) {
    events.add('decode');
    decodeCalls++;
    final receipt = evidence.observedAtUtc;
    return LibreGen1DecodedNfcHistory(
      scanMinute: 180,
      receivedAt: receipt,
      samples: [
        LibreNfcHistorySample(
          reading: CgmReading(
            valueMgdl: 110,
            source: CgmRecordSource.vendor,
            sensorMinute: 165,
            recordedAt: receipt.subtract(const Duration(minutes: 15)),
            isDisplayProvisional: true,
          ),
          firstReceivedAt: receipt,
          origin: LibreHistoryOrigin.nfcHistory,
        ),
      ],
    );
  }

  void disposeController() {
    if (!controllerDisposed) {
      controllerDisposed = true;
      controller.dispose();
    }
  }

  Future<void> dispose() async {
    for (final gate in [
      nfc.startGate,
      nfc.stopGate,
      nfc.cancelGate,
      nfc.disposeGate,
      radio.disconnectGate,
      evidenceGate,
      store.writeGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await sync.dispose();
    disposeController();
    await radio.close();
  }
}

class _Store implements HealthStateStore {
  final values = <String, String>{};
  Completer<void>? writeGate;
  String? gatedKey;
  bool gatedWriteStarted = false;
  bool loseAcknowledgement = false;
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == gatedKey) {
      gatedWriteStarted = true;
      await writeGate?.future;
    }
    values[key] = value;
    if (loseAcknowledgement && key.startsWith('openHealth.history.')) {
      loseAcknowledgement = false;
      throw StateError('synthetic private storage detail');
    }
  }
}

class _Nfc
    implements Libre2NfcSetupSession, Libre2NfcCompletedReadAttemptProvider {
  _Nfc(this.events);
  final List<String> events;
  final stream = StreamController<Libre2NfcSetupState>.broadcast(sync: true);
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Completer<void>? cancelGate;
  Completer<void>? disposeGate;
  bool cancelStarted = false;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  bool active = false;
  bool emitMetadata = true;
  bool deferAttempt = false;
  bool stopFails = false;
  bool disposeFails = false;
  String? attempt;
  Libre2NfcSetupState metadata = const Libre2NfcSetupState.metadataRead(
    model: Libre2SensorModel.libre2,
    sensorStatus: Libre2SensorStatus.active,
  );
  @override
  Stream<Libre2NfcSetupState> get states {
    if (cancelGate == null) return stream.stream;
    return Stream<Libre2NfcSetupState>.multi((controller) {
      final subscription = stream.stream.listen(
        controller.addSync,
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      controller.onCancel = () async {
        await subscription.cancel();
        cancelStarted = true;
        await cancelGate?.future;
      };
    }, isBroadcast: true);
  }

  @override
  String? get completedReadAttemptId => attempt;
  @override
  Future<void> start() async {
    starts++;
    events.add('start');
    await startGate?.future;
    active = true;
    stream.add(const Libre2NfcSetupState.listening());
    if (emitMetadata) {
      stream.add(const Libre2NfcSetupState.reading());
      stream.add(metadata);
      if (deferAttempt) {
        scheduleMicrotask(() => attempt = _attempt);
      } else {
        attempt = _attempt;
      }
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    events.add('stop');
    await stopGate?.future;
    if (stopFails) throw StateError('synthetic private native error');
    active = false;
    attempt = null;
  }

  @override
  Future<void> retry() async {
    throw StateError('No retry authority');
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await disposeGate?.future;
    await stream.close();
    if (disposeFails) throw StateError('synthetic private disposal error');
  }
}

class _RevocableNfc extends _Nfc implements LibreNfcHistoryEvidenceRevoker {
  _RevocableNfc(super.events);
  int revocations = 0;
  Completer<void>? revocationGate;
  bool revocationFails = false;
  @override
  Future<void> revokeHistoryEvidence() async {
    revocations++;
    await revocationGate?.future;
    if (revocationFails) throw StateError('Synthetic discard failure.');
  }
}

class _Driver implements CgmDriver {
  _Driver(this.session);
  final _Radio session;
  int connects = 0;
  @override
  String get driverId => 'libre2-gen1';
  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connects++;
    return session;
  }
}

class _Radio implements CgmSession {
  _Radio(this.sensor, this.events);
  @override
  final DiscoveredSensor sensor;
  final List<String> events;
  List<CgmReading> history = [];
  Completer<void>? disconnectGate;
  int disconnects = 0;
  final stream = StreamController<CgmSessionSnapshot>.broadcast(sync: true);
  @override
  CgmSessionSnapshot get currentSnapshot => CgmSessionSnapshot(
    sensor: sensor,
    stage: CgmSyncStage.ready,
    statusText: 'Connected',
    capabilities: const CgmCapabilities(),
    history: history,
  );
  @override
  Stream<CgmSessionSnapshot> get snapshots => stream.stream;
  @override
  Stream<CgmLogEntry> get logs => const Stream.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  @override
  Future<void> disconnect() async {
    disconnects++;
    events.add('disconnect');
    await disconnectGate?.future;
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => [];
  @override
  Future<void> refresh() async {}
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async => [];
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}
  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
  Future<void> close() => stream.close();
}
