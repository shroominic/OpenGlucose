import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

import 'support/gen1_timing_fixtures.dart';

void main() {
  late _Harness harness;
  setUp(() => harness = _Harness());
  tearDown(() async {
    try {
      await harness.session?.disconnect();
    } on LibreGen1LiveException catch (error) {
      // Some tests deliberately leave quarantined physical ownership.
      expect(
        error.kind,
        anyOf(
          LibreGen1LiveFailure.cleanupUnconfirmed,
          LibreGen1LiveFailure.observationStorageUnavailable,
        ),
      );
    }
    await harness.connection.packets.close();
    await harness.connection.states.close();
  });

  for (final durable in [false, true]) {
    for (final minute in [61, 75, 120, 121, 122, 137, 65534]) {
      test(
        'BLE sparse history uses exact slot timing at $minute (durable=$durable)',
        () async {
          if (durable) harness.observations = _ObservationStore();
          final result = _packetWithHistory(minute);
          harness.decoderProvider = _DecoderProvider()..result = result;
          final receipt = harness.now;
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          await _receivePacket(session, harness.connection, minute: minute);
          final expected = {
            minute,
            for (final sample in result.historySamples)
              if (sample.sampleAgeMinutes >= 60) sample.sampleAgeMinutes,
          }.toList()..sort();
          final history = session.currentSnapshot.history;
          expect(history.map((reading) => reading.sensorMinute), expected);
          for (final reading in history) {
            expect(
              reading.recordedAt,
              receipt.subtract(
                Duration(minutes: minute - reading.sensorMinute!),
              ),
            );
            expect(reading.source, CgmRecordSource.vendor);
            expect(reading.isDisplayProvisional, isTrue);
          }
          expect(session.currentSnapshot.latestReading!.sensorMinute, minute);
          expect(session.currentSnapshot.latestReading!.recordedAt, receipt);
          if (minute == 121) {
            expect(expected, [75, 90, 105, 106, 109, 114, 115, 117, 119, 121]);
          }
          if (durable) {
            expect(harness.observations!.committedMinutes, [minute]);
            expect(
              () => harness.observations!.lastHistoricalReadings.clear(),
              throwsUnsupportedError,
            );
          }
        },
      );
    }
    for (final rejection in LibreGen1GlucoseRejection.values) {
      test(
        'valid BLE history survives rejected current $rejection (durable=$durable)',
        () async {
          if (durable) harness.observations = _ObservationStore();
          harness.decoderProvider = _DecoderProvider()
            ..result = _packetWithHistory(121, currentRejection: rejection);
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          await _receivePacket(session, harness.connection, minute: 121);
          expect(session.currentSnapshot.latestReading, isNull);
          expect(session.currentSnapshot.history, hasLength(9));
          expect(
            session.currentSnapshot.history.map(
              (reading) => reading.sensorMinute,
            ),
            [75, 90, 105, 106, 109, 114, 115, 117, 119],
          );
          expect(
            session.currentSnapshot.history.any(
              (reading) => reading.sensorMinute == 121,
            ),
            isFalse,
          );
        },
      );
    }
  }

  for (final rejectedTrend in [false, true]) {
    test(
      'same-minute BLE overlap prefers accepted trend (rejected=$rejectedTrend)',
      () async {
        final observations = harness.observations = _ObservationStore();
        harness.decoderProvider = _DecoderProvider()
          ..result = _packetWithHistory(
            120,
            history: [
              _historySample(
                105,
                LibreGen1BleHistoryKind.history,
                glucose: 101,
              ),
              _historySample(
                105,
                LibreGen1BleHistoryKind.trend,
                glucose: rejectedTrend ? null : 102,
                rejection: rejectedTrend
                    ? LibreGen1GlucoseRejection.invalidData
                    : null,
              ),
            ],
          );
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        await _receivePacket(session, harness.connection, minute: 120);
        expect(session.currentSnapshot.history, hasLength(2));
        expect(
          session.currentSnapshot.history.first.valueMgdl,
          rejectedTrend ? 101 : 102,
        );
        expect(
          observations.lastHistoricalReadings.single.kind,
          rejectedTrend
              ? LibreGen1BleHistoryKind.history
              : LibreGen1BleHistoryKind.trend,
        );
      },
    );
  }

  final malformedHistory = <String, List<LibreGen1GlucoseHistorySample>>{
    'too many': [
      for (var i = 0; i < 10; i++)
        _historySample(119, LibreGen1BleHistoryKind.trend),
    ],
    'duplicate slot': [
      _historySample(119, LibreGen1BleHistoryKind.trend),
      _historySample(119, LibreGen1BleHistoryKind.trend),
    ],
    'wrong kind': [_historySample(119, LibreGen1BleHistoryKind.history)],
    'current': [_historySample(121, LibreGen1BleHistoryKind.trend)],
    'future': [_historySample(122, LibreGen1BleHistoryKind.trend)],
    'wrong trend offset': [_historySample(120, LibreGen1BleHistoryKind.trend)],
    'wrong history delay': [
      _historySample(120, LibreGen1BleHistoryKind.history),
    ],
    'rejection with value': [
      _historySample(
        119,
        LibreGen1BleHistoryKind.trend,
        rejection: LibreGen1GlucoseRejection.invalidData,
      ),
    ],
  };
  for (final entry in malformedHistory.entries) {
    test('malformed BLE historical shape is rejected: ${entry.key}', () async {
      final observations = harness.observations = _ObservationStore();
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(121, history: entry.value);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: 121);
      expect(session.currentSnapshot.history, isEmpty);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(
        observations.state.observedMinute,
        121,
      ); // Valid CRC still consumes age.
      expect(observations.lastHistoricalReadings, isEmpty);
      expect(session.currentStatus.failure, isNull);
    });
  }

  test('per-slot invalid glucose skips only that older BLE slot', () async {
    harness.observations = _ObservationStore();
    harness.decoderProvider = _DecoderProvider()
      ..result = _packetWithHistory(
        121,
        history: [
          _historySample(
            119,
            LibreGen1BleHistoryKind.trend,
            glucose: double.nan,
          ),
          _historySample(117, LibreGen1BleHistoryKind.trend, glucose: 0),
          _historySample(115, LibreGen1BleHistoryKind.trend, glucose: null),
          _historySample(114, LibreGen1BleHistoryKind.trend, glucose: 104),
          _historySample(
            105,
            LibreGen1BleHistoryKind.history,
            glucose: null,
            rejection: LibreGen1GlucoseRejection.invalidData,
          ),
        ],
      );
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, harness.connection, minute: 121);
    expect(
      session.currentSnapshot.history.map((reading) => reading.sensorMinute),
      [114, 121],
    );
  });

  test('invalid packet lifetime cannot retain any BLE history', () async {
    harness.observations = _ObservationStore();
    harness.decoderProvider = _DecoderProvider()
      ..result = LibreGen1GlucoseResult(
        sensorAgeMinutes: 121,
        sampleAgeMinutes: 121,
        glucoseMgdl: 100,
        expectedLifetimeMinutes: 121,
        historySamples: _packetWithHistory(121).historySamples,
      );
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, harness.connection, minute: 121);
    expect(session.currentSnapshot.history, isEmpty);
    expect(session.currentSnapshot.latestReading, isNull);
  });

  for (final durable in [false, true]) {
    test(
      'BLE duplicate packets and old slots preserve first acquisition (durable=$durable)',
      () async {
        if (durable) harness.observations = _ObservationStore();
        final provider = harness.decoderProvider = _DecoderProvider()
          ..result = _packetWithHistory(120);
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        await _receivePacket(session, harness.connection, minute: 120);
        final original = session.currentSnapshot.history.firstWhere(
          (reading) => reading.sensorMinute == 120,
        );
        final firstHistory = List<CgmReading>.of(
          session.currentSnapshot.history,
        );
        harness.now = harness.now.add(const Duration(hours: 1));
        provider.result = _packetWithHistory(120, glucose: 200);
        await _receivePacket(session, harness.connection, minute: 120);
        expect(session.currentSnapshot.history, firstHistory);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(provider.decodeCalls, 1);
        provider.result = _packetWithHistory(122, glucose: 200);
        await _receivePacket(session, harness.connection, minute: 122);
        final retained = session.currentSnapshot.history.firstWhere(
          (reading) => reading.sensorMinute == 120,
        );
        expect(retained, same(original));
        expect(session.currentSnapshot.latestReading!.sensorMinute, 122);
      },
    );
  }

  test('nonpersistent BLE history stays sorted and bounded', () async {
    harness.historyLimit = 4;
    harness.decoderProvider = _DecoderProvider()
      ..result = _packetWithHistory(121);
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, harness.connection, minute: 121);
    expect(
      session.currentSnapshot.history.map((reading) => reading.sensorMinute),
      [115, 117, 119, 121],
    );
    harness.decoderProvider!.result = _packetWithHistory(122);
    await _receivePacket(session, harness.connection, minute: 122);
    expect(
      session.currentSnapshot.history.map((reading) => reading.sensorMinute),
      [119, 120, 121, 122],
    );
  });

  test('BLE history batch respects an existing clear cutoff', () async {
    final observations = harness.observations = _ObservationStore()
      ..state = LibreGen1ObservationState(observedMinute: 95)
      ..clearedThroughMinute = 95;
    harness.decoderProvider = _DecoderProvider()
      ..result = _packetWithHistory(121);
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, harness.connection, minute: 121);
    expect(
      session.currentSnapshot.history.every(
        (reading) => reading.sensorMinute! > 95,
      ),
      isTrue,
    );
    expect(observations.state.history, hasLength(8));
    expect(session.currentStatus.failure, isNull);
  });

  test(
    'stale durable BLE batch remains history without current freshness',
    () async {
      var monotonic = Duration.zero;
      harness.observationMonotonicNow = () => monotonic;
      harness.timingFreshness = const Duration(seconds: 1);
      harness.observations = _ObservationStore();
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(121)
        ..afterDecode = () => monotonic = const Duration(seconds: 2);
      final receipt = harness.now;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: 121);
      expect(session.currentSnapshot.history, hasLength(10));
      expect(session.currentSnapshot.history.last.recordedAt, receipt);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
    },
  );

  test(
    'cancelled durable BLE batch retains history but never publishes live',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitGate = Completer<void>();
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(121);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, blePacketAtMinute(121));
      await observations.commitStarted.future;
      final later = <CgmSessionSnapshot>[];
      session.snapshots.listen(later.add);
      final closing = session.disconnect();
      await Future<void>.delayed(Duration.zero);
      observations.commitGate!.complete();
      await closing;
      expect(observations.state.history, hasLength(10));
      expect(observations.committedMinutes, [121]);
      expect(later.every((snapshot) => snapshot.latestReading == null), isTrue);
      expect(later.any(_hasCommittedObservation), isFalse);
    },
  );

  test(
    'store cannot acknowledge a new BLE batch while dropping history',
    () async {
      harness.observations = _ObservationStore()..dropHistoricalReading = true;
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(121);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, blePacketAtMinute(121));
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
      expect(session.currentSnapshot.latestReading, isNull);
      await expectLater(session.disconnect(), throwsA(_storageUnavailable));
    },
  );

  test(
    'a returned old-hole candidate cannot change the supplied BLE value',
    () async {
      harness.observations = _ObservationStore()
        ..state = LibreGen1ObservationState(observedMinute: 120)
        ..alterHistoricalReading = true;
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(
          122,
          history: [_historySample(118, LibreGen1BleHistoryKind.trend)],
        );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, blePacketAtMinute(122));
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
      await expectLater(session.disconnect(), throwsA(_storageUnavailable));
    },
  );

  test(
    'trimmed presentation history does not lose first-acquisition ack evidence',
    () async {
      final old = CgmReading(
        valueMgdl: 87,
        source: CgmRecordSource.vendor,
        sensorMinute: 118,
        recordedAt: harness.now,
        isDisplayProvisional: true,
      );
      harness.historyLimit = 1;
      harness.observations = _ObservationStore()
        ..state = LibreGen1ObservationState(
          observedMinute: 120,
          history: [old, old.copyWith(sensorMinute: 120)],
        );
      harness.decoderProvider = _DecoderProvider()
        ..result = _packetWithHistory(
          122,
          history: [_historySample(118, LibreGen1BleHistoryKind.trend)],
        );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: 122);
      expect(session.currentStatus.failure, isNull);
      expect(harness.observations!.state.history.first, same(old));
      expect(session.currentSnapshot.history.single.sensorMinute, 122);
    },
  );

  test('durable mode requires a store and bounded queue/deadline', () {
    LibreGen1Driver build({
      bool requireStore = false,
      Duration timeout = const Duration(seconds: 5),
      int limit = 3,
    }) => LibreGen1Driver(
      transport: harness.transport,
      bootstrapProvider: harness.store,
      counterStore: harness.store,
      requireDurableObservations: requireStore,
      observationTimeout: timeout,
      observationQueueLimit: limit,
    );
    expect(() => build(requireStore: true), throwsArgumentError);
    expect(() => build(timeout: Duration.zero), throwsArgumentError);
    expect(
      () => build(timeout: const Duration(seconds: 6)),
      throwsArgumentError,
    );
    expect(() => build(limit: 0), throwsArgumentError);
    expect(() => build(limit: 4), throwsArgumentError);
    expect(harness.events, isEmpty);
  });

  test('durable restore finishes before any BLE operation', () async {
    final observations = harness.observations = _ObservationStore()
      ..loadGate = Completer<void>();
    final starting = harness.start();
    await observations.loadStarted.future;
    expect(harness.events, isEmpty);
    expect(harness.transport.scanCalls, 0);
    observations.loadGate!.complete();
    final session = await starting;
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    expect(observations.bindings.single.storageKey, _sensor().storageKey);
  });

  test('durable early packet keeps its pre-CCCD-ack receipt time', () async {
    harness.observations = _ObservationStore();
    harness.decoderProvider = _DecoderProvider();
    final receivedAt = harness.now;
    harness.connection.duringNotify = () {
      _sendPacket(harness.connection, _encrypted);
      harness.now = harness.now.add(const Duration(hours: 2));
    };
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.validatedPacket);
    expect(session.currentSnapshot.history.single.recordedAt, receivedAt);
  });

  for (final priorLiveMinute in [null, 50]) {
    test(
      'NFC replay barrier does not become live timing ($priorLiveMinute)',
      () async {
        final imported = CgmReading(
          valueMgdl: 105,
          source: CgmRecordSource.vendor,
          sensorMinute: 75,
          recordedAt: harness.now.subtract(const Duration(minutes: 15)),
          isDisplayProvisional: true,
        );
        final observations = harness.observations = _ObservationStore()
          ..state = LibreGen1ObservationState(
            observedMinute: priorLiveMinute,
            replayBarrierMinute: 90,
            history: [imported],
          );
        harness.decoderProvider = _DecoderProvider();
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        expect(session.currentSnapshot.history, [imported]);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
        expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
        for (final minute in [60, 90]) {
          await _receivePacket(session, harness.connection, minute: minute);
          expect(session.currentSnapshot.latestReading, isNull);
          expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
          expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
          expect(observations.state.observedMinute, priorLiveMinute);
          expect(harness.decoderProvider!.decodeCalls, 0);
        }
        harness.decoderProvider!.result = _currentSample(91, 106);
        await _receivePacket(session, harness.connection, minute: 91);
        expect(observations.state.observedMinute, 91);
        expect(session.currentSnapshot.latestReading!.sensorMinute, 91);
        expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
      },
    );
  }

  test(
    'NFC import ordered before BLE commit rejects stale live publication',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..state = LibreGen1ObservationState(observedMinute: 50);
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      observations.state = LibreGen1ObservationState(
        observedMinute: 50,
        replayBarrierMinute: 90,
      );
      await _receivePacket(session, harness.connection, minute: 60);
      expect(session.currentStatus.failure, isNull);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
      expect(observations.state.observedMinute, 50);
      expect(observations.state.effectiveReplayBarrierMinute, 90);
    },
  );

  test('failed durable restore cannot scan or consume a login count', () async {
    final observations = harness.observations = _ObservationStore()
      ..loadFails = true;
    await expectLater(harness.start(), throwsA(_storageUnavailable));
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
    expect(observations.bindings, hasLength(1));
    expect(harness.session, isNull);
    expect(harness.events, isEmpty);
    expect(harness.transport.scanCalls, 0);
    expect(harness.transport.connectCalls, 0);
    expect(harness.store.nextCount, 1);
  });

  for (final lateFailure in [false, true]) {
    test(
      'timed-out restore stays quarantined after late ${lateFailure ? 'failure' : 'success'}',
      () async {
        final observations = harness.observations = _ObservationStore()
          ..loadGate = Completer<void>()
          ..loadFails = lateFailure;
        harness.observationTimeout = const Duration(seconds: 4);
        final timers = <_ControlledTimer>[];
        Future<void> expectBlockedWithoutRf() async {
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
          expect(observations.bindings, hasLength(1));
          expect(harness.session, isNull);
          expect(harness.events, isEmpty);
          expect(harness.transport.scanCalls, 0);
          expect(harness.transport.connectCalls, 0);
          expect(harness.store.nextCount, 1);
        }

        await runZoned(
          () async {
            final failedStart = expectLater(
              harness.start(),
              throwsA(_storageUnavailable),
            );
            await observations.loadStarted.future;
            timers.singleWhere((timer) => timer.isActive).fire();
            await failedStart;
            await expectBlockedWithoutRf();
            observations.loadGate!.complete();
            await Future<void>.delayed(Duration.zero);
            await expectBlockedWithoutRf();
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration == harness.observationTimeout) {
                final timer = _ControlledTimer(() => zone.runGuarded(callback));
                timers.add(timer);
                return timer;
              }
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
      },
    );
  }

  test('durable reading and timing wait for atomic commit', () async {
    final observations = harness.observations = _ObservationStore()
      ..commitGate = Completer<void>();
    harness.decoderProvider = _DecoderProvider();
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    final firstReceipt = harness.now;
    final received = _receivePacket(session, harness.connection);
    await observations.commitStarted.future;
    expect(session.currentSnapshot.latestReading, isNull);
    expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
    expect(session.currentSnapshot.history, isEmpty);
    expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
    expect(observations.state.observedMinute, isNull);
    harness.now = harness.now.add(const Duration(hours: 1));
    observations.commitGate!.complete();
    await received;
    final reading = session.currentSnapshot.history.single;
    expect(reading.recordedAt, firstReceipt);
    expect(reading.source, CgmRecordSource.vendor);
    expect(reading.isDisplayProvisional, isTrue);
    expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 60);
    expect(observations.state.history.single, same(reading));
    expect(observations.state.observedMinute, 60);
    expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
  });

  for (final mode in ['reading', 'warmup', 'rejected', 'missingDecoder']) {
    test('durable $mode frontier survives a new Dart driver', () async {
      final observations = harness.observations = _ObservationStore();
      final minute = mode == 'warmup' ? 59 : 60;
      if (mode != 'missingDecoder') {
        harness.decoderProvider = _DecoderProvider()
          ..result = mode == 'rejected'
              ? const LibreGen1GlucoseResult(
                  sensorAgeMinutes: 60,
                  rejection: LibreGen1GlucoseRejection.invalidData,
                )
              : _currentSample(minute, 100);
      }
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: minute);
      final firstHistory = observations.state.history;
      expect(observations.state.observedMinute, minute);
      expect(firstHistory.length, mode == 'reading' ? 1 : 0);
      expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
      expect(
        session.currentSnapshot.stage,
        mode == 'reading' ? CgmSyncStage.ready : CgmSyncStage.syncing,
      );
      await session.disconnect();
      expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
      final next = _Harness()
        ..observations = observations
        ..decoderProvider = (_DecoderProvider()
          ..result = _currentSample(minute, 120))
        ..now = harness.now.add(const Duration(days: 1));
      addTearDown(() async {
        await next.session?.disconnect();
        await next.connection.packets.close();
        await next.connection.states.close();
      });
      final resumed = await next.start();
      await _waitFor(resumed, LibreGen1LivePhase.awaitingPacket);
      expect(resumed.currentSnapshot.history, firstHistory);
      expect(resumed.currentSnapshot.latestReading, isNull);
      expect(resumed.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(resumed.currentSnapshot.sessionInfo.sessionStart, isNull);
      expect(_hasCommittedObservation(resumed.currentSnapshot), isFalse);
      await _receivePacket(resumed, next.connection, minute: minute);
      expect(resumed.currentSnapshot.latestReading, isNull);
      expect(resumed.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(next.decoderProvider!.decodeCalls, 0);
      expect(_hasCommittedObservation(resumed.currentSnapshot), isFalse);
      expect(observations.state.history, firstHistory);
      next.decoderProvider!.result = _currentSample(61, 121);
      await _receivePacket(resumed, next.connection, minute: 61);
      expect(observations.state.observedMinute, 61);
      expect(resumed.currentSnapshot.latestReading!.sensorMinute, 61);
      expect(_hasCommittedObservation(resumed.currentSnapshot), isTrue);
    });
  }

  test(
    'committed selection evidence excludes replay, regression, expiry and failure',
    () async {
      harness.observations = _ObservationStore();
      final timers = <_ControlledTimer>[];
      // Keep receipt-clock arithmetic exact while advancing only the expiry.
      harness.observationMonotonicNow = () => Duration.zero;
      await runZoned(
        () async {
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
          await _receivePacket(session, harness.connection, minute: 59);
          expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
          expect(session.currentSnapshot.latestReading, isNull);
          expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
          for (final minute in [59, 58]) {
            await _receivePacket(session, harness.connection, minute: minute);
            expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
          }
          await _receivePacket(session, harness.connection, minute: 60);
          expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
          final expired = session.snapshots.firstWhere(
            (snapshot) => snapshot.metadata['cgm.libre2.timing'] == 'stale',
          );
          timers.singleWhere((timer) => timer.isActive).fire();
          final stale = await expired;
          expect(_hasCommittedObservation(stale), isFalse);
          expect(stale.latestReading, isNull);
          expect(stale.sessionInfo.elapsedMinutes, isNull);
          expect(stale.stage, CgmSyncStage.syncing);
          await _receivePacket(session, harness.connection, minute: 61);
          expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
          final corrupt = List<int>.of(blePacketAtMinute(62));
          corrupt[0] ^= 1;
          _sendPacket(harness.connection, corrupt);
          await _waitFor(session, LibreGen1LivePhase.failed);
          expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
          expect(
            session.currentStatus.failure,
            LibreGen1LiveFailure.invalidPacket,
          );
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == harness.timingFreshness) {
              final timer = _ControlledTimer(() => zone.runGuarded(callback));
              timers.add(timer);
              return timer;
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  test(
    'durable commit failure closes RF without publishing a reading',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitFails = true;
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
      expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
      await expectLater(session.disconnect(), throwsA(_storageUnavailable));
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
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(session.currentSnapshot.history, isEmpty);
      expect(observations.state.observedMinute, isNull);
      expect(harness.events.where((event) => event == 'write'), hasLength(1));
      expect(harness.events, contains('disconnect'));
    },
  );

  test(
    'disconnect waits for dispatched commit but never publishes it live',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitGate = Completer<void>();
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await observations.commitStarted.future;
      final later = <CgmSessionSnapshot>[];
      session.snapshots.listen(later.add);
      var closed = false;
      final closing = session.disconnect().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(harness.events, contains('disconnect'));
      expect(closed, isFalse);
      _sendPacket(harness.connection, blePacketAtMinute(61));
      observations.commitGate!.complete();
      await closing;
      expect(later.every((snapshot) => snapshot.latestReading == null), isTrue);
      expect(later.any(_hasCommittedObservation), isFalse);
      expect(session.currentSnapshot.history.single.sensorMinute, 60);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(observations.committedMinutes, [60]);
      expect(observations.state.history.single.sensorMinute, 60);
    },
  );

  test(
    'durable queue is bounded and cannot silently accept overflow',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitGate = Completer<void>();
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await observations.commitStarted.future;
      _sendPacket(harness.connection, blePacketAtMinute(61));
      _sendPacket(harness.connection, blePacketAtMinute(62));
      _sendPacket(harness.connection, blePacketAtMinute(63));
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationQueueOverflow,
      );
      observations.commitGate!.complete();
      await session.disconnect();
      expect(observations.committedMinutes, [60]);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history.single.sensorMinute, 60);
    },
  );

  test(
    'timed-out commit stays quarantined after its late durable reply',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitGate = Completer<void>();
      harness.decoderProvider = _DecoderProvider();
      harness.observationTimeout = const Duration(seconds: 4);
      final timers = <_ControlledTimer>[];
      await runZoned(
        () async {
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          _sendPacket(harness.connection, _encrypted);
          await observations.commitStarted.future;
          timers.singleWhere((timer) => timer.isActive).fire();
          await _waitFor(session, LibreGen1LivePhase.failed);
          await expectLater(session.disconnect(), throwsA(_storageUnavailable));
          expect(harness.events, contains('disconnect'));
          observations.commitGate!.complete();
          await Future<void>.delayed(Duration.zero);
          expect(observations.state.history.single.sensorMinute, 60);
          expect(session.currentSnapshot.latestReading, isNull);
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
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == harness.observationTimeout) {
              final timer = _ControlledTimer(() => zone.runGuarded(callback));
              timers.add(timer);
              return timer;
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  test(
    'durable queue commits in receipt order with immutable snapshots',
    () async {
      final observations = harness.observations = _ObservationStore()
        ..commitGate = Completer<void>();
      final decoder = harness.decoderProvider = _DecoderProvider();
      decoder.afterDecode = () => decoder.result = _currentSample(
        59 + decoder.decodeCalls,
        99 + decoder.decodeCalls.toDouble(),
      );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final histories = <List<int?>>[];
      session.snapshots.listen((snapshot) {
        if (snapshot.latestReading != null) {
          histories.add(
            snapshot.history.map((reading) => reading.sensorMinute).toList(),
          );
        }
      });
      _sendPacket(harness.connection, _encrypted);
      await observations.commitStarted.future;
      _sendPacket(harness.connection, blePacketAtMinute(61));
      _sendPacket(harness.connection, blePacketAtMinute(62));
      final receivedAll = session.snapshots.firstWhere(
        (snapshot) => snapshot.history.length == 3,
      );
      observations.commitGate!.complete();
      await receivedAll.timeout(const Duration(seconds: 1));
      expect(observations.committedMinutes, [60, 61, 62]);
      expect(histories, [
        [60],
        [60, 61],
        [60, 61, 62],
      ]);
    },
  );

  for (final elapsed in [
    const Duration(minutes: 3),
    const Duration(minutes: 11),
  ]) {
    test(
      'durable freshness charges storage delay $elapsed to receipt deadline',
      () async {
        var monotonic = Duration.zero;
        harness.observationMonotonicNow = () => monotonic;
        final observations = harness.observations = _ObservationStore()
          ..commitGate = Completer<void>();
        harness.decoderProvider = _DecoderProvider();
        final durations = <Duration>[];
        await runZoned(
          () async {
            final session = await harness.start();
            await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
            final received = _receivePacket(session, harness.connection);
            await observations.commitStarted.future;
            monotonic = elapsed;
            harness.now = harness.now.subtract(const Duration(days: 30));
            observations.commitGate!.complete();
            await received;
            expect(
              session.currentSnapshot.history.single.recordedAt,
              DateTime.utc(2026, 1, 1),
            );
            if (elapsed > harness.timingFreshness) {
              expect(
                _hasCommittedObservation(session.currentSnapshot),
                isFalse,
              );
              expect(session.currentSnapshot.latestReading, isNull);
              expect(
                session.currentSnapshot.sessionInfo.elapsedMinutes,
                isNull,
              );
              expect(
                session.currentSnapshot.metadata['cgm.libre2.timing'],
                'stale',
              );
              expect(
                durations.where(
                  (duration) => duration > const Duration(minutes: 5),
                ),
                isEmpty,
              );
            } else {
              expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
              expect(session.currentSnapshot.latestReading, isNotNull);
              expect(durations, contains(harness.timingFreshness - elapsed));
              expect(durations, isNot(contains(harness.timingFreshness)));
            }
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              durations.add(duration);
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
      },
    );
  }

  test(
    'a store reply without the committed reading cannot publish glucose',
    () async {
      harness.observations = _ObservationStore()..dropReading = true;
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
      expect(session.currentSnapshot.latestReading, isNull);
      await expectLater(session.disconnect(), throwsA(_storageUnavailable));
    },
  );

  test(
    'a malformed store reply cannot mark a repeated minute as new',
    () async {
      final observations = harness.observations = _ObservationStore();
      harness.decoderProvider = _DecoderProvider();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final firstReceipt = observations.state.history.single.recordedAt;
      observations.advanceDuplicate = true;
      harness.now = harness.now.add(const Duration(days: 1));
      _sendPacket(harness.connection, _encrypted);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
      expect(session.currentSnapshot.latestReading, isNull);
      expect(observations.state.history.single.recordedAt, firstReceipt);
      expect(harness.decoderProvider!.decodeCalls, 1);
      await expectLater(session.disconnect(), throwsA(_storageUnavailable));
    },
  );

  for (final hasDecoder in [false, true]) {
    test(
      'advanced acknowledgement cannot exclude its own minute (decoder=$hasDecoder)',
      () async {
        final observations = harness.observations = _ObservationStore()
          ..advancedReplyBarrier = 61;
        if (hasDecoder) harness.decoderProvider = _DecoderProvider();
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        _sendPacket(harness.connection, _encrypted);
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(
          session.currentStatus.failure,
          LibreGen1LiveFailure.observationStorageUnavailable,
        );
        expect(observations.state.observedMinute, 60);
        expect(observations.state.effectiveReplayBarrierMinute, 61);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
        expect(_hasCommittedObservation(session.currentSnapshot), isFalse);
        expect(session.currentSnapshot.history, isEmpty);
        await expectLater(session.disconnect(), throwsA(_storageUnavailable));
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
      },
    );
  }

  test('timing freshness cannot exceed the ten-minute observation policy', () {
    for (final freshness in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(minutes: 11),
    ]) {
      expect(
        () => LibreGen1Driver(
          transport: harness.transport,
          bootstrapProvider: harness.store,
          counterStore: harness.store,
          timingFreshness: freshness,
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'MIT timing advances without a decoder and never invents lifecycle',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      for (final minute in [0, 59, 60, 20160, 20161]) {
        await _receivePacket(session, harness.connection, minute: minute);
        final snapshot = session.currentSnapshot;
        expect(snapshot.sessionInfo.elapsedMinutes, minute);
        expect(snapshot.sessionInfo.sessionStart, isNull);
        expect(snapshot.sessionInfo.sessionStopped, isFalse);
        expect(snapshot.sessionInfo.expectedLifetimeMinutes, 20160);
        expect(snapshot.history, isEmpty);
        expect(snapshot.latestReading, isNull);
        expect(snapshot.metadata['cgm.libre2.timing'], 'observed');
        expect(_hasCommittedObservation(snapshot), isFalse);
        expect(
          snapshot.statusText,
          minute < 60
              ? 'Sensor warming up.'
              : 'Receiving sensor data. Glucose decoding is not ready.',
        );
      }
      await session.disconnect();
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
    },
  );

  test(
    'rejected glucose advances timing and blocks replay through recovery',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider()
        ..result = const LibreGen1GlucoseResult(
          sensorAgeMinutes: 60,
          rejection: LibreGen1GlucoseRejection.invalidData,
        );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 60);
      expect(session.currentSnapshot.history, isEmpty);
      final replacement = _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      provider.result = _currentSample(60, 110);
      final calls = provider.decodeCalls;
      await _receivePacket(session, replacement);
      expect(provider.decodeCalls, calls);
      expect(session.currentSnapshot.history, isEmpty);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      provider.result = _currentSample(61, 111);
      await _receivePacket(session, replacement, minute: 61);
      expect(session.currentSnapshot.history.single.sensorMinute, 61);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 61);
    },
  );

  test(
    'decoder cannot invent a later minute than the CRC-validated wire age',
    () async {
      final provider = harness.decoderProvider = _DecoderProvider()
        ..result = _currentSample(61, 100);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: 60);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 60);
      provider.result = _currentSample(60, 100);
      await _receivePacket(session, harness.connection, minute: 60);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(provider.decodeCalls, 1);
    },
  );

  test(
    'warmup-to-active timing remains independent of decoder preparation',
    () async {
      harness.decoderProvider = _DecoderProvider()..prepareFails = true;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection, minute: 59);
      expect(session.currentSnapshot.statusText, 'Sensor warming up.');
      await _receivePacket(session, harness.connection, minute: 60);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 60);
      expect(session.currentSnapshot.statusText, isNot('Sensor warming up.'));
      expect(session.currentSnapshot.latestReading, isNull);
    },
  );

  test(
    'timing expires without new packets and duplicates cannot revive it',
    () async {
      final timers = <_ControlledTimer>[];
      await runZoned(
        () async {
          final provider = harness.decoderProvider = _DecoderProvider();
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          final expired = session.snapshots.firstWhere(
            (snapshot) => snapshot.metadata['cgm.libre2.timing'] == 'stale',
          );
          await _receivePacket(session, harness.connection);
          final retained = session.currentSnapshot.history;
          expect(timers, hasLength(1));
          // A duplicate received before expiry cannot replace the timer.
          await _receivePacket(session, harness.connection);
          expect(timers, hasLength(1));
          expect(timers.single.isActive, isTrue);
          harness.now = harness.now.subtract(const Duration(days: 10));
          timers.single.fire();
          await expired.timeout(const Duration(seconds: 3));
          expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
          expect(session.currentSnapshot.latestReading, isNull);
          expect(session.currentSnapshot.history, retained);
          expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
          expect(session.currentSnapshot.sessionInfo.sessionStopped, isFalse);
          await _receivePacket(session, harness.connection);
          expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
          expect(session.currentSnapshot.latestReading, isNull);
          provider.result = _currentSample(61, 101);
          await _receivePacket(session, harness.connection, minute: 61);
          expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 61);
          expect(session.currentSnapshot.history.length, 2);
          expect(timers, hasLength(2));
          await session.disconnect();
          expect(timers.last.isActive, isFalse);
          timers.last.fire();
          expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == harness.timingFreshness) {
              final timer = _ControlledTimer(() => zone.runGuarded(callback));
              timers.add(timer);
              return timer;
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
    },
  );

  test('Libre declares receipt history without bootstrap or BLE I/O', () {
    final CgmSensorDataProfileProvider provider = harness.driver;
    final profile = provider.sensorDataProfile;
    expect(profile, same(LibreGen1Driver.dataProfile));
    expect(profile.warmupMinutes, 60);
    expect(profile.expectedLifetimeMinutes, 20160);
    expect(
      profile.timestampBasis,
      CgmReadingTimestampBasis.acquisitionRelative,
    );
    expect(profile.duplicatePolicy, CgmHistoryDuplicatePolicy.keepFirst);
    expect(profile.currentReadingPolicy, CgmCurrentReadingPolicy.liveOnly);
    expect(
      profile.retainedLifecyclePolicy,
      CgmRetainedLifecyclePolicy.reportedOnly,
    );
    expect(profile.canInferRetainedLifecycle, isFalse);
    expect(LibreGen1Driver.capabilities.supportsHistory, isFalse);
    expect(harness.events, isEmpty);
    expect(harness.store.readCalls, 0);
    expect(harness.transport.scanCalls, 0);
    expect(harness.transport.connectCalls, 0);
  });

  test(
    'Libre unsupported actions stay unavailable without extra I/O',
    () async {
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final snapshot = session.currentSnapshot;
      final capabilities = snapshot.capabilities;
      expect(capabilities.supportsDirectBle, isTrue);
      expect(capabilities.supportsDiagnostics, isTrue);
      expect(capabilities.supportsVendorPairing, isFalse);
      expect(capabilities.supportsAdvertisementGlucose, isFalse);
      expect(capabilities.supportsHistoryBackfill, isFalse);
      expect(capabilities.supportsRawHistory, isFalse);
      expect(capabilities.supportsCalibration, isFalse);
      expect(capabilities.supportsUnsafeAdmin, isFalse);
      expect(capabilities.supportsCommunicationInterval, isFalse);
      expect(capabilities.supportsAutoUpdateControl, isFalse);
      expect(session, isNot(isA<CgmBondTransferSession>()));
      expect(session.unsafeAdmin, isNull);
      final completedEvents = List<String>.of(harness.events);
      final nextCount = harness.store.nextCount;

      await expectLater(session.syncHistory(), throwsUnsupportedError);
      await expectLater(
        session.syncHistory(includeRawHistory: true, requestedStartOffset: 0),
        throwsUnsupportedError,
      );
      expect(await session.fetchCalibrations(), isEmpty);
      await expectLater(
        session.submitCalibration(glucoseMgdl: 100, sensorMinute: 100),
        throwsUnsupportedError,
      );
      await session.refresh();
      await session.refreshLiveData();
      expect(await session.refreshDiagnostics(), snapshot.diagnostics);

      expect(session.currentSnapshot, same(snapshot));
      expect(harness.events, completedEvents);
      expect(harness.store.nextCount, nextCount);
      expect(harness.transport.scanCalls, 1);
      expect(harness.transport.connectCalls, 1);
    },
  );

  for (final signature in ['9d0830', 'c50930', '7f0e30']) {
    test(
      'live snapshot reports accepted variant $signature without clocks',
      () async {
        harness.store.bootstrap = _bootstrap(
          patchInfoHex: '${signature}013412',
        );
        final gate = Completer<void>();
        harness.decoderProvider = _DecoderProvider()..prepareGate = gate;
        final session = await harness.start();
        _expectBootstrapSessionInfo(session, signature);
        expect(harness.events, isEmpty);
        expect(harness.transport.scanCalls, 0);
        expect(harness.transport.connectCalls, 0);
        expect(harness.store.nextCount, 1);

        gate.complete();
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        _expectBootstrapSessionInfo(session, signature);
        await session.disconnect();
        _expectBootstrapSessionInfo(session, signature);
      },
    );
  }

  for (final signature in ['c60931', '7f0e31']) {
    test('informational Plus variant $signature does not permit bootstrap', () {
      expect(
        () => _bootstrap(patchInfoHex: '${signature}013412'),
        throwsA(
          isA<LibreGen1LiveException>().having(
            (error) => error.kind,
            'kind',
            LibreGen1LiveFailure.invalidBootstrap,
          ),
        ),
      );
      expect(harness.events, isEmpty);
      expect(harness.store.readCalls, 0);
      expect(harness.transport.scanCalls, 0);
      expect(harness.transport.connectCalls, 0);
    });
  }

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
      _expectBootstrapSessionInfo(session, '9d0830');
      expect(harness.transport.scanCalls, 1);
      expect(harness.store.nextCount, 2);
      closeGate.complete();
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      expect(harness.store.readCalls, 2);
      expect(harness.transport.connectCalls, 1);
      harness.transport.emit(_advertisement(harness.now));
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      _expectBootstrapSessionInfo(session, '9d0830');
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
      _expectBootstrapSessionInfo(session, '9d0830');
    },
  );

  test(
    'durable recovery waits past the setup deadline without login retries',
    () async {
      harness.observations = _ObservationStore();
      harness.advertisementTimeout = const Duration(milliseconds: 25);
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final firstLogin = harness.connection.lastWrite;
      final replacement = _replacement(harness);
      harness.transport.autoAdvertise = false;
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        session.currentStatus.phase,
        LibreGen1LivePhase.awaitingAdvertisement,
      );
      expect(
        session.currentSnapshot.metadata['cgm.libre2.waitingForReturn'],
        'true',
      );
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, isNull);
      expect(harness.transport.scanTimeout, isNull);
      expect(harness.transport.scanCalls, 2);
      expect(harness.transport.connectCalls, 1);
      expect(harness.store.nextCount, 2);
      expect(harness.store.readCalls, 2);

      // Delivery of cached, wrong-target, or future observations is not return.
      harness.now = harness.now.add(const Duration(hours: 1));
      harness.transport.emit(
        _advertisement(harness.now.subtract(const Duration(hours: 2))),
      );
      harness.transport.emit(
        _advertisement(harness.now.add(const Duration(seconds: 1))),
      );
      harness.transport.emit(
        _advertisement(harness.now, deviceId: '02:00:00:00:00:02'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(harness.transport.connectCalls, 1);
      harness.transport.emit(_advertisement(harness.now));
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      expect(harness.transport.connectCalls, 2);
      expect(harness.transport.scanStoppedAtConnect, isTrue);
      expect(harness.store.nextCount, 3);
      expect(harness.store.readCalls, 3);
      expect(replacement.lastWrite, isNot(firstLogin));
      expect(
        session.currentSnapshot.metadata,
        isNot(contains('cgm.libre2.waitingForReturn')),
      );
    },
  );

  for (final failure in [
    'cancel',
    'scanError',
    'scanDone',
    'cleanup',
    'targetChanged',
    'changedDuringCleanup',
    'missing',
    'readFailure',
    'cancelDuringRead',
  ]) {
    test('durable return wait preserves $failure boundary', () async {
      harness.observations = _ObservationStore();
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      harness.transport.autoAdvertise = false;
      _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      expect(harness.transport.scanTimeout, isNull);

      LibreGen1LiveFailure? expected;
      switch (failure) {
        case 'cancel':
          await session.disconnect();
          break;
        case 'scanError':
          harness.transport.advertisements!.addError(
            BleFailure(
              kind: BleFailureKind.bluetoothOff,
              operation: BleOperation.scan,
              diagnosticCode: 'synthetic.bluetoothOff',
            ),
          );
          expected = LibreGen1LiveFailure.bluetoothOff;
          break;
        case 'scanDone':
          await harness.transport.advertisements!.close();
          expected = LibreGen1LiveFailure.scanFailed;
          break;
        case 'cleanup':
          harness.transport.cancelFails = true;
          harness.transport.emit(_advertisement(harness.now));
          expected = LibreGen1LiveFailure.cleanupUnconfirmed;
          break;
        case 'targetChanged':
          harness.store.bootstrap = _bootstrap(streamingBase: 0x12345679);
          harness.transport.emit(_advertisement(harness.now));
          expected = LibreGen1LiveFailure.targetMismatch;
          break;
        case 'changedDuringCleanup':
          final gate = Completer<void>();
          harness.transport.cancelGate = gate;
          harness.transport.emit(_advertisement(harness.now));
          while (harness.transport.scanCancelCalls < 2) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(harness.store.readCalls, 2);
          expect(harness.transport.connectCalls, 1);
          harness.store.bootstrap = _bootstrap(streamingBase: 0x12345679);
          gate.complete();
          expected = LibreGen1LiveFailure.targetMismatch;
          break;
        case 'missing':
          harness.store.bootstrap = null;
          harness.transport.emit(_advertisement(harness.now));
          expected = LibreGen1LiveFailure.bootstrapUnavailable;
          break;
        case 'readFailure':
          harness.store.readFails = true;
          harness.transport.emit(_advertisement(harness.now));
          expected = LibreGen1LiveFailure.bootstrapUnavailable;
          break;
        case 'cancelDuringRead':
          final gate = Completer<void>();
          harness.store.readGate = gate;
          harness.transport.emit(_advertisement(harness.now));
          while (harness.store.readCalls < 3) {
            await Future<void>.delayed(Duration.zero);
          }
          final closing = session.disconnect();
          gate.complete();
          await closing;
          break;
      }
      if (expected != null) {
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(session.currentStatus.failure, expected);
      }
      expect(harness.transport.connectCalls, 1);
      expect(harness.store.nextCount, 2);
      expect(harness.transport.scanCalls, 2);
      if (failure != 'scanDone') {
        harness.transport.emit(_advertisement(harness.now));
      }
      await Future<void>.delayed(Duration.zero);
      expect(harness.transport.connectCalls, 1);
    });
  }

  test(
    'return receiver revalidation timeout cannot connect after late read',
    () async {
      var captureReadDeadline = false;
      _ControlledTimer? readDeadline;
      await runZoned(
        () async {
          harness.observations = _ObservationStore();
          final session = await harness.start();
          await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
          await _receivePacket(session, harness.connection);
          harness.transport.autoAdvertise = false;
          _replacement(harness);
          harness.connection.states.add(BleConnectionState.disconnected);
          await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
          final gate = Completer<void>();
          harness.store.readGate = gate;
          captureReadDeadline = true;
          harness.transport.emit(_advertisement(harness.now));
          while (harness.store.readCalls < 3) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(readDeadline, isNotNull);
          readDeadline!.fire();
          await _waitFor(session, LibreGen1LivePhase.failed);
          expect(
            session.currentStatus.failure,
            LibreGen1LiveFailure.bootstrapUnavailable,
          );
          gate.complete();
          await Future<void>.delayed(Duration.zero);
          expect(harness.transport.connectCalls, 1);
          expect(harness.store.nextCount, 2);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (captureReadDeadline &&
                duration == const Duration(seconds: 15)) {
              expect(readDeadline, isNull);
              return readDeadline = _ControlledTimer(callback);
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
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

  test(
    'stable committed reception earns one recovery per healthy attempt',
    () async {
      var monotonic = Duration.zero;
      harness.observations = _ObservationStore();
      harness.observationMonotonicNow = () => monotonic;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      var current = harness.connection;
      var minute = 61;
      final loginPayloads = <List<int>>[current.lastWrite!];
      for (var recovery = 1; recovery <= 3; recovery++) {
        final next = _replacement(harness);
        current.states.add(BleConnectionState.disconnected);
        await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
        expect(harness.transport.connectCalls, recovery + 1);
        expect(harness.store.nextCount, recovery + 2);
        expect(
          session.currentSnapshot.metadata['cgm.libre2.recoveryAttempts'],
          '$recovery',
        );
        expect(loginPayloads, isNot(contains(next.lastWrite)));
        loginPayloads.add(next.lastWrite!);
        current = next;
        if (recovery < 3) {
          for (var packet = 0; packet < 3; packet++) {
            monotonic += const Duration(minutes: 1);
            // Wall-clock movement does not supply or remove stability evidence.
            harness.now = harness.now.subtract(const Duration(hours: 1));
            await _receivePacket(session, current, minute: minute++);
            expect(_hasCommittedObservation(session.currentSnapshot), isTrue);
          }
        }
      }
      // A replacement without fresh observations has no further budget.
      current.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(harness.transport.connectCalls, 4);
      expect(harness.events.where((event) => event == 'reserve').length, 4);
      expect(harness.events.where((event) => event == 'write').length, 4);
      expect(harness.observations!.committedMinutes, [
        60,
        61,
        62,
        63,
        64,
        65,
        66,
      ]);
    },
  );

  for (final evidence in [
    'replay',
    'tooFast',
    'minuteGap',
    'clockGap',
    'clockRollback',
    'stale',
    'twoPackets',
    'noStore',
  ]) {
    test('$evidence does not earn another automatic recovery', () async {
      var monotonic = Duration.zero;
      if (evidence != 'noStore') harness.observations = _ObservationStore();
      harness.observationMonotonicNow = () => monotonic;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final replacement = _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      final seconds = switch (evidence) {
        'tooFast' => [0, 59, 119],
        'clockGap' => [0, 60, 181],
        'clockRollback' => [60, 120, 60],
        'twoPackets' => [0, 120],
        _ => [0, 60, 120],
      };
      for (var index = 0; index < seconds.length; index++) {
        monotonic = Duration(seconds: seconds[index]);
        final minute = evidence == 'replay'
            ? 61
            : evidence == 'minuteGap' && index == 2
            ? 66
            : 61 + index;
        await _receivePacket(session, replacement, minute: minute);
      }
      if (evidence == 'stale') monotonic += const Duration(seconds: 121);
      replacement.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(harness.transport.scanCalls, 2);
      expect(harness.transport.connectCalls, 2);
      expect(harness.store.nextCount, 3);
    });
  }

  for (final failure in [
    'closeFailure',
    'targetChanged',
    'counterFailure',
    'cancel',
  ]) {
    test('renewed recovery still enforces $failure', () async {
      var monotonic = Duration.zero;
      harness.observations = _ObservationStore();
      harness.observationMonotonicNow = () => monotonic;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      await _receivePacket(session, harness.connection);
      final replacement = _replacement(harness);
      harness.connection.states.add(BleConnectionState.disconnected);
      await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
      for (var index = 0; index < 3; index++) {
        monotonic = Duration(minutes: index);
        await _receivePacket(session, replacement, minute: 61 + index);
      }
      _replacement(harness);
      final closeGate = Completer<void>();
      switch (failure) {
        case 'closeFailure':
          replacement.disconnectFails = true;
        case 'targetChanged':
          harness.store.bootstrap = _bootstrap(
            bootstrapId: 'replacement-owner',
          );
        case 'counterFailure':
          harness.store.reserveFails = true;
        case 'cancel':
          replacement.disconnectGate = closeGate;
      }
      replacement.states.add(BleConnectionState.disconnected);
      if (failure == 'cancel') {
        await _waitFor(session, LibreGen1LivePhase.reconnecting);
        final closing = session.disconnect();
        closeGate.complete();
        await closing;
      } else {
        await _waitFor(session, LibreGen1LivePhase.failed);
      }
      expect(harness.events.where((event) => event == 'write').length, 2);
      expect(
        harness.transport.connectCalls,
        failure == 'counterFailure' ? 3 : 2,
      );
      expect(harness.store.nextCount, 3);
    });
  }

  test('an unacknowledged third commit does not rearm recovery', () async {
    var monotonic = Duration.zero;
    final observations = harness.observations = _ObservationStore();
    harness.observationMonotonicNow = () => monotonic;
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, harness.connection);
    final replacement = _replacement(harness);
    harness.connection.states.add(BleConnectionState.disconnected);
    await _waitFor(session, LibreGen1LivePhase.awaitingPacket);
    await _receivePacket(session, replacement, minute: 61);
    monotonic = const Duration(minutes: 1);
    await _receivePacket(session, replacement, minute: 62);
    final gate = observations.commitGate = Completer<void>();
    monotonic = const Duration(minutes: 2);
    _sendPacket(replacement, blePacketAtMinute(63));
    await Future<void>.delayed(Duration.zero);
    replacement.states.add(BleConnectionState.disconnected);
    await _waitFor(session, LibreGen1LivePhase.failed);
    gate.complete();
    await session.disconnect();
    expect(harness.transport.scanCalls, 2);
    expect(harness.transport.connectCalls, 2);
    expect(harness.store.nextCount, 3);
  });

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
      _expectBootstrapSessionInfo(session, '9d0830');
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
      _sendPacket(replacement, blePacketAtMinute(61));
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
      await _receivePacket(session, harness.connection, minute: 65);
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
      expect(session.currentSnapshot.sessionInfo.elapsedMinutes, 65);
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
        await _receivePacket(session, harness.connection, minute: minute);
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
        await _receivePacket(session, harness.connection, minute: minute);
        expect(session.currentSnapshot.history, snapshots.last.history);
        expect(session.currentSnapshot.latestReading, isNull);
      }
      provider.result = _currentSample(64, 104);
      await _receivePacket(session, harness.connection, minute: 64);
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
        await _receivePacket(
          session,
          harness.connection,
          minute: result.$2.sensorAgeMinutes,
        );
        expect(session.currentSnapshot.history, acceptedHistory);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
        expect(session.currentSnapshot.sessionInfo.sessionStart, isNull);
        expect(
          session.currentSnapshot.sessionInfo.elapsedMinutes,
          result.$2.sensorAgeMinutes < 60 ? 60 : result.$2.sensorAgeMinutes,
        );
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
      await _receivePacket(session, harness.connection, minute: 61);
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
      _sendPacket(harness.connection, blePacketAtMinute(61));
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

  for (final durable in [false, true]) {
    test(
      'initial advertisement timeout sends no login (durable=$durable)',
      () async {
        if (durable) harness.observations = _ObservationStore();
        harness.advertisementTimeout = const Duration(milliseconds: 10);
        harness.transport.autoAdvertise = false;
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(
          session.currentStatus.failure,
          LibreGen1LiveFailure.advertisementUnavailable,
        );
        expect(harness.transport.scanTimeout, harness.advertisementTimeout);
        expect(
          session.currentSnapshot.metadata,
          isNot(contains('cgm.libre2.waitingForReturn')),
        );
        expect(harness.events, isEmpty);
        expect(harness.store.nextCount, 1);
        expect(harness.transport.scanCancelCalls, 1);
        await session.refresh();
        expect(harness.transport.scanCalls, 1);
      },
    );
  }

  for (final synchronous in [false, true]) {
    for (final operation in [BleOperation.adapter, BleOperation.scan]) {
      for (final kind in [
        BleFailureKind.bluetoothOff,
        BleFailureKind.permissionRequired,
        BleFailureKind.bluetoothUnavailable,
      ]) {
        test(
          'typed $operation $kind scan failure stays closed (sync=$synchronous)',
          () async {
            final failure = BleFailure(
              kind: kind,
              operation: operation,
              diagnosticCode: 'synthetic-private-diagnostic',
            );
            harness.transport.autoAdvertise = false;
            if (synchronous) {
              harness.transport.scanError = failure;
            }
            final session = await harness.start();
            if (!synchronous) {
              await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
              harness.transport.advertisements!.addError(failure);
            }
            await _waitFor(session, LibreGen1LivePhase.failed);
            expect(session.currentStatus.failure!.name, kind.name);
            expect(session.currentSnapshot.lastError, 'libre2.${kind.name}');
            expect(
              session
                  .currentSnapshot
                  .metadata[cgmAutomaticReconnectAllowedMetadataKey],
              'false',
            );
            expect(
              session.currentSnapshot.diagnostics
                  .map(
                    (item) => [
                      item.key,
                      item.title,
                      item.summary,
                      item.rawHex,
                      item.fields,
                    ],
                  )
                  .toString(),
              isNot(contains('synthetic-private-diagnostic')),
            );
            expect(
              session.currentSnapshot.metadata.toString(),
              isNot(contains('synthetic-private-diagnostic')),
            );
            expect(harness.transport.connectCalls, 0);
            expect(harness.store.nextCount, 1);
            expect(harness.events, isEmpty);
            await session.refresh();
            expect(harness.transport.scanCalls, 1);
          },
        );
      }
    }
  }

  for (final error in [
    StateError('private Bluetooth off description is not a classification'),
    BleFailure(
      kind: BleFailureKind.unexpected,
      operation: BleOperation.scan,
      diagnosticCode: 'synthetic-private-diagnostic',
    ),
    BleFailure(
      kind: BleFailureKind.bluetoothOff,
      operation: BleOperation.write,
      diagnosticCode: 'synthetic-private-diagnostic',
    ),
    BleFailure(
      kind: BleFailureKind.operationTimedOut,
      operation: BleOperation.scan,
      diagnosticCode: 'synthetic-private-diagnostic',
    ),
  ].indexed) {
    test(
      'unclassified scanner error ${error.$1} is not sensor-not-found',
      () async {
        harness.transport.autoAdvertise = false;
        final session = await harness.start();
        await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
        harness.transport.advertisements!.addError(error.$2);
        await _waitFor(session, LibreGen1LivePhase.failed);
        expect(session.currentStatus.failure!.name, 'scanFailed');
        expect(session.currentSnapshot.lastError, 'libre2.scanFailed');
        expect(
          session.currentSnapshot.metadata.toString(),
          isNot(contains('private')),
        );
        expect(harness.transport.connectCalls, 0);
        expect(harness.store.nextCount, 1);
        expect(harness.events, isEmpty);
      },
    );
  }

  test(
    'a scanner ending before its deadline is not a discovery timeout',
    () async {
      harness.transport.autoAdvertise = false;
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.awaitingAdvertisement);
      await harness.transport.advertisements!.close();
      await _waitFor(session, LibreGen1LivePhase.failed);
      expect(session.currentStatus.failure!.name, 'scanFailed');
      expect(harness.transport.connectCalls, 0);
      expect(harness.store.nextCount, 1);
    },
  );

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

  for (final scenario in [
    (
      name: 'Android GATT 133',
      kind: BleFailureKind.sensorPossiblyInUse,
      operation: BleOperation.connect,
      code: 'fbp.android.connect.133.sensorpossiblyinuse',
      expectedCode: 'androidGatt133',
    ),
    (
      name: 'unknown native code',
      kind: BleFailureKind.sensorPossiblyInUse,
      operation: BleOperation.connect,
      code: 'synthetic-private-device-020000000001',
      expectedCode: 'connectionFailed',
    ),
    (
      name: 'connect timeout',
      kind: BleFailureKind.operationTimedOut,
      operation: BleOperation.connect,
      code: 'dart.connect.timeout.operationtimedout',
      expectedCode: 'connectionFailed',
    ),
    (
      name: 'adapter permission',
      kind: BleFailureKind.permissionRequired,
      operation: BleOperation.adapter,
      code: 'synthetic-private-device-020000000001',
      expectedCode: 'connectionFailed',
    ),
    (
      name: 'Bluetooth off',
      kind: BleFailureKind.bluetoothOff,
      operation: BleOperation.adapter,
      code: 'synthetic-private-device-020000000001',
      expectedCode: 'connectionFailed',
    ),
    (
      name: '133 lookalike with different operation',
      kind: BleFailureKind.sensorPossiblyInUse,
      operation: BleOperation.read,
      code: 'fbp.android.connect.133.sensorpossiblyinuse',
      expectedCode: 'connectionFailed',
    ),
    (
      name: '133 lookalike with different kind',
      kind: BleFailureKind.unexpected,
      operation: BleOperation.connect,
      code: 'fbp.android.connect.133.sensorpossiblyinuse',
      expectedCode: 'connectionFailed',
    ),
  ]) {
    test('pre-login ${scenario.name} has closed diagnostics only', () async {
      harness.transport.connectError = BleFailure(
        kind: scenario.kind,
        operation: scenario.operation,
        diagnosticCode: scenario.code,
      );
      final session = await harness.start();
      await _waitFor(session, LibreGen1LivePhase.failed);
      final snapshot = session.currentSnapshot;
      final fields = snapshot.diagnostics.single.fields;
      expect(fields['transportFailurePhase'], 'connecting');
      expect(fields['transportFailureKind'], scenario.kind.name);
      expect(fields['transportOperation'], scenario.operation.name);
      expect(fields['transportCode'], scenario.expectedCode);
      expect(fields.toString(), isNot(contains(scenario.code)));
      expect(
        session.currentStatus.failure,
        LibreGen1LiveFailure.connectionFailed,
      );
      expect(snapshot.lastError, 'libre2.connectionFailed');
      expect(
        snapshot.statusText,
        'Sensor connection failed. Try connecting again.',
      );
      expect(BleFailure.fromMetadata(snapshot.metadata), isNull);
      expect(
        snapshot.metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
      expect(snapshot.metadata['cgm.libre2.recoveryAttempts'], '0');
      expect(harness.transport.scanCalls, 1);
      expect(harness.transport.connectCalls, 1);
      expect(harness.events, ['connect']);
      expect(harness.store.nextCount, 1);
      expect(harness.connection.lastWrite, isNull);
      harness.transport.emit(_advertisement(harness.now));
      await session.refresh();
      await session.refreshLiveData();
      expect(harness.transport.connectCalls, 1);
      expect(harness.events, ['connect']);
      expect(await session.refreshDiagnostics(), snapshot.diagnostics);
      await session.disconnect();
      expect(session.currentSnapshot.diagnostics.single.fields, fields);
    });
  }

  test('untyped connect errors do not expose diagnostic text', () async {
    harness.transport.connectError = StateError(
      'synthetic private connect error for 02:00:00:00:00:01',
    );
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    final snapshot = session.currentSnapshot;
    expect(
      snapshot.diagnostics.single.fields.keys,
      isNot(contains(startsWith('transport'))),
    );
    expect(
      snapshot.diagnostics.single.fields.toString(),
      isNot(contains('02:')),
    );
    expect(snapshot.lastError, 'libre2.connectionFailed');
    expect(harness.events, ['connect']);
    expect(harness.store.nextCount, 1);
  });

  test('post-connect error does not acquire pre-login diagnostics', () async {
    harness.connection.discoverError = BleFailure(
      kind: BleFailureKind.sensorPossiblyInUse,
      operation: BleOperation.connect,
      diagnosticCode: 'fbp.android.connect.133.sensorpossiblyinuse',
    );
    final session = await harness.start();
    await _waitFor(session, LibreGen1LivePhase.failed);
    await session.disconnect();
    final snapshot = session.currentSnapshot;
    expect(
      snapshot.diagnostics.single.fields.keys,
      isNot(contains(startsWith('transport'))),
    );
    expect(snapshot.lastError, 'libre2.topologyRejected');
    expect(harness.events, ['connect', 'discover', 'disconnect']);
    expect(harness.store.nextCount, 1);
  });

  test(
    'explicit new connect does not retain prior failure diagnostics',
    () async {
      harness.transport.connectError = BleFailure(
        kind: BleFailureKind.sensorPossiblyInUse,
        operation: BleOperation.connect,
        diagnosticCode: 'fbp.android.connect.133.sensorpossiblyinuse',
      );
      final failed = await harness.start();
      await _waitFor(failed, LibreGen1LivePhase.failed);
      await failed.disconnect();
      harness.transport.connectError = null;
      final connected = await harness.start();
      await _waitFor(connected, LibreGen1LivePhase.awaitingPacket);
      expect(
        connected.currentSnapshot.diagnostics.single.fields.keys,
        isNot(contains(startsWith('transport'))),
      );
      expect(connected.currentSnapshot.lastError, isNull);
      expect(harness.transport.connectCalls, 2);
      expect(harness.store.nextCount, 2);
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
        // The fresh BLE packet supplies age; the saved NFC lifecycle does not.
        expect(snapshot.sessionInfo.elapsedMinutes, 60);
        expect(snapshot.sessionInfo.sessionStopped, isFalse);
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
  String patchInfoHex = '9d0830013412',
}) => LibreGen1StreamingBootstrap(
  bootstrapId: bootstrapId,
  deviceId: '02:00:00:00:00:01',
  uid: LibreGen1Uid.algorithmOrder(_hex('0011223344556677')),
  initialPatchInfo: LibreGen1PatchInfo(_hex(patchInfoHex)),
  streamingBase: streamingBase,
  lifecycle: lifecycle,
);

void _expectBootstrapSessionInfo(LibreGen1Session session, String signature) {
  final info = session.currentSnapshot.sessionInfo;
  expect(info.warmupMinutes, 60);
  expect(info.expectedLifetimeMinutes, 14 * 24 * 60);
  expect(info.sessionStart, isNull);
  expect(info.elapsedMinutes, isNull);
  final variant = info.sensorVariant!;
  expect(variant.source, CgmSensorVariantSource.nfcPatchInfo);
  expect(variant.protocolFamily, 'abbott-sas');
  expect(variant.model, 'FreeStyle Libre 2');
  expect(variant.variantCode, signature);
  expect(variant.securityGeneration, 'gen1');
  expect(variant.region, isNull);
}

DiscoveredSensor _sensor() => const DiscoveredSensor(
  driverId: LibreGen1Driver.driverIdentifier,
  deviceId: '02:00:00:00:00:01',
  displayName: 'FreeStyle Libre 2',
  storageKey: 'libre2-gen1:synthetic',
  rssi: 0,
  capabilities: LibreGen1Driver.capabilities,
);

bool _hasCommittedObservation(CgmSessionSnapshot snapshot) =>
    snapshot.metadata['cgm.libre2.observationCommitted'] == 'true';

class _ControlledTimer implements Timer {
  _ControlledTimer(this._callback);
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;
  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    _callback();
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
}

class _Harness {
  final events = <String>[];
  DateTime now = DateTime.utc(2026, 1, 1);
  Duration advertisementTimeout = const Duration(seconds: 150);
  Duration timingFreshness = const Duration(minutes: 10);
  Duration observationTimeout = const Duration(seconds: 5);
  _ObservationStore? observations;
  Duration Function()? observationMonotonicNow;
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
    observationStore: observations,
    observationTimeout: observationTimeout,
    observationMonotonicNow: observationMonotonicNow,
    requireDurableObservations: observations != null,
    historyLimit: historyLimit,
    advertisementTimeout: advertisementTimeout,
    timingFreshness: timingFreshness,
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

class _ObservationStore implements LibreGen1ObservationStore {
  LibreGen1ObservationState state = LibreGen1ObservationState();
  final bindings = <LibreGen1ObservationBinding>[];
  final committedMinutes = <int>[];
  final loadStarted = Completer<void>();
  final commitStarted = Completer<void>();
  Completer<void>? loadGate;
  Completer<void>? commitGate;
  bool loadFails = false;
  bool commitFails = false;
  bool dropReading = false;
  bool dropHistoricalReading = false;
  bool alterHistoricalReading = false;
  int? clearedThroughMinute;
  List<LibreGen1HistoricalReading> lastHistoricalReadings = const [];
  bool advanceDuplicate = false;
  int? advancedReplyBarrier;
  @override
  Future<LibreGen1ObservationState> load(
    LibreGen1ObservationBinding binding,
  ) async {
    bindings.add(binding);
    if (!loadStarted.isCompleted) loadStarted.complete();
    await loadGate?.future;
    if (loadFails) throw StateError('synthetic store load');
    return state;
  }

  @override
  Future<LibreGen1ObservationCommit> commit(
    LibreGen1ObservationBinding binding, {
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  }) async {
    lastHistoricalReadings = historicalReadings;
    if (!commitStarted.isCompleted) commitStarted.complete();
    await commitGate?.future;
    if (commitFails) throw StateError('synthetic store commit');
    final barrier = state.effectiveReplayBarrierMinute;
    if (barrier != null && sensorMinute <= barrier) {
      return LibreGen1ObservationCommit(
        advanced: advanceDuplicate,
        state: state,
      );
    }
    final retained = <int, CgmReading>{
      for (final item in state.history) item.sensorMinute!: item,
    };
    if (!dropHistoricalReading) {
      for (final item in historicalReadings) {
        final minute = item.reading.sensorMinute!;
        if (clearedThroughMinute == null || minute > clearedThroughMinute!) {
          retained.putIfAbsent(
            minute,
            () => alterHistoricalReading
                ? item.reading.copyWith(valueMgdl: item.reading.valueMgdl + 1)
                : item.reading,
          );
        }
      }
    }
    if (reading != null && !dropReading) {
      retained.putIfAbsent(reading.sensorMinute!, () => reading);
    }
    final ordered = retained.values.toList()
      ..sort(
        (left, right) => left.sensorMinute!.compareTo(right.sensorMinute!),
      );
    state = LibreGen1ObservationState(
      observedMinute: sensorMinute,
      replayBarrierMinute: advancedReplyBarrier,
      history: ordered,
    );
    committedMinutes.add(sensorMinute);
    return LibreGen1ObservationCommit(advanced: true, state: state);
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
  Object? connectError;
  Object? scanError;
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
    if (connectError case final error?) throw error;
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
    if (scanError case final error?) throw error;
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
  Object? discoverError;
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
    if (discoverError case final error?) throw error;
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

final _encrypted = blePacketAtMinute(60);
void _sendPacket(_Connection connection, List<int> bytes) {
  connection.packets.add(bytes.sublist(0, 20));
  connection.packets.add(bytes.sublist(20, 38));
  connection.packets.add(bytes.sublist(38));
}

Future<void> _receivePacket(
  LibreGen1Session session,
  _Connection connection, {
  int minute = 60,
}) async {
  final previousCount = session.currentStatus.validatedPacketCount;
  final received = session.statuses
      .firstWhere((status) => status.validatedPacketCount > previousCount)
      .timeout(const Duration(seconds: 1));
  _sendPacket(connection, blePacketAtMinute(minute));
  await received;
}

LibreGen1GlucoseHistorySample _historySample(
  int minute,
  LibreGen1BleHistoryKind kind, {
  double? glucose = 100,
  LibreGen1GlucoseRejection? rejection,
}) => LibreGen1GlucoseHistorySample(
  sampleAgeMinutes: minute,
  kind: kind,
  glucoseMgdl: glucose,
  rejection: rejection,
);

LibreGen1GlucoseResult _packetWithHistory(
  int age, {
  double glucose = 100,
  LibreGen1GlucoseRejection? currentRejection,
  List<LibreGen1GlucoseHistorySample>? history,
}) => LibreGen1GlucoseResult(
  sensorAgeMinutes: age,
  sampleAgeMinutes: age,
  glucoseMgdl: currentRejection == null ? glucose : null,
  rejection: currentRejection,
  expectedLifetimeMinutes: 65535,
  historySamples:
      history ??
      [
        for (final offset in [2, 4, 6, 7, 12, 15])
          _historySample(
            age - offset,
            LibreGen1BleHistoryKind.trend,
            glucose: glucose,
          ),
        for (final offset in [0, 15, 30])
          _historySample(
            ((age - 2) ~/ 15) * 15 - offset,
            LibreGen1BleHistoryKind.history,
            glucose: glucose,
          ),
      ],
);

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

final _storageUnavailable = isA<LibreGen1LiveException>().having(
  (error) => error.kind,
  'kind',
  LibreGen1LiveFailure.observationStorageUnavailable,
);
