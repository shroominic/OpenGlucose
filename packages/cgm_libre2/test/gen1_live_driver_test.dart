import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

void main() {
  late _Harness harness;
  setUp(() => harness = _Harness());
  tearDown(() async {
    try {
      await harness.session?.disconnect();
    } on LibreGen1LiveException catch (error) {
      // Some tests deliberately leave quarantined physical ownership.
      expect(error.kind, LibreGen1LiveFailure.cleanupUnconfirmed);
    }
    await harness.connection.packets.close();
    await harness.connection.states.close();
  });

  test(
    'cancellation during optional preparation cannot start BLE later',
    () async {
      final gate = Completer<void>();
      final provider = harness.decoderProvider = _DecoderProvider()
        ..prepareGate = gate;
      final session = await harness.start();
      expect(provider.preparations, 1);
      expect(harness.transport.scanCalls, 0);
      final closing = session.disconnect();
      gate.complete();
      await closing;
      expect(harness.transport.scanCalls, 0);
      expect(harness.transport.connectCalls, 0);
      expect(harness.store.nextCount, 1);
    },
  );

  test(
    'cancellation during recovery bootstrap read prevents replacement',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      final gate = Completer<void>();
      harness.store.readGate = gate;
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.reconnecting);
      final closing = session.disconnect();
      gate.complete();
      await closing;
      expect(harness.transport.connectCalls, 1);
      expect(harness.transport.scanCalls, 1);
      expect(harness.store.nextCount, 2);
    },
  );

  test(
    'replacement advertisement timeout never consumes another counter',
    () async {
      harness.advertisementTimeout = const Duration(milliseconds: 10);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      harness.transport.autoAdvertise = false;
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.advertisementUnavailable,
      );
      expect(harness.transport.scanCalls, 2);
      expect(harness.transport.connectCalls, 1);
      expect(harness.store.nextCount, 2);
    },
  );

  test(
    'one recovery waits for cleanup, fresh ad and a new durable login',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      final firstLogin = harness.connection.lastWrite;
      final closeGate = Completer<void>();
      harness.connection.disconnectGate = closeGate;
      harness.transport.autoAdvertise = false;
      final replacement = _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.reconnecting);
      expect(harness.transport.scanCalls, 1);
      expect(harness.store.nextCount, 2);
      closeGate.complete();
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      expect(harness.store.readCalls, 2);
      expect(harness.transport.connectCalls, 1);
      harness.transport.emit(_advertisement(harness.now));
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(harness.transport.connectCalls, 2);
      expect(harness.store.nextCount, 3);
      expect(replacement.lastWrite, isNot(firstLogin));
      expect(harness.events, [
        'connect',
        'discover',
        'reserve',
        'write',
        'acknowledged',
        'listen',
        'notify',
        'disconnect',
        'connect',
        'discover',
        'reserve',
        'write',
        'acknowledged',
        'listen',
        'notify',
      ]);
      _sendPacket(replacement, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      replacement.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(harness.transport.connectCalls, 2);
      expect(harness.transport.scanCalls, 2);
      expect(harness.store.nextCount, 3);
      expect(
        session.currentSnapshot.metadata['cgm.libre2.recoveryAttempts'],
        '1',
      );
    },
  );

  for (final failure in [
    'beforePacket',
    'stateError',
    'notificationError',
    'notificationDone',
    'invalidPacket',
    'closeFailure',
  ]) {
    test('$failure cannot trigger a replacement session', () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      if (failure != 'beforePacket') {
        _sendPacket(harness.connection, _encrypted);
        await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      }
      switch (failure) {
        case 'stateError':
          harness.connection.states.addError(StateError('private synthetic'));
          break;
        case 'notificationError':
          harness.connection.packets.addError(StateError('private synthetic'));
          break;
        case 'notificationDone':
          await harness.connection.packets.close();
          break;
        case 'invalidPacket':
          harness.connection.packets.add([1]);
          break;
        case 'closeFailure':
          harness.connection.disconnectFails = true;
          harness.connection.states.add(BleConnectionState.disconnected);
          break;
        default:
          harness.connection.states.add(BleConnectionState.disconnected);
      }
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(harness.transport.scanCalls, 1);
      expect(harness.transport.connectCalls, 1);
      expect(harness.store.nextCount, 2);
    });
  }

  for (final failure in [
    'missingBootstrap',
    'replacedBootstrap',
    'sameIdChangedKey',
    'storeRead',
    'unknownLogin',
    'topology',
    'reserve',
  ]) {
    test('replacement $failure stops with no third attempt', () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      final replacement = _replacement(harness);
      switch (failure) {
        case 'missingBootstrap':
          harness.store.bootstrap = null;
          break;
        case 'replacedBootstrap':
          harness.store.bootstrap = _bootstrap(bootstrapId: 'other');
          break;
        case 'sameIdChangedKey':
          harness.store.bootstrap = _bootstrap(streamingBase: 7);
          break;
        case 'storeRead':
          harness.store.readFails = true;
          break;
        case 'unknownLogin':
          replacement.writeFails = true;
          break;
        case 'topology':
          replacement.invalidTopology = 'missingLogin';
          break;
        case 'reserve':
          harness.store.reserveFails = true;
          break;
      }
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      await session.refresh();
      expect(harness.transport.connectCalls, lessThanOrEqualTo(2));
      expect(harness.transport.scanCalls, lessThanOrEqualTo(2));
      expect(
        harness.events.where((e) => e == 'write').length,
        failure == 'unknownLogin' ? 2 : 1,
      );
      if (failure == 'unknownLogin') {
        expect(harness.events.lastIndexOf('unknown'), greaterThan(0));
      }
    });
  }

  test(
    'user cancellation during replacement ad wait blocks late actions',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      harness.transport.autoAdvertise = false;
      _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      await session.disconnect();
      harness.transport.emit(_advertisement(harness.now));
      await Future<void>.delayed(Duration.zero);
      expect(harness.transport.connectCalls, 1);
      expect(harness.store.nextCount, 2);
    },
  );

  test(
    'decoder is optional, provisional, monotonic and re-prepared on recovery',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider();
      provider.result = const LibreGen1GlucoseResult(
        sensorAgeMinutes: 60,
        sampleAgeMinutes: 60,
        glucoseMgdl: 100,
        expectedLifetimeMinutes: 20160,
      );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(provider.preparations, 1);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      final reading = session.currentSnapshot.latestReading!;
      expect(reading.valueMgdl, 100);
      expect(reading.source, CgmRecordSource.vendor);
      expect(reading.isDisplayProvisional, isTrue);
      expect(reading.recordedAt, harness.now);
      expect(reading.rawValue, isNull);
      expect(session.currentSnapshot.history, [reading]);
      final replacement = _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(provider.preparations, 2);
      expect(session.currentSnapshot.history, [reading]);
      expect(session.currentSnapshot.latestReading, isNull);
      _sendPacket(replacement, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, [reading]);
      expect(
        session.currentSnapshot.metadata['cgm.libre2.decoder'],
        'invalidData',
      );
      provider.result = const LibreGen1GlucoseResult(
        sensorAgeMinutes: 61,
        sampleAgeMinutes: 61,
        glucoseMgdl: 101,
      );
      _sendPacket(replacement, _encrypted);
      await Future<void>.delayed(Duration.zero);
      expect(session.currentSnapshot.latestReading?.sensorMinute, 61);
      expect(
        session.currentSnapshot.history.map((point) => point.sensorMinute),
        [60, 61],
      );
      expect(session.currentSnapshot.history.first, same(reading));
      final receivedHistory = session.currentSnapshot.history;
      replacement.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(session.currentSnapshot.history, receivedHistory);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
    },
  );

  test(
    'history keeps received minutes and UTC times without filling gaps',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final first = session.currentSnapshot.history.single;
      final firstSnapshot = session.currentSnapshot;

      // A repeated minute cannot replace its original value or timestamp.
      harness.now = harness.now.add(const Duration(minutes: 4));
      provider.result = _currentSample(60, 200);
      await _receivePacket(session, harness.connection);
      expect(session.currentSnapshot.history, [first]);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.syncing);

      // Sensor-minute order stays authoritative even if the phone clock changes.
      // Keep the supplied receipt instant; do not invent a monotonic wall clock.
      harness.now = DateTime(2025, 12, 31, 23, 58);
      provider.result = _currentSample(65, 105);
      await _receivePacket(session, harness.connection);
      final history = session.currentSnapshot.history;
      expect(history.map((point) => point.sensorMinute), [60, 65]);
      expect(history.map((point) => point.valueMgdl), [100, 105]);
      expect(history.first, same(first));
      expect(history.last.recordedAt, harness.now.toUtc());
      expect(history.every((point) => point.recordedAt!.isUtc), isTrue);
      expect(history.every((point) => point.isDisplayProvisional), isTrue);
      expect(
        history.every((point) => point.source == CgmRecordSource.vendor),
        isTrue,
      );
      expect(history.every((point) => point.rawValue == null), isTrue);
      expect(firstSnapshot.history, [first]);
      expect(() => history.clear(), throwsUnsupportedError);
      expect(session.currentSnapshot.capabilities.supportsHistory, isFalse);
      expect(session.syncHistory(), throwsUnsupportedError);
      expect(session.currentSnapshot.sessionInfo.sessionStart, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
    },
  );

  test(
    'bounded history evicts oldest without reopening accepted minutes',
    () async {
      harness.historyLimit = 2;
      final provider = harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final snapshots = <CgmSessionSnapshot>[];
      for (final minute in [60, 61, 62]) {
        provider.result = _currentSample(minute, minute + 40);
        await _receivePacket(session, harness.connection);
        snapshots.add(session.currentSnapshot);
      }
      expect(snapshots.first.history.map((point) => point.sensorMinute), [60]);
      expect(snapshots[1].history.map((point) => point.sensorMinute), [60, 61]);
      expect(snapshots.last.history.map((point) => point.sensorMinute), [
        61,
        62,
      ]);
      for (final minute in [60, 61, 62]) {
        provider.result = _currentSample(minute, 250);
        await _receivePacket(session, harness.connection);
        expect(session.currentSnapshot.history, snapshots.last.history);
        expect(session.currentSnapshot.latestReading, isNull);
      }
      provider.result = _currentSample(64, 104);
      await _receivePacket(session, harness.connection);
      expect(
        session.currentSnapshot.history.map((point) => point.sensorMinute),
        [62, 64],
      );
    },
  );

  test('history limit is explicit and bounded by the sensor-minute domain', () {
    for (final limit in [0, -1, 0x10001]) {
      expect(
        () => LibreGen1Driver(
          transport: harness.transport,
          bootstrapProvider: harness.store,
          counterStore: harness.store,
          historyLimit: limit,
        ),
        throwsArgumentError,
      );
    }
  });

  for (final result in [
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 59,
      sampleAgeMinutes: 59,
      glucoseMgdl: 90,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      sampleAgeMinutes: 61,
      glucoseMgdl: 110,
      rejection: LibreGen1GlucoseRejection.warmingUp,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      sampleAgeMinutes: 61,
      glucoseMgdl: 110,
      expectedLifetimeMinutes: 61,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      sampleAgeMinutes: 60,
      glucoseMgdl: 110,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      sampleAgeMinutes: 61,
      glucoseMgdl: double.nan,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      rejection: LibreGen1GlucoseRejection.noCurrentSample,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 61,
      sampleAgeMinutes: 61,
      glucoseMgdl: 110,
      rejection: LibreGen1GlucoseRejection.invalidData,
    ),
  ].indexed) {
    test(
      'rejected sample ${result.$1} keeps history but cannot imply current readiness',
      () async {
        final provider = harness.decoderProvider = _DecoderProvider();
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        await _receivePacket(session, harness.connection);
        final acceptedHistory = session.currentSnapshot.history;
        provider.result = result.$2;
        await _receivePacket(session, harness.connection);
        expect(session.currentSnapshot.history, acceptedHistory);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
        expect(session.currentSnapshot.sessionInfo.sessionStart, isNull);
        expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
        expect(harness.events.where((event) => event == 'disconnect'), isEmpty);
      },
    );
  }

  test(
    'decoder exception and CRC failure retain only earlier accepted history',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final acceptedHistory = session.currentSnapshot.history;
      provider.decodeFails = true;
      await _receivePacket(session, harness.connection);
      expect(session.currentSnapshot.history, acceptedHistory);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
      final decodeCalls = provider.decodeCalls;
      final corruptPacket = List<int>.of(_encrypted)..[12] ^= 1;
      _sendPacket(harness.connection, corruptPacket);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(provider.decodeCalls, decodeCalls);
      expect(session.currentSnapshot.history, acceptedHistory);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(session.currentStatus.failure, LibreGen1LiveFailure.invalidPacket);
      expect(harness.transport.connectCalls, 1);
    },
  );

  test(
    'explicit disconnect retains history; a new session starts empty',
    () async {
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final acceptedHistory = session.currentSnapshot.history;
      await session.disconnect();
      expect(session.currentSnapshot.history, acceptedHistory);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
      final replacement = _replacement(harness);
      final next = await harness.start();
      await _waitFor(next, LibreGen1LivePhase.awaitingPacket);
      expect(next.currentSnapshot.history, isEmpty);
      await _receivePacket(next, replacement);
      expect(next.currentSnapshot.history.length, 1);
      expect(next.currentSnapshot.history.single.sensorMinute, 60);
    },
  );

  test(
    'disconnect before queued publication does not lose an accepted point',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final closed = Completer<void>();
      provider.afterDecode = () => scheduleMicrotask(() async {
        await session.disconnect();
        closed.complete();
      });
      _sendPacket(harness.connection, _encrypted);
      await closed.future.timeout(const Duration(seconds: 1));
      expect(session.currentSnapshot.history.single.sensorMinute, 60);
      expect(session.currentSnapshot.history.single.valueMgdl, 100);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
    },
  );

  test(
    'a synchronous packet burst cannot put future points in earlier snapshots',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final snapshots = <CgmSessionSnapshot>[];
      final subscription = session.snapshots.listen((snapshot) {
        if (snapshot.latestReading != null) snapshots.add(snapshot);
      });
      final received = session.statuses.firstWhere(
        (status) => status.validatedPacketCount == 2,
      );
      _sendPacket(harness.connection, _encrypted);
      provider.result = _currentSample(61, 101);
      _sendPacket(harness.connection, _encrypted);
      await received.timeout(const Duration(seconds: 1));
      expect(
        snapshots.map((snapshot) => snapshot.latestReading!.sensorMinute),
        [60, 61],
      );
      expect(snapshots.first.history.map((point) => point.sensorMinute), [60]);
      expect(snapshots.last.history.map((point) => point.sensorMinute), [
        60,
        61,
      ]);
      await subscription.cancel();
    },
  );

  for (final result in [
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 59,
      sampleAgeMinutes: 59,
      glucoseMgdl: 100,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 59,
      glucoseMgdl: 100,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: double.nan,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: double.infinity,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: 0,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: 100,
      expectedLifetimeMinutes: 60,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: 100,
      expectedLifetimeMinutes: 0,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 65536,
      sampleAgeMinutes: 65536,
      glucoseMgdl: 100,
    ),
    const LibreGen1GlucoseResult(
      sensorAgeMinutes: 60,
      sampleAgeMinutes: 60,
      glucoseMgdl: 100,
      rejection: LibreGen1GlucoseRejection.invalidData,
    ),
  ].indexed) {
    test(
      'decoder rejection ${result.$1} cannot publish glucose or stop transport',
      () async {
        harness.decoderProvider = _DecoderProvider()..result = result.$2;
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        _sendPacket(harness.connection, _encrypted);
        await _waitFor(session, LibreGen1LivePhase.validatedPacket);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
        expect(harness.events.where((e) => e == 'disconnect'), isEmpty);
      },
    );
  }

  for (final failure in ['prepare', 'decode']) {
    test(
      'private $failure errors stay closed and leave streaming intact',
      () async {
        harness.decoderProvider = _DecoderProvider()
          ..prepareFails = failure == 'prepare'
          ..decodeFails = failure == 'decode';
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        _sendPacket(harness.connection, _encrypted);
        await _waitFor(session, LibreGen1LivePhase.validatedPacket);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.lastError, isNull);
        expect(session.currentSnapshot.statusText, isNot(contains('private')));
        expect(harness.events.where((e) => e == 'disconnect'), isEmpty);
      },
    );
  }

  for (final delaySeconds in [40, 119, 149]) {
    test(
      'accepts a first fresh advertisement at $delaySeconds seconds',
      () async {
        harness.transport.autoAdvertise = false;
        final driver = LibreGen1Driver(
          transport: harness.transport,
          bootstrapProvider: harness.store,
          counterStore: harness.store,
          utcNow: () => harness.now,
        );
        final session = harness.session = await driver.connect(_sensor());
        await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
        harness.now = harness.now.add(Duration(seconds: delaySeconds));
        expect(harness.events, isEmpty);
        expect(harness.store.nextCount, 1);
        harness.transport.emit(_advertisement(harness.now));
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        expect(harness.transport.scanTimeout, const Duration(seconds: 150));
        expect(harness.transport.scanCancelCalls, 1);
        expect(harness.transport.scanStoppedAtConnect, isTrue);
        expect(harness.transport.connectCalls, 1);
      },
    );
  }

  test('default 150-second deadline blocks later advertisements', () async {
    void Function()? expireAdvertisementWait;
    await runZoned(
      () async {
        harness.transport.autoAdvertise = false;
        final driver = LibreGen1Driver(
          transport: harness.transport,
          bootstrapProvider: harness.store,
          counterStore: harness.store,
          utcNow: () => harness.now,
        );
        final session = harness.session = await driver.connect(_sensor());
        await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
        expect(expireAdvertisementWait, isNotNull);
        harness.now = harness.now.add(const Duration(seconds: 150));
        expireAdvertisementWait!();
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(
          session.currentStatus.failure,
          LibreGen1LiveFailure.advertisementUnavailable,
        );
        harness.transport.emit(_advertisement(harness.now));
        await Future<void>.delayed(Duration.zero);
        expect(harness.events, isEmpty);
        expect(harness.store.nextCount, 1);
        expect(harness.transport.scanCancelCalls, 1);
        expect(harness.transport.connectCalls, 0);
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 150)) {
            expect(expireAdvertisementWait, isNull);
            expireAdvertisementWait = callback;
            // The deadline callback is advanced explicitly. Its real timer is
            // still cancelled by the normal driver cleanup in this test.
            return parent.createTimer(zone, const Duration(days: 1), callback);
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
  });

  test('advertisement wait cannot exceed the explicit 150-second bound', () {
    for (final invalid in [Duration.zero, const Duration(seconds: 151)]) {
      expect(
        () => LibreGen1Driver(
          transport: harness.transport,
          bootstrapProvider: harness.store,
          counterStore: harness.store,
          advertisementTimeout: invalid,
        ),
        throwsArgumentError,
      );
    }
  });

  test('no advertisement times out without connection or login', () async {
    harness.advertisementTimeout = const Duration(milliseconds: 10);
    harness.transport.autoAdvertise = false;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(
      session.currentStatus.failure,
      LibreGen1LiveFailure.advertisementUnavailable,
    );
    expect(harness.events, isEmpty);
    expect(harness.store.nextCount, 1);
    expect(harness.transport.scanCancelCalls, 1);
    await session.refresh();
    expect(harness.transport.scanCalls, 1);
  });

  test(
    'ignores wrong target, missing service, stale and undated ads',
    () async {
      harness.transport.autoAdvertise = false;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      harness.transport.emit(
        _advertisement(harness.now, deviceId: '02:00:00:00:00:02'),
      );
      harness.transport.emit(_advertisement(harness.now, services: const []));
      harness.transport.emit(
        _advertisement(harness.now.subtract(const Duration(seconds: 1))),
      );
      harness.transport.emit(_advertisement(null));
      harness.transport.emit(
        _advertisement(harness.now.add(const Duration(seconds: 1))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(harness.events, isEmpty);
      expect(harness.store.nextCount, 1);
      harness.transport.emit(_advertisement(harness.now, services: ['fde3']));
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(harness.transport.connectCalls, 1);
    },
  );

  test('cancelling advertisement wait blocks late connect', () async {
    harness.transport.autoAdvertise = false;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
    await session.disconnect();
    harness.transport.emit(_advertisement(harness.now));
    await Future<void>.delayed(Duration.zero);
    expect(harness.events, isEmpty);
    expect(harness.transport.scanCancelCalls, 1);
    expect(session.currentStatus.phase, LibreGen1LivePhase.disconnected);
  });

  test('scan cancellation must complete before connecting', () async {
    harness.transport.cancelGate = Completer<void>();
    final session = await harness.start();
    await Future<void>.delayed(Duration.zero);
    expect(harness.transport.scanCancelCalls, 1);
    expect(harness.events, isEmpty);
    final stopped = session.disconnect();
    harness.transport.cancelGate!.complete();
    await stopped;
    expect(harness.events, isEmpty);
  });

  test(
    'uncertain scan cancellation blocks connect and keeps the lease',
    () async {
      harness.transport.cancelFails = true;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.cleanupUnconfirmed,
      );
      expect(harness.events, isEmpty);
      await expectLater(
        harness.driver.connect(_sensor()),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.sessionInUse,
          ),
        ),
      );
      expect(harness.transport.scanCancelCalls, 1);
      await expectLater(session.disconnect(), throwsA(_cleanupUnconfirmed));
      expect(harness.transport.scanCancelCalls, 1);
    },
  );

  test('unsupported one-shot transport fails before scanning', () async {
    harness.transport.supportsSingleAttemptConnect = false;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(
      session.currentStatus.failure,
      LibreGen1LiveFailure.oneShotUnavailable,
    );
    expect(harness.transport.scanCalls, 0);
    expect(harness.events, isEmpty);
  });

  test(
    'a failed physical connect is not retried and consumes no counter',
    () async {
      harness.transport.connectFails = true;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.connectionFailed,
      );
      expect(harness.transport.connectCalls, 1);
      expect(harness.events, ['connect']);
      expect(harness.store.nextCount, 1);
      harness.transport.emit(_advertisement(harness.now));
      await session.refresh();
      expect(harness.transport.connectCalls, 1);
    },
  );

  test('only the exact NFC response target appears in discovery', () async {
    await harness.driver.reloadBootstrap();
    expect(
      harness.driver.mapScanResult(
        const BleScanResult(
          deviceId: '02:00:00:00:00:02',
          deviceName: 'FreeStyle Libre 2',
          rssi: -40,
          serviceUuids: [LibreUuids.sasService],
        ),
      ),
      isNull,
    );
    final sensor = harness.driver.mapScanResult(
      const BleScanResult(
        deviceId: '02:00:00:00:00:01',
        deviceName: '',
        rssi: -55,
      ),
    );
    expect(sensor?.driverId, LibreGen1Driver.driverIdentifier);
    expect(sensor?.displayName, 'FreeStyle Libre 2');
    expect(sensor?.advertisement, isNull);
  });

  test('missing bootstrap prohibits all BLE operations', () async {
    harness.store.bootstrap = null;
    expect(await harness.driver.reloadBootstrap(), isFalse);
    expect(harness.driver.bootstrappedSensor, isNull);
    await expectLater(
      harness.driver.connect(_sensor()),
      throwsA(
        isA<LibreGen1LiveException>().having(
          (e) => e.kind,
          'kind',
          LibreGen1LiveFailure.bootstrapUnavailable,
        ),
      ),
    );
    expect(harness.events, isEmpty);
  });

  test(
    'read-only restore does not scan, connect, or reserve a counter',
    () async {
      expect(harness.driver.bootstrappedSensor, isNull);
      expect(await harness.driver.reloadBootstrap(), isTrue);
      expect(
        harness.driver.bootstrappedSensor?.storageKey,
        _sensor().storageKey,
      );
      expect(harness.transport.scanCalls, 0);
      expect(harness.transport.connectCalls, 0);
      expect(harness.store.nextCount, 1);
      expect(harness.events, isEmpty);
    },
  );

  test('missing or unreadable restore clears the cached target', () async {
    await harness.driver.reloadBootstrap();
    expect(harness.driver.bootstrappedSensor, isNotNull);
    harness.store.bootstrap = null;
    expect(await harness.driver.reloadBootstrap(), isFalse);
    expect(harness.driver.bootstrappedSensor, isNull);
    expect(harness.driver.mapScanResult(_advertisement(harness.now)), isNull);

    harness.store.bootstrap = _bootstrap();
    await harness.driver.reloadBootstrap();
    harness.store.readFails = true;
    await expectLater(
      harness.driver.reloadBootstrap(),
      throwsA(isA<LibreGen1LiveException>()),
    );
    expect(harness.driver.bootstrappedSensor, isNull);
    expect(harness.driver.mapScanResult(_advertisement(harness.now)), isNull);
    expect(harness.events, isEmpty);
  });

  test(
    'new Dart driver uses next durable count after unknown prior login',
    () async {
      harness.connection.writeFails = true;
      final firstSession = await harness.start();
      await _waitFor(firstSession, LibreGen1LivePhase.failed);
      expect(harness.events, contains('unknown'));
      expect(harness.store.nextCount, 2);
      final firstRequest = List<int>.of(harness.connection.lastWrite!);
      await firstSession.disconnect();

      final restoredEvents = <String>[];
      final restoredConnection = _Connection(restoredEvents);
      final restoredTransport = _Transport(
        restoredConnection,
        restoredEvents,
        () => harness.now,
      );
      final restoredDriver = LibreGen1Driver(
        transport: restoredTransport,
        bootstrapProvider: harness.store,
        counterStore: harness.store,
        utcNow: () => harness.now,
      );
      LibreGen1Session? restoredSession;
      try {
        await restoredDriver.reloadBootstrap();
        expect(restoredEvents, isEmpty);
        expect(restoredTransport.scanCalls, 0);
        expect(harness.store.nextCount, 2);
        restoredSession = await restoredDriver.connect(
          restoredDriver.bootstrappedSensor!,
        );
        await _waitFor(restoredSession, LibreGen1LivePhase.awaitingPacket);
        expect(harness.store.nextCount, 3);
        expect(restoredConnection.lastWrite, isNot(equals(firstRequest)));
        expect(restoredTransport.connectCalls, 1);
        expect(
          restoredSession
              .currentSnapshot
              .metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
      } finally {
        await restoredSession?.disconnect();
        await restoredConnection.packets.close();
        await restoredConnection.states.close();
      }
    },
  );

  for (final lifecycle in [
    LibreGen1LifecycleState.warmingUp,
    LibreGen1LifecycleState.active,
  ]) {
    test(
      'saved ${lifecycle.name} is historical evidence, not a current countdown',
      () async {
        harness.store.bootstrap = _bootstrap(lifecycle: lifecycle);
        // A changed wall clock cannot turn a recorded NFC lifecycle into a
        // verified sensor start, elapsed age, readiness, or glucose reading.
        harness.now = harness.now.add(const Duration(days: 30));
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        _sendPacket(harness.connection, _encrypted);
        await _waitFor(session, LibreGen1LivePhase.validatedPacket);
        final snapshot = session.currentSnapshot;
        expect(
          snapshot.diagnostics.single.fields['lifecycleAtNfcBootstrap'],
          lifecycle.name,
        );
        expect(snapshot.stage, CgmSyncStage.syncing);
        expect(snapshot.sessionInfo.sessionStart, isNull);
        expect(snapshot.sessionInfo.elapsedMinutes, isNull);
        expect(snapshot.latestReading, isNull);
        expect(snapshot.lastAdvertisement, isNull);
        expect(snapshot.history, isEmpty);
        expect(snapshot.rawHistory, isEmpty);
      },
    );
  }

  test(
    'bootstrap replacement prevents a stale selection from connecting',
    () async {
      harness.store.bootstrap = _bootstrap(bootstrapId: 'replacement');
      await expectLater(
        harness.driver.connect(_sensor()),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.targetMismatch,
          ),
        ),
      );
      expect(harness.events, isEmpty);
    },
  );

  test('transport-returned device must still match the NFC address', () async {
    harness.connection.actualDeviceId = '02:00:00:00:00:02';
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(session.currentStatus.failure, LibreGen1LiveFailure.targetMismatch);
    expect(harness.events, ['connect', 'disconnect']);
  });

  for (final invalidCase in [
    'missingLogin',
    'wrongService',
    'noWriteResponse',
    'noNotify',
    'duplicateService',
    'gksAndSas',
  ]) {
    test(
      'rejects $invalidCase before reserving a counter or writing',
      () async {
        harness.connection.invalidTopology = invalidCase;
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(
          session.currentStatus.failure,
          LibreGen1LiveFailure.topologyRejected,
        );
        expect(harness.events, ['connect', 'discover', 'disconnect']);
      },
    );
  }

  test('durable counter failure prevents login', () async {
    harness.store.reserveFails = true;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(
      session.currentStatus.failure,
      LibreGen1LiveFailure.counterUnavailable,
    );
    expect(harness.events, ['connect', 'discover', 'reserve', 'disconnect']);
  });

  for (final count in [0, 65536]) {
    test('counter $count cannot produce a login', () async {
      harness.store.nextCount = count;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(harness.events, ['connect', 'discover', 'reserve', 'disconnect']);
    });
  }

  test(
    'reserve then one with-response login then durable ack then subscribe',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(harness.events, [
        'connect',
        'discover',
        'reserve',
        'write',
        'acknowledged',
        'listen',
        'notify',
      ]);
      expect(harness.connection.withoutResponse, isFalse);
      expect(harness.connection.lastWrite, _hex('79563412c7bb30289c3b68c9'));
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, isEmpty);
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
      expect(session.unsafeAdmin, isNull);
      await session.refresh();
      await session.refreshLiveData();
      expect(harness.events.where((e) => e == 'write').length, 1);
    },
  );

  test(
    'login failure records unknown and does not subscribe or retry',
    () async {
      harness.connection.writeFails = true;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.loginOutcomeUnknown,
      );
      expect(harness.events, [
        'connect',
        'discover',
        'reserve',
        'write',
        'unknown',
        'disconnect',
      ]);
    },
  );

  test('durable ack failure does not subscribe', () async {
    harness.store.ackFails = true;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(harness.events, [
      'connect',
      'discover',
      'reserve',
      'write',
      'acknowledged',
      'unknown',
      'disconnect',
    ]);
  });

  test(
    'disconnect during reservation cannot write from a stale callback',
    () async {
      harness.store.reservationBlock = Completer<void>();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.reservingLogin);
      final stopped = session.disconnect();
      harness.store.reservationBlock!.complete();
      await stopped;
      expect(harness.events, ['connect', 'discover', 'reserve', 'disconnect']);
      expect(session.currentStatus.phase, LibreGen1LivePhase.disconnected);
    },
  );

  test('disconnect during login cannot subscribe after late ack', () async {
    harness.connection.writeBlock = Completer<void>();
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.loggingIn);
    final stopped = session.disconnect();
    harness.connection.writeBlock!.complete();
    await stopped;
    expect(harness.events, [
      'connect',
      'discover',
      'reserve',
      'write',
      'unknown',
      'disconnect',
    ]);
  });

  test(
    'parallel connect is rejected while the first session owns transport',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await expectLater(
        harness.driver.connect(_sensor()),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.sessionInUse,
          ),
        ),
      );
      expect(harness.events.where((e) => e == 'write').length, 1);
    },
  );

  test(
    'valid fragments prove CRC integrity but never publish ADC as glucose',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.validatedPacket);
      expect(session.currentStatus.validatedPacketCount, 1);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, isEmpty);
      expect(session.currentSnapshot.rawHistory, isEmpty);
      final diagnostic = session.currentSnapshot.diagnostics.single;
      expect(diagnostic.rawHex, isEmpty);
      expect(diagnostic.fields['glucoseDecoded'], 'false');
      expect('${session.currentStatus} $diagnostic', isNot(contains('001122')));
    },
  );

  test('notification received inside CCCD ack is buffered until ack', () async {
    harness.connection.duringNotify = () {
      _sendPacket(harness.connection, _encrypted);
    };
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.validatedPacket);
    expect(session.currentStatus.validatedPacketCount, 1);
    expect(
      harness.events.indexOf('acknowledged'),
      lessThan(harness.events.indexOf('notify')),
    );
  });

  test('CRC failure stops output and closes transport without retry', () async {
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    final corrupted = [..._encrypted]..[10] ^= 1;
    _sendPacket(harness.connection, corrupted);
    await _waitFor(session, LibreGen1LivePhase.failed);
    expect(session.currentStatus.failure, LibreGen1LiveFailure.invalidPacket);
    expect(session.currentStatus.validatedPacketCount, 0);
    expect(session.currentSnapshot.latestReading, isNull);
    expect(harness.events.where((e) => e == 'write').length, 1);
  });

  test(
    'out of order fragment is terminal and later fragments do not recover',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      harness.connection.packets.add(List<int>.filled(18, 0));
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(session.currentStatus.validatedPacketCount, 0);
    },
  );

  test(
    'failed disconnect retains lease and blocks a second connection',
    () async {
      harness.decoderProvider = _DecoderProvider();
      harness.connection.disconnectFails = true;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final acceptedHistory = session.currentSnapshot.history;
      final snapshots = <CgmSessionSnapshot>[];
      final subscription = session.snapshots.listen(snapshots.add);
      final stopped = session.disconnect();
      await expectLater(stopped, throwsA(_cleanupUnconfirmed));
      expect(session.disconnect(), same(stopped));
      await expectLater(session.disconnect(), throwsA(_cleanupUnconfirmed));
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.cleanupUnconfirmed,
      );
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, acceptedHistory);
      expect(snapshots.last.lastError, 'libre2.cleanupUnconfirmed');
      expect(harness.events.where((event) => event == 'disconnect').length, 1);
      await subscription.cancel();
      await expectLater(
        harness.driver.connect(_sensor()),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (e) => e.kind,
            'kind',
            LibreGen1LiveFailure.sessionInUse,
          ),
        ),
      );
    },
  );

  test(
    'disconnect timeout stays failed after late transport completion',
    () async {
      var disconnectDeadlines = 0;
      var interceptClose = false;
      await runZoned(
        () async {
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          final gate = harness.connection.disconnectGate = Completer<void>();
          interceptClose = true;
          final stopped = session.disconnect();
          final failed = expectLater(stopped, throwsA(_cleanupUnconfirmed));
          await failed;
          expect(disconnectDeadlines, 1);
          expect(
            session.currentStatus.failure,
            LibreGen1LiveFailure.cleanupUnconfirmed,
          );
          gate.complete();
          await Future<void>.delayed(Duration.zero);
          await expectLater(session.disconnect(), throwsA(_cleanupUnconfirmed));
          await expectLater(
            harness.driver.connect(_sensor()),
            throwsA(
              isA<LibreGen1LiveException>().having(
                (error) => error.kind,
                'kind',
                LibreGen1LiveFailure.sessionInUse,
              ),
            ),
          );
          expect(
            harness.events.where((event) => event == 'disconnect').length,
            1,
          );
          expect(harness.transport.connectCalls, 1);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (interceptClose && duration == const Duration(seconds: 15)) {
              disconnectDeadlines += 1;
              // Advance the real timeout timer so it is inactive before the
              // original transport future completes; a manual callback alone
              // would not model Future.timeout's late-completion guard.
              return parent.createTimer(zone, Duration.zero, callback);
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  test('bootstrap rejects non-live lifecycle and redacts material', () {
    for (final state in LibreGen1LifecycleState.values.where(
      (state) =>
          state != LibreGen1LifecycleState.warmingUp &&
          state != LibreGen1LifecycleState.active,
    )) {
      expect(
        () => _bootstrap(lifecycle: state),
        throwsA(isA<LibreGen1LiveException>()),
      );
    }
    expect(_bootstrap().toString(), contains('<redacted>'));
  });
}

Future<void> _waitFor(
  LibreGen1Session session,
  LibreGen1LivePhase phase,
) async {
  if (session.currentStatus.phase != phase) {
    await session.statuses
        .firstWhere((s) => s.phase == phase)
        .timeout(const Duration(seconds: 2));
  }
  await Future<void>.delayed(Duration.zero);
}

LibreGen1StreamingBootstrap _bootstrap({
  String bootstrapId = 'synthetic',
  int streamingBase = 0x12345678,
  LibreGen1LifecycleState lifecycle = LibreGen1LifecycleState.warmingUp,
}) => LibreGen1StreamingBootstrap(
  bootstrapId: bootstrapId,
  deviceId: '02:00:00:00:00:01',
  uid: LibreGen1Uid.algorithmOrder(_hex('0011223344556677')),
  initialPatchInfo: LibreGen1PatchInfo(_hex('9d0830013412')),
  streamingBase: streamingBase,
  lifecycle: lifecycle,
);

DiscoveredSensor _sensor() => const DiscoveredSensor(
  driverId: LibreGen1Driver.driverIdentifier,
  deviceId: '02:00:00:00:00:01',
  displayName: 'FreeStyle Libre 2',
  storageKey: 'libre2-gen1:synthetic',
  rssi: 0,
  capabilities: LibreGen1Driver.capabilities,
);

class _Harness {
  final events = <String>[];
  DateTime now = DateTime.utc(2026, 1, 1);
  Duration advertisementTimeout = const Duration(seconds: 150);
  int historyLimit = 0x10000;
  _DecoderProvider? decoderProvider;
  late final store = _Store(events);
  late final connection = _Connection(events);
  late final transport = _Transport(connection, events, () => now);
  late final driver = LibreGen1Driver(
    transport: transport,
    bootstrapProvider: store,
    counterStore: store,
    glucoseDecoderProvider: decoderProvider,
    historyLimit: historyLimit,
    advertisementTimeout: advertisementTimeout,
    utcNow: () => now,
  );
  LibreGen1Session? session;
  Future<LibreGen1Session> start() async =>
      session = await driver.connect(_sensor());
}

class _Store
    implements LibreGen1StreamingBootstrapProvider, LibreGen1LoginCounterStore {
  _Store(this.events);
  final List<String> events;
  LibreGen1StreamingBootstrap? bootstrap = _bootstrap();
  int nextCount = 1;
  bool reserveFails = false;
  bool readFails = false;
  bool ackFails = false;
  int readCalls = 0;
  Completer<void>? readGate;
  Completer<void>? reservationBlock;
  @override
  Future<LibreGen1StreamingBootstrap?> readBootstrap() async {
    readCalls += 1;
    await readGate?.future;
    if (readFails) throw StateError('synthetic protected store read failure');
    return bootstrap;
  }

  @override
  Future<int> reserveNextUnlockCount(String bootstrapId) async {
    events.add('reserve');
    await reservationBlock?.future;
    if (reserveFails) throw StateError('synthetic private native error');
    return nextCount++;
  }

  @override
  Future<void> markLoginOutcome(
    String bootstrapId,
    int unlockCount,
    LibreGen1LoginOutcome outcome,
  ) async {
    events.add(outcome.name);
    if (ackFails && outcome == LibreGen1LoginOutcome.acknowledged) {
      throw StateError('synthetic private native error');
    }
  }
}

class _Transport implements BleTransport, BleSingleAttemptTransport {
  _Transport(this.connection, this.events, this.now);
  _Connection connection;
  final List<String> events;
  final DateTime Function() now;
  bool autoAdvertise = true;
  bool cancelFails = false;
  bool connectFails = false;
  @override
  bool supportsSingleAttemptConnect = true;
  Completer<void>? cancelGate;
  StreamController<BleScanResult>? advertisements;
  Duration? scanTimeout;
  int scanCalls = 0;
  int scanCancelCalls = 0;
  int connectCalls = 0;
  bool scanStopped = false;
  bool? scanStoppedAtConnect;
  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => fail('Libre must not use the default retrying connection');

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connectCalls += 1;
    scanStoppedAtConnect = scanStopped;
    events.add('connect');
    if (connectFails) throw TimeoutException('synthetic connect failure');
    return connection;
  }

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanCalls += 1;
    scanTimeout = timeout;
    expect(allowDuplicates, isTrue);
    expect(withServices, [LibreUuids.sasService]);
    advertisements = StreamController<BleScanResult>(
      onListen: () {
        if (autoAdvertise) scheduleMicrotask(() => emit(_advertisement(now())));
      },
      onCancel: () async {
        scanCancelCalls += 1;
        await cancelGate?.future;
        if (cancelFails) {
          throw StateError('synthetic scan cancellation failure');
        }
        scanStopped = true;
      },
    );
    return advertisements!.stream;
  }

  void emit(BleScanResult result) => advertisements?.add(result);
}

BleScanResult _advertisement(
  DateTime? observedAt, {
  String deviceId = '02:00:00:00:00:01',
  List<String> services = const [LibreUuids.sasService],
}) => BleScanResult(
  deviceId: deviceId,
  deviceName: '',
  rssi: -55,
  serviceUuids: services,
  observedAt: observedAt,
);

class _Connection implements BleConnection {
  _Connection(this.events);
  final List<String> events;
  final packets = StreamController<List<int>>.broadcast(sync: true);
  final states = StreamController<BleConnectionState>.broadcast(sync: true);
  String actualDeviceId = '02:00:00:00:00:01';
  String? invalidTopology;
  bool writeFails = false;
  bool disconnectFails = false;
  bool? withoutResponse;
  List<int>? lastWrite;
  Completer<void>? writeBlock;
  Completer<void>? disconnectGate;
  void Function()? duringNotify;
  @override
  String get deviceId => actualDeviceId;
  @override
  Stream<BleConnectionState> get connectionStates => states.stream;
  @override
  bool get supportsBondLifecycle => true;
  @override
  Future<List<BleService>> discoverServices() async {
    events.add('discover');
    final sas = BleService(
      uuid: 'fde3',
      characteristics: [
        if (invalidTopology != 'missingLogin')
          BleCharacteristicRef(
            serviceUuid: invalidTopology == 'wrongService' ? '180f' : 'fde3',
            characteristicUuid: 'f001',
            properties: BleCharacteristicProperties(
              write: invalidTopology != 'noWriteResponse',
              writeWithoutResponse: true,
            ),
          ),
        BleCharacteristicRef(
          serviceUuid: 'fde3',
          characteristicUuid: 'f002',
          properties: BleCharacteristicProperties(
            notify: invalidTopology != 'noNotify',
          ),
        ),
      ],
    );
    return [
      sas,
      if (invalidTopology == 'duplicateService') sas,
      if (invalidTopology == 'gksAndSas')
        const BleService(uuid: LibreUuids.gksDataService, characteristics: []),
    ];
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    events.add('write');
    expect(
      normalizeLibreUuid(characteristic.characteristicUuid),
      LibreUuids.sasLogin,
    );
    this.withoutResponse = withoutResponse;
    lastWrite = List.of(value);
    await writeBlock?.future;
    if (writeFails) throw StateError('synthetic private native error');
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) {
    events.add('listen');
    expect(
      normalizeLibreUuid(characteristic.characteristicUuid),
      LibreUuids.sasData,
    );
    return packets.stream;
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    events.add('notify');
    expect(enabled, isTrue);
    duringNotify?.call();
  }

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    await disconnectGate?.future;
    if (disconnectFails) throw StateError('synthetic private native error');
  }

  @override
  Future<void> ensureBonded() async => fail('No bond operation permitted');
  @override
  Future<BleBondState> currentBondState() async =>
      fail('No bond operation permitted');
  @override
  Future<void> removeBond() async => fail('No bond operation permitted');
  @override
  Future<void> requestMtu(int mtu) async => fail('No MTU operation permitted');
  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async =>
      fail('No characteristic read permitted');
}

_Connection _replacement(_Harness harness) {
  final connection = _Connection(harness.events);
  harness.transport.connection = connection;
  addTearDown(() async {
    await connection.packets.close();
    await connection.states.close();
  });
  return connection;
}

class _DecoderProvider
    implements LibreGen1GlucoseDecoderProvider, LibreGen1GlucoseDecoder {
  int preparations = 0;
  int decodeCalls = 0;
  bool prepareFails = false;
  Completer<void>? prepareGate;
  bool decodeFails = false;
  void Function()? afterDecode;
  LibreGen1GlucoseResult result = const LibreGen1GlucoseResult(
    sensorAgeMinutes: 60,
    sampleAgeMinutes: 60,
    glucoseMgdl: 100,
  );
  @override
  Future<LibreGen1GlucoseDecoder?> prepare(
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    preparations += 1;
    await prepareGate?.future;
    if (prepareFails) throw StateError('private synthetic evidence');
    return this;
  }

  @override
  LibreGen1GlucoseResult decode({
    required List<int> encryptedPacket,
    required DateTime receivedAt,
  }) {
    decodeCalls += 1;
    if (decodeFails) throw StateError('private synthetic decoder');
    expect(encryptedPacket.length, 46);
    afterDecode?.call();
    return result;
  }
}

final _encrypted = _hex(
  '1234471336ff3b472ad9beded5f439d8ac2321e91148671898c6d9a87115'
  '374fe9548541dfbb9084271c356f1acf',
);
void _sendPacket(_Connection connection, List<int> bytes) {
  connection.packets.add(bytes.sublist(0, 20));
  connection.packets.add(bytes.sublist(20, 38));
  connection.packets.add(bytes.sublist(38));
}

Future<void> _receivePacket(
  LibreGen1Session session,
  _Connection connection,
) async {
  final previousCount = session.currentStatus.validatedPacketCount;
  final received = session.statuses
      .firstWhere((status) => status.validatedPacketCount > previousCount)
      .timeout(const Duration(seconds: 1));
  _sendPacket(connection, _encrypted);
  await received;
}

LibreGen1GlucoseResult _currentSample(int minute, double glucose) =>
    LibreGen1GlucoseResult(
      sensorAgeMinutes: minute,
      sampleAgeMinutes: minute,
      glucoseMgdl: glucose,
    );

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

final _cleanupUnconfirmed = isA<LibreGen1LiveException>().having(
  (error) => error.kind,
  'kind',
  LibreGen1LiveFailure.cleanupUnconfirmed,
);
