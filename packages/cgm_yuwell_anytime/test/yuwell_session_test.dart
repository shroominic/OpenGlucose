import 'dart:async';
import 'dart:math' as math;

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('Yuwell live session safety', () {
    test(
      'requires explicit activation and performs no persistent write',
      () async {
        final fixture = _Fixture();
        final session = await fixture.connect(authorized: false);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.activationRequired)),
        );

        expect(session.currentSnapshot.metadata['activationRequired'], 'true');
        expect(
          fixture.connection.writes.map((write) => write.value.first),
          everyElement(isNot(isIn(<int>[0x03, 0x30, 0x38, 0x06, 0x0f]))),
        );
        expect(fixture.journal.current, isNull);
        expect(
          fixture.journal.events.where((event) => event.startsWith('prepare:')),
          isEmpty,
        );
        expect(fixture.connection.disconnected, isTrue);
      },
    );

    test('persists each state before completing its write intent', () async {
      final events = <String>[];
      final fixture = _Fixture(sharedEvents: events);
      final session = await fixture.connect(authorized: true);

      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      _expectBefore(events, 'credential:identityPrepared', 'write:30');
      _expectBefore(
        events,
        'credential:identityPrepared',
        'prepare:setCommunicationId',
      );
      _expectBefore(events, 'transmitted:setCommunicationId', 'write:30');
      _expectBefore(
        events,
        'credential:authenticated',
        'complete:setCommunicationId',
      );
      _expectBefore(events, 'credential:configured', 'complete:configure');
      _expectBefore(events, 'credential:activationPrepared', 'write:06');
      _expectBefore(
        events,
        'credential:lowPowerPending',
        'complete:initialize',
      );
      _expectBefore(events, 'credential:active', 'complete:lowPower');
      expect(
        fixture.connection.writes
            .singleWhere((write) => write.value.first == 0x3f)
            .value,
        appendYuwellSum8(const <int>[0x3f, 0x55, 0xaa]),
      );
      final config = fixture.connection.writes
          .singleWhere((write) => write.value.first == 0x38)
          .value;
      expect(hasValidSum8Frame(config), isTrue);
      expect(
        YuwellCt5ByteTransform.decode(
          config.sublist(1, config.length - 1),
          key: 0,
        ),
        <int>[1, 23, 4, 50, 3, 16, 0x55, 0, 48, 48, 48, 48],
      );
      expect(
        fixture.connection.writes
            .singleWhere((write) => write.value.first == 0x06)
            .value,
        appendYuwellSum8(const <int>[0x06, 15, 1]),
      );
      expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, isEmpty);
      expect(session.currentSnapshot.rawHistory, isEmpty);
      expect(session.currentSnapshot.capabilities.supportsRawHistory, isFalse);
    });

    test('prefers ATT write response and otherwise uses WWR', () async {
      final withResponse = _Fixture(
        writeProperties: const BleCharacteristicProperties(
          write: true,
          writeWithoutResponse: true,
        ),
      );
      final first = await withResponse.connect(authorized: false);
      await expectLater(
        first.initialize(),
        throwsA(isA<YuwellSessionException>()),
      );
      expect(withResponse.connection.writes, isNotEmpty);
      expect(
        withResponse.connection.writes.every((write) => !write.withoutResponse),
        isTrue,
      );

      final wwr = _Fixture(
        writeProperties: const BleCharacteristicProperties(
          writeWithoutResponse: true,
        ),
      );
      final second = await wwr.connect(authorized: false);
      await expectLater(
        second.initialize(),
        throwsA(isA<YuwellSessionException>()),
      );
      expect(wwr.connection.writes, isNotEmpty);
      expect(
        wwr.connection.writes.every((write) => write.withoutResponse),
        isTrue,
      );
    });

    test(
      'restores active credentials, auto-syncs index zero, and keeps records private',
      () async {
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          historyRecordCount: 1,
        );
        final session = await fixture.connect();

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );

        expect(
          fixture.connection.historyStarts,
          containsAllInOrder(<int>[0, 1]),
        );
        expect(
          fixture.connection.writes.map((write) => write.value.first),
          <int>[0x31, 0x03, 0x47, 0x47, 0x11, 0x0f],
        );
        expect(session.currentSnapshot.historySync.latestStoredOffset, 3);
        expect(session.currentSnapshot.latestReading, isNull);
        expect(session.currentSnapshot.history, isEmpty);
        expect(session.currentSnapshot.rawHistory, isEmpty);
        expect(
          session.currentSnapshot.sessionInfo.expectedLifetimeMinutes,
          23085,
        );
      },
    );

    test('default output policy stays disabled after warmup', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historyRecordCount: 16,
      );
      final session = await fixture.connect();

      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      expect(session.currentSnapshot.latestReading, isNull);
      expect(session.currentSnapshot.history, isEmpty);
      expect(
        session.currentSnapshot.metadata[yuwellValidationStateMetadataKey],
        'target-unverified',
      );
      expect(
        session.currentSnapshot.metadata[yuwellOutputModeMetadataKey],
        'disabled',
      );
    });

    test('engineering policy publishes provisional V1150 history', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historyRecordCount: 16,
        glucoseOutputPolicy:
            YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
      );
      final session = await fixture.connect();

      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      final history = session.currentSnapshot.history;
      expect(history, hasLength(2));
      expect(history.map((reading) => reading.sensorMinute), <int>[45, 48]);
      expect(history.map((reading) => reading.recordedAt), <DateTime>[
        DateTime.utc(2026, 8, 1, 12, 45, 3),
        DateTime.utc(2026, 8, 1, 12, 48, 3),
      ]);
      expect(history.every((reading) => reading.valueMgdl == 100), isTrue);
      expect(history.every((reading) => reading.isDisplayProvisional), isTrue);
      expect(session.currentSnapshot.latestReading, same(history.last));
      expect(
        session.currentSnapshot.metadata[yuwellValidationStateMetadataKey],
        'engineering-unverified',
      );
      expect(
        session.currentSnapshot.metadata[yuwellOutputModeMetadataKey],
        'engineering-provisional',
      );
      expect(session.currentSnapshot.statusText, contains('unverified'));
    });

    test('engineering history proof advances across an FF slot', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historySlots: <List<int>>[
          List<int>.filled(17, 0xff),
          for (var index = 1; index <= 14; index++) _recordBytes,
        ],
        glucoseOutputPolicy:
            YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
      );
      final session = await fixture.connect();

      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      expect(session.currentSnapshot.history, hasLength(1));
      expect(session.currentSnapshot.latestReading?.sensorMinute, 45);
      expect(session.currentSnapshot.latestReading?.valueMgdl, 100);
    });

    test('same-index history overlap does not duplicate live output', () async {
      final historySlots = <List<int>>[
        for (var index = 0; index <= 14; index++) _recordBytes,
      ];
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historySlots: historySlots,
        glucoseOutputPolicy:
            YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
      );
      final session = await fixture.connect();
      await session.initialize();

      fixture.connection.emitNotification(_liveFrame(15, _recordBytes));
      await _waitUntil(() => session.currentSnapshot.history.length == 2);

      historySlots.add(_recordBytes);
      await session.refresh();
      expect(session.currentSnapshot.history, hasLength(2));
      expect(fixture.connection.historyStarts, contains(15));

      fixture.connection.emitNotification(_liveFrame(16, _recordBytes));
      await _waitUntil(() => session.currentSnapshot.history.length == 3);
      expect(
        session.currentSnapshot.history.map((reading) => reading.sensorMinute),
        <int>[45, 48, 51],
      );
    });

    test(
      'uses negotiated MTU only after the first record establishes layout',
      () async {
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          negotiatedMtu: 512,
          historyRecordCount: 31,
        );
        final session = await fixture.connect();

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );

        expect(fixture.connection.historyCounts.take(2), <int>[1, 29]);
        expect(session.currentSnapshot.historySync.latestStoredOffset, 93);
      },
    );

    test('does not retry a set-ID with an unknown write outcome', () async {
      final fixture = _Fixture(dropResponseOpcode: 0x30);
      final session = await fixture.connect(authorized: true);

      await expectLater(
        session.initialize(),
        throwsA(_failure(YuwellSessionFailureKind.writeOutcomeUnknown)),
      );

      expect(fixture.connection.opcodeWriteCount(0x30), 1);
      expect(
        fixture.journal.current?.operation,
        YuwellActivationWrite.setCommunicationId,
      );
      expect(fixture.journal.current?.state, YuwellWriteIntentState.unknown);
      expect(
        fixture.credentials.value?.phase,
        YuwellCredentialPhase.identityPrepared,
      );
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
    });

    test(
      'surfaces an unknown outcome when transport fails after the barrier',
      () async {
        final fixture = _Fixture(throwWriteOpcode: 0x30);
        final session = await fixture.connect(authorized: true);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.writeOutcomeUnknown)),
        );

        expect(fixture.connection.opcodeWriteCount(0x30), 1);
        expect(fixture.connection.opcodeWriteCount(0x38), 0);
        expect(fixture.connection.opcodeWriteCount(0x06), 0);
        expect(
          fixture.journal.current?.operation,
          YuwellActivationWrite.setCommunicationId,
        );
        expect(fixture.journal.current?.state, YuwellWriteIntentState.unknown);
        expect(
          session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
          YuwellSessionFailureKind.writeOutcomeUnknown.name,
        );
      },
    );

    test('preserves an auto-history low-power unknown outcome', () async {
      final fixture = _Fixture(throwWriteOpcode: 0x0f, throwWriteOccurrence: 2);
      final session = await fixture.connect(authorized: true);

      await session.initialize();
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey] ==
            YuwellSessionFailureKind.writeOutcomeUnknown.name,
      );

      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(
        session.currentSnapshot.lastError,
        'yuwell.session.writeOutcomeUnknown',
      );
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
      expect(fixture.connection.opcodeWriteCount(0x0f), 2);
      expect(
        fixture.journal.current?.operation,
        YuwellActivationWrite.lowPower,
      );
      expect(fixture.journal.current?.state, YuwellWriteIntentState.unknown);
    });

    test('terminal auto-history failure ignores later live data', () async {
      final fixture = _Fixture(
        historyRecordCount: 15,
        throwWriteOpcode: 0x0f,
        throwWriteOccurrence: 2,
        glucoseOutputPolicy:
            YuwellV1150GlucoseOutputPolicy.engineeringProvisional,
      );
      final session = await fixture.connect(authorized: true);

      await session.initialize();
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey] ==
            YuwellSessionFailureKind.writeOutcomeUnknown.name,
      );
      final terminalSnapshot = session.currentSnapshot;
      final ackCount = fixture.connection.opcodeWriteCount(0x45);
      expect(terminalSnapshot.history, isEmpty);
      expect(terminalSnapshot.lastError, 'yuwell.session.writeOutcomeUnknown');

      fixture.connection.emitNotification(_liveFrame(15, _recordBytes));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(fixture.connection.opcodeWriteCount(0x45), ackCount);
      expect(session.currentSnapshot, same(terminalSnapshot));
      expect(
        session.currentSnapshot.lastError,
        'yuwell.session.writeOutcomeUnknown',
      );
      expect(
        session
            .currentSnapshot
            .metadata[cgmAutomaticReconnectAllowedMetadataKey],
        'false',
      );
    });

    test('live ACK transport failure remains reconnect eligible', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        throwWriteOpcode: 0x45,
      );
      final session = await fixture.connect();
      await session.initialize();

      fixture.connection.emitNotification(_liveFrame(0, _recordBytes));
      await _waitUntil(() => fixture.connection.disconnected);

      expect(fixture.connection.opcodeWriteCount(0x45), 1);
      expect(fixture.journal.current, isNull);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(session.currentSnapshot.lastError, 'yuwell.session.connection');
      expect(
        session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
        YuwellSessionFailureKind.connection.name,
      );
      expect(
        session.currentSnapshot.metadata,
        isNot(contains(cgmAutomaticReconnectAllowedMetadataKey)),
      );
      expect(
        session.currentSnapshot.metadata['cgm.yuwell.last-source'],
        isNull,
      );
    });

    test(
      'disconnect after low-power barrier is terminal on first snapshot',
      () async {
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          lowPowerResponseDelay: const Duration(milliseconds: 80),
        );
        final session = await fixture.connect();
        final failures = <CgmSessionSnapshot>[];
        final subscription = session.snapshots.listen((snapshot) {
          if (snapshot.stage == CgmSyncStage.error) failures.add(snapshot);
        });

        final initialization = session.initialize();
        await _waitUntil(() => fixture.connection.opcodeWriteCount(0x0f) == 1);
        await fixture.connection.disconnect();
        await _waitUntil(() => failures.isNotEmpty);

        final firstFailure = failures.first;
        expect(firstFailure.lastError, 'yuwell.session.writeOutcomeUnknown');
        expect(
          firstFailure.metadata[yuwellFailureCodeMetadataKey],
          YuwellSessionFailureKind.writeOutcomeUnknown.name,
        );
        expect(
          firstFailure.metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
        await expectLater(
          initialization,
          throwsA(_failure(YuwellSessionFailureKind.writeOutcomeUnknown)),
        );
        expect(fixture.journal.current?.state, YuwellWriteIntentState.unknown);
        await subscription.cancel();
      },
    );

    test(
      'disconnect during response persistence preserves unknown outcome',
      () async {
        final fixture = _Fixture(credentials: _activeCredentials());
        final persistenceStarted = Completer<void>();
        final releasePersistence = Completer<void>();
        fixture.credentials.gateWrite(
          phase: YuwellCredentialPhase.active,
          started: persistenceStarted,
          release: releasePersistence.future,
        );
        final session = await fixture.connect();
        final failures = <CgmSessionSnapshot>[];
        final subscription = session.snapshots.listen((snapshot) {
          if (snapshot.stage == CgmSyncStage.error) failures.add(snapshot);
        });
        addTearDown(() async {
          if (!releasePersistence.isCompleted) releasePersistence.complete();
          await subscription.cancel();
          await session.disconnect();
        });

        final initialization = session.initialize();
        await persistenceStarted.future.timeout(const Duration(seconds: 1));
        await fixture.connection.disconnect();
        await _waitUntil(() => failures.isNotEmpty);

        expect(failures.first.lastError, 'yuwell.session.writeOutcomeUnknown');
        expect(
          failures.first.metadata[yuwellFailureCodeMetadataKey],
          YuwellSessionFailureKind.writeOutcomeUnknown.name,
        );
        expect(
          failures.first.metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );

        releasePersistence.complete();
        await expectLater(
          initialization,
          throwsA(_failure(YuwellSessionFailureKind.writeOutcomeUnknown)),
        );

        expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
        expect(
          fixture.journal.current?.operation,
          YuwellActivationWrite.lowPower,
        );
        expect(fixture.journal.current?.state, YuwellWriteIntentState.unknown);
        expect(
          session.currentSnapshot.lastError,
          'yuwell.session.writeOutcomeUnknown',
        );
        expect(
          failures.every(
            (snapshot) =>
                snapshot.metadata[yuwellFailureCodeMetadataKey] ==
                YuwellSessionFailureKind.writeOutcomeUnknown.name,
          ),
          isTrue,
        );
      },
    );

    test(
      'cleanup disconnect preserves the primary initialization failure',
      () async {
        final fixture = _Fixture(dropResponseOpcode: 0x01);
        final session = await fixture.connect();
        final failures = <CgmSessionSnapshot>[];
        final subscription = session.snapshots.listen((snapshot) {
          if (snapshot.stage == CgmSyncStage.error) failures.add(snapshot);
        });
        addTearDown(() async {
          await subscription.cancel();
          await session.disconnect();
        });

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.responseTimeout)),
        );

        expect(fixture.connection.disconnected, isTrue);
        expect(failures, isNotEmpty);
        expect(
          failures.every(
            (snapshot) =>
                snapshot.metadata[yuwellFailureCodeMetadataKey] ==
                YuwellSessionFailureKind.responseTimeout.name,
          ),
          isTrue,
        );
        expect(
          session.currentSnapshot.lastError,
          'yuwell.session.responseTimeout',
        );
        expect(
          session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
          YuwellSessionFailureKind.responseTimeout.name,
        );
      },
    );

    test('service discovery missing the CT5 primary service fails closed '
        'before any write', () async {
      // Synthetic GATT topology only, not a captured device response.
      // Exercises _verifyTopology, the first fail-closed gate in
      // _initialize(): it runs immediately after discoverServices() and
      // before notification subscription or any write.
      final fixture = _Fixture(serviceOverride: const <BleService>[]);
      final session = await fixture.connect();

      await expectLater(
        session.initialize(),
        throwsA(_failure(YuwellSessionFailureKind.topology)),
      );

      expect(fixture.connection.writes, isEmpty);
      expect(fixture.connection.disconnected, isTrue);
      expect(
        session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
        YuwellSessionFailureKind.topology.name,
      );
    });

    test('non-V1150 version response fails closed and records the exact '
        'firmware as evidence', () async {
      // Synthetic digits only — not a captured value from any real unit.
      // See the evidence-boundary doc: "Unit tests use synthetic values
      // only and prove deterministic local behavior, not compatibility
      // with a retail device or firmware version."
      final fixture = _Fixture(
        versionResponse: const <int>[
          1,
          20,
          26,
          9,
          2,
          0,
          2,
          0,
          0,
          3,
          0,
          0,
          0,
          0,
        ],
      );
      final session = await fixture.connect();

      await expectLater(
        session.initialize(),
        throwsA(
          _failure(YuwellSessionFailureKind.unsupportedFirmware)
              .having((error) => error.firmware, 'firmware', 'V2003')
              .having((error) => error.bound, 'bound', isFalse),
        ),
      );

      // Exactly the version query and the one best-effort binding-status
      // evidence read — the same query _beginFreshActivation sends first,
      // unconditionally, before any state-changing write. Nothing that
      // could touch activation, calibration, or a state-changing write ran
      // for this firmware branch.
      expect(fixture.connection.writes.map((write) => write.value.first), <int>[
        0x01,
        0x11,
      ]);
      expect(fixture.connection.disconnected, isTrue);
      expect(
        session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
        YuwellSessionFailureKind.unsupportedFirmware.name,
      );
      expect(
        session.currentSnapshot.metadata[yuwellFirmwareMetadataKey],
        'V2003',
      );
      expect(
        session.currentSnapshot.metadata[yuwellBindingStateMetadataKey],
        'unbound',
      );
    });

    test(
      'non-V1150 evidence read failing does not mask the firmware diagnosis',
      () async {
        // The best-effort binding-status query itself gets no response here
        // (dropResponseOpcode) — the primary unsupportedFirmware diagnostic
        // must still surface, just without binding-state evidence attached.
        final fixture = _Fixture(
          versionResponse: const <int>[
            1,
            20,
            26,
            9,
            2,
            0,
            2,
            0,
            0,
            3,
            0,
            0,
            0,
            0,
          ],
          dropResponseOpcode: 0x11,
        );
        final session = await fixture.connect();

        await expectLater(
          session.initialize(),
          throwsA(
            _failure(YuwellSessionFailureKind.unsupportedFirmware)
                .having((error) => error.firmware, 'firmware', 'V2003')
                .having((error) => error.bound, 'bound', isNull),
          ),
        );

        expect(
          session.currentSnapshot.metadata[yuwellFirmwareMetadataKey],
          'V2003',
        );
        expect(
          session.currentSnapshot.metadata.containsKey(
            yuwellBindingStateMetadataKey,
          ),
          isFalse,
        );
      },
    );

    test('non-V1150 version response from an already-bound sensor still fails '
        'closed and records the bound evidence', () async {
      // Synthetic digits only — not a captured value from any real unit.
      // Covers the other branch of the best-effort evidence read: the
      // sensor reports itself already bound (to some other app/phone).
      // The firmware gate must still fire first and record that fact —
      // this must not be confused with the fresh-activation alreadyBound
      // path, which never runs here because this unit never reaches
      // _beginFreshActivation.
      final fixture = _Fixture(
        versionResponse: const <int>[
          1,
          20,
          26,
          9,
          2,
          0,
          2,
          0,
          0,
          3,
          0,
          0,
          0,
          0,
        ],
        bindingStatus: true,
      );
      final session = await fixture.connect();

      await expectLater(
        session.initialize(),
        throwsA(
          _failure(YuwellSessionFailureKind.unsupportedFirmware)
              .having((error) => error.firmware, 'firmware', 'V2003')
              .having((error) => error.bound, 'bound', isTrue),
        ),
      );

      // Same exact two reads as the unbound case — version, then the one
      // best-effort binding-status evidence query. Being already bound
      // must not add, skip, or reorder any write.
      expect(fixture.connection.writes.map((write) => write.value.first), <int>[
        0x01,
        0x11,
      ]);
      expect(fixture.connection.disconnected, isTrue);
      expect(
        session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
        YuwellSessionFailureKind.unsupportedFirmware.name,
      );
      expect(
        session.currentSnapshot.metadata[yuwellFirmwareMetadataKey],
        'V2003',
      );
      expect(
        session.currentSnapshot.metadata[yuwellBindingStateMetadataKey],
        'bound',
      );
    });

    test('a resumed session whose saved credentials are not '
        'transmitter-computed fails closed before any radio traffic', () async {
      // Synthetic credentials only — this phase/cipher/coefficient
      // combination is not a captured value from any real unit.
      //
      // This is a distinct branch from the three non-V1150 tests above:
      // those all go through _initialize's fresh version query, so their
      // exception carries the queried firmware string and the one
      // best-effort binding-status evidence read. A resumed session with
      // saved credentials skips that version query entirely (per
      // _initialize's `credentials == null` branch) and instead reaches
      // _resume, whose own bare `unsupportedFirmware` guard fires first —
      // before check-id, before any evidence read, before the activation
      // gate. Nothing was queried this attempt, so firmware/bound must
      // both stay null rather than repeat a stale or synthesized value.
      final fixture = _Fixture(
        credentials: _activeCredentials().copyWith(transmitterComputed: false),
      );
      final session = await fixture.connect(authorized: true);

      await expectLater(
        session.initialize(),
        throwsA(
          _failure(YuwellSessionFailureKind.unsupportedFirmware)
              .having((error) => error.firmware, 'firmware', isNull)
              .having((error) => error.bound, 'bound', isNull),
        ),
      );

      // No version query, no evidence read, no write of any kind — the
      // guard is the first statement _resume runs.
      expect(fixture.connection.writes, isEmpty);
      expect(fixture.journal.current, isNull);
      expect(fixture.connection.disconnected, isTrue);
      expect(
        session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey],
        YuwellSessionFailureKind.unsupportedFirmware.name,
      );
      expect(
        session.currentSnapshot.metadata.containsKey(yuwellFirmwareMetadataKey),
        isFalse,
      );
      expect(
        session.currentSnapshot.metadata.containsKey(
          yuwellBindingStateMetadataKey,
        ),
        isFalse,
      );
    });

    test('an unresolved non-setDate intent with no saved credentials at all '
        'fails closed before any radio traffic', () async {
      // A different hole than the test above: there credentials existed
      // but were not transmitter-computed, so _resume's bare guard fired.
      // Here there are no saved credentials at all, so _initialize's own
      // fresh-admission branch does not run either (it requires
      // _unresolvedIntent == null) — control falls into the
      // credentials-based else-branch, whose `credentials?.transmitterComputed
      // == false ? 'unsupported' : 'V1150'` cannot tell "never admitted"
      // apart from "unsupported" once credentials is null, and defaults
      // to 'V1150'. That default is never observed only because
      // _recoverUnresolved's bare credentials-null guard fires first for
      // every operation except the separately reviewed setDate recovery.
      // This locks that guard in place as a regression test rather than
      // leaving it as an unexercised side effect of the setDate tests.
      final journal = _MemoryIntentStore(
        initial: const YuwellUnresolvedWriteIntent(
          token: 'opaque-no-credentials',
          operation: YuwellActivationWrite.initialize,
          state: YuwellWriteIntentState.unknown,
        ),
      );
      final fixture = _Fixture(journal: journal);
      final session = await fixture.connect(authorized: true);

      await expectLater(
        session.initialize(),
        throwsA(_failure(YuwellSessionFailureKind.unresolvedWrite)),
      );

      // No version query, no evidence read, no activation write — the
      // guard is the first statement _recoverUnresolved runs for any
      // operation but setDate.
      expect(fixture.connection.writes, isEmpty);
      expect(journal.current, isNotNull);
    });

    test(
      'blocks accepted interrupted set-ID when the cipher was not observed',
      () async {
        final prepared = _preparedIdentityCredentials();
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-1',
            operation: YuwellActivationWrite.setCommunicationId,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final fixture = _Fixture(
          credentials: prepared,
          journal: journal,
          checkIdAccepted: true,
        );
        final session = await fixture.connect(authorized: true);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.unresolvedWrite)),
        );

        expect(fixture.connection.opcodeWriteCount(0x30), 0);
        expect(journal.current, isNotNull);
        expect(
          session
              .currentSnapshot
              .metadata[cgmAutomaticReconnectAllowedMetadataKey],
          'false',
        );
      },
    );

    test('keeps a plain transport disconnect reconnect-eligible', () async {
      final fixture = _Fixture(credentials: _activeCredentials());
      final session = await fixture.connect();
      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      await fixture.connection.disconnect();
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata[yuwellFailureCodeMetadataKey] ==
            YuwellSessionFailureKind.disconnected.name,
      );

      expect(session.currentSnapshot.stage, CgmSyncStage.error);
      expect(
        session.currentSnapshot.metadata,
        isNot(contains(cgmAutomaticReconnectAllowedMetadataKey)),
      );
    });

    test('leases one sensor across concurrent driver instances', () async {
      final fixture = _Fixture(credentials: _activeCredentials());
      final first = await fixture.connect();
      await first.initialize();

      await expectLater(
        fixture.connect(),
        throwsA(_failure(YuwellSessionFailureKind.sessionInUse)),
      );

      await first.disconnect();
      final replacement = await fixture.connect();
      expect(replacement.sensor.storageKey, first.sensor.storageKey);
      await replacement.disconnect();
    });

    test('connect() rejects a sensor descriptor from a different driver '
        'before any transport use', () async {
      // Synthetic descriptor only. The three-part identity check
      // (driverId/deviceId/storageKey prefix) runs synchronously at the top
      // of connect(), before scan or connect ever reaches the transport, so
      // this uses a transport that throws if it is ever called at all
      // instead of one that could silently succeed.
      final driver = YuwellAnytimeDriver(
        const _UnreachableTransport(),
        credentialStore: _MemoryCredentialStore(
          value: null,
          events: <String>[],
        ),
        writeIntentStore: _MemoryIntentStore(),
      );
      const sensor = DiscoveredSensor(
        driverId: 'not-yuwell-anytime',
        deviceId: 'synthetic-device',
        displayName: 'Anytime0123456789',
        storageKey: 'yuwell:synthetic-device',
        rssi: -40,
        capabilities: YuwellAnytimeDriver.capabilities,
      );

      await expectLater(
        driver.connect(sensor),
        throwsA(_failure(YuwellSessionFailureKind.invalidSensor)),
      );
    });

    test(
      'keeps rejected set-ID tombstone when retry is not authorized',
      () async {
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-auth',
            operation: YuwellActivationWrite.setCommunicationId,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final fixture = _Fixture(
          credentials: _preparedIdentityCredentials(),
          journal: journal,
          checkIdAccepted: false,
          bindingStatus: false,
        );
        final session = await fixture.connect(authorized: false);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.activationRequired)),
        );

        expect(journal.current?.token, 'opaque-auth');
        expect(fixture.connection.opcodeWriteCount(0x30), 0);
      },
    );

    test(
      'keeps rejected set-ID tombstone when another identity is bound',
      () async {
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-bound',
            operation: YuwellActivationWrite.setCommunicationId,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final fixture = _Fixture(
          credentials: _preparedIdentityCredentials(),
          journal: journal,
          checkIdAccepted: false,
          bindingStatus: true,
        );
        final session = await fixture.connect(authorized: true);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.alreadyBound)),
        );

        expect(fixture.connection.opcodeWriteCount(0x11), 1);
        expect(fixture.connection.opcodeWriteCount(0x30), 0);
        expect(journal.current?.token, 'opaque-bound');
        expect(journal.current?.state, YuwellWriteIntentState.unknown);
      },
    );

    test('recovers a durable identity created before its journal', () async {
      final rejectedFixture = _Fixture(
        credentials: _preparedIdentityCredentials(),
        checkIdAccepted: false,
        bindingStatus: false,
      );
      final rejectedSession = await rejectedFixture.connect(authorized: true);

      await rejectedSession.initialize();
      await _waitUntil(
        () => rejectedSession.currentSnapshot.historySync.lastSyncAt != null,
      );
      expect(rejectedFixture.connection.opcodeWriteCount(0x30), 1);
      _expectBefore(rejectedFixture.events, 'write:11', 'write:30');

      final acceptedFixture = _Fixture(
        credentials: _preparedIdentityCredentials(),
        checkIdAccepted: true,
      );
      final acceptedSession = await acceptedFixture.connect(authorized: true);
      await expectLater(
        acceptedSession.initialize(),
        throwsA(_failure(YuwellSessionFailureKind.unresolvedWrite)),
      );
      expect(acceptedFixture.connection.opcodeWriteCount(0x30), 0);
    });

    test(
      'does not resend a journal-less identity when another identity is bound',
      () async {
        final fixture = _Fixture(
          credentials: _preparedIdentityCredentials(),
          checkIdAccepted: false,
          bindingStatus: true,
        );
        final session = await fixture.connect(authorized: true);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.alreadyBound)),
        );

        expect(fixture.connection.opcodeWriteCount(0x11), 1);
        expect(fixture.connection.opcodeWriteCount(0x30), 0);
        expect(
          fixture.credentials.value?.phase,
          YuwellCredentialPhase.identityPrepared,
        );
        expect(fixture.journal.current, isNull);
      },
    );

    test(
      'keeps unresolved fresh date when activation is not authorized',
      () async {
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-date',
            operation: YuwellActivationWrite.setDate,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final fixture = _Fixture(journal: journal);
        final session = await fixture.connect(authorized: false);

        await expectLater(
          session.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.activationRequired)),
        );

        expect(journal.current?.token, 'opaque-date');
        expect(fixture.connection.opcodeWriteCount(0x03), 0);
      },
    );

    test(
      'retries the exact durable identity only after rejected check-ID',
      () async {
        final prepared = _preparedIdentityCredentials();
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-2',
            operation: YuwellActivationWrite.setCommunicationId,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final fixture = _Fixture(
          credentials: prepared,
          journal: journal,
          checkIdAccepted: false,
          bindingStatus: false,
        );
        final session = await fixture.connect(authorized: true);

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );

        final setId = fixture.connection.writes.singleWhere(
          (write) => write.value.first == 0x30,
        );
        expect(setId.value, prepared.communicationIdentity.encodeSetId());
        expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
        _expectBefore(fixture.events, 'write:11', 'write:30');
      },
    );

    test(
      'keeps interrupted initialize unresolved until a concrete record proves activity',
      () async {
        final activationTime = DateTime.utc(2026, 8, 1, 12);
        final prepared = _activeCredentials().copyWith(
          phase: YuwellCredentialPhase.activationPrepared,
          activationStartedAt: activationTime,
        );
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-3',
            operation: YuwellActivationWrite.initialize,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final emptyFixture = _Fixture(
          credentials: prepared,
          journal: journal,
          bindingStatus: true,
        );
        final emptySession = await emptyFixture.connect();

        await expectLater(
          emptySession.initialize(),
          throwsA(_failure(YuwellSessionFailureKind.unresolvedWrite)),
        );
        expect(journal.current, isNotNull);
        expect(emptyFixture.connection.opcodeWriteCount(0x06), 0);

        final provedJournal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-4',
            operation: YuwellActivationWrite.initialize,
            state: YuwellWriteIntentState.unknown,
          ),
        );
        final provedFixture = _Fixture(
          credentials: prepared,
          journal: provedJournal,
          bindingStatus: true,
          historyRecordCount: 1,
        );
        final provedSession = await provedFixture.connect();

        await provedSession.initialize();
        expect(provedJournal.current, isNull);
        expect(
          provedFixture.credentials.value?.phase,
          YuwellCredentialPhase.active,
        );
        expect(provedFixture.connection.opcodeWriteCount(0x06), 0);
        expect(provedSession.currentSnapshot.latestReading, isNull);
      },
    );

    test('replays prepared configure before the BLE barrier', () async {
      final journal = _MemoryIntentStore(
        initial: const YuwellUnresolvedWriteIntent(
          token: 'opaque-configure-prepared',
          operation: YuwellActivationWrite.configure,
          state: YuwellWriteIntentState.prepared,
        ),
      );
      final fixture = _Fixture(
        credentials: _authenticatedCredentials(),
        journal: journal,
      );
      final session = await fixture.connect();

      await session.initialize();

      expect(journal.events, contains('cancel:configure'));
      expect(fixture.connection.opcodeWriteCount(0x38), 1);
      expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
    });

    test('replays prepared initialize before the BLE barrier', () async {
      final journal = _MemoryIntentStore(
        initial: const YuwellUnresolvedWriteIntent(
          token: 'opaque-initialize-prepared',
          operation: YuwellActivationWrite.initialize,
          state: YuwellWriteIntentState.prepared,
        ),
      );
      final fixture = _Fixture(
        credentials: _activationPreparedCredentials(),
        journal: journal,
      );
      final session = await fixture.connect();

      await session.initialize();

      expect(journal.events, contains('cancel:initialize'));
      expect(fixture.connection.opcodeWriteCount(0x06), 1);
      expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
    });

    test('resumes activation prepared before journal creation', () async {
      final fixture = _Fixture(credentials: _activationPreparedCredentials());
      final session = await fixture.connect();

      await session.initialize();

      expect(fixture.connection.opcodeWriteCount(0x06), 1);
      expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
      expect(fixture.journal.current, isNull);
    });

    test(
      'does not repeat initialize after low-power-pending was durable',
      () async {
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-active-init',
            operation: YuwellActivationWrite.initialize,
            state: YuwellWriteIntentState.transmitted,
          ),
        );
        final fixture = _Fixture(
          credentials: _lowPowerPendingCredentials(),
          journal: journal,
        );
        final session = await fixture.connect();

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );

        expect(fixture.connection.opcodeWriteCount(0x06), 0);
        // One post-init replay and one reviewed post-history command.
        expect(fixture.connection.opcodeWriteCount(0x0f), 2);
        expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
        expect(journal.current, isNull);
      },
    );

    test(
      'resumes low-power-pending after crash before journal creation',
      () async {
        final fixture = _Fixture(credentials: _lowPowerPendingCredentials());
        final session = await fixture.connect();

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );

        expect(fixture.connection.opcodeWriteCount(0x06), 0);
        expect(fixture.connection.opcodeWriteCount(0x0f), 2);
        expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
        expect(fixture.journal.current, isNull);
      },
    );

    test(
      'replays every crash-state low-power intent through a durable phase',
      () async {
        for (final state in <YuwellWriteIntentState>[
          YuwellWriteIntentState.prepared,
          YuwellWriteIntentState.transmitted,
          YuwellWriteIntentState.unknown,
        ]) {
          final journal = _MemoryIntentStore(
            initial: YuwellUnresolvedWriteIntent(
              token: 'opaque-low-power-${state.name}',
              operation: YuwellActivationWrite.lowPower,
              state: state,
            ),
          );
          final fixture = _Fixture(
            credentials: _lowPowerPendingCredentials(),
            journal: journal,
          );
          final session = await fixture.connect();

          await session.initialize();
          await _waitUntil(
            () => session.currentSnapshot.historySync.lastSyncAt != null,
          );
          expect(fixture.connection.opcodeWriteCount(0x0f), 2);
          expect(journal.events, contains('recover:lowPower'));
          expect(journal.current, isNull);
          expect(
            fixture.credentials.value?.phase,
            YuwellCredentialPhase.active,
          );
        }
      },
    );

    test(
      'replays a stale low-power tombstone from active credentials',
      () async {
        final journal = _MemoryIntentStore(
          initial: const YuwellUnresolvedWriteIntent(
            token: 'opaque-low-power-response',
            operation: YuwellActivationWrite.lowPower,
            state: YuwellWriteIntentState.transmitted,
          ),
        );
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          journal: journal,
        );
        final session = await fixture.connect();

        await session.initialize();
        await _waitUntil(
          () => session.currentSnapshot.historySync.lastSyncAt != null,
        );
        expect(fixture.connection.opcodeWriteCount(0x0f), 2);
        expect(journal.current, isNull);
        expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      },
    );

    test('migrates a legacy active initialize tombstone safely', () async {
      final journal = _MemoryIntentStore(
        initial: const YuwellUnresolvedWriteIntent(
          token: 'opaque-legacy-init',
          operation: YuwellActivationWrite.initialize,
          state: YuwellWriteIntentState.transmitted,
        ),
      );
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        journal: journal,
      );
      final session = await fixture.connect();

      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );
      expect(fixture.connection.opcodeWriteCount(0x06), 0);
      expect(fixture.connection.opcodeWriteCount(0x0f), 2);
      expect(fixture.credentials.value?.phase, YuwellCredentialPhase.active);
      expect(journal.current, isNull);
    });

    test('replays every set-date crash state before saved history', () async {
      for (final state in YuwellWriteIntentState.values) {
        final journal = _MemoryIntentStore(
          initial: YuwellUnresolvedWriteIntent(
            token: 'opaque-date-${state.name}',
            operation: YuwellActivationWrite.setDate,
            state: state,
          ),
        );
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          journal: journal,
        );
        final session = await fixture.connect();

        await session.initialize();

        expect(
          fixture.connection.writes.map((write) => write.value.first),
          <int>[0x31, 0x03, 0x47, 0x11, 0x0f],
        );
        expect(journal.events, contains('recover:setDate'));
        expect(journal.current, isNull);
      }
    });

    test(
      'keeps saved history syncing until status and low-power complete',
      () async {
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          historyRecordCount: 1,
          lowPowerResponseDelay: const Duration(milliseconds: 25),
        );
        final session = await fixture.connect();

        final initialization = session.initialize();
        await _waitUntil(() => fixture.connection.opcodeWriteCount(0x0f) == 1);

        expect(session.currentSnapshot.stage, CgmSyncStage.syncing);
        await initialization;
        expect(session.currentSnapshot.stage, CgmSyncStage.ready);
      },
    );

    test('coalesces concurrent auto and manual history requests', () async {
      final fixture = _Fixture(
        historyResponseDelay: const Duration(milliseconds: 20),
      );
      final session = await fixture.connect(authorized: true);

      await session.initialize();
      await Future.wait<void>(<Future<void>>[
        session.refresh(),
        session.refreshLiveData(),
      ]);

      expect(fixture.connection.opcodeWriteCount(0x47), 1);
      expect(fixture.connection.opcodeWriteCount(0x11), 2);
      expect(fixture.connection.opcodeWriteCount(0x0f), 2);
    });

    test('ACKs and rejects base live frames on V1150', () async {
      final fixture = _Fixture(credentials: _activeCredentials());
      final session = await fixture.connect();
      await session.initialize();

      fixture.connection.emitNotification(const <int>[0x35]);
      await _waitUntil(() => fixture.connection.disconnected);

      expect(
        fixture.connection.writes.any(
          (write) =>
              _listEquals(write.value, const <int>[0x35, 0x55, 0xaa, 0x34]),
        ),
        isTrue,
      );
      expect(
        session.currentSnapshot.metadata['cgm.yuwell.last-source'],
        isNull,
      );
      expect(session.currentSnapshot.lastError, contains('malformedResponse'));
    });

    test('disconnect stops an in-flight auto-history cycle', () async {
      final fixture = _Fixture(
        historyResponseDelay: const Duration(milliseconds: 80),
      );
      final session = await fixture.connect(authorized: true);
      await session.initialize();
      await _waitUntil(() => fixture.connection.opcodeWriteCount(0x47) == 1);

      await session.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
      // Only the fresh pre-bind status and initial post-init low-power ran.
      expect(fixture.connection.opcodeWriteCount(0x11), 1);
      expect(fixture.connection.opcodeWriteCount(0x0f), 1);
      expect(fixture.journal.current, isNull);
    });

    test(
      'defers historical session completion until after low-power',
      () async {
        final terminalRecord = List<int>.of(_recordBytes)..[8] = 5;
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          historyRecordCount: 1,
          historyRecordBytes: terminalRecord,
          lowPowerResponseDelay: const Duration(milliseconds: 20),
        );
        final session = await fixture.connect();
        final events = fixture.events;
        final subscription = session.snapshots.listen((snapshot) {
          if (snapshot.health.expired) events.add('snapshot:expired');
        });

        await session.initialize();

        expect(session.currentSnapshot.health.expired, isTrue);
        await _waitUntil(() => events.contains('snapshot:expired'));
        _expectBefore(events, 'write:0f', 'snapshot:expired');
        await subscription.cancel();
      },
    );

    test(
      'history resumes from the first contiguous gap, not a live max',
      () async {
        final fixture = _Fixture(
          credentials: _activeCredentials(),
          historyRecordCount: 2,
        );
        final session = await fixture.connect();
        await session.initialize();

        fixture.connection.emitNotification(_liveFrame(5, _recordBytes));
        await _waitUntil(
          () =>
              session.currentSnapshot.metadata['cgm.yuwell.last-source'] ==
              'live',
        );
        await session.refresh();

        expect(fixture.connection.historyStarts.last, 2);
        expect(session.currentSnapshot.historySync.latestStoredOffset, 6);
      },
    );

    test('history cursor advances across an observed FF slot', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historySlots: <List<int>>[List<int>.filled(17, 0xff), _recordBytes],
      );
      final session = await fixture.connect();
      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      expect(session.currentSnapshot.historySync.latestStoredOffset, 6);
      await session.refresh();

      expect(fixture.connection.historyStarts.last, 2);
      expect(session.currentSnapshot.historySync.latestStoredOffset, 6);
    });

    test('a high live record never advances the history cursor', () async {
      final historySlots = <List<int>>[];
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        historySlots: historySlots,
      );
      final session = await fixture.connect();
      await session.initialize();

      fixture.connection.emitNotification(_liveFrame(5, _recordBytes));
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata['cgm.yuwell.last-source'] ==
            'live',
      );
      historySlots.addAll(List<List<int>>.filled(5, _recordBytes));

      await session.refresh();
      expect(fixture.connection.historyStarts.last, 5);
      await session.refresh();
      expect(fixture.connection.historyStarts.last, 5);

      historySlots.add(List<int>.filled(17, 0xff));
      await session.refresh();
      expect(fixture.connection.historyStarts.last, 6);
      await session.refresh();
      expect(fixture.connection.historyStarts.last, 6);
    });

    test('disconnect waits for a delayed live ACK handler', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        ackDelay: const Duration(milliseconds: 40),
      );
      final session = await fixture.connect();
      await session.initialize();

      fixture.connection.emitNotification(_liveFrame(5, _recordBytes));
      await _waitUntil(
        () =>
            fixture.connection.writes.any((write) => write.value.first == 0x45),
      );
      await session.disconnect();

      expect(session.currentSnapshot.stage, CgmSyncStage.disconnected);
      expect(
        session.currentSnapshot.metadata['cgm.yuwell.last-source'],
        isNull,
      );
      expect(fixture.events, contains('ack-complete'));
    });

    test('ACKs malformed recognized live data before disconnecting', () async {
      final fixture = _Fixture(
        credentials: _activeCredentials(),
        ackDelay: const Duration(milliseconds: 15),
      );
      final session = await fixture.connect();
      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      fixture.connection.emitNotification(const <int>[0x45, 0x00]);
      await _waitUntil(() => fixture.connection.disconnected);

      expect(
        fixture.connection.writes.any(
          (write) =>
              _listEquals(write.value, const <int>[0x45, 0x55, 0xaa, 0x44]),
        ),
        isTrue,
      );
      expect(session.currentSnapshot.lastError, contains('malformedResponse'));
      _expectBefore(fixture.events, 'ack-complete', 'disconnect');
    });

    test('deduplicates identical live indexes and rejects conflicts', () async {
      final fixture = _Fixture(credentials: _activeCredentials());
      final session = await fixture.connect();
      await session.initialize();
      await _waitUntil(
        () => session.currentSnapshot.historySync.lastSyncAt != null,
      );

      fixture.connection.emitNotification(_liveFrame(7, _recordBytes));
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata['cgm.yuwell.last-source'] ==
            'live',
      );
      fixture.connection.emitNotification(_liveFrame(7, _recordBytes));
      await _waitUntil(
        () =>
            session.currentSnapshot.metadata['cgm.yuwell.last-record'] ==
            'duplicate',
      );
      expect(fixture.connection.disconnected, isFalse);

      final conflict = List<int>.of(_recordBytes)..[1] = 0x65;
      fixture.connection.emitNotification(_liveFrame(7, conflict));
      await _waitUntil(() => fixture.connection.disconnected);

      expect(session.currentSnapshot.lastError, contains('malformedResponse'));
      expect(fixture.connection.opcodeWriteCount(0x45), 3);
    });
  });

  group('Yuwell history framing', () {
    test(
      'FF consumes its original slot and FC terminates without compaction',
      () {
        final clear = <int>[
          ...List<int>.filled(17, 0xff),
          ..._recordBytes,
          ...List<int>.filled(17, 0xfc),
        ];
        final frame = appendYuwellSum8(<int>[
          0x47,
          10,
          0,
          ...YuwellCt5ByteTransform.encode(clear, key: 0),
        ]);

        final parsed = YuwellHistoryFrame.parse(frame, cipher: 0);

        expect(parsed.layout, YuwellHistoryRecordLayout.alert17);
        expect(parsed.consumedSlots, 2);
        expect(parsed.terminated, isTrue);
        expect(parsed.indexedRecords.single.index, 11);
      },
    );
  });
}

TypeMatcher<YuwellSessionException> _failure(YuwellSessionFailureKind kind) =>
    isA<YuwellSessionException>().having((error) => error.kind, 'kind', kind);

void _expectBefore(List<String> events, String first, String second) {
  expect(events, contains(first));
  expect(events, contains(second));
  expect(events.indexOf(first), lessThan(events.indexOf(second)));
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('test condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

bool _listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<int> _liveFrame(int index, List<int> record) => appendYuwellSum8(<int>[
  0x45,
  index & 0xff,
  index >> 8,
  ...YuwellCt5ByteTransform.encode(record, key: 0),
]);

const _calibrationCode = 'M4Z612345678912345ABC';
const _recordBytes = <int>[
  0x00,
  0x64,
  0x00,
  0x65,
  40,
  0,
  0,
  100,
  0,
  0,
  0,
  0,
  0,
  0,
  80,
  0,
  0,
];

YuwellSessionCredentials _preparedIdentityCredentials() =>
    YuwellSessionCredentials(
      communicationIdentity: YuwellCommunicationIdentity.parse('000000000000'),
      cipher: null,
      k: 0,
      r: 0,
      transmitterComputed: true,
      phase: YuwellCredentialPhase.identityPrepared,
    );

YuwellSessionCredentials _authenticatedCredentials() =>
    YuwellSessionCredentials(
      communicationIdentity: YuwellCommunicationIdentity.parse('000000000000'),
      cipher: 0,
      k: 0,
      r: 0,
      transmitterComputed: true,
      phase: YuwellCredentialPhase.authenticated,
    );

YuwellSessionCredentials _activationPreparedCredentials() =>
    YuwellSessionCredentials(
      communicationIdentity: YuwellCommunicationIdentity.parse('000000000000'),
      cipher: 0,
      k: 1.23,
      r: 4.5,
      transmitterComputed: true,
      phase: YuwellCredentialPhase.activationPrepared,
      activationStartedAt: DateTime.utc(2026, 8, 1, 12),
    );

YuwellSessionCredentials _activeCredentials() => YuwellSessionCredentials(
  communicationIdentity: YuwellCommunicationIdentity.parse('000000000000'),
  cipher: 0,
  k: 1.23,
  r: 4.5,
  transmitterComputed: true,
  phase: YuwellCredentialPhase.active,
  activationStartedAt: DateTime.utc(2026, 8, 1, 12),
);

YuwellSessionCredentials _lowPowerPendingCredentials() =>
    _activeCredentials().copyWith(phase: YuwellCredentialPhase.lowPowerPending);

final class _Fixture {
  _Fixture({
    YuwellSessionCredentials? credentials,
    _MemoryIntentStore? journal,
    List<String>? sharedEvents,
    BleCharacteristicProperties writeProperties =
        const BleCharacteristicProperties(write: true),
    int? negotiatedMtu,
    int historyRecordCount = 0,
    int? dropResponseOpcode,
    int? throwWriteOpcode,
    int throwWriteOccurrence = 1,
    bool checkIdAccepted = true,
    bool? bindingStatus,
    Duration ackDelay = Duration.zero,
    Duration historyResponseDelay = Duration.zero,
    Duration lowPowerResponseDelay = Duration.zero,
    List<int> historyRecordBytes = _recordBytes,
    List<List<int>>? historySlots,
    List<int>? versionResponse,
    List<BleService>? serviceOverride,
    this.glucoseOutputPolicy = YuwellV1150GlucoseOutputPolicy.disabled,
  }) : events = sharedEvents ?? <String>[],
       credentials = _MemoryCredentialStore(
         value: credentials,
         events: sharedEvents ?? <String>[],
       ),
       journal =
           journal ?? _MemoryIntentStore(events: sharedEvents ?? <String>[]),
       connection = _ScriptedConnection(
         writeProperties: writeProperties,
         negotiatedMtu: negotiatedMtu,
         historyRecordCount: historySlots?.length ?? historyRecordCount,
         dropResponseOpcode: dropResponseOpcode,
         throwWriteOpcode: throwWriteOpcode,
         throwWriteOccurrence: throwWriteOccurrence,
         checkIdAccepted: checkIdAccepted,
         bindingStatus: bindingStatus ?? credentials != null,
         ackDelay: ackDelay,
         historyResponseDelay: historyResponseDelay,
         lowPowerResponseDelay: lowPowerResponseDelay,
         historyRecordBytes: historyRecordBytes,
         historySlots: historySlots,
         versionResponse: versionResponse,
         serviceOverride: serviceOverride,
         events: sharedEvents ?? <String>[],
       ) {
    // When no shared list was supplied, put every fake on this fixture's list.
    if (sharedEvents == null) {
      this.credentials.events = events;
      this.journal.events = events;
      connection.events = events;
    }
  }

  final List<String> events;
  final _MemoryCredentialStore credentials;
  final _MemoryIntentStore journal;
  final _ScriptedConnection connection;
  final YuwellV1150GlucoseOutputPolicy glucoseOutputPolicy;
  final YuwellSessionLeaseRegistry leaseRegistry = YuwellSessionLeaseRegistry();

  Future<YuwellAnytimeSession> connect({bool authorized = false}) async {
    final transport = _ScriptedTransport(connection);
    final driver = YuwellAnytimeDriver(
      transport,
      credentialStore: credentials,
      writeIntentStore: journal,
      identityGenerator: YuwellSecureIdentityGenerator(random: _ZeroRandom()),
      timingProfile: const YuwellTimingProfile(
        connectTimeout: Duration(milliseconds: 100),
        responseTimeout: Duration(milliseconds: 40),
        maxHistoryBatches: 8000,
      ),
      sessionLeaseRegistry: leaseRegistry,
      glucoseOutputPolicy: glucoseOutputPolicy,
      clock: () => DateTime.utc(2026, 8, 1, 13),
    );
    final mapped = driver.discovery.mapScanResult(
      const BleScanResult(
        deviceId: 'synthetic-device',
        deviceName: 'Anytime0123456789',
        rssi: -40,
      ),
    )!;
    final sensor = DiscoveredSensor(
      driverId: mapped.driverId,
      deviceId: mapped.deviceId,
      displayName: mapped.displayName,
      storageKey: mapped.storageKey,
      rssi: mapped.rssi,
      capabilities: mapped.capabilities,
      notes: mapped.notes,
      metadata: <String, String>{
        ...mapped.metadata,
        cgmAllowSessionActivationMetadataKey: authorized.toString(),
      },
    );
    return await driver.connect(sensor) as YuwellAnytimeSession;
  }
}

final class _MemoryCredentialStore implements YuwellCredentialStore {
  _MemoryCredentialStore({required this.value, required this.events});

  YuwellSessionCredentials? value;
  List<String> events;
  YuwellCredentialPhase? _gatedPhase;
  Completer<void>? _gatedWriteStarted;
  Future<void>? _gatedWriteRelease;

  void gateWrite({
    required YuwellCredentialPhase phase,
    required Completer<void> started,
    required Future<void> release,
  }) {
    _gatedPhase = phase;
    _gatedWriteStarted = started;
    _gatedWriteRelease = release;
  }

  @override
  Future<void> delete(String storageKey) async {
    value = null;
    events.add('credential:deleted');
  }

  @override
  Future<YuwellSessionCredentials?> read(String storageKey) async => value;

  @override
  Future<void> write(
    String storageKey,
    YuwellSessionCredentials credentials,
  ) async {
    if (credentials.phase == _gatedPhase) {
      final started = _gatedWriteStarted;
      if (started != null && !started.isCompleted) started.complete();
      await _gatedWriteRelease;
    }
    value = credentials;
    events.add('credential:${credentials.phase.name}');
  }
}

final class _MemoryIntentStore implements YuwellWriteIntentStore {
  _MemoryIntentStore({this.initial, List<String>? events})
    : current = initial,
      events = events ?? <String>[];

  final YuwellUnresolvedWriteIntent? initial;
  YuwellUnresolvedWriteIntent? current;
  List<String> events;
  var _serial = 0;

  @override
  Future<bool> hasUnresolved(String storageKey) async => current != null;

  @override
  Future<YuwellUnresolvedWriteIntent?> readUnresolved(
    String storageKey,
  ) async => current;

  @override
  Future<String> prepare(
    String storageKey,
    YuwellActivationWrite operation,
  ) async {
    if (current != null) throw StateError('unresolved intent exists');
    final token = 'opaque-${++_serial}';
    current = YuwellUnresolvedWriteIntent(
      token: token,
      operation: operation,
      state: YuwellWriteIntentState.prepared,
    );
    events.add('prepare:${operation.name}');
    return token;
  }

  @override
  Future<void> markTransmitted(String token) async {
    final value = _require(token);
    current = YuwellUnresolvedWriteIntent(
      token: token,
      operation: value.operation,
      state: YuwellWriteIntentState.transmitted,
    );
    events.add('transmitted:${value.operation.name}');
  }

  @override
  Future<void> markCompleted(String token) async {
    final value = _require(token);
    if (value.state != YuwellWriteIntentState.transmitted) {
      throw StateError('only transmitted intents can complete normally');
    }
    events.add('complete:${value.operation.name}');
    current = null;
  }

  @override
  Future<void> markUnknown(String token) async {
    final value = _require(token);
    current = YuwellUnresolvedWriteIntent(
      token: token,
      operation: value.operation,
      state: YuwellWriteIntentState.unknown,
    );
    events.add('unknown:${value.operation.name}');
  }

  @override
  Future<void> cancelPrepared(String token) async {
    final value = _require(token);
    if (value.state != YuwellWriteIntentState.prepared) {
      throw StateError('only prepared intents can be cancelled');
    }
    events.add('cancel:${value.operation.name}');
    current = null;
  }

  @override
  Future<void> resolveRecovered(
    String token, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    final value = _require(token);
    if (value.operation != expectedOperation || value.state != expectedState) {
      throw StateError('recovered intent changed');
    }
    events.add('recover:${value.operation.name}');
    current = null;
  }

  @override
  Future<String> replaceRecoveredWithPrepared(
    String token,
    String storageKey,
    YuwellActivationWrite operation, {
    required YuwellActivationWrite expectedOperation,
    required YuwellWriteIntentState expectedState,
  }) async {
    final value = _require(token);
    if (value.operation != expectedOperation ||
        value.state != expectedState ||
        value.operation != YuwellActivationWrite.setCommunicationId ||
        operation != YuwellActivationWrite.setCommunicationId) {
      throw StateError('only set-ID can be atomically recovered');
    }
    final replacement = 'opaque-${++_serial}';
    current = YuwellUnresolvedWriteIntent(
      token: replacement,
      operation: operation,
      state: YuwellWriteIntentState.prepared,
    );
    events.add('replace:${operation.name}');
    return replacement;
  }

  YuwellUnresolvedWriteIntent _require(String token) {
    final value = current;
    if (value == null || value.token != token) {
      throw StateError('token mismatch');
    }
    return value;
  }
}

/// A transport that must never be called. [YuwellAnytimeDriver.connect]
/// validates the [DiscoveredSensor] descriptor before touching the
/// transport at all, so a test for that guard should prove the transport
/// stays untouched, not merely unconfigured.
final class _UnreachableTransport implements BleTransport {
  const _UnreachableTransport();

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw StateError('invalidSensor must reject before transport use');

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => throw StateError('invalidSensor must reject before transport use');
}

final class _ScriptedTransport implements BleTransport {
  const _ScriptedTransport(this.connection);

  final _ScriptedConnection connection;

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => connection;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => const Stream<BleScanResult>.empty();
}

final class _ScriptedConnection implements BleConnection, BleNegotiatedMtu {
  _ScriptedConnection({
    required this.writeProperties,
    required this.negotiatedMtu,
    required int historyRecordCount,
    required this.dropResponseOpcode,
    required this.throwWriteOpcode,
    required this.throwWriteOccurrence,
    required this.checkIdAccepted,
    required bool bindingStatus,
    required this.ackDelay,
    required this.historyResponseDelay,
    required this.lowPowerResponseDelay,
    required this.historyRecordBytes,
    required this.historySlots,
    this.versionResponse,
    this.serviceOverride,
    required this.events,
  }) : _historyRecordCount = historyRecordCount,
       _bound = bindingStatus;

  final BleCharacteristicProperties writeProperties;
  @override
  final int? negotiatedMtu;
  final int _historyRecordCount;
  final int? dropResponseOpcode;
  final int? throwWriteOpcode;
  final int throwWriteOccurrence;
  final bool checkIdAccepted;
  bool _bound;
  final Duration ackDelay;
  final Duration historyResponseDelay;
  final Duration lowPowerResponseDelay;
  final List<int> historyRecordBytes;
  final List<List<int>>? historySlots;
  final List<int>? versionResponse;
  final List<BleService>? serviceOverride;
  int get historyRecordCount => historySlots?.length ?? _historyRecordCount;
  List<String> events;
  final writes = <_Write>[];
  final historyStarts = <int>[];
  final historyCounts = <int>[];
  final _states = StreamController<BleConnectionState>.broadcast();
  final _notifications = StreamController<List<int>>.broadcast();
  bool disconnected = false;

  @override
  String get deviceId => 'synthetic-device';

  @override
  Stream<BleConnectionState> get connectionStates => _states.stream;

  @override
  bool get supportsBondLifecycle => false;

  int opcodeWriteCount(int opcode) =>
      writes.where((write) => write.value.first == opcode).length;

  void emitNotification(List<int> frame) => _notifications.add(frame);

  @override
  Future<BleBondState> currentBondState() async => BleBondState.unknown;

  @override
  Future<List<BleService>> discoverServices() async =>
      serviceOverride ??
      <BleService>[
        BleService(
          uuid: yuwellCt5ServiceUuid,
          characteristics: <BleCharacteristicRef>[
            const BleCharacteristicRef(
              serviceUuid: yuwellCt5ServiceUuid,
              characteristicUuid: yuwellCt5NotifyCharacteristicUuid,
              properties: BleCharacteristicProperties(notify: true),
            ),
            BleCharacteristicRef(
              serviceUuid: yuwellCt5ServiceUuid,
              characteristicUuid: yuwellCt5WriteCharacteristicUuid,
              properties: writeProperties,
            ),
          ],
        ),
      ];

  @override
  Future<void> disconnect() async {
    events.add('disconnect');
    disconnected = true;
    if (!_states.isClosed) _states.add(BleConnectionState.disconnected);
  }

  @override
  Future<void> ensureBonded() async =>
      throw StateError('Yuwell must not request an OS bond');

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) =>
      _notifications.stream;

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async =>
      const <int>[];

  @override
  Future<void> removeBond() async =>
      throw StateError('Yuwell must not remove an OS bond');

  @override
  Future<void> requestMtu(int mtu) async {
    events.add('mtu-request');
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) async {
    events.add('notify:${enabled ? 'on' : 'off'}');
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final immutable = List<int>.unmodifiable(value);
    writes.add(_Write(immutable, withoutResponse));
    final opcode = immutable.first;
    events.add('write:${opcode.toRadixString(16).padLeft(2, '0')}');
    if (opcode == throwWriteOpcode &&
        opcodeWriteCount(opcode) == throwWriteOccurrence) {
      throw StateError('synthetic transport write failure');
    }
    if (opcode == 0x30) _bound = true;
    if (opcode == 0x45 || opcode == 0x35) {
      await Future<void>.delayed(ackDelay);
      events.add('ack-complete');
      return;
    }
    if (opcode == dropResponseOpcode) {
      return;
    }
    final response = _response(immutable);
    if (response != null) {
      final delay = switch (opcode) {
        0x47 => historyResponseDelay,
        0x0f => lowPowerResponseDelay,
        _ => Duration.zero,
      };
      if (delay == Duration.zero) {
        scheduleMicrotask(() => _notifications.add(response));
      } else {
        unawaited(
          Future<void>.delayed(delay, () {
            if (!_notifications.isClosed) _notifications.add(response);
          }),
        );
      }
    }
  }

  List<int>? _response(List<int> request) => switch (request.first) {
    0x01 =>
      versionResponse ??
          const <int>[1, 20, 26, 9, 2, 0, 1, 1, 5, 0, 0, 0, 0, 0],
    0x03 => appendYuwellSum8(const <int>[0x03, 0]),
    0x11 => appendYuwellSum8(<int>[
      0x11,
      0,
      _bound ? 1 : 0,
      ...List<int>.filled(10, 0),
    ]),
    0x30 => appendYuwellSum8(const <int>[0x30, 0, 0, 0, 0, 1, 2, 3, 4]),
    0x31 => appendYuwellSum8(<int>[0x31, 0, 0, 0, 0, checkIdAccepted ? 1 : 0]),
    0x3f => <int>[
      0x3f,
      ...YuwellCt5ByteTransform.encode(_calibrationCode.codeUnits, key: 0),
    ],
    0x38 => appendYuwellSum8(<int>[
      0x38,
      ...YuwellCt5ByteTransform.encode(List<int>.filled(12, 0), key: 0),
    ]),
    0x06 => appendYuwellSum8(const <int>[0x06, 1]),
    0x0f => const <int>[0x0f],
    0x47 => _historyResponse(request),
    _ => null,
  };

  List<int> _historyResponse(List<int> request) {
    final start = request[1] | (request[2] << 8);
    final count = request[3];
    historyStarts.add(start);
    historyCounts.add(count);
    if (start >= historyRecordCount) {
      return appendYuwellSum8(<int>[0x47, start & 0xff, start >> 8]);
    }
    final returned = math.min(count, historyRecordCount - start);
    final clear = <int>[];
    for (var offset = 0; offset < returned; offset++) {
      clear.addAll(historySlots?[start + offset] ?? historyRecordBytes);
    }
    return appendYuwellSum8(<int>[
      0x47,
      start & 0xff,
      start >> 8,
      ...YuwellCt5ByteTransform.encode(clear, key: 0),
    ]);
  }
}

final class _Write {
  const _Write(this.value, this.withoutResponse);

  final List<int> value;
  final bool withoutResponse;
}

final class _ZeroRandom implements math.Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}
