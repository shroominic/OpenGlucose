import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/android_live_update_bridge.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/live_activity_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit history pause closes Bluetooth before granting read scope',
    () async {
      final client = _FakeAndroidClient();
      final session = _TestSession(_snapshot())
        ..disconnectGate = Completer<void>();
      final driver = _TestDriver(session);
      final controller = await _controller(session, client, driver: driver);
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      var acquired = false;
      final pending = controller.pauseForLibreHistoryRead(_sensor).then((
        scope,
      ) {
        acquired = true;
        return scope;
      });
      await _drain();
      expect(controller.historyReadInProgress, isTrue);
      expect(acquired, isFalse);
      await controller.scan();
      await controller.retryConnection();
      await controller.ensureFreshData(force: true);
      await expectLater(controller.chooseAnotherSensor(), throwsStateError);
      expect(driver.connectCalls, 1);
      expect(driver.scanCalls, 0);
      expect(controller.snapshot!.sensor.deviceId, _sensor.deviceId);
      session.disconnectGate!.complete();
      final scope = await pending;
      expect(scope.isCurrent, isTrue);
      expect(client.active, isFalse);
      expect(controller.snapshot!.stage, CgmSyncStage.disconnected);
      await expectLater(
        controller.pauseForLibreHistoryRead(_sensor),
        throwsStateError,
      );
      scope.release(cleanupConfirmed: true);
      expect(scope.isCurrent, isFalse);
      expect(controller.historyReadInProgress, isFalse);
      expect(controller.sensorConnectionCleanupUnconfirmed, isFalse);
      await controller.ensureFreshData(force: true);
      await _drain();
      expect(driver.connectCalls, 1, reason: 'Release does not reconnect');
      await controller.retryConnection();
      expect(driver.connectCalls, 2);
      await controller.disconnect();
      controller.dispose();
      await session.close();
    },
  );

  test(
    'history pause waits for pending native start and native stop',
    () async {
      final client = _FakeAndroidClient()..nextStatusGate = Completer<void>();
      final start = client.nextStatusGate!;
      final session = _TestSession(_snapshot());
      final controller = await _controller(session, client);
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      client.nextEndGate = Completer<void>();
      final stop = client.nextEndGate!;
      var acquired = false;
      final pending = controller.pauseForLibreHistoryRead(_sensor).then((
        scope,
      ) {
        acquired = true;
        return scope;
      });
      await _drain();
      expect(acquired, isFalse);
      start.complete();
      await _drain();
      expect(acquired, isFalse);
      stop.complete();
      final scope = await pending;
      expect(client.active, isFalse);
      scope.release(cleanupConfirmed: true);
      await controller.disconnect();
      controller.dispose();
      await session.close();
    },
  );

  test(
    'unconfirmed NFC cleanup cannot be upgraded by a late release',
    () async {
      final client = _FakeAndroidClient();
      final session = _TestSession(_snapshot());
      final driver = _TestDriver(session);
      final controller = await _controller(session, client, driver: driver);
      await controller.connect(_sensor, allowSessionActivation: false);
      final scope = await controller.pauseForLibreHistoryRead(_sensor);
      scope.release(cleanupConfirmed: false);
      scope.release(cleanupConfirmed: true);
      expect(scope.isCurrent, isFalse);
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      await controller.scan();
      await controller.retryConnection();
      expect(driver.scanCalls, 0);
      expect(driver.connectCalls, 1);
      expect(controller.snapshot!.sensor.deviceId, _sensor.deviceId);
      controller.dispose();
      await session.close();
    },
  );

  test('failed Bluetooth close never grants a history read scope', () async {
    final client = _FakeAndroidClient();
    final session = _TestSession(_snapshot());
    final controller = await _controller(session, client);
    await controller.connect(_sensor, allowSessionActivation: false);
    session.disconnectError = StateError('Synthetic close failure');
    await expectLater(
      controller.pauseForLibreHistoryRead(_sensor),
      throwsStateError,
    );
    expect(controller.historyReadInProgress, isFalse);
    expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
    expect(controller.snapshot!.sensor.deviceId, _sensor.deviceId);
    controller.dispose();
    await session.close();
  });

  test('disposing controller invalidates the acquired scope', () async {
    final client = _FakeAndroidClient();
    final session = _TestSession(_snapshot());
    final controller = await _controller(session, client);
    await controller.connect(_sensor, allowSessionActivation: false);
    final scope = await controller.pauseForLibreHistoryRead(_sensor);
    controller.dispose();
    expect(scope.isCurrent, isFalse);
    scope.release(cleanupConfirmed: true);
    await session.close();
  });

  test('old scope release cannot release a newer history operation', () async {
    final client = _FakeAndroidClient();
    final session = _TestSession(_snapshot());
    final controller = await _controller(session, client);
    await controller.connect(_sensor, allowSessionActivation: false);
    final first = await controller.pauseForLibreHistoryRead(_sensor);
    first.release(cleanupConfirmed: true);
    final second = await controller.pauseForLibreHistoryRead(_sensor);
    first.release(cleanupConfirmed: false);
    expect(second.isCurrent, isTrue);
    expect(controller.sensorConnectionCleanupUnconfirmed, isFalse);
    second.release(cleanupConfirmed: true);
    await controller.disconnect();
    controller.dispose();
    await session.close();
  });

  test('connection policy is independent of measurement eligibility', () {
    for (final stage in <CgmSyncStage>[
      CgmSyncStage.connecting,
      CgmSyncStage.bonding,
      CgmSyncStage.pairing,
      CgmSyncStage.activating,
      CgmSyncStage.syncing,
      CgmSyncStage.ready,
    ]) {
      final snapshot = _snapshot(stage: stage, provisional: true);
      expect(_keep(snapshot, hasSession: true), isTrue, reason: stage.name);
      expect(
        shouldPublishLiveActivity(
          snapshot: snapshot,
          latestReading: snapshot.latestReading,
        ),
        isFalse,
      );
    }
    expect(_keep(_snapshot()), isFalse, reason: 'A saved snapshot is not work');
    expect(_keep(_snapshot(), connectionAttemptActive: true), isTrue);
    expect(
      _keep(
        _snapshot(stage: CgmSyncStage.disconnected),
        connectionAttemptActive: true,
      ),
      isTrue,
      reason: 'An owned reconnect spans old-transport close and new setup',
    );
    expect(_keep(_snapshot(), transportCleanupInProgress: true), isTrue);
    for (final stage in <CgmSyncStage>[
      CgmSyncStage.error,
      CgmSyncStage.disconnected,
      CgmSyncStage.scanning,
    ]) {
      expect(_keep(_snapshot(stage: stage), hasSession: true), isFalse);
    }
    expect(
      _keep(
        _snapshot(stage: CgmSyncStage.disconnected),
        recoveryScheduled: true,
      ),
      isTrue,
    );
    expect(
      _keep(_snapshot(), hasSession: true, cleanupUnconfirmed: true),
      isFalse,
    );
    expect(_keep(null, hasSession: true), isFalse);
    expect(
      _keep(_snapshot(directBle: false), hasSession: true),
      isFalse,
    );
  });

  test(
    'owned Libre return wait keeps status service without publishing data',
    () {
      final waiting = _snapshot(stage: CgmSyncStage.connecting).copyWith(
        metadata: {
          'cgm.libre2.phase': 'awaitingAdvertisement',
          'cgm.libre2.waitingForReturn': 'true',
          cgmAutomaticReconnectAllowedMetadataKey: 'false',
        },
      );
      expect(_keep(waiting, hasSession: true), isTrue);
      expect(
        _keep(waiting),
        isFalse,
        reason: 'Saved metadata does not own work',
      );
      expect(
        _keep(waiting, hasSession: true, cleanupUnconfirmed: true),
        isFalse,
      );
      expect(
        shouldPublishLiveActivity(snapshot: waiting, latestReading: null),
        isFalse,
      );
    },
  );

  test(
    'end waits for in-flight start and discards queued obsolete values',
    () async {
      final client = _FakeAndroidClient()..nextStatusGate = Completer<void>();
      final gate = client.nextStatusGate!;
      final dispatcher = AndroidLiveUpdateDispatcher(client: client);
      final first = dispatcher.update(keepConnectionActive: true);
      await _drain();
      expect(client.calls, <String>['status']);
      final obsolete = dispatcher.update(
        keepConnectionActive: true,
        eligiblePayload: _eligiblePayload,
      );
      var ended = false;
      final end = dispatcher.end().then((_) => ended = true);
      await _drain();
      expect(ended, isFalse);
      expect(client.calls, <String>['status']);
      gate.complete();
      await Future.wait<void>(<Future<void>>[first, obsolete, end]);
      expect(client.calls, <String>['status', 'end']);
      expect(client.active, isFalse);
      expect(client.numericPayloads, isEmpty);
    },
  );

  test('a newer end cannot drop an awaited native stop barrier', () async {
    final client = _FakeAndroidClient()
      ..nextStatusGate = Completer<void>()
      ..nextEndGate = Completer<void>();
    final startGate = client.nextStatusGate!;
    final endGate = client.nextEndGate!;
    final dispatcher = AndroidLiveUpdateDispatcher(client: client);
    final start = dispatcher.update(keepConnectionActive: true);
    await _drain();
    var firstEnded = false;
    final firstEnd = dispatcher.end().then((_) => firstEnded = true);
    final secondEnd = dispatcher.end();
    startGate.complete();
    await _drain();
    final firstCompletedBeforeNativeStop = firstEnded;
    endGate.complete();
    await Future.wait<void>(<Future<void>>[start, firstEnd, secondEnd]);
    expect(firstCompletedBeforeNativeStop, isFalse);
    expect(client.calls, <String>['status', 'end', 'end']);
    expect(client.active, isFalse);
  });

  test('a newer end cannot hide failure of an earlier native stop', () async {
    final client = _FakeAndroidClient()
      ..nextStatusGate = Completer<void>()
      ..nextEndError = StateError('synthetic native stop failure');
    final startGate = client.nextStatusGate!;
    final dispatcher = AndroidLiveUpdateDispatcher(client: client);
    final start = dispatcher.update(keepConnectionActive: true);
    await _drain();
    Object? firstFailure;
    Object? secondFailure;
    final firstEnd = dispatcher.end().then<void>(
      (_) {},
      onError: (Object error) => firstFailure = error,
    );
    final secondEnd = dispatcher.end().then<void>(
      (_) {},
      onError: (Object error) => secondFailure = error,
    );
    startGate.complete();
    await Future.wait<void>(<Future<void>>[start, firstEnd, secondEnd]);
    expect(firstFailure, isA<StateError>());
    expect(secondFailure, isNull);
    expect(client.calls, <String>['status', 'end', 'end']);
    expect(client.active, isFalse);
  });

  test('a newer start must run after the queued native stop barrier', () async {
    final client = _FakeAndroidClient()..nextStatusGate = Completer<void>();
    final startGate = client.nextStatusGate!;
    final dispatcher = AndroidLiveUpdateDispatcher(client: client);
    final firstStart = dispatcher.update(keepConnectionActive: true);
    await _drain();
    final end = dispatcher.end();
    final nextStart = dispatcher.update(keepConnectionActive: true);
    startGate.complete();
    await Future.wait<void>(<Future<void>>[firstStart, end, nextStart]);
    expect(client.calls, <String>['status', 'end', 'status']);
    await dispatcher.end();
  });

  test('new status supersedes an older queued numeric update', () async {
    final client = _FakeAndroidClient()..nextStatusGate = Completer<void>();
    final gate = client.nextStatusGate!;
    final dispatcher = AndroidLiveUpdateDispatcher(client: client);
    final first = dispatcher.update(keepConnectionActive: true);
    await _drain();
    final oldValue = dispatcher.update(
      keepConnectionActive: true,
      eligiblePayload: _eligiblePayload,
    );
    final newest = dispatcher.update(keepConnectionActive: true);
    gate.complete();
    await Future.wait<void>(<Future<void>>[first, oldValue, newest]);
    expect(client.calls, <String>['status', 'status']);
    expect(client.numericPayloads, isEmpty);
    await dispatcher.end();
  });

  testWidgets('timed-out end is an error, not native stop proof', (
    tester,
  ) async {
    final client = _FakeAndroidClient()..nextEndGate = Completer<void>();
    final gate = client.nextEndGate!;
    final dispatcher = AndroidLiveUpdateDispatcher(
      client: client,
      commandTimeout: const Duration(seconds: 1),
    );
    Object? failure;
    var succeeded = false;
    final end = dispatcher.end().then<void>(
      (_) => succeeded = true,
      onError: (Object error) => failure = error,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await end;
    expect(succeeded, isFalse);
    expect(failure, isA<TimeoutException>());
    gate.complete();
    await tester.pump();
    expect(succeeded, isFalse);
    expect(client.calls, <String>['end']);
  });

  test(
    'controller keeps provisional and missing readings off numeric path',
    () async {
      final client = _FakeAndroidClient();
      final session = _TestSession(_snapshot(provisional: true));
      final controller = await _controller(session, client);
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      expect(client.active, isTrue);
      expect(client.calls, contains('status'));
      expect(client.numericPayloads, isEmpty);
      expect(controller.allHistoricalReadings, isEmpty);

      session.emit(_snapshot(stage: CgmSyncStage.syncing));
      await _drain();
      expect(client.active, isTrue);
      expect(client.numericPayloads, isEmpty);
      session.emit(_snapshot(stage: CgmSyncStage.ready));
      await _drain();
      expect(client.active, isTrue);
      expect(client.numericPayloads, isEmpty);

      session.emit(_snapshot(stage: CgmSyncStage.error));
      await _drain();
      expect(client.calls.last, 'end');
      expect(client.active, isFalse);
      await controller.disconnect();
      controller.dispose();
      await session.close();
    },
  );

  test(
    'early Android failure is observed while iOS is still pending',
    () async {
      final client = _FakeAndroidClient()
        ..statusError = StateError('synthetic');
      final iosGate = Completer<void>();
      final session = _TestSession(_snapshot(provisional: true));
      final controller = await _controller(
        session,
        client,
        iosUpdate: (_) => iosGate.future,
      );
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      expect(iosGate.isCompleted, isFalse);
      expect(controller.lastError, contains('failed (StateError)'));
      expect(client.active, isFalse);
      iosGate.complete();
      await _drain();
      await controller.disconnect();
      controller.dispose();
      await session.close();
    },
  );

  test(
    'owned reconnect does not stop the connection service between transports',
    () async {
      final client = _FakeAndroidClient();
      final session = _TestSession(_snapshot(provisional: true));
      final controller = await _controller(session, client);
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      client.calls.clear();
      await controller.connect(_sensor, allowSessionActivation: false);
      await _drain();
      expect(client.calls, isNotEmpty);
      expect(client.calls, everyElement('status'));
      expect(client.active, isTrue);
      await controller.disconnect();
      controller.dispose();
      await session.close();
    },
  );

  for (final archiveFails in [false, true]) {
    test(
      'local disconnect waits for delayed native start (archiveFails=$archiveFails)',
      () async {
        final client = _FakeAndroidClient()..nextStatusGate = Completer<void>();
        final gate = client.nextStatusGate!;
        final session = _TestSession(
          _snapshot(provisional: true, verifiedLibreReception: true),
        );
        final store = _ArchiveFailureStore(failArchive: archiveFails);
        final controller = await _controller(
          session,
          client,
          healthStateStore: store,
          driver: _TestDriver(session, verifiedLibreReception: true),
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          controller.dispose();
          await session.close();
        });
        await controller.connect(_sensor, allowSessionActivation: false);
        await _drain();
        expect(client.calls, contains('status'));
        var completed = false;
        final disconnect = controller.disconnect().then(
          (_) => completed = true,
        );
        await _drain();
        expect(completed, isFalse, reason: 'Native start has not settled yet');
        gate.complete();
        await disconnect;
        expect(client.active, isFalse);
        expect(client.calls.last, 'end');
        final afterDisconnect = client.calls.length;
        controller.updateDisplayPreferences(const DisplayPreferences());
        await _drain();
        expect(client.calls.skip(afterDisconnect), everyElement('end'));
        if (archiveFails) {
          expect(controller.snapshot!.stage, CgmSyncStage.disconnected);
          expect(controller.snapshot!.history, hasLength(1));
          expect(
            controller.lastError,
            contains('Clearing the selected sensor'),
          );
          expect(store.getString('openHealth.lastSensor'), isNotNull);
          expect(controller.archivedSensors, isEmpty);
        } else {
          expect(controller.snapshot, isNull);
          expect(store.getString('openHealth.lastSensor'), isNull);
        }
        expect(client.numericPayloads, isEmpty);
      },
    );
  }
}

bool _keep(
  CgmSessionSnapshot? snapshot, {
  bool hasSession = false,
  bool connectionAttemptActive = false,
  bool recoveryScheduled = false,
  bool transportCleanupInProgress = false,
  bool cleanupUnconfirmed = false,
}) => shouldKeepAndroidConnectionActive(
  snapshot: snapshot,
  hasSession: hasSession,
  connectionAttemptActive: connectionAttemptActive,
  recoveryScheduled: recoveryScheduled,
  transportCleanupInProgress: transportCleanupInProgress,
  cleanupUnconfirmed: cleanupUnconfirmed,
);

const _sensor = DiscoveredSensor(
  driverId: 'libre2-gen1',
  deviceId: 'synthetic-connection-service',
  displayName: 'Synthetic sensor',
  storageKey: 'libre2-gen1:synthetic-connection-service',
  rssi: -40,
  capabilities: CgmCapabilities(supportsDirectBle: true),
);

CgmSessionSnapshot _snapshot({
  CgmSyncStage stage = CgmSyncStage.ready,
  bool provisional = false,
  bool directBle = true,
  bool verifiedLibreReception = false,
}) {
  final reading = provisional
      ? CgmReading(
          valueMgdl: 123,
          recordedAt: DateTime.now(),
          sensorMinute: 100,
          source: CgmRecordSource.vendor,
          isDisplayProvisional: true,
        )
      : null;
  return CgmSessionSnapshot(
    stage: stage,
    statusText: 'Synthetic private status must never reach keepalive',
    sensor: _sensor,
    capabilities: CgmCapabilities(supportsDirectBle: directBle),
    latestReading: reading,
    history: <CgmReading>[if (reading != null) reading],
    sessionInfo: CgmSessionInfo(
      elapsedMinutes: verifiedLibreReception ? 100 : null,
    ),
    metadata: <String, String>{
      cgmAutomaticReconnectAllowedMetadataKey: 'false',
      if (verifiedLibreReception) ...{
        'cgm.libre2.observationCommitted': 'true',
        'cgm.libre2.phase': 'validatedPacket',
        'cgm.libre2.timing': 'observed',
      },
    },
  );
}

const _eligiblePayload = LiveActivityPayload(
  sensorName: 'OpenGlucose',
  stageCode: 'live',
  stageLabel: 'Live',
  valueText: '123',
  unitText: 'mg/dL',
  lastReadingText: '08:00',
  lifeText: '',
  detailText: 'Updated',
  trendSymbol: '',
  deltaText: '',
  isStale: false,
);

class _FakeAndroidClient implements AndroidLiveUpdateClient {
  final calls = <String>[];
  final numericPayloads = <LiveActivityPayload>[];
  Completer<void>? nextStatusGate;
  Completer<void>? nextEndGate;
  Error? statusError;
  Error? nextEndError;
  bool active = false;

  @override
  Future<void> keepConnectionActive() async {
    calls.add('status');
    final error = statusError;
    if (error != null) throw error;
    final gate = nextStatusGate;
    nextStatusGate = null;
    if (gate != null) await gate.future;
    active = true;
  }

  @override
  Future<void> upsert(LiveActivityPayload payload) async {
    calls.add('value');
    numericPayloads.add(payload);
    active = true;
  }

  @override
  Future<void> end() async {
    calls.add('end');
    final error = nextEndError;
    nextEndError = null;
    if (error != null) throw error;
    final gate = nextEndGate;
    nextEndGate = null;
    if (gate != null) await gate.future;
    active = false;
  }
}

Future<CgmAppController> _controller(
  _TestSession session,
  AndroidLiveUpdateClient client, {
  Future<void> Function(LiveActivityPayload?)? iosUpdate,
  HealthStateStore? healthStateStore,
  _TestDriver? driver,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = CgmAppController(
    preferences: await SharedPreferences.getInstance(),
    driver: driver ?? _TestDriver(session),
    androidLiveUpdateClient: client,
    iosLiveActivityUpdater: iosUpdate,
    healthStateStore: healthStateStore,
  );
  await controller.initialize();
  return controller;
}

class _ArchiveFailureStore implements HealthStateStore {
  _ArchiveFailureStore({required this.failArchive});
  final bool failArchive;
  final _values = <String, String>{};

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> remove(String key) async => _values.remove(key);

  @override
  Future<void> setString(String key, String value) async {
    if (failArchive && key.startsWith('openHealth.history.archive.')) {
      throw StateError('Synthetic archive write failed');
    }
    _values[key] = value;
  }
}

class _TestDriver implements CgmDriver {
  _TestDriver(this.session, {this.verifiedLibreReception = false});
  final _TestSession session;
  final bool verifiedLibreReception;
  int connectCalls = 0;
  int scanCalls = 0;
  @override
  String get driverId => _sensor.driverId;
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCalls++;
    session.currentSnapshot = _snapshot(
      provisional: true,
      verifiedLibreReception: verifiedLibreReception,
    );
    return session;
  }

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    scanCalls++;
    return const Stream<DiscoveredSensor>.empty();
  }
}

class _TestSession implements CgmSession {
  _TestSession(this.currentSnapshot);
  final _snapshots = StreamController<CgmSessionSnapshot>.broadcast();
  @override
  CgmSessionSnapshot currentSnapshot;
  Completer<void>? disconnectGate;
  Error? disconnectError;
  void emit(CgmSessionSnapshot value) {
    currentSnapshot = value;
    _snapshots.add(value);
  }

  Future<void> close() => _snapshots.close();
  @override
  DiscoveredSensor get sensor => _sensor;
  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();
  @override
  Future<void> disconnect() async {
    final error = disconnectError;
    if (error != null) throw error;
    await disconnectGate?.future;
    currentSnapshot = currentSnapshot.copyWith(
      stage: CgmSyncStage.disconnected,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _drain() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
