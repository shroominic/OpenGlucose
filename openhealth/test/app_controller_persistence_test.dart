import 'dart:async';
import 'dart:convert';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/cgm_driver_registry.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/messaging/message_context_builder.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_history_repository.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'BLE-only backfill reaches controller archive without current glucose',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fixture = _LibreArchiveFixture();
      await fixture.prepare();
      addTearDown(fixture.dispose);
      final receivedAt = DateTime.now().toUtc();
      final historical = _reading(
        valueMgdl: 105,
        sensorMinute: 165,
        recordedAt: receivedAt.subtract(const Duration(minutes: 15)),
      ).copyWith(isDisplayProvisional: true);
      final committed = await fixture.repository.commitLibre(
        fixture.binding,
        sensorMinute: 180,
        receivedAt: receivedAt,
        historicalReadings: [
          LibreGen1HistoricalReading(
            reading: historical,
            kind: LibreGen1BleHistoryKind.history,
          ),
        ],
      );
      final controller = await fixture.controller([committed.state.history]);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      expect(controller.snapshot!.history, hasLength(33));
      expect(controller.latestReading, isNull);
      expect(controller.displayLatestReading, isNull);
      expect(
        controller.allHistoricalReadings.any(
          (entry) => entry.sensorMinute == 165,
        ),
        isFalse,
      );
      expect(
        fixture.repository.confirmedLibreLiveReading(
          sensorHistoryKey(fixture.sensor),
          historical,
        ),
        isNull,
      );
      await controller.disconnect();
      expect(controller.archivedReadingCount, 33);
      expect(controller.archivedSensors, hasLength(4));
      final archive = controller.archivedSensors.singleWhere(
        (entry) => !fixture.archiveBytes.containsKey(entry.historyKey),
      );
      final exported = controller.archivedSensorExportData(archive);
      expect(exported.hasAcquisitionEvidence, isTrue);
      final entry = exported.acquisitionEntries!.single;
      expect(entry.origin, LibreHistoryOrigin.bleHistory);
      expect(entry.timestampBasis, LibreHistoryTimestampBasis.sensorRelative);
      expect(entry.firstReceivedAt, receivedAt);
      expect(entry.reading.toJson(), historical.toJson());
      fixture.expectArchiveBytes(fixture.archiveBytes);
    },
  );

  test(
    'uncertain NFC import keeps confirmed controller history readable',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = _LostAcknowledgementHistoryStore();
      final fixture = _LibreArchiveFixture(store: store);
      await fixture.prepare();
      addTearDown(fixture.dispose);
      final controller = await fixture.controller([fixture.readings]);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      final scope = await controller.pauseForLibreHistoryRead(fixture.sensor);
      final ticket = await fixture.repository.beginNfcHistoryImport(
        fixture.binding,
        connectionOwner: scope,
      );
      final receipt = DateTime.now().toUtc();
      final key = sensorHistoryKey(fixture.sensor);
      final before = store.getString(key);
      store.loseNextWriteFor = key;
      await expectLater(
        fixture.repository.importNfcHistory(
          ticket,
          connectionOwner: scope,
          scanMinute: 180,
          scanReceivedAt: receipt,
          samples: [
            LibreNfcHistorySample(
              reading: _reading(
                valueMgdl: 150,
                sensorMinute: 165,
                recordedAt: receipt.subtract(const Duration(minutes: 15)),
              ).copyWith(isDisplayProvisional: true),
              firstReceivedAt: receipt,
              origin: LibreHistoryOrigin.nfcHistory,
            ),
          ],
        ),
        throwsStateError,
      );
      expect(
        store.getString(key),
        isNot(before),
        reason: 'The dispatched write lost its acknowledgement',
      );
      expect(fixture.repository.isQuarantined(key), isTrue);
      expect(
        () => fixture.repository.retainOnDisconnect(key),
        throwsStateError,
        reason: 'The display predicate cannot grant mutation authority',
      );
      expect(
        controller.snapshot!.history.map((r) => r.toJson()),
        fixture.readings.map((r) => r.toJson()),
      );
      expect(controller.latestReading, isNull);
      expect(controller.displayLatestReading, isNull);
      controller.refreshImportedLibreHistory(fixture.sensor);
      expect(controller.snapshot!.history, hasLength(32));
      expect(
        controller.snapshot!.history.any((r) => r.sensorMinute == 165),
        isFalse,
      );
      expect(controller.archivedReadingCount, 32);
      fixture.expectArchiveBytes(fixture.archiveBytes);
      scope.release(cleanupConfirmed: true);
    },
  );

  test(
    'NFC outage history is archived with provenance, never as live glucose',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fixture = _LibreArchiveFixture();
      await fixture.prepare();
      addTearDown(fixture.dispose);
      final owner = Object();
      final ticket = await fixture.repository.beginNfcHistoryImport(
        fixture.binding,
        connectionOwner: owner,
      );
      final receivedAt = DateTime.now().toUtc();
      final historical = _reading(
        valueMgdl: 105,
        sensorMinute: 165,
        recordedAt: receivedAt.subtract(const Duration(minutes: 15)),
      ).copyWith(isDisplayProvisional: true);
      await fixture.repository.importNfcHistory(
        ticket,
        connectionOwner: owner,
        scanMinute: 180,
        scanReceivedAt: receivedAt,
        samples: [
          LibreNfcHistorySample(
            reading: historical,
            firstReceivedAt: receivedAt,
            origin: LibreHistoryOrigin.nfcHistory,
          ),
        ],
      );
      final all = fixture.repository.readCommittedHistory(
        sensorHistoryKey(fixture.sensor),
      );
      final controller = await fixture.controller([all]);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      controller.refreshImportedLibreHistory(fixture.sensor);
      expect(controller.snapshot!.history, hasLength(33));
      expect(controller.latestReading, isNull);
      expect(controller.displayLatestReading, isNull);
      await controller.disconnect();
      expect(controller.archivedReadingCount, 33);
      expect(controller.archivedSensors, hasLength(4));
      final newArchive = controller.archivedSensors.singleWhere(
        (archive) => !fixture.archiveBytes.containsKey(archive.historyKey),
      );
      final entries = fixture.repository.readLibreHistoryEntries(
        newArchive.historyKey,
      );
      expect(entries, hasLength(1));
      expect(entries.single.origin, LibreHistoryOrigin.nfcHistory);
      expect(
        entries.single.timestampBasis,
        LibreHistoryTimestampBasis.sensorRelative,
      );
      expect(entries.single.firstReceivedAt, receivedAt);
      expect(entries.single.reading.toJson(), historical.toJson());
      fixture.expectArchiveBytes(fixture.archiveBytes);
    },
  );

  test(
    'clear cannot succeed while a Libre archive delta is being saved',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = _GatedArchiveHealthStateStore();
      final fixture = _LibreArchiveFixture(store: store);
      await fixture.prepare();
      final reading = _reading(
        valueMgdl: 111,
        sensorMinute: 132,
        recordedAt: fixture.readings.last.recordedAt!.add(
          const Duration(minutes: 1),
        ),
      );
      await fixture.commit(reading);
      final controller = await fixture.controller([
        [...fixture.readings, reading],
      ]);
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        await fixture.dispose();
      });
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      store.gateNextArchiveWrite = true;
      final disconnect = controller.disconnect();
      await store.started.future.timeout(const Duration(seconds: 1));
      expect(await controller.clearPersistedHistory(), isFalse);
      expect(
        fixture.repository.readCommittedHistory(
          sensorHistoryKey(fixture.sensor),
        ),
        hasLength(33),
      );
      store.release.complete();
      await disconnect.timeout(const Duration(seconds: 1));
      expect(controller.archivedReadingCount, 33);
      expect(controller.snapshot, isNull);
      fixture.expectArchiveBytes(fixture.archiveBytes);
    },
  );

  for (final nestedVariant in [false, true]) {
    test(
      'AiDEX disconnect preserves malformed Libre manifest (variant=$nestedVariant)',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final id = base64Url
            .encode(utf8.encode('libre2-gen1|libre2-gen1:unknown|1'))
            .replaceAll('=', '');
        final raw = jsonEncode([
          {
            'driverId': 'libre2-gen1',
            'storageKey': 'libre2-gen1:unknown',
            'historyKey': nestedVariant
                ? 'openHealth.history.archive.$id'
                : 'openHealth.history.archive.unresolved',
            'readingCount': nestedVariant ? 0 : 1,
            if (nestedVariant) ...{
              'id': id,
              'sensorVariant': {
                'model': 42,
                'unknownField': 'must remain unchanged',
              },
            },
          },
        ]);
        final store = _ControllableHealthStateStore(
          initialValues: {
            'openHealth.sensorArchive': raw,
            'openHealth.history.archive.unresolved':
                'unresolved synthetic bytes',
          },
        );
        final sensor = _multiDriverSensor(
          driverId: 'aidex',
          storageKey: 'synthetic-aidex',
        );
        final driver = _ControlledDriver([
          _ControlledSession(_testSnapshot(sensor, stage: CgmSyncStage.ready)),
        ], driverId: 'aidex');
        final controller = CgmAppController(
          preferences: await SharedPreferences.getInstance(),
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        expect(controller.archiveManifestUnavailable, isTrue);
        await controller.connect(sensor, allowSessionActivation: false);
        await controller.disconnect();
        expect(controller.snapshot!.sensor.storageKey, sensor.storageKey);
        expect(controller.lastError, isNotNull);
        expect(controller.archivedReadingCount, isNull);
        expect(store.getString('openHealth.lastSensor'), isNotNull);
        expect(store.getString('openHealth.sensorArchive'), raw);
        expect(
          store.getString('openHealth.history.archive.unresolved'),
          'unresolved synthetic bytes',
        );
        expect(
          store.setAttempts.where(
            (key) => key.startsWith('openHealth.history.archive.'),
          ),
          isEmpty,
        );
      },
    );
  }

  for (final initial in [true, false]) {
    test(
      'fresh durable Libre timing saves selection ${initial ? 'initially' : 'from stream'} without glucose',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = _ControllableHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'libre2-gen1:verified-timing',
        );
        final verified = _committedTimingSnapshot(
          sensor,
          elapsed: initial ? 20 : 80,
        );
        final session = _ControlledSession(
          initial
              ? verified
              : _testSnapshot(sensor, stage: CgmSyncStage.syncing),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: await SharedPreferences.getInstance(),
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
        await controller.connect(sensor, allowSessionActivation: false);
        if (!initial) {
          expect(store.getString('openHealth.lastSensor'), isNull);
          expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
          session.emit(verified);
          await _drainEventQueue();
        }
        expect(store.getString('openHealth.lastSensor'), isNotNull);
        expect(controller.snapshot!.stage, CgmSyncStage.syncing);
        expect(controller.snapshot!.latestReading, isNull);
        expect(controller.snapshot!.history, isEmpty);
        expect(controller.allHistoricalReadings, isEmpty);
        expect(controller.hasVerifiedLibreReceptionFor(sensor), isTrue);
        expect(
          controller.hasVerifiedLibreReceptionFor(
            _multiDriverSensor(
              driverId: sensor.driverId,
              storageKey: 'libre2-gen1:wrong-receiver',
            ),
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'incomplete stale and unrelated timing cannot verify selection',
    () async {
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:verified-timing',
      );
      final valid = _committedTimingSnapshot(sensor);
      final ordinary = _multiDriverSensor(
        driverId: 'aidex',
        storageKey: 'synthetic-aidex',
      );
      final cases = <CgmSessionSnapshot>[
        valid.copyWith(
          metadata: {...valid.metadata}
            ..remove('cgm.libre2.observationCommitted'),
        ),
        valid.copyWith(
          stage: CgmSyncStage.ready,
          metadata: {...valid.metadata}
            ..remove('cgm.libre2.observationCommitted'),
        ),
        valid.copyWith(
          metadata: {
            ...valid.metadata,
            'cgm.libre2.observationCommitted': 'false',
          },
        ),
        for (final phase in ['awaitingPacket', 'subscribing', 'failed'])
          valid.copyWith(
            metadata: {...valid.metadata, 'cgm.libre2.phase': phase},
          ),
        for (final timing in ['stale', 'repeatedOrRegressed', 'unavailable'])
          valid.copyWith(
            metadata: {...valid.metadata, 'cgm.libre2.timing': timing},
          ),
        valid.copyWith(stage: CgmSyncStage.error),
        valid.copyWith(sessionInfo: const CgmSessionInfo()),
        _committedTimingSnapshot(sensor, elapsed: -1),
        _committedTimingSnapshot(sensor, elapsed: 65536),
        valid.copyWith(lastError: 'libre2.observationStorageUnavailable'),
        _committedTimingSnapshot(ordinary),
        _committedTimingSnapshot(
          _multiDriverSensor(
            driverId: sensor.driverId,
            storageKey: 'libre2-gen1:another-target',
          ),
        ),
        _committedTimingSnapshot(
          _multiDriverSensor(
            driverId: sensor.driverId,
            storageKey: 'libre2-gen1:another-target',
          ),
        ).copyWith(stage: CgmSyncStage.ready),
      ];
      for (final candidate in cases) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = _ControllableHealthStateStore();
        final selected = candidate.sensor.driverId == 'aidex'
            ? ordinary
            : sensor;
        final session = _ControlledSession(candidate);
        final driver = _ControlledDriver([
          session,
        ], driverId: selected.driverId);
        final controller = CgmAppController(
          preferences: await SharedPreferences.getInstance(),
          driver: driver,
          healthStateStore: store,
        );
        await controller.initialize();
        await controller.connect(selected, allowSessionActivation: false);
        await _drainEventQueue();
        expect(controller.hasVerifiedLibreReceptionFor(selected), isFalse);
        expect(
          store.getString('openHealth.lastSensor'),
          isNull,
          reason: '${candidate.stage}: ${candidate.metadata}',
        );
        controller.dispose();
        await driver.close();
      }
    },
  );

  test(
    'Disconnect removes a gated durable timing promotion and rejects late evidence',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = _GatedSelectionHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:cancel-timing',
      );
      final verified = _committedTimingSnapshot(sensor);
      final session = _ControlledSession(verified);
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: await SharedPreferences.getInstance(),
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      final connect = controller.connect(sensor, allowSessionActivation: false);
      await store.started.future.timeout(const Duration(seconds: 1));
      expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
      var finished = false;
      final disconnect = controller.disconnect().then((_) => finished = true);
      expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
      await _drainEventQueue();
      expect(finished, isFalse);
      store.release.complete();
      await Future.wait([
        connect,
        disconnect,
      ]).timeout(const Duration(seconds: 1));
      session.emit(verified);
      await _drainEventQueue();
      expect(controller.snapshot, isNull);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.archivedSensors, isEmpty);
      expect(driver.connectedSensors, hasLength(1));
      expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
    },
  );

  test('Libre reception completion is revoked during history pause', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sensor = _multiDriverSensor(
      driverId: 'libre2-gen1',
      storageKey: 'libre2-gen1:pause-reception',
    );
    final session = _ControlledSession(_committedTimingSnapshot(sensor));
    final driver = _ControlledDriver([session], driverId: sensor.driverId);
    final controller = CgmAppController(
      preferences: await SharedPreferences.getInstance(),
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    addTearDown(() async {
      controller.dispose();
      await driver.close();
    });
    await controller.initialize();
    await controller.connect(sensor, allowSessionActivation: false);
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isTrue);
    final pendingPause = controller.pauseForLibreHistoryRead(sensor);
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
    final pause = await pendingPause;
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
    pause.release(cleanupConfirmed: true);
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
    session.emit(_committedTimingSnapshot(sensor, elapsed: 21));
    await _drainEventQueue();
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
  });

  test('Libre selection persistence failure cannot finish setup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sensor = _multiDriverSensor(
      driverId: 'libre2-gen1',
      storageKey: 'libre2-gen1:failed-reception-selection',
    );
    final session = _ControlledSession(_committedTimingSnapshot(sensor));
    final driver = _ControlledDriver([session], driverId: sensor.driverId);
    final controller = CgmAppController(
      preferences: await SharedPreferences.getInstance(),
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(
        failSetPrefix: 'openHealth.lastSensor',
      ),
    );
    addTearDown(() async {
      controller.dispose();
      await driver.close();
    });
    await controller.initialize();
    await controller.connect(sensor, allowSessionActivation: false);
    expect(controller.lastError, isNotNull);
    expect(controller.hasVerifiedLibreReceptionFor(sensor), isFalse);
    expect(controller.hasLibreReceptionSetupFailureFor(sensor), isTrue);
    expect(controller.snapshot!.stage, CgmSyncStage.syncing);
    expect(controller.snapshot!.latestReading, isNull);
  });

  test('Libre archives only new points after migrated disconnects', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fixture = _LibreArchiveFixture();
    await fixture.prepare();
    final original = Map<String, String>.of(fixture.archiveBytes);
    final repeatedReceipt = fixture.readings.last.recordedAt!;
    final newReading = _reading(
      valueMgdl: 111,
      sensorMinute: 132,
      recordedAt: repeatedReceipt,
    );
    final rollbackReading = _reading(
      valueMgdl: 112,
      sensorMinute: 133,
      recordedAt: fixture.readings.first.recordedAt!.subtract(
        const Duration(hours: 1),
      ),
    );
    final histories = [
      fixture.readings,
      [...fixture.readings, newReading],
      [...fixture.readings, newReading],
      [...fixture.readings, newReading, rollbackReading],
    ];
    final controller = await fixture.controller(histories);
    addTearDown(fixture.dispose);
    expect(
      fixture.repository.readCommittedHistory(sensorHistoryKey(fixture.sensor)),
      hasLength(32),
    );

    await controller.connect(fixture.sensor, allowSessionActivation: false);
    await _drainEventQueue();
    await controller.disconnect();
    expect(controller.archivedSensors, hasLength(3));
    expect(controller.archivedReadingCount, 32);
    fixture.expectArchiveBytes(original);

    await fixture.commit(newReading);
    final orphanId = base64Url
        .encode(
          utf8.encode(
            '${fixture.binding.driverId}|${fixture.binding.storageKey}|'
            '${repeatedReceipt.millisecondsSinceEpoch + 1}',
          ),
        )
        .replaceAll('=', '');
    final orphanKey = 'openHealth.history.archive.$orphanId';
    await fixture.store.setString(orphanKey, 'unresolved synthetic orphan');
    await controller.connect(fixture.sensor, allowSessionActivation: false);
    await _drainEventQueue();
    await controller.disconnect();
    expect(controller.archivedSensors, hasLength(4));
    expect(controller.archivedReadingCount, 33);
    fixture.expectArchiveBytes(original);
    expect(fixture.store.getString(orphanKey), 'unresolved synthetic orphan');
    final delta = controller.archivedSensors.singleWhere(
      (entry) => !original.containsKey(entry.historyKey),
    );
    expect(
      controller.readingsForArchivedSensor(delta).single.sensorMinute,
      132,
    );
    expect(
      controller.readingsForArchivedSensor(delta).single.recordedAt,
      repeatedReceipt,
    );
    expect(delta.startedAt, isNull);
    final afterFirstDelta = {
      for (final entry in controller.archivedSensors)
        entry.historyKey: fixture.store.getString(entry.historyKey)!,
    };

    await controller.connect(fixture.sensor, allowSessionActivation: false);
    await _drainEventQueue();
    await controller.disconnect();
    expect(controller.archivedSensors, hasLength(4));
    expect(controller.archivedReadingCount, 33);
    fixture.expectArchiveBytes(afterFirstDelta);

    await fixture.commit(rollbackReading);
    await controller.connect(fixture.sensor, allowSessionActivation: false);
    await _drainEventQueue();
    await controller.disconnect();
    expect(controller.archivedSensors, hasLength(5));
    expect(controller.archivedReadingCount, 34);
    fixture.expectArchiveBytes(afterFirstDelta);
    final retained = await fixture.repository.loadLibre(fixture.binding);
    expect(retained.observedMinute, 133);
    expect(retained.history, hasLength(34));
    expect(fixture.store.getString('openHealth.lastSensor'), isNull);
  });

  test(
    'Libre archive delta preserves clear tombstone and prior archives',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fixture = _LibreArchiveFixture();
      await fixture.prepare();
      final newReading = _reading(
        valueMgdl: 111,
        sensorMinute: 132,
        recordedAt: fixture.readings.last.recordedAt!.add(
          const Duration(minutes: 1),
        ),
      );
      final controller = await fixture.controller([
        fixture.readings,
        [newReading],
      ]);
      addTearDown(fixture.dispose);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(await controller.clearPersistedHistory(), isTrue);
      expect(controller.snapshot!.history, isEmpty);
      await controller.disconnect();
      expect(controller.archivedSensors, hasLength(3));
      expect(controller.archivedReadingCount, 32);
      fixture.expectArchiveBytes(fixture.archiveBytes);
      final cleared = await fixture.repository.loadLibre(fixture.binding);
      expect(cleared.history, isEmpty);
      expect(cleared.observedMinute, 131);
      final replay = await fixture.repository.commitLibre(
        fixture.binding,
        sensorMinute: 131,
        receivedAt: newReading.recordedAt!,
      );
      expect(replay.advanced, isFalse);
      await fixture.commit(newReading);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      await _drainEventQueue();
      await controller.disconnect();
      expect(controller.archivedReadingCount, 33);
      expect(
        (await fixture.repository.loadLibre(
          fixture.binding,
        )).history.single.sensorMinute,
        132,
      );
      fixture.expectArchiveBytes(fixture.archiveBytes);
    },
  );

  test(
    'malformed related Libre archive keeps selection and all bytes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fixture = _LibreArchiveFixture();
      await fixture.prepare();
      final controller = await fixture.controller([fixture.readings]);
      addTearDown(fixture.dispose);
      await controller.connect(fixture.sensor, allowSessionActivation: false);
      await _drainEventQueue();
      final badKey = fixture.archiveBytes.keys.first;
      await fixture.store.setString(badKey, '{"unknown":true}');
      final before = Map<String, String>.of(fixture.store._values);
      await controller.disconnect();
      expect(controller.snapshot!.sensor.storageKey, fixture.sensor.storageKey);
      expect(controller.snapshot!.stage, CgmSyncStage.disconnected);
      expect(controller.lastError, isNotNull);
      expect(controller.archivedReadingCount, isNull);
      expect(controller.allHistoricalReadings, isEmpty);
      expect(fixture.store.getString('openHealth.lastSensor'), isNotNull);
      expect(
        fixture.store.getString('openHealth.sensorArchive'),
        before['openHealth.sensorArchive'],
      );
      for (final key in fixture.archiveBytes.keys) {
        expect(fixture.store.getString(key), before[key]);
      }
      expect(
        (await fixture.repository.loadLibre(fixture.binding)).observedMinute,
        131,
      );
    },
  );

  test(
    'Libre observation load failure keeps its closed code and blocks retry',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-load-failure',
      );
      final driver = _ControlledDriver(
        [],
        driverId: sensor.driverId,
        connectError: const LibreGen1LiveException(
          LibreGen1LiveFailure.observationStorageUnavailable,
        ),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      expect(
        controller.snapshot!.lastError,
        'libre2.observationStorageUnavailable',
      );
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(snapshotAllowsAutomaticReconnect(controller.snapshot!), isFalse);
      expect(
        primaryErrorTextForSnapshot(controller.snapshot!),
        startsWith(
          'Sensor updates stopped because readings could not be saved.',
        ),
      );
      await controller.disconnect();
      expect(controller.snapshot!.sensor.storageKey, sensor.storageKey);
      expect(controller.archivedSensors, isEmpty);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(1));
      expect(store.getString('openHealth.lastSensor'), isNull);
    },
  );

  test(
    'uncertain Libre storage keeps selection and blocks reconnect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final repository = SensorHistoryRepository(store);
      final binding = LibreGen1ObservationBinding(
        bootstrapId: 'synthetic-uncertain',
        sensorBindingDigest: 'd' * 64,
      );
      final sensor = DiscoveredSensor(
        driverId: binding.driverId,
        deviceId: 'synthetic-device',
        displayName: 'Libre 2',
        storageKey: binding.storageKey,
        rssi: -45,
        capabilities: const CgmCapabilities(),
      );
      final reading = _reading(
        valueMgdl: 110,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 10),
      );
      await repository.commitLibre(
        binding,
        sensorMinute: 100,
        receivedAt: reading.recordedAt!,
        reading: reading,
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [reading],
          verifiedLibreReception: true,
        ),
        disconnectError: const LibreGen1LiveException(
          LibreGen1LiveFailure.observationStorageUnavailable,
        ),
      );
      final driver = _ControlledDriver([session], driverId: binding.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        historyRepository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      await controller.disconnect();
      expect(controller.snapshot!.sensor.storageKey, sensor.storageKey);
      expect(
        controller.snapshot!.lastError,
        'libre2.observationStorageUnavailable',
      );
      expect(controller.snapshot!.history, hasLength(1));
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(1));
    },
  );

  test(
    'Libre disconnect archives readings but keeps the durable frontier',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final repository = SensorHistoryRepository(store);
      final binding = LibreGen1ObservationBinding(
        bootstrapId: 'synthetic-receiver',
        sensorBindingDigest: 'a' * 64,
      );
      final sensor = DiscoveredSensor(
        driverId: binding.driverId,
        deviceId: 'synthetic-device',
        displayName: 'Libre 2',
        storageKey: binding.storageKey,
        rssi: -45,
        capabilities: const CgmCapabilities(),
      );
      final reading = _reading(
        valueMgdl: 110,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 10),
      );
      await repository.commitLibre(
        binding,
        sensorMinute: 100,
        receivedAt: reading.recordedAt!,
        reading: reading,
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
      );
      final driver = _ControlledDriver([session], driverId: binding.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        historyRepository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      expect(controller.snapshot, isNull);
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      await controller.disconnect();
      expect(controller.snapshot, isNull);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.archivedSensors, hasLength(1));
      expect(
        repository
            .readCommittedHistory(sensorHistoryKey(sensor))
            .single
            .recordedAt,
        reading.recordedAt,
      );
      final restartedRepository = SensorHistoryRepository(store);
      final retained = await restartedRepository.loadLibre(binding);
      expect(retained.observedMinute, 100);
      expect(retained.history, hasLength(1));
      final replay = await restartedRepository.commitLibre(
        binding,
        sensorMinute: 100,
        receivedAt: reading.recordedAt!.add(const Duration(minutes: 1)),
      );
      expect(replay.advanced, isFalse);
      expect(replay.state.history.single.recordedAt, reading.recordedAt);
    },
  );

  test(
    'Libre clear cannot redisplay or persist a stale driver snapshot',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final repository = SensorHistoryRepository(store);
      final binding = LibreGen1ObservationBinding(
        bootstrapId: 'synthetic-clear',
        sensorBindingDigest: 'b' * 64,
      );
      final sensor = DiscoveredSensor(
        driverId: binding.driverId,
        deviceId: 'synthetic-device',
        displayName: 'Libre 2',
        storageKey: binding.storageKey,
        rssi: -45,
        capabilities: const CgmCapabilities(),
      );
      final reading = _reading(
        valueMgdl: 110,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 10),
      );
      await repository.commitLibre(
        binding,
        sensorMinute: 100,
        receivedAt: reading.recordedAt!,
        reading: reading,
      );
      final stale = _testSnapshot(
        sensor,
        stage: CgmSyncStage.ready,
        history: [reading],
      );
      final session = _ControlledSession(stale);
      final driver = _ControlledDriver([session], driverId: binding.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        historyRepository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(await controller.clearPersistedHistory(), isTrue);
      session.emit(stale);
      await _drainEventQueue();
      expect(controller.snapshot!.history, isEmpty);
      expect(controller.latestReading, isNull);
      await controller.disconnect();
      final retained = await SensorHistoryRepository(store).loadLibre(binding);
      expect(retained.observedMinute, 100);
      expect(retained.history, isEmpty);
    },
  );

  test(
    'unselected durable Libre history is visible only after explicit connect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final repository = SensorHistoryRepository(store);
      final binding = LibreGen1ObservationBinding(
        bootstrapId: 'synthetic-unpromoted',
        sensorBindingDigest: 'c' * 64,
      );
      final sensor = DiscoveredSensor(
        driverId: binding.driverId,
        deviceId: 'synthetic-device',
        displayName: 'Libre 2',
        storageKey: binding.storageKey,
        rssi: -45,
        capabilities: const CgmCapabilities(),
      );
      final reading = _reading(
        valueMgdl: 110,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 10),
      );
      await repository.commitLibre(
        binding,
        sensorMinute: 100,
        receivedAt: reading.recordedAt!,
        reading: reading,
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          lastError: 'libre2.advertisementUnavailable',
        ),
      );
      final driver = _ControlledDriver([session], driverId: binding.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        historyRepository: repository,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await _drainEventQueue();
      expect(controller.snapshot, isNull);
      expect(driver.connectedSensors, isEmpty);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(controller.snapshot!.history, hasLength(1));
      expect(controller.latestReading, isNull);
      expect(store.getString('openHealth.lastSensor'), isNull);
    },
  );

  test(
    'disposed controller closes a late driver result without attaching',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _testSensor();
      final started = Completer<void>();
      final release = Completer<void>();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready),
      );
      final driver = _ControlledDriver(
        [session],
        connectStarted: started,
        connectGate: release.future,
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.initialize();
      final connecting = controller.connect(
        sensor,
        allowSessionActivation: false,
      );
      await started.future.timeout(const Duration(seconds: 1));
      final beforeDispose = notifications;
      controller.dispose();
      release.complete();
      await connecting.timeout(const Duration(seconds: 1));
      await _drainEventQueue();
      expect(session.disconnectCalls, 1);
      expect(session.hasSnapshotListener, isFalse);
      expect(controller.snapshot?.stage, isNot(CgmSyncStage.ready));
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(notifications, beforeDispose);
      await driver.close();
    },
  );

  test(
    'manual sync cannot request history after its session disconnects',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final started = Completer<void>();
      final release = Completer<void>();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready),
        refreshLiveDataStarted: started,
        refreshLiveDataGate: release.future,
      );
      final driver = _ControlledDriver([session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      final sync = controller.sync();
      await started.future.timeout(const Duration(seconds: 1));
      await controller.disconnect(clearSelection: false);
      release.complete();
      await sync.timeout(const Duration(seconds: 1));
      expect(session.syncHistoryCalls, 0);
      expect(session.disconnectCalls, 1);
      expect(controller.lastError, isNull);
    },
  );

  test(
    'Disconnect cancels activation notice while read-only probe closes',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final started = Completer<void>();
      final release = Completer<void>();
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          metadata: {'activationRequired': 'true'},
        ),
        disconnectStarted: started,
        disconnectGate: release.future,
      );
      final driver = _ControlledDriver([session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      final connect = controller.connect(sensor, allowSessionActivation: false);
      await started.future.timeout(const Duration(seconds: 1));
      expect(controller.activationRequiredSensor, isNull);
      final disconnect = controller.disconnect();
      release.complete();
      await connect.timeout(const Duration(seconds: 1));
      await disconnect.timeout(const Duration(seconds: 1));
      expect(controller.activationRequiredSensor, isNull);
      expect(controller.snapshot, isNull);
      expect(session.disconnectCalls, 1);
      expect(driver.connectedSensors, hasLength(1));
      expect(
        driver
            .connectedSensors
            .single
            .metadata[cgmAllowSessionActivationMetadataKey],
        'false',
      );
    },
  );

  test(
    'foreground refresh cannot reconnect during explicit disconnect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:synthetic-disconnect-refresh-race',
      );
      final reading = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      );
      final closeStarted = Completer<void>();
      final closeRelease = Completer<void>();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
        disconnectStarted: closeStarted,
        disconnectGate: closeRelease.future,
      );
      final driver = _ControlledDriver([
        session,
        _ControlledSession(_testSnapshot(sensor, stage: CgmSyncStage.ready)),
      ], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        if (!closeRelease.isCompleted) closeRelease.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      final disconnect = controller.disconnect();
      await closeStarted.future.timeout(const Duration(seconds: 1));
      await controller.ensureFreshData(force: true);
      await controller.retryConnection();
      expect(driver.connectedSensors, hasLength(1));
      closeRelease.complete();
      await disconnect.timeout(const Duration(seconds: 1));
      await controller.ensureFreshData(force: true);
      await _drainEventQueue();
      expect(controller.snapshot, isNull);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(driver.connectedSensors, hasLength(1));
      expect(
        controller
            .readingsForArchivedSensor(controller.archivedSensors.single)
            .map((value) => value.toJson()),
        [reading.toJson()],
      );
      expect(session.disconnectCalls, 1);
    },
  );

  for (final cleanupFails in [false, true]) {
    test(
      'explicit disconnect owns late connection cleanup (fails=$cleanupFails)',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _ControllableHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'libre2-gen1:synthetic-late-connect',
        );
        final connectStarted = Completer<void>();
        final connectRelease = Completer<void>();
        final closeStarted = Completer<void>();
        final closeRelease = Completer<void>();
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready),
          disconnectStarted: closeStarted,
          disconnectGate: closeRelease.future,
          disconnectError: cleanupFails
              ? const LibreGen1LiveException(
                  LibreGen1LiveFailure.cleanupUnconfirmed,
                )
              : null,
        );
        final driver = _ControlledDriver(
          [session],
          driverId: sensor.driverId,
          connectStarted: connectStarted,
          connectGate: connectRelease.future,
        );
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          if (!connectRelease.isCompleted) connectRelease.complete();
          if (!closeRelease.isCompleted) closeRelease.complete();
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        final connect = controller.connect(
          sensor,
          allowSessionActivation: false,
        );
        await connectStarted.future.timeout(const Duration(seconds: 1));
        var disconnected = false;
        final disconnect = controller.disconnect().then(
          (_) => disconnected = true,
        );
        await _drainEventQueue();
        expect(disconnected, isFalse);
        connectRelease.complete();
        await closeStarted.future.timeout(const Duration(seconds: 1));
        await connect.timeout(const Duration(seconds: 1));
        expect(disconnected, isFalse);
        expect(controller.snapshot?.stage, isNot(CgmSyncStage.ready));
        expect(store.getString('openHealth.lastSensor'), isNull);
        await controller.ensureFreshData(force: true);
        expect(driver.connectedSensors, hasLength(1));
        closeRelease.complete();
        await disconnect.timeout(const Duration(seconds: 1));
        expect(session.disconnectCalls, 1);
        expect(controller.sensorConnectionCleanupUnconfirmed, cleanupFails);
        if (cleanupFails) {
          expect(controller.snapshot?.lastError, 'libre2.cleanupUnconfirmed');
          expect(controller.archivedSensors, isEmpty);
          await controller.connect(sensor, allowSessionActivation: false);
        } else {
          expect(controller.snapshot, isNull);
          expect(controller.archivedSensors, isEmpty);
        }
        await controller.ensureFreshData(force: true);
        expect(driver.connectedSensors, hasLength(1));
        expect(store.getString('openHealth.lastSensor'), isNull);
      },
    );
  }

  for (final outcome in ['timeout', 'throws']) {
    test(
      'unresolved driver $outcome retains cleanup authority after Disconnect',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'synthetic-unresolved-connect',
        );
        final reading = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        );
        final savedSelection = jsonEncode(sensor.toJson());
        final savedHistory = jsonEncode([reading.toJson()]);
        final store = _ControllableHealthStateStore(
          initialValues: {
            'openHealth.lastSensor': savedSelection,
            _historyStateKey(sensor): savedHistory,
          },
        );
        final started = Completer<void>();
        final release = Completer<void>();
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready),
        );
        final driver = _ControlledDriver(
          [session],
          driverId: sensor.driverId,
          connectStarted: started,
          connectGate: release.future,
        );
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
          pendingConnectionCleanupTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await _drainEventQueue();
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        final connect = controller.connect(
          sensor,
          allowSessionActivation: false,
        );
        await started.future.timeout(const Duration(seconds: 1));
        final disconnect = controller.disconnect();
        if (outcome == 'throws') {
          release.completeError(StateError('synthetic connect failure'));
        }
        await disconnect.timeout(const Duration(seconds: 1));
        expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
        expect(controller.snapshot?.lastError, 'libre2.cleanupUnconfirmed');
        expect(controller.snapshot?.history.map((value) => value.toJson()), [
          reading.toJson(),
        ]);
        expect(controller.archivedSensors, isEmpty);
        expect(store.getString('openHealth.lastSensor'), savedSelection);
        expect(store.getString(_historyStateKey(sensor)), savedHistory);
        expect(session.disconnectCalls, 0);
        await controller.connect(sensor, allowSessionActivation: false);
        expect(driver.connectedSensors, hasLength(1));
        if (outcome == 'timeout') release.complete();
        await connect.timeout(const Duration(seconds: 1));
        await _drainEventQueue();
        expect(session.disconnectCalls, outcome == 'timeout' ? 1 : 0);
        expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
        expect(controller.snapshot?.stage, CgmSyncStage.error);
        expect(controller.archivedSensors, isEmpty);
        expect(store.getString('openHealth.lastSensor'), savedSelection);
        await controller.ensureFreshData(force: true);
        expect(driver.connectedSensors, hasLength(1));
      },
    );
  }

  test(
    'explicit disconnect cancels reconnect during its old-session close',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final closeStarted = Completer<void>();
      final closeRelease = Completer<void>();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready),
        disconnectStarted: closeStarted,
        disconnectGate: closeRelease.future,
      );
      final driver = _ControlledDriver([session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      addTearDown(() async {
        if (!closeRelease.isCompleted) closeRelease.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor);
      final reconnect = controller.retryConnection();
      await closeStarted.future.timeout(const Duration(seconds: 1));
      final disconnect = controller.disconnect();
      closeRelease.complete();
      await reconnect.timeout(const Duration(seconds: 1));
      await disconnect.timeout(const Duration(seconds: 1));
      expect(controller.snapshot, isNull);
      expect(driver.connectedSensors, hasLength(1));
      expect(session.disconnectCalls, 1);
      expect(controller.archivedSensors, hasLength(1));
      await controller.ensureFreshData(force: true);
      expect(driver.connectedSensors, hasLength(1));
    },
  );

  testWidgets('Current sensor Disconnect ends the inline connection intent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore();
    final sensor = _multiDriverSensor(
      driverId: 'libre2-gen1',
      storageKey: 'libre2-gen1:synthetic-inline-disconnect',
    );
    final session = _ControlledSession(
      _testSnapshot(
        sensor,
        stage: CgmSyncStage.connecting,
        metadata: {'cgm.libre2.phase': 'awaitingAdvertisement'},
      ),
    );
    final driver = _ScannableControlledDriver(sensor, session);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );
    await controller.initialize();
    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(
          preferences: preferences,
          writesAllowed: false,
        )..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connectSensorButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connectButton-1')));
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Looking for your Libre 2 sensor'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('Current sensor'));
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final button = find.byKey(const ValueKey('disconnectSensorButton'));
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(session.disconnectCalls, 1);
    expect(controller.archivedSensors, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.pageBack();
    for (var index = 0; index < 20; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.snapshot, isNull);
    expect(controller.archivedSensors, isEmpty);
    expect(find.byKey(const ValueKey('connectSensorButton')), findsOneWidget);
    expect(find.byKey(const ValueKey('sensorConnectionScreen')), findsNothing);
    expect(driver.connectedSensors, hasLength(1));
    expect(driver.scanCalls, 1);
    await tester.pump(const Duration(seconds: 46));
    expect(driver.connectedSensors, hasLength(1));
    expect(driver.scanCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await driver.close();
  });

  for (final clearSelection in [false, true]) {
    test(
      'disconnect retains final closed-session history (clear=$clearSelection)',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _ControllableHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'libre2-gen1:synthetic-final-history',
        );
        final original = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        ).copyWith(isDisplayProvisional: true);
        final duplicate = original.copyWith(
          valueMgdl: 105,
          recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
        );
        final finalReading = original.copyWith(
          sensorMinute: 101,
          valueMgdl: 101,
          recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
        );
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [original]),
          snapshotOnDisconnect: _testSnapshot(
            sensor,
            stage: CgmSyncStage.disconnected,
            history: [duplicate, finalReading],
          ),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        await controller.connect(sensor, allowSessionActivation: false);
        await controller.disconnect(clearSelection: clearSelection);
        final retained = clearSelection
            ? controller.readingsForArchivedSensor(
                controller.archivedSensors.single,
              )
            : controller.snapshot!.history;
        expect(retained.map((item) => item.toJson()), [
          original.toJson(),
          finalReading.toJson(),
        ]);
        if (!clearSelection) {
          expect(jsonDecode(store.getString(_historyStateKey(sensor))!), [
            original.toJson(),
            finalReading.toJson(),
          ]);
          expect(controller.snapshot?.latestReading, isNull);
        }
      },
    );
  }

  test(
    'reconnect flushes a pending post-promotion reading before reload',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-debounced-history',
      );
      final original = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      ).copyWith(isDisplayProvisional: true);
      final next = original.copyWith(
        sensorMinute: 101,
        valueMgdl: 101,
        recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [original],
          verifiedLibreReception: true,
        ),
      );
      final replacement = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver([
        session,
        replacement,
      ], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [original, next],
          verifiedLibreReception: true,
        ),
      );
      expect(
        jsonDecode(store.getString(_historyStateKey(sensor))!) as List,
        hasLength(1),
      );
      await controller.connect(sensor, allowSessionActivation: false);
      expect(controller.snapshot!.history.map((item) => item.toJson()), [
        original.toJson(),
        next.toJson(),
      ]);
      expect(jsonDecode(store.getString(_historyStateKey(sensor))!), [
        original.toJson(),
        next.toJson(),
      ]);
    },
  );

  test(
    'ordinary history flush retains memory and blocks reconnect until saved',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'synthetic-flush-failure',
      );
      final original = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      ).copyWith(isDisplayProvisional: true);
      final next = original.copyWith(
        sensorMinute: 101,
        valueMgdl: 101,
        recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [original]),
      );
      final replacement = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver([
        session,
        replacement,
      ], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [original, next],
        ),
      );
      store.failSetPrefix = _historyStateKey(sensor);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(1));
      expect(controller.snapshot!.history.map((item) => item.toJson()), [
        original.toJson(),
        next.toJson(),
      ]);
      expect(controller.lastError, contains('Saving history failed'));
      expect(controller.archivedSensors, isEmpty);
      expect(store.removeAttempts, isEmpty);
      store.failSetPrefix = null;
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(2));
      expect(controller.snapshot!.history.map((item) => item.toJson()), [
        original.toJson(),
        next.toJson(),
      ]);
      expect(jsonDecode(store.getString(_historyStateKey(sensor))!), [
        original.toJson(),
        next.toJson(),
      ]);
    },
  );

  test(
    'ordinary cache clear resets a failed flush before reconnect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'synthetic-clear-after-flush-failure',
      );
      final reading = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
      );
      final replacement = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver([
        session,
        replacement,
      ], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      store.failSetPrefix = _historyStateKey(sensor);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(1));
      expect(controller.lastError, contains('Saving history failed'));
      store.failSetPrefix = null;
      expect(await controller.clearPersistedHistory(), isTrue);
      expect(store.getString(_historyStateKey(sensor)), isNull);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(2));
      expect(controller.snapshot!.history, isEmpty);
      expect(store.getString(_historyStateKey(sensor)), isNull);
    },
  );

  test(
    'disconnect waits for an older in-flight history write before final flush',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _GatedHistoryHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-ordered-writes',
      );
      final original = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      ).copyWith(isDisplayProvisional: true);
      final second = original.copyWith(
        sensorMinute: 101,
        recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
      );
      final finalReading = original.copyWith(
        sensorMinute: 102,
        recordedAt: original.recordedAt!.add(const Duration(minutes: 2)),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [original]),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      store.gateNextHistoryWrite = true;
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [original, second],
        ),
      );
      await store.started.future.timeout(const Duration(seconds: 2));
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [original, second, finalReading],
        ),
      );
      var completed = false;
      final disconnect = controller.disconnect(clearSelection: false).then((_) {
        completed = true;
      });
      await _drainEventQueue();
      expect(completed, isFalse);
      store.release.complete();
      await disconnect.timeout(const Duration(seconds: 1));
      expect(jsonDecode(store.getString(_historyStateKey(sensor))!), [
        original.toJson(),
        second.toJson(),
        finalReading.toJson(),
      ]);
    },
  );

  for (final clearSelection in [false, true]) {
    test(
      'ordinary history deletion waits for queued writes (clear=$clearSelection)',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _GatedHistoryHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'controlled',
          storageKey: 'synthetic-queued-deletion',
        );
        final original = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        ).copyWith(isDisplayProvisional: true);
        final next = original.copyWith(
          sensorMinute: 101,
          recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
        );
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [original]),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          if (!store.release.isCompleted) store.release.complete();
          await _drainEventQueue();
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        await controller.connect(sensor, allowSessionActivation: false);
        store.gateNextHistoryWrite = true;
        session.emit(
          _testSnapshot(
            sensor,
            stage: CgmSyncStage.ready,
            history: [original, next],
          ),
        );
        await store.started.future.timeout(const Duration(seconds: 2));
        var completed = false;
        final deletion =
            (clearSelection
                    ? controller.disconnect(archiveWhenClearing: false)
                    : controller.clearPersistedHistory().then((cleared) {
                        expect(cleared, isTrue);
                      }))
                .then((_) => completed = true);
        await _drainEventQueue();
        expect(completed, isFalse);
        expect(store.removeAttempts, isNot(contains(_historyStateKey(sensor))));
        store.release.complete();
        await deletion.timeout(const Duration(seconds: 1));
        await _drainEventQueue();
        expect(store.getString(_historyStateKey(sensor)), isNull);
        expect(controller.archivedSensors, isEmpty);
        expect(
          store.getString('openHealth.lastSensor'),
          clearSelection ? isNull : isNotNull,
        );
      },
    );
  }

  for (final mismatch in ['driver', 'device', 'storage']) {
    test(
      'uncertain cleanup rejects final history with wrong $mismatch',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _ControllableHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'synthetic-uncertain-target',
        );
        final foreign = DiscoveredSensor(
          driverId: mismatch == 'driver' ? 'other' : sensor.driverId,
          deviceId: mismatch == 'device' ? 'other-device' : sensor.deviceId,
          storageKey: mismatch == 'storage'
              ? 'other-storage'
              : sensor.storageKey,
          displayName: 'Other synthetic sensor',
          rssi: -42,
          capabilities: sensor.capabilities,
        );
        final reading = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        );
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
          snapshotOnDisconnect: _testSnapshot(
            foreign,
            stage: CgmSyncStage.error,
            history: [reading.copyWith(sensorMinute: 101)],
          ),
          disconnectError: const LibreGen1LiveException(
            LibreGen1LiveFailure.cleanupUnconfirmed,
          ),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        await controller.connect(sensor, allowSessionActivation: false);
        await controller.disconnect();
        expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
        expect(controller.snapshot?.lastError, 'libre2.cleanupUnconfirmed');
        expect(controller.snapshot!.sensor, sensor);
        expect(controller.snapshot!.history.map((item) => item.toJson()), [
          reading.toJson(),
        ]);
        expect(jsonDecode(store.getString(_historyStateKey(sensor))!), [
          reading.toJson(),
        ]);
        expect(controller.archivedSensors, isEmpty);
        expect(store.removeAttempts, isEmpty);
      },
    );

    test(
      'disconnect does not merge final history with wrong $mismatch',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'libre2-gen1:synthetic-target',
        );
        final foreign = DiscoveredSensor(
          driverId: mismatch == 'driver' ? 'other' : sensor.driverId,
          deviceId: mismatch == 'device' ? 'other-device' : sensor.deviceId,
          storageKey: mismatch == 'storage'
              ? 'other-storage'
              : sensor.storageKey,
          displayName: 'Other synthetic sensor',
          rssi: -42,
          capabilities: sensor.capabilities,
        );
        final reading = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        );
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
          snapshotOnDisconnect: _testSnapshot(
            foreign,
            stage: CgmSyncStage.disconnected,
            history: [reading.copyWith(sensorMinute: 101)],
          ),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: _ControllableHealthStateStore(),
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        await controller.connect(sensor, allowSessionActivation: false);
        await controller.disconnect();
        expect(
          controller
              .readingsForArchivedSensor(controller.archivedSensors.single)
              .map((item) => item.toJson()),
          [reading.toJson()],
        );
      },
    );
  }

  test(
    'elapsed-only nominal expiry does not retire the selected receiver',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-elapsed-only',
      );
      final reading = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 9, 8),
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [reading],
          sessionInfo: const CgmSessionInfo(
            elapsedMinutes: 20160,
            expectedLifetimeMinutes: 20160,
          ),
          verifiedLibreReception: true,
        ),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(controller.snapshot, isNotNull);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      expect(store.removeAttempts, isEmpty);
    },
  );

  for (final stopped in [false, true]) {
    test(
      'reported terminal lifecycle still archives (stopped=$stopped)',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final store = _ControllableHealthStateStore();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'libre2-gen1:synthetic-reported-terminal',
        );
        final reading = _reading(
          valueMgdl: 100,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 9, 9, 8),
        );
        final session = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [reading]),
        );
        final driver = _ControlledDriver([session], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });
        await controller.initialize();
        await controller.connect(sensor, allowSessionActivation: false);
        session.emit(
          _testSnapshot(
            sensor,
            stage: CgmSyncStage.ready,
            history: [reading],
            sessionInfo: CgmSessionInfo(sessionStopped: stopped),
          ).copyWith(health: CgmHealthSnapshot(expired: !stopped)),
        );
        await _drainEventQueue();
        expect(controller.snapshot, isNull);
        expect(
          controller.archivedSensors.single.reason,
          SensorArchiveReason.expired,
        );
        expect(
          controller
              .readingsForArchivedSensor(controller.archivedSensors.single)
              .map((item) => item.toJson()),
          [reading.toJson()],
        );
        expect(store.getString('openHealth.lastSensor'), isNull);
      },
    );
  }

  test(
    'unconfirmed Libre disconnect retains state and blocks new connections',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-cleanup',
      );
      final reading = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.now(),
      ).copyWith(isDisplayProvisional: true);
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [reading],
          verifiedLibreReception: true,
        ),
        disconnectError: const LibreGen1LiveException(
          LibreGen1LiveFailure.cleanupUnconfirmed,
        ),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      await controller.disconnect();
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(controller.snapshot?.lastError, 'libre2.cleanupUnconfirmed');
      expect(controller.snapshot?.history, [reading]);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      await controller.connect(sensor);
      await controller.disconnect();
      expect(driver.connectedSensors, hasLength(1));
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(controller.snapshot?.stage, CgmSyncStage.error);
      controller.dispose();
      await driver.close();
      await _drainEventQueue();
    },
  );

  test(
    'unconfirmed Libre cleanup waits for pending selection promotion',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _GatedSelectionHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-pending-promotion',
      );
      final reading = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.utc(2026, 9, 6, 8),
      ).copyWith(isDisplayProvisional: true);
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [reading],
          verifiedLibreReception: true,
        ),
        disconnectError: const LibreGen1LiveException(
          LibreGen1LiveFailure.cleanupUnconfirmed,
        ),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      // Keep the first connect in-flight so the gated selection write can pause
      // mid-promotion; awaiting it here would deadlock on store.release.
      final connect = controller.connect(sensor, allowSessionActivation: false);
      await store.started.future.timeout(const Duration(seconds: 1));
      expect(store.getString('openHealth.lastSensor'), isNull);
      var disconnectCompleted = false;
      final disconnect = controller.disconnect().then((_) {
        disconnectCompleted = true;
      });
      await _drainEventQueue();
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(disconnectCompleted, isFalse);
      await controller.connect(sensor, allowSessionActivation: false);
      expect(driver.connectedSensors, hasLength(1));

      // The final privacy-clear path must run after this promotion settles.
      // Platform channel calls are no-ops in host tests, so this test verifies
      // the awaited boundary rather than claiming native background evidence.
      store.release.complete();
      await disconnect.timeout(const Duration(seconds: 1));
      await connect.timeout(const Duration(seconds: 1));
      expect(disconnectCompleted, isTrue);
      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(controller.snapshot?.lastError, 'libre2.cleanupUnconfirmed');
      expect(controller.snapshot?.history, [reading]);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      expect(store.removeAttempts, isNot(contains('openHealth.lastSensor')));
      await controller.chooseAnotherSensor();
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      expect(driver.connectedSensors, hasLength(1));
    },
  );

  test(
    'provisional live history stays local and retains quality after restore',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'libre2-gen1:synthetic-receiver',
      );
      final readings = List.generate(
        3,
        (index) => CgmReading(
          valueMgdl: 100.0 + index,
          source: CgmRecordSource.vendor,
          sensorMinute: 100 + index,
          recordedAt: DateTime.utc(2026, 9, 6, 8, index),
          isDisplayProvisional: true,
        ),
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: readings,
          metadata: {'cgm.libre2.phase': 'glucoseReady'},
        ),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(controller.visibleHistory, hasLength(3));
      expect(controller.allHistoricalReadings, isEmpty);
      await controller.disconnect(clearSelection: false);
      final stored =
          jsonDecode(store.getString(_historyStateKey(sensor))!) as List;
      expect(stored, hasLength(3));
      expect(
        stored
            .map((row) => Map<String, Object?>.from(row as Map))
            .every((row) => row['isDisplayProvisional'] == true),
        isTrue,
      );
      controller.dispose();
      await driver.close();

      final restoredDriver = _ControlledDriver([
        _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.connecting),
        ),
      ], driverId: sensor.driverId);
      final restored = CgmAppController(
        preferences: preferences,
        driver: restoredDriver,
        healthStateStore: store,
      );
      await restored.initialize();
      expect(restored.snapshot?.sessionInfo.sessionStart, isNull);
      await restored.connect(sensor, allowSessionActivation: false);
      expect(restored.visibleHistory, hasLength(3));
      expect(
        restored.visibleHistory.every(
          (reading) => reading.isDisplayProvisional,
        ),
        isTrue,
      );
      expect(
        restored.visibleHistory.map((reading) => reading.recordedAt),
        readings.map((reading) => reading.recordedAt),
      );
      expect(restored.allHistoricalReadings, isEmpty);
      await restored.disconnect(clearSelection: true);
      final archive = restored.archivedSensors.single;
      expect(archive.startedAt, isNull);
      expect(restored.readingsForArchivedSensor(archive), hasLength(3));
      expect(
        restored
            .readingsForArchivedSensor(archive)
            .every((reading) => reading.isDisplayProvisional),
        isTrue,
      );
      expect(restored.allHistoricalReadings, isEmpty);
      restored.dispose();
      await restoredDriver.close();
    },
  );

  for (final scenario in <({String name, int sensorMinute, Duration age})>[
    (
      name: 'recent receipt and old sensor counter',
      sensorMinute: 15 * 24 * 60 - 1,
      age: const Duration(minutes: 2),
    ),
    (
      name: 'old receipt and recent sensor counter',
      sensorMinute: 100,
      age: const Duration(days: 20),
    ),
    (
      name: 'recent receipt and recent sensor counter',
      sensorMinute: 100,
      age: const Duration(minutes: 2),
    ),
  ]) {
    test(
      'Libre restore retains ${scenario.name} without inferred expiry',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'synthetic-unknown-lifecycle',
        );
        final reading = _reading(
          valueMgdl: 100,
          sensorMinute: scenario.sensorMinute,
          recordedAt: DateTime.now().toUtc().subtract(scenario.age),
        ).copyWith(isDisplayProvisional: true);
        final store = _ControllableHealthStateStore(
          initialValues: {
            'openHealth.lastSensor': jsonEncode(sensor.toJson()),
            _historyStateKey(sensor): jsonEncode([reading.toJson()]),
          },
        );
        final driver = _ControlledDriver([], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });

        await controller.initialize();

        expect(controller.snapshot?.stage, CgmSyncStage.connecting);
        expect(controller.snapshot?.sessionInfo.sessionStart, isNull);
        expect(controller.snapshot?.sessionInfo.elapsedMinutes, isNull);
        expect(
          computeSensorLifecycle(controller.snapshot!).phase,
          SensorLifecyclePhase.unknown,
        );
        expect(controller.visibleHistory.map((item) => item.toJson()), [
          reading.toJson(),
        ]);
        expect(controller.archivedSensors, isEmpty);
        expect(store.getString('openHealth.lastSensor'), isNotNull);
        expect(store.removeAttempts, isEmpty);
        expect(controller.allHistoricalReadings, isEmpty);
      },
    );
  }

  test(
    'Libre reconnect preserves the first receipt of a retained minute',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-repeated-minute',
      );
      final original = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      ).copyWith(isDisplayProvisional: true);
      final duplicate = original.copyWith(
        valueMgdl: 101,
        recordedAt: original.recordedAt!.add(const Duration(seconds: 30)),
      );
      final next = original.copyWith(
        valueMgdl: 102,
        sensorMinute: 101,
        recordedAt: original.recordedAt!.add(const Duration(minutes: 1)),
      );
      final store = _ControllableHealthStateStore(
        initialValues: {
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          _historyStateKey(sensor): jsonEncode([original.toJson()]),
        },
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [duplicate, next],
        ),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });

      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(controller.visibleHistory.map((item) => item.toJson()), [
        original.toJson(),
        next.toJson(),
      ]);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: [duplicate, next],
        ),
      );
      expect(controller.visibleHistory.map((item) => item.toJson()), [
        original.toJson(),
        next.toJson(),
      ]);
      await controller.disconnect(clearSelection: false);
      final stored =
          jsonDecode(store.getString(_historyStateKey(sensor))!) as List;
      expect(stored, [original.toJson(), next.toJson()]);
      expect(controller.allHistoricalReadings, isEmpty);
    },
  );

  test(
    'Libre duplicate latest does not renew retained reading freshness',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-current-duplicate',
      );
      final reference = DateTime.now().toUtc();
      final original = _reading(
        valueMgdl: 100,
        sensorMinute: 100,
        recordedAt: reference.subtract(const Duration(minutes: 20)),
      ).copyWith(isDisplayProvisional: true);
      final duplicate = original.copyWith(
        valueMgdl: 105,
        recordedAt: reference,
      );
      CgmSessionSnapshot snapshot(CgmReading? reading, CgmSyncStage stage) =>
          CgmSessionSnapshot(
            stage: stage,
            statusText: stage.name,
            sensor: sensor,
            capabilities: sensor.capabilities,
            latestReading: reading,
            history: [if (reading != null) reading],
            metadata: {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
          );
      final store = _ControllableHealthStateStore(
        initialValues: {
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          _historyStateKey(sensor): jsonEncode([original.toJson()]),
        },
      );
      final session = _ControlledSession(
        snapshot(duplicate, CgmSyncStage.ready),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });

      await controller.initialize();
      expect(controller.latestReading, isNull);
      expect(controller.displayLatestReading, isNull);
      await controller.connect(sensor, allowSessionActivation: false);
      await _drainEventQueue();
      expect(controller.snapshot?.latestReading?.toJson(), original.toJson());
      expect(controller.latestReading?.toJson(), original.toJson());
      expect(controller.displayLatestReading?.toJson(), original.toJson());
      expect(
        reference.difference(controller.latestReading!.recordedAt!),
        const Duration(minutes: 20),
      );
      session.emit(snapshot(duplicate, CgmSyncStage.ready));
      expect(controller.latestReading?.toJson(), original.toJson());

      for (final state in [
        snapshot(null, CgmSyncStage.ready),
        snapshot(
          duplicate.copyWith(source: CgmRecordSource.raw),
          CgmSyncStage.ready,
        ),
        snapshot(duplicate.copyWith(valueMgdl: -1), CgmSyncStage.ready),
        snapshot(duplicate, CgmSyncStage.syncing),
        snapshot(duplicate, CgmSyncStage.disconnected),
        snapshot(duplicate, CgmSyncStage.error),
      ]) {
        session.emit(state);
        expect(controller.snapshot?.latestReading, isNull);
        expect(controller.latestReading, isNull);
        expect(controller.displayLatestReading, isNull);
        expect(controller.snapshot!.history.first.toJson(), original.toJson());
      }
      await controller.disconnect(clearSelection: false);
    },
  );

  test(
    'invalid retained Libre history blocks restore without rewriting data',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-invalid-retained',
      );
      final invalid = _reading(
        valueMgdl: -1,
        sensorMinute: 100,
        recordedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ).copyWith(isDisplayProvisional: true);
      final incoming = invalid.copyWith(
        valueMgdl: 100,
        recordedAt: DateTime.now(),
      );
      final store = _ControllableHealthStateStore(
        initialValues: {
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          _historyStateKey(sensor): jsonEncode([invalid.toJson()]),
        },
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.ready, history: [incoming]),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await expectLater(controller.initialize(), throwsStateError);
      expect(driver.connectedSensors, isEmpty);
      expect(
        store.getString(_historyStateKey(sensor)),
        jsonEncode([invalid.toJson()]),
      );
      expect(
        store.getString('openHealth.lastSensor'),
        jsonEncode(sensor.toJson()),
      );
      expect(store.removeAttempts, isEmpty);
    },
  );

  test(
    'live-notification glucose consent stays explicit and reversible',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ProductionTestDriver(),
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();

      expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
      expect(
        await controller.updateSensitiveLiveActivityContent(enabled: true),
        isTrue,
      );
      expect(controller.sensitiveLiveActivityContentEnabled, isTrue);
      expect(
        await controller.updateSensitiveLiveActivityContent(enabled: false),
        isTrue,
      );
      expect(controller.sensitiveLiveActivityContentEnabled, isFalse);

      controller.dispose();
    },
  );

  test('failed live-notification publish rolls consent back closed', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final nativeWrites = <bool>[];
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        nativeWrites.add(enabled);
      },
      liveActivityPrivacyRefresh: () async {
        throw StateError('simulated publish failure');
      },
    );

    await controller.initialize();

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isFalse,
    );
    expect(nativeWrites, <bool>[true, false]);
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
    expect(controller.liveActivityPrivacyUpdateInFlight, isFalse);
    expect(controller.lastError, contains('Updating lock-screen privacy'));

    controller.dispose();
  });

  test('failed redacted refresh keeps withdrawn consent disabled', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final nativeWrites = <bool>[];
    var failRefresh = false;
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        nativeWrites.add(enabled);
      },
      liveActivityPrivacyRefresh: () async {
        if (failRefresh) {
          throw StateError('simulated redacted refresh failure');
        }
      },
    );

    await controller.initialize();
    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isTrue,
    );
    failRefresh = true;

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: false),
      isFalse,
    );
    expect(nativeWrites, <bool>[true, false]);
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);

    controller.dispose();
  });

  test('failed native withdrawal still fails closed in Flutter', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    var nativeEnabled = false;
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: _ControllableHealthStateStore(),
      liveActivityPrivacySetter: ({required enabled}) async {
        if (!enabled) {
          throw StateError('simulated withdrawal persistence failure');
        }
        nativeEnabled = enabled;
      },
      liveActivityPrivacyRefresh: () async {},
    );

    await controller.initialize();
    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: true),
      isTrue,
    );
    expect(nativeEnabled, isTrue);
    expect(controller.sensitiveLiveActivityContentEnabled, isTrue);

    expect(
      await controller.updateSensitiveLiveActivityContent(enabled: false),
      isFalse,
    );
    expect(controller.sensitiveLiveActivityContentEnabled, isFalse);
    expect(controller.liveActivityPrivacyUpdateInFlight, isFalse);

    controller.dispose();
  });

  test('does not persist an unverified sensor selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final store = _ControllableHealthStateStore();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );

    await controller.initialize();
    await controller.connect(sensor);
    await _drainEventQueue();

    expect(store.getString('openHealth.lastSensor'), isNull);
    expect(
      driver
          .connectedSensors
          .single
          .metadata[cgmAllowSessionActivationMetadataKey],
      'true',
    );

    controller.dispose();
    await driver.close();
  });

  test(
    'terminal driver failure blocks reconnect after a ready selection',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final reading = _reading(
        valueMgdl: 101,
        sensorMinute: 45,
        recordedAt: DateTime.utc(2026, 1, 1, 0, 45),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final unusedReconnectSession = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[
        session,
        unusedReconnectSession,
      ]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
        reconnectDelay: Duration.zero,
      );

      await controller.initialize();
      await controller.connect(sensor);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[reading],
        ),
      );
      await _drainEventQueue();
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          history: <CgmReading>[reading],
          metadata: const <String, String>{
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
          },
          lastError: 'yuwell.session.writeOutcomeUnknown',
        ),
      );
      await _drainEventQueue();

      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(driver.connectedSensors, hasLength(1));

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'user-action BLE failure does not auto-retry or archive an unverified sensor',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
        reconnectDelay: Duration.zero,
      );
      final failure = BleFailure(
        kind: BleFailureKind.sensorPossiblyInUse,
        operation: BleOperation.bond,
        diagnosticCode: 'fbp.android.bond.busy',
      );

      await controller.initialize();
      await controller.connect(sensor);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          metadata: failure.toMetadata(),
          lastError: 'Bluetooth setup could not be completed.',
        ),
      );
      await _drainEventQueue();

      expect(controller.connectionRequiresUserAction, isTrue);
      expect(controller.lastError, contains('another phone'));
      expect(driver.connectedSensors, hasLength(1));

      await controller.chooseAnotherSensor();
      expect(controller.snapshot, isNull);
      expect(controller.archivedSensors, isEmpty);

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'terminal P02 snapshot survives forced freshness during listener attachment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final failure = BleFailure(
        kind: BleFailureKind.bondRejected,
        operation: BleOperation.bond,
        diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
      );
      final terminalSnapshot = _testSnapshot(
        sensor,
        stage: CgmSyncStage.error,
        metadata: <String, String>{
          aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
          ...failure.toMetadata(),
        },
        lastError: 'Bluetooth setup could not be completed.',
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
        snapshotOnSnapshotsAccess: terminalSnapshot,
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
        reconnectDelay: Duration.zero,
      );

      await controller.initialize();
      await controller
          .connect(sensor)
          .timeout(const Duration(milliseconds: 100));

      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(
        controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.bond,
      );
      expect(
        BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
        'aidex.bond.sensor-paired-os-unbonded',
      );
      expect(controller.connectionRequiresUserAction, isTrue);
      expect(controller.lastError, isNotNull);
      expect(driver.connectedSensors, hasLength(1));

      await controller.ensureFreshData(force: true);

      expect(controller.snapshot?.stage, CgmSyncStage.error);
      expect(
        controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
        AidexSetupPhase.bond,
      );
      expect(
        BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
        'aidex.bond.sensor-paired-os-unbonded',
      );
      expect(session.refreshLiveDataCalls, 0);
      expect(session.syncHistoryCalls, 0);

      controller.dispose();
      await driver.close();
    },
  );

  test('attached terminal P02 snapshot blocks forced freshness', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final failure = BleFailure(
      kind: BleFailureKind.bondRejected,
      operation: BleOperation.bond,
      diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
    );
    final terminalSnapshot = _testSnapshot(
      sensor,
      stage: CgmSyncStage.error,
      metadata: <String, String>{
        aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
        ...failure.toMetadata(),
      },
      lastError: 'Bluetooth setup could not be completed.',
    );
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(terminalSnapshot);
    await _drainEventQueue();
    await controller.ensureFreshData(force: true);

    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(
      controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
      AidexSetupPhase.bond,
    );
    expect(
      BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
      'aidex.bond.sensor-paired-os-unbonded',
    );
    expect(session.refreshLiveDataCalls, 0);
    expect(session.syncHistoryCalls, 0);

    controller.dispose();
    await driver.close();
  });

  test('refresh transition to P02 error cannot start history sync', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final failure = BleFailure(
      kind: BleFailureKind.bondRejected,
      operation: BleOperation.bond,
      diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
    );
    final terminalSnapshot = _testSnapshot(
      sensor,
      stage: CgmSyncStage.error,
      metadata: <String, String>{
        aidexSetupPhaseMetadataKey: AidexSetupPhase.bond,
        ...failure.toMetadata(),
      },
      lastError: 'Bluetooth setup could not be completed.',
    );
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.ready),
      snapshotOnRefreshLiveData: terminalSnapshot,
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );

    await controller.initialize();
    await controller.connect(sensor);
    await _drainEventQueue();
    await controller.ensureFreshData(force: true);

    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(
      controller.snapshot?.metadata[aidexSetupPhaseMetadataKey],
      AidexSetupPhase.bond,
    );
    expect(
      BleFailure.fromMetadata(controller.snapshot!.metadata)?.diagnosticCode,
      'aidex.bond.sensor-paired-os-unbonded',
    );
    expect(session.refreshLiveDataCalls, 1);
    expect(session.syncHistoryCalls, 0);

    await _drainEventQueue();
    controller.dispose();
    await driver.close();
  });

  for (final stage in [CgmSyncStage.error, CgmSyncStage.disconnected]) {
    test(
      'restored Libre $stage offers explicit saved-sensor recovery',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _multiDriverSensor(
          driverId: 'libre2-gen1',
          storageKey: 'synthetic-manual-recovery',
        );
        final store = _ControllableHealthStateStore(
          initialValues: {'openHealth.lastSensor': jsonEncode(sensor.toJson())},
        );
        final failed = _ControlledSession(
          _testSnapshot(
            sensor,
            stage: stage,
            lastError: 'libre2.advertisementUnavailable',
            metadata: {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
          ),
        );
        final retry = _ControlledSession(
          _testSnapshot(sensor, stage: CgmSyncStage.connecting),
        );
        final driver = _ControlledDriver([
          failed,
          retry,
        ], driverId: sensor.driverId);
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
          reconnectDelay: Duration.zero,
        );
        addTearDown(() async {
          controller.dispose();
          await driver.close();
        });

        await controller.initialize();
        expect(controller.connectionRequiresUserAction, isFalse);
        await controller.connect(sensor, allowSessionActivation: false);
        await _drainEventQueue();
        expect(controller.connectionRequiresUserAction, isTrue);
        expect(controller.sensorConnectionCleanupUnconfirmed, isFalse);
        expect(driver.connectedSensors, hasLength(1));
        await controller.retryConnection();
        expect(driver.connectedSensors, hasLength(2));
        expect(
          driver
              .connectedSensors
              .last
              .metadata[cgmAllowSessionActivationMetadataKey],
          'false',
        );
        expect(controller.connectionRequiresUserAction, isFalse);
        await controller.disconnect(clearSelection: false);
      },
    );
  }

  test(
    'Libre manual recovery requires terminal policy and known cleanup',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _multiDriverSensor(
        driverId: 'libre2-gen1',
        storageKey: 'synthetic-manual-policy',
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver([session], driverId: sensor.driverId);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      addTearDown(() async {
        controller.dispose();
        await driver.close();
      });
      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      for (final scenario in [
        (
          stage: CgmSyncStage.connecting,
          code: 'libre2.advertisementUnavailable',
          policy: 'false',
        ),
        (
          stage: CgmSyncStage.error,
          code: 'libre2.advertisementUnavailable',
          policy: 'true',
        ),
        (stage: CgmSyncStage.error, code: '', policy: 'false'),
        (
          stage: CgmSyncStage.error,
          code: 'libre2.cleanupUnconfirmed',
          policy: 'false',
        ),
      ]) {
        session.emit(
          _testSnapshot(
            sensor,
            stage: scenario.stage,
            lastError: scenario.code,
            metadata: {
              cgmAutomaticReconnectAllowedMetadataKey: scenario.policy,
            },
          ),
        );
        expect(controller.connectionRequiresUserAction, isFalse);
      }
      expect(controller.sensorConnectionCleanupUnconfirmed, isTrue);
      expect(driver.connectedSensors, hasLength(1));
    },
  );

  test('unclassified initial BLE setup failure does not auto-retry', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );
    await controller.initialize();
    await controller.connect(sensor);
    session.emit(
      _testSnapshot(
        sensor,
        stage: CgmSyncStage.error,
        lastError: 'initializing session failed (StateError)',
      ),
    );
    await _drainEventQueue();

    expect(controller.connectionRequiresUserAction, isFalse);
    expect(driver.connectedSensors, hasLength(1));

    controller.dispose();
    await driver.close();
  });

  testWidgets('unverified disconnect exposes manual BLE recovery actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );
    final failure = BleFailure(
      kind: BleFailureKind.deviceDisconnected,
      operation: BleOperation.connect,
      diagnosticCode: 'aidex.connection.disconnected',
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(
      _testSnapshot(
        sensor,
        stage: CgmSyncStage.disconnected,
        metadata: failure.toMetadata(),
        lastError: 'BLE connection lost',
      ),
    );

    expect(controller.connectionRequiresUserAction, isTrue);
    expect(driver.connectedSensors, hasLength(1));

    await tester.pumpWidget(
      OpenGlucoseApp(
        controller: controller,
        healthExport: HealthExportController(
          preferences: preferences,
          writesAllowed: false,
        )..initialize(),
        preferences: preferences,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('retryBleSetupButton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('chooseAnotherSensorButton')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await driver.close();
  });

  test('promotes a ready sensor to the durable selection', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final store = _ControllableHealthStateStore();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );

    await controller.initialize();
    await controller.connect(sensor);
    session.emit(_testSnapshot(sensor, stage: CgmSyncStage.ready));
    await _drainEventQueue();

    final persisted =
        jsonDecode(store.getString('openHealth.lastSensor')!)
            as Map<String, dynamic>;
    expect(persisted['storageKey'], sensor.storageKey);
    expect(
      persisted['metadata'],
      isNot(contains(cgmAllowSessionActivationMetadataKey)),
    );

    controller.dispose();
    await driver.close();
  });

  test(
    'activation-required state clears selection without creating an archive',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      final reading = _reading(
        valueMgdl: 118,
        sensorMinute: 15,
        recordedAt: DateTime.now(),
      );

      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.error,
          history: <CgmReading>[reading],
          metadata: const <String, String>{'activationRequired': 'true'},
        ),
      );
      await _drainEventQueue();

      expect(controller.snapshot, isNull);
      expect(controller.activationRequiredSensor, sensor);
      expect(controller.archivedSensors, isEmpty);
      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(store.getString('openHealth.sensorArchive'), isNull);
      expect(store.getString(_historyStateKey(sensor)), isNull);
      expect(
        store.setAttempts.where(
          (key) => key.startsWith('openHealth.history.archive.'),
        ),
        isEmpty,
      );

      await controller.chooseAnotherSensor();
      expect(controller.activationRequiredSensor, isNull);

      controller.dispose();
      await driver.close();
    },
  );

  for (final failure in <({String label, bool archiveWrite})>[
    (label: 'archive manifest write', archiveWrite: true),
    (label: 'active pointer removal', archiveWrite: false),
  ]) {
    test(
      '${failure.label} failure preserves a retryable disconnected selection',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final preferences = await SharedPreferences.getInstance();
        final sensor = _testSensor();
        final reading = _reading(
          valueMgdl: 121,
          sensorMinute: 30,
          recordedAt: DateTime.now(),
        );
        final session = _ControlledSession(
          _testSnapshot(
            sensor,
            stage: CgmSyncStage.ready,
            history: <CgmReading>[reading],
            sessionInfo: CgmSessionInfo(
              sessionStart: reading.recordedAt!.subtract(
                const Duration(minutes: 30),
              ),
            ),
          ),
        );
        final driver = _ControlledDriver(<_ControlledSession>[session]);
        final store = _ControllableHealthStateStore();
        final controller = CgmAppController(
          preferences: preferences,
          driver: driver,
          healthStateStore: store,
        );

        await controller.initialize();
        await controller.connect(sensor);
        await _drainEventQueue();
        expect(store.getString('openHealth.lastSensor'), isNotNull);

        if (failure.archiveWrite) {
          store.failSetPrefix = 'openHealth.sensorArchive';
        } else {
          store.failRemovePrefix = 'openHealth.lastSensor';
        }
        await controller.disconnect();

        expect(controller.snapshot?.stage, CgmSyncStage.disconnected);
        expect(
          controller.snapshot?.statusText,
          'Disconnected — could not archive sensor',
        );
        expect(store.getString('openHealth.lastSensor'), isNotNull);
        expect(controller.lastError, contains('Clearing the selected sensor'));

        store.failSetPrefix = null;
        store.failRemovePrefix = null;
        await controller.disconnect();

        expect(controller.snapshot, isNull);
        expect(store.getString('openHealth.lastSensor'), isNull);
        expect(controller.archivedSensors, hasLength(1));
        expect(
          controller.readingsForArchivedSensor(
            controller.archivedSensors.single,
          ),
          hasLength(1),
        );

        controller.dispose();
        await driver.close();
      },
    );
  }

  test(
    'active history dedupes rebased timestamps by source and sensor minute',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final now = DateTime.now();
      final persistedReading = _reading(
        valueMgdl: 111,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 5)),
      );
      final rebasedReading = _reading(
        valueMgdl: 124,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 4)),
      );
      final otherSourceReading = CgmReading(
        valueMgdl: 126,
        source: CgmRecordSource.broadcast,
        sensorMinute: 42,
        recordedAt: now.subtract(const Duration(minutes: 4)),
      );
      final session = _ControlledSession(
        _testSnapshot(sensor, stage: CgmSyncStage.connecting),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final store = _ControllableHealthStateStore();
      await store.setString(
        'openHealth.lastSensor',
        jsonEncode(sensor.toJson()),
      );
      await store.setString(
        _historyStateKey(sensor),
        jsonEncode(<Object?>[persistedReading.toJson()]),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(sensor, allowSessionActivation: false);
      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[rebasedReading, otherSourceReading],
        ),
      );
      await _drainEventQueue();

      final history = controller.snapshot!.history;
      expect(history, hasLength(2));
      final vendorReadings = history
          .where((reading) => reading.source == CgmRecordSource.vendor)
          .toList(growable: false);
      expect(vendorReadings, hasLength(1));
      expect(vendorReadings.single.valueMgdl, rebasedReading.valueMgdl);
      expect(vendorReadings.single.recordedAt, rebasedReading.recordedAt);
      expect(
        history.where((reading) => reading.source == CgmRecordSource.broadcast),
        hasLength(1),
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'minute 59 stays out of presentation at the minute 60 boundary',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final boundary = DateTime.now();
      final sessionStart = boundary.subtract(const Duration(minutes: 60));
      final minute59 = _reading(
        valueMgdl: 171,
        sensorMinute: 59,
        recordedAt: sessionStart.add(const Duration(minutes: 59)),
      );
      final minute60 = _reading(
        valueMgdl: 112,
        sensorMinute: 60,
        recordedAt: boundary,
      );
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[minute59],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();
      await controller.connect(sensor);
      await _drainEventQueue();

      expect(controller.latestReading?.sensorMinute, 59);
      expect(controller.displayLatestReading, isNull);
      final waitingContext = buildMessageContext(controller, now: boundary);
      expect(waitingContext.isWarmingUp, isFalse);
      expect(waitingContext.hasReadings, isFalse);

      session.emit(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[minute59, minute60],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      await _drainEventQueue();

      expect(controller.displayLatestReading?.sensorMinute, 60);
      expect(
        buildMessageContext(controller, now: boundary).hasReadings,
        isTrue,
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'active presentation history excludes the sensor warmup window',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor();
      final sessionStart = DateTime.now().subtract(const Duration(hours: 2));
      final history = <CgmReading>[
        for (final minute in <int>[0, 59, 60, 61])
          _reading(
            valueMgdl: 100 + minute.toDouble(),
            sensorMinute: minute,
            recordedAt: sessionStart.add(Duration(minutes: minute)),
          ),
      ];
      final session = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: history,
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();
      await controller.connect(sensor);
      await _drainEventQueue();

      expect(controller.snapshot!.history, hasLength(4));
      expect(
        controller.visibleHistory.map((reading) => reading.sensorMinute),
        <int?>[60, 61],
      );
      expect(
        controller.allHistoricalReadings.map((reading) => reading.sensorMinute),
        <int?>[60, 61],
      );

      controller.dispose();
      await driver.close();
    },
  );

  test(
    'same-id rearchive merges history and preserves session metadata',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final sensor = _testSensor(metadata: const <String, String>{});
      final sessionStart = DateTime.now().subtract(const Duration(days: 1));
      final firstReading = _reading(
        valueMgdl: 101,
        sensorMinute: 30,
        recordedAt: sessionStart.add(const Duration(minutes: 30)),
      );
      final secondReading = _reading(
        valueMgdl: 139,
        sensorMinute: 120,
        recordedAt: sessionStart.add(const Duration(minutes: 120)),
      );
      final firstSession = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[firstReading],
          sessionInfo: CgmSessionInfo(
            serial: 'SERIAL-ONE',
            model: 'MODEL-ONE',
            firmware: 'FW-ONE',
            sessionStart: sessionStart,
          ),
        ),
      );
      final secondSession = _ControlledSession(
        _testSnapshot(
          sensor,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[secondReading],
          sessionInfo: CgmSessionInfo(sessionStart: sessionStart),
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[
        firstSession,
        secondSession,
      ]);
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(sensor);
      await controller.disconnect(archiveReason: SensorArchiveReason.replaced);
      await controller.connect(sensor);
      await controller.disconnect();

      expect(controller.archivedSensors, hasLength(1));
      final archived = controller.archivedSensors.single;
      expect(archived.serial, 'SERIAL-ONE');
      expect(archived.model, 'MODEL-ONE');
      expect(archived.firmware, 'FW-ONE');
      expect(archived.reason, SensorArchiveReason.replaced);
      expect(archived.startedAt, sessionStart);
      expect(archived.readingCount, 2);
      expect(
        controller
            .readingsForArchivedSensor(archived)
            .map((reading) => reading.valueMgdl),
        <double>[101, 139],
      );
      expect(
        controller
            .displayReadingsForArchivedSensor(archived)
            .map((reading) => reading.valueMgdl),
        <double>[139],
      );
      expect(
        controller.allHistoricalReadings.map((reading) => reading.valueMgdl),
        <double>[139],
      );

      controller.dispose();
      await driver.close();
    },
  );

  test('surfaces a debounced history persistence failure', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failSetPrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    final sensor = controller.sensors.single;
    await controller.connect(sensor);

    await controller.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(controller.lastError, contains('Saving history failed'));
    expect(controller.lastError, contains('StateError'));
    expect(
      controller.logs.any(
        (entry) => entry.message.contains('Saving history failed'),
      ),
      isTrue,
    );

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test('does not report a failed history deletion as successful', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failRemovePrefix: 'openHealth.history.',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _ProductionTestDriver(),
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    final sensor = controller.sensors.single;
    await controller.connect(sensor);

    final cleared = await controller.clearPersistedHistory();

    expect(cleared, isFalse);
    expect(store.removeAttempts, contains(_historyStateKey(sensor)));
    expect(controller.lastError, contains('Clearing stored history failed'));

    await controller.disconnect(clearSelection: false);
    controller.dispose();
  });

  test(
    'a history write does not clear an unrelated deletion failure',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore(
        failRemovePrefix: 'openHealth.history.',
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ProductionTestDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(await controller.clearPersistedHistory(), isFalse);
      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(controller.lastError, contains('Clearing stored history failed'));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
    },
  );

  test(
    'disconnect still clears private state when BLE teardown fails',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _DisconnectFailingDriver(),
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(store.getString('openHealth.lastSensor'), isNotNull);

      await controller.disconnect();

      expect(store.getString('openHealth.lastSensor'), isNull);
      expect(controller.snapshot, isNull);
      expect(
        controller.lastError,
        contains('Disconnecting sensor session failed'),
      );
      expect(
        controller.logs.any(
          (entry) => entry.message.contains(
            'Disconnecting sensor session failed (StateError)',
          ),
        ),
        isTrue,
      );
      controller.dispose();
    },
  );

  test(
    'confirmed sensor transfer uses the capability then clears selection',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(CgmBondTransferScope.allLe),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);

      expect(controller.canMoveSensorToAnotherPhone, isTrue);
      final plan = await controller.inspectSensorTransfer();
      expect(plan.removesAllLeBonds, isTrue);
      expect(driver.session!.inspectCalls, 1);

      await controller.moveSensorToAnotherPhone(plan);

      expect(driver.session!.executeCalls, 1);
      expect(driver.session!.normalDisconnectCalls, 1);
      expect(controller.snapshot, isNull);
      expect(controller.canMoveSensorToAnotherPhone, isFalse);
      controller.dispose();
    },
  );

  test(
    'unknown sensor transfer outcome stays selected and is privacy safe',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
        executeFailure: const CgmBondTransferException(
          CgmBondTransferFailureKind.sensorResponseUnknown,
          outcome: CgmBondTransferOutcome.unknown,
        ),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: _ControllableHealthStateStore(),
      );
      await controller.initialize();
      await controller.scan();
      await controller.connect(controller.sensors.single);
      final plan = await controller.inspectSensorTransfer();

      await expectLater(
        controller.moveSensorToAnotherPhone(plan),
        throwsA(isA<CgmBondTransferException>()),
      );

      expect(driver.session!.executeCalls, 1);
      expect(driver.session!.normalDisconnectCalls, 0);
      expect(controller.snapshot, isNotNull);
      expect(controller.lastError, contains('Do not retry'));
      expect(controller.lastError, isNot(contains('device-id-private')));
      await controller.disconnect();
      controller.dispose();
    },
  );

  test('transfer state must persist before the driver can write', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final store = _ControllableHealthStateStore(
      failSetPrefix: 'openHealth.bondTransfer.',
    );
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: store,
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);
    final plan = await controller.inspectSensorTransfer();

    await expectLater(
      controller.moveSensorToAnotherPhone(plan),
      throwsA(
        isA<CgmBondTransferException>()
            .having(
              (failure) => failure.kind,
              'kind',
              CgmBondTransferFailureKind.statePersistenceFailed,
            )
            .having(
              (failure) => failure.outcome,
              'outcome',
              CgmBondTransferOutcome.notStarted,
            ),
      ),
    );

    expect(driver.session!.executeCalls, 0);
    expect(controller.snapshot, isNotNull);
    expect(controller.lastError, contains('Do not retry'));
    await controller.disconnect();
    controller.dispose();
  });

  test(
    'accepted transfer tombstone blocks reconnect after process death',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = _ControllableHealthStateStore();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
        executeFailureAfterAccepted: const CgmBondTransferException(
          CgmBondTransferFailureKind.disconnectUnconfirmed,
          outcome: CgmBondTransferOutcome.sensorAccepted,
        ),
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final sensor = controller.sensors.single;
      await controller.connect(sensor);
      await _drainEventQueue();
      final plan = await controller.inspectSensorTransfer();

      await expectLater(
        controller.moveSensorToAnotherPhone(plan),
        throwsA(isA<CgmBondTransferException>()),
      );

      final tombstoneKey = _bondTransferStateKey(sensor);
      expect(store.getString(tombstoneKey), 'sensor-accepted');
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      controller.dispose();

      final restoredDriver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final restored = CgmAppController(
        preferences: preferences,
        driver: restoredDriver,
        healthStateStore: store,
        reconnectDelay: Duration.zero,
      );
      await restored.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(restoredDriver.connectCalls, 0);
      expect(restored.snapshot?.stage, CgmSyncStage.error);
      expect(
        restored.snapshot?.metadata[cgmBondTransferStateMetadataKey],
        'sensor-accepted',
      );
      expect(restored.lastError, contains('Do not retry'));

      await restored.disconnect();
      expect(store.getString(tombstoneKey), 'sensor-accepted');
      expect(restored.snapshot, isNotNull);

      await restored.acknowledgeInterruptedSelectedSensorTransfer();
      expect(store.getString(tombstoneKey), isNull);
      expect(restored.snapshot, isNull);
      restored.dispose();
    },
  );

  test('normal disconnect cannot interrupt an executing transfer', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final started = Completer<void>();
    final release = Completer<void>();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.allLe),
      executeStarted: started,
      executeRelease: release,
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);
    final plan = await controller.inspectSensorTransfer();

    final transfer = controller.moveSensorToAnotherPhone(plan);
    await started.future;
    expect(controller.bondTransferInFlight, isTrue);

    await controller.disconnect();

    expect(driver.session!.normalDisconnectCalls, 0);
    expect(controller.snapshot, isNotNull);
    release.complete();
    await transfer;

    expect(driver.session!.normalDisconnectCalls, 1);
    expect(controller.snapshot, isNull);
    controller.dispose();
  });

  test('transfer confirmation cannot target a replacement session', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    final sensor = controller.sensors.single;
    await controller.connect(sensor);
    final inspectedSession = driver.session!;
    final plan = await controller.inspectSensorTransfer();

    await controller.disconnect();
    await controller.connect(sensor);
    final replacementSession = driver.session!;
    expect(replacementSession, isNot(same(inspectedSession)));

    await expectLater(
      controller.moveSensorToAnotherPhone(plan),
      throwsA(
        isA<CgmBondTransferException>().having(
          (failure) => failure.kind,
          'kind',
          CgmBondTransferFailureKind.sessionNotReady,
        ),
      ),
    );

    expect(inspectedSession.executeCalls, 0);
    expect(replacementSession.executeCalls, 0);
    await controller.disconnect();
    controller.dispose();
  });

  test(
    'orphan unknown marker stays fail closed without a clear action',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = _bondTransferStateKey(sensor);
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{tombstoneKey: 'outcome-unknown'},
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final scannedSensor = controller.sensors.single;

      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isTrue);
      expect(
        controller.canAcknowledgeInterruptedSensorTransfer(scannedSensor),
        isFalse,
      );
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 0);

      await expectLater(
        controller.acknowledgeInterruptedSensorTransfer(scannedSensor),
        throwsA(
          isA<CgmBondTransferException>()
              .having(
                (failure) => failure.kind,
                'kind',
                CgmBondTransferFailureKind.sensorResponseUnknown,
              )
              .having(
                (failure) => failure.outcome,
                'outcome',
                CgmBondTransferOutcome.unknown,
              ),
        ),
      );

      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), 'outcome-unknown');
      controller.dispose();
    },
  );

  test(
    'unknown selected marker cannot use the accepted-state bypass',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = _bondTransferStateKey(sensor);
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(sensor.toJson()),
          tombstoneKey: 'outcome-unknown',
        },
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
        reconnectDelay: Duration.zero,
      );
      await controller.initialize();

      await controller.disconnect(acknowledgeInterruptedTransfer: true);

      expect(store.getString(tombstoneKey), 'outcome-unknown');
      expect(store.getString('openHealth.lastSensor'), isNotNull);
      expect(controller.snapshot, isNotNull);
      expect(controller.lastError, contains('Do not reconnect'));
      expect(driver.connectCalls, 0);
      await expectLater(
        controller.acknowledgeInterruptedSelectedSensorTransfer(),
        throwsA(
          isA<CgmBondTransferException>().having(
            (failure) => failure.kind,
            'kind',
            CgmBondTransferFailureKind.sensorResponseUnknown,
          ),
        ),
      );
      controller.dispose();
    },
  );

  test(
    'orphan accepted marker requires explicit local acknowledgment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final driver = _BondTransferDriver(
        plan: const CgmBondTransferPlan(
          CgmBondTransferScope.requestingDeviceLe,
        ),
      );
      final sensor = driver._delegate.scenarioSensor;
      final tombstoneKey = _bondTransferStateKey(sensor);
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{tombstoneKey: 'sensor-accepted'},
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );
      await controller.initialize();
      await controller.scan();
      final scannedSensor = controller.sensors.single;

      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isTrue);
      expect(
        controller.canAcknowledgeInterruptedSensorTransfer(scannedSensor),
        isTrue,
      );
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), 'sensor-accepted');

      await controller.acknowledgeInterruptedSensorTransfer(scannedSensor);

      expect(driver.connectCalls, 0);
      expect(store.getString(tombstoneKey), isNull);
      expect(controller.sensorHasInterruptedTransfer(scannedSensor), isFalse);
      await controller.connect(scannedSensor);
      expect(driver.connectCalls, 1);
      await controller.disconnect();
      controller.dispose();
    },
  );

  test('normal disconnect never invokes sensor bond transfer', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final driver = _BondTransferDriver(
      plan: const CgmBondTransferPlan(CgmBondTransferScope.requestingDeviceLe),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );
    await controller.initialize();
    await controller.scan();
    await controller.connect(controller.sensors.single);

    await controller.disconnect();

    expect(driver.session!.inspectCalls, 0);
    expect(driver.session!.executeCalls, 0);
    expect(driver.session!.normalDisconnectCalls, 1);
    controller.dispose();
  });

  test(
    'multi-driver scan keeps equal platform IDs distinct and routes connect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final alphaSensor = _multiDriverSensor(
        driverId: 'alpha',
        storageKey: 'alpha:shared-device',
      );
      final betaSensor = _multiDriverSensor(
        driverId: 'beta',
        storageKey: 'beta:shared-device',
      );
      final alphaSession = _ControlledSession(
        _testSnapshot(alphaSensor, stage: CgmSyncStage.ready),
      );
      final betaSession = _ControlledSession(
        _testSnapshot(betaSensor, stage: CgmSyncStage.ready),
      );
      final alphaDriver = _ControlledDriver(
        <_ControlledSession>[alphaSession],
        driverId: 'alpha',
      );
      final betaDriver = _ControlledDriver(
        <_ControlledSession>[betaSession],
        driverId: 'beta',
      );
      final registry = CgmDriverRegistry(
        transport: const _OneShotBleTransport(),
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: alphaDriver,
            scanServiceUuids: const <String>['181f'],
            discover: (result) =>
                result.deviceName == 'alpha' ? alphaSensor : null,
          ),
          CgmDriverRegistration(
            driver: betaDriver,
            scanServiceUuids: const <String>['fde3'],
            discover: (result) =>
                result.deviceName == 'beta' ? betaSensor : null,
          ),
        ],
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: registry,
        healthStateStore: _ControllableHealthStateStore(),
      );

      await controller.initialize();
      await controller.scan();

      expect(controller.sensors, hasLength(2));
      expect(
        controller.sensors.map((sensor) => sensor.driverId).toSet(),
        const <String>{'alpha', 'beta'},
      );

      await controller.connect(betaSensor);

      expect(alphaDriver.connectedSensors, isEmpty);
      expect(betaDriver.connectedSensors, hasLength(1));
      expect(betaDriver.connectedSensors.single.driverId, 'beta');

      await controller.disconnect();
      controller.dispose();
      await alphaDriver.close();
      await betaDriver.close();
    },
  );

  test(
    'registry restores an existing Aidex selection without migration',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final aidexSensor = _multiDriverSensor(
        driverId: 'aidex',
        storageKey: 'serial:LEGACY-1',
      );
      final legacyReading = _reading(
        valueMgdl: 121,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final aidexSession = _ControlledSession(
        _testSnapshot(aidexSensor, stage: CgmSyncStage.ready),
      );
      final aidexDriver = _ControlledDriver(
        <_ControlledSession>[aidexSession],
        driverId: 'aidex',
      );
      final registry = CgmDriverRegistry(
        transport: const _OneShotBleTransport(),
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: aidexDriver,
            scanServiceUuids: const <String>['181f'],
            discover: (_) => aidexSensor,
          ),
        ],
      );
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(aidexSensor.toJson()),
          'openHealth.history.serial:LEGACY-1': jsonEncode(<Object?>[
            legacyReading.toJson(),
          ]),
        },
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: registry,
        healthStateStore: store,
        reconnectDelay: Duration.zero,
      );

      await controller.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(aidexDriver.connectedSensors, hasLength(1));
      expect(aidexDriver.connectedSensors.single.storageKey, 'serial:LEGACY-1');
      expect(
        aidexDriver.connectedSensors.single.metadata['resumeOffset'],
        '10',
      );
      expect(
        aidexDriver.connectedSensors.single.metadata['resumeHistory'],
        isNotNull,
      );
      expect(controller.snapshot?.sensor.driverId, 'aidex');
      expect(controller.snapshot?.history.single.valueMgdl, 121);
      expect(store.getString('openHealth.lastSensor'), isNotNull);

      await controller.disconnect(clearSelection: false);
      controller.dispose();
      await aidexDriver.close();
    },
  );

  test('registry leaves an unsupported persisted driver untouched', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final unsupported = _multiDriverSensor(
      driverId: 'openglucose-driver-registry',
      storageKey: 'registry:corrupt',
    );
    final aidexDriver = _ControlledDriver(
      const <_ControlledSession>[],
      driverId: 'aidex',
    );
    final registry = CgmDriverRegistry(
      transport: const _OneShotBleTransport(),
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: aidexDriver,
          scanServiceUuids: const <String>['181f'],
          discover: (_) => null,
        ),
      ],
    );
    final encoded = jsonEncode(unsupported.toJson());
    final store = _ControllableHealthStateStore(
      initialValues: <String, String>{'openHealth.lastSensor': encoded},
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: registry,
      healthStateStore: store,
    );

    await controller.initialize();

    expect(aidexDriver.connectedSensors, isEmpty);
    expect(controller.snapshot, isNull);
    expect(store.getString('openHealth.lastSensor'), encoded);

    controller.dispose();
  });

  test(
    'equal storage keys from different drivers never resume state',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final alphaSensor = _multiDriverSensor(
        driverId: 'alpha',
        storageKey: 'shared-key',
      );
      final betaSensor = _multiDriverSensor(
        driverId: 'beta',
        storageKey: 'shared-key',
      );
      final oldReading = _reading(
        valueMgdl: 188,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final betaSession = _ControlledSession(
        _testSnapshot(betaSensor, stage: CgmSyncStage.ready),
      );
      final alphaDriver = _ControlledDriver(
        const <_ControlledSession>[],
        driverId: 'alpha',
      );
      final betaDriver = _ControlledDriver(
        <_ControlledSession>[betaSession],
        driverId: 'beta',
      );
      final registry = CgmDriverRegistry(
        transport: const _OneShotBleTransport(),
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: alphaDriver,
            scanServiceUuids: const <String>['181f'],
            discover: (_) => null,
          ),
          CgmDriverRegistration(
            driver: betaDriver,
            scanServiceUuids: const <String>['fde3'],
            discover: (_) => null,
          ),
        ],
      );
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(alphaSensor.toJson()),
          'openHealth.history.shared-key': jsonEncode(<Object?>[
            oldReading.toJson(),
          ]),
        },
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: registry,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(betaSensor);
      await _drainEventQueue();

      expect(betaDriver.connectedSensors, hasLength(1));
      expect(
        betaDriver.connectedSensors.single.metadata.containsKey(
          'resumeHistory',
        ),
        isFalse,
      );
      expect(controller.snapshot?.history, isEmpty);
      expect(
        DiscoveredSensor.fromJson(
          jsonDecode(store.getString('openHealth.lastSensor')!)
              as Map<String, Object?>,
        ).driverId,
        'beta',
      );

      await controller.disconnect(clearSelection: false);
      controller.dispose();
      await betaDriver.close();
    },
  );

  test(
    'equal storage keys retain separate histories across restart',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final alphaSensor = _multiDriverSensor(
        driverId: 'alpha',
        storageKey: 'shared-key',
      );
      final betaSensor = _multiDriverSensor(
        driverId: 'beta',
        storageKey: 'shared-key',
      );
      final alphaReading = _reading(
        valueMgdl: 188,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      final betaReading = _reading(
        valueMgdl: 112,
        sensorMinute: 11,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final firstAlphaDriver = _ControlledDriver(
        const <_ControlledSession>[],
        driverId: 'alpha',
      );
      final firstBetaDriver = _ControlledDriver(
        <_ControlledSession>[
          _ControlledSession(
            _testSnapshot(
              betaSensor,
              stage: CgmSyncStage.ready,
              history: <CgmReading>[betaReading],
            ),
          ),
        ],
        driverId: 'beta',
      );
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(alphaSensor.toJson()),
          _historyStateKey(alphaSensor): jsonEncode(<Object?>[
            alphaReading.toJson(),
          ]),
        },
      );
      final firstController = CgmAppController(
        preferences: preferences,
        driver: CgmDriverRegistry(
          transport: const _OneShotBleTransport(),
          registrations: <CgmDriverRegistration>[
            CgmDriverRegistration(
              driver: firstAlphaDriver,
              scanServiceUuids: const <String>['181f'],
              discover: (_) => null,
            ),
            CgmDriverRegistration(
              driver: firstBetaDriver,
              scanServiceUuids: const <String>['fde3'],
              discover: (_) => null,
            ),
          ],
        ),
        healthStateStore: store,
      );

      await firstController.initialize();
      await firstController.connect(betaSensor);

      expect(firstController.snapshot?.history.single.valueMgdl, 112);
      expect(store.getString(_historyStateKey(alphaSensor)), isNotNull);
      expect(store.getString(_historyStateKey(betaSensor)), isNotNull);
      await firstController.disconnect(clearSelection: false);
      firstController.dispose();
      await firstBetaDriver.close();

      final restoredBetaDriver = _ControlledDriver(
        <_ControlledSession>[
          _ControlledSession(
            _testSnapshot(betaSensor, stage: CgmSyncStage.ready),
          ),
        ],
        driverId: 'beta',
      );
      final restoredController = CgmAppController(
        preferences: preferences,
        driver: CgmDriverRegistry(
          transport: const _OneShotBleTransport(),
          registrations: <CgmDriverRegistration>[
            CgmDriverRegistration(
              driver: _ControlledDriver(
                const <_ControlledSession>[],
                driverId: 'alpha',
              ),
              scanServiceUuids: const <String>['181f'],
              discover: (_) => null,
            ),
            CgmDriverRegistration(
              driver: restoredBetaDriver,
              scanServiceUuids: const <String>['fde3'],
              discover: (_) => null,
            ),
          ],
        ),
        healthStateStore: store,
      );

      await restoredController.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(restoredBetaDriver.connectedSensors, hasLength(1));
      expect(restoredController.snapshot?.history, hasLength(1));
      expect(restoredController.snapshot?.history.single.valueMgdl, 112);
      expect(
        restoredBetaDriver.connectedSensors.single.metadata['resumeHistory'],
        isNot(contains('188')),
      );

      await restoredController.disconnect(clearSelection: false);
      restoredController.dispose();
      await restoredBetaDriver.close();
    },
  );

  test('a legacy Aidex tombstone cannot block another driver', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final aidexSensor = _multiDriverSensor(
      driverId: 'aidex',
      storageKey: 'shared-transfer-key',
    );
    final betaSensor = _multiDriverSensor(
      driverId: 'beta',
      storageKey: 'shared-transfer-key',
    );
    final betaDriver = _ControlledDriver(
      <_ControlledSession>[
        _ControlledSession(
          _testSnapshot(betaSensor, stage: CgmSyncStage.ready),
        ),
      ],
      driverId: 'beta',
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: CgmDriverRegistry(
        transport: const _OneShotBleTransport(),
        registrations: <CgmDriverRegistration>[
          CgmDriverRegistration(
            driver: _ControlledDriver(
              const <_ControlledSession>[],
              driverId: 'aidex',
            ),
            scanServiceUuids: const <String>['181f'],
            discover: (_) => null,
          ),
          CgmDriverRegistration(
            driver: betaDriver,
            scanServiceUuids: const <String>['fde3'],
            discover: (_) => null,
          ),
        ],
      ),
      healthStateStore: _ControllableHealthStateStore(
        initialValues: <String, String>{
          _bondTransferStateKey(aidexSensor): 'sensor-accepted',
        },
      ),
    );

    await controller.initialize();

    expect(controller.sensorHasInterruptedTransfer(aidexSensor), isTrue);
    expect(controller.sensorHasInterruptedTransfer(betaSensor), isFalse);
    await controller.connect(betaSensor);
    expect(betaDriver.connectedSensors, hasLength(1));

    await controller.disconnect(clearSelection: false);
    controller.dispose();
    await betaDriver.close();
  });

  test(
    'stable identity promotion moves history and survives restart',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final discovered = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:provisional',
      );
      final verified = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:stable',
      );
      final provisionalReading = _reading(
        valueMgdl: 106,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      final verifiedReading = _reading(
        valueMgdl: 118,
        sensorMinute: 11,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final session = _ControlledSession(
        _testSnapshot(
          verified,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[verifiedReading],
        ),
      );
      final driver = _ControlledDriver(<_ControlledSession>[session]);
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          _historyStateKey(discovered): jsonEncode(<Object?>[
            provisionalReading.toJson(),
          ]),
        },
      );
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(discovered);
      await _drainEventQueue();

      final persisted = DiscoveredSensor.fromJson(
        jsonDecode(store.getString('openHealth.lastSensor')!)
            as Map<String, Object?>,
      );
      expect(
        driver.connectedSensors.single.storageKey,
        'controlled:provisional',
      );
      expect(controller.snapshot?.sensor.storageKey, 'controlled:stable');
      expect(persisted.storageKey, 'controlled:stable');
      expect(store.getString(_historyStateKey(discovered)), isNull);
      expect(store.getString(_historyStateKey(verified)), isNotNull);
      expect(controller.snapshot?.history, hasLength(2));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
      await driver.close();

      final restoredDriver = _ControlledDriver(<_ControlledSession>[
        _ControlledSession(
          _testSnapshot(verified, stage: CgmSyncStage.ready),
        ),
      ]);
      final restored = CgmAppController(
        preferences: preferences,
        driver: restoredDriver,
        healthStateStore: store,
      );
      await restored.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(restored.snapshot?.sensor.storageKey, 'controlled:stable');
      expect(restored.snapshot?.history, hasLength(2));
      expect(
        restoredDriver.connectedSensors.single.metadata['resumeHistory'],
        isNotNull,
      );

      await restored.disconnect(clearSelection: false);
      restored.dispose();
      await restoredDriver.close();
    },
  );

  test(
    'failed stable-history persistence keeps the provisional pointer',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final discovered = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:provisional-failure',
      );
      final verified = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:stable-failure',
      );
      final reading = _reading(
        valueMgdl: 109,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(discovered.toJson()),
          _historyStateKey(discovered): jsonEncode(<Object?>[
            reading.toJson(),
          ]),
        },
        failSetPrefix: _historyStateKey(verified),
      );
      final driver = _ControlledDriver(<_ControlledSession>[
        _ControlledSession(
          _testSnapshot(
            verified,
            stage: CgmSyncStage.ready,
            history: <CgmReading>[reading],
          ),
        ),
      ]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(discovered);

      final persisted = DiscoveredSensor.fromJson(
        jsonDecode(store.getString('openHealth.lastSensor')!)
            as Map<String, Object?>,
      );
      expect(persisted.storageKey, discovered.storageKey);
      expect(store.getString(_historyStateKey(discovered)), isNotNull);
      expect(store.getString(_historyStateKey(verified)), isNull);
      expect(controller.lastError, contains('verified sensor selection'));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
      await driver.close();
    },
  );

  test(
    'failed stable-history promotion retries after reconnect and restart',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final discovered = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:provisional-retry',
      );
      final verified = _multiDriverSensor(
        driverId: 'controlled',
        storageKey: 'controlled:stable-retry',
      );
      final provisionalReading = _reading(
        valueMgdl: 109,
        sensorMinute: 10,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      final reconnectReading = _reading(
        valueMgdl: 117,
        sensorMinute: 11,
        recordedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final firstSession = _ControlledSession(
        _testSnapshot(
          verified,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[provisionalReading],
        ),
      );
      final reconnectSession = _ControlledSession(
        _testSnapshot(verified, stage: CgmSyncStage.connecting),
      );
      final store = _ControllableHealthStateStore(
        initialValues: <String, String>{
          'openHealth.lastSensor': jsonEncode(discovered.toJson()),
          _historyStateKey(discovered): jsonEncode(<Object?>[
            provisionalReading.toJson(),
          ]),
        },
        failSetPrefix: _historyStateKey(verified),
      );
      final driver = _ControlledDriver(<_ControlledSession>[
        firstSession,
        reconnectSession,
      ]);
      final controller = CgmAppController(
        preferences: preferences,
        driver: driver,
        healthStateStore: store,
      );

      await controller.initialize();
      await controller.connect(discovered);

      expect(
        DiscoveredSensor.fromJson(
          jsonDecode(store.getString('openHealth.lastSensor')!)
              as Map<String, Object?>,
        ).storageKey,
        discovered.storageKey,
      );
      expect(store.getString(_historyStateKey(discovered)), isNotNull);
      expect(store.getString(_historyStateKey(verified)), isNull);

      await controller.disconnect(clearSelection: false);
      store.failSetPrefix = null;
      await controller.connect(verified);

      expect(driver.connectedSensors, hasLength(2));
      expect(
        driver.connectedSensors.last.metadata['resumeHistory'],
        isNotNull,
      );

      reconnectSession.emit(
        _testSnapshot(
          verified,
          stage: CgmSyncStage.ready,
          history: <CgmReading>[reconnectReading],
        ),
      );
      await _drainEventQueue();

      final persisted = DiscoveredSensor.fromJson(
        jsonDecode(store.getString('openHealth.lastSensor')!)
            as Map<String, Object?>,
      );
      final stableHistory =
          jsonDecode(store.getString(_historyStateKey(verified))!)
              as List<dynamic>;
      expect(persisted.storageKey, verified.storageKey);
      expect(store.getString(_historyStateKey(discovered)), isNull);
      expect(stableHistory, hasLength(2));
      expect(controller.snapshot?.history, hasLength(2));

      await controller.disconnect(clearSelection: false);
      controller.dispose();
      await driver.close();

      final restoredDriver = _ControlledDriver(<_ControlledSession>[
        _ControlledSession(
          _testSnapshot(verified, stage: CgmSyncStage.ready),
        ),
      ]);
      final restored = CgmAppController(
        preferences: preferences,
        driver: restoredDriver,
        healthStateStore: store,
      );
      await restored.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(restored.snapshot?.sensor.storageKey, verified.storageKey);
      expect(restored.snapshot?.history, hasLength(2));
      expect(
        restoredDriver.connectedSensors.single.metadata['resumeHistory'],
        isNotNull,
      );

      await restored.disconnect(clearSelection: false);
      restored.dispose();
      await restoredDriver.close();
    },
  );

  test('unsupported capabilities never call optional session APIs', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _multiDriverSensor(
      driverId: 'controlled',
      storageKey: 'controlled:no-optional-features',
    );
    final session = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.ready),
    );
    final driver = _ControlledDriver(<_ControlledSession>[session]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
    );

    await controller.initialize();
    await controller.connect(sensor);
    await controller.ensureFreshData(force: true);
    await controller.sync();
    await controller.refreshHistory();
    await controller.refreshDiagnostics();
    await controller.loadCalibrations();

    expect(session.refreshLiveDataCalls, 2);
    expect(session.syncHistoryCalls, 0);
    expect(session.refreshDiagnosticsCalls, 0);
    expect(session.fetchCalibrationsCalls, 0);

    await controller.disconnect();
    controller.dispose();
    await driver.close();
  });

  test('disposing the controller cancels its physical scan', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final transport = _BlockingBleTransport();
    final driver = _ControlledDriver(
      const <_ControlledSession>[],
      driverId: 'aidex',
    );
    final registry = CgmDriverRegistry(
      transport: transport,
      registrations: <CgmDriverRegistration>[
        CgmDriverRegistration(
          driver: driver,
          scanServiceUuids: const <String>['181f'],
          discover: (_) => null,
        ),
      ],
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: registry,
      healthStateStore: _ControllableHealthStateStore(),
    );

    await controller.initialize();
    final scan = controller.scan();
    await _drainEventQueue();
    expect(transport.scanStarted, isTrue);

    controller.dispose();

    await transport.cancelled.future.timeout(const Duration(seconds: 1));
    await scan.timeout(const Duration(seconds: 1));
  });

  test('initial ready snapshot disables activation on reconnect', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _testSensor();
    final initialSession = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.ready),
    );
    final reconnectSession = _ControlledSession(
      _testSnapshot(sensor, stage: CgmSyncStage.connecting),
    );
    final driver = _ControlledDriver(<_ControlledSession>[
      initialSession,
      reconnectSession,
    ]);
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
      healthStateStore: _ControllableHealthStateStore(),
      reconnectDelay: Duration.zero,
    );

    await controller.initialize();
    await controller.connect(sensor);
    initialSession.emit(
      _testSnapshot(sensor, stage: CgmSyncStage.disconnected),
    );
    await _drainEventQueue();

    expect(driver.connectedSensors, hasLength(2));
    expect(
      driver
          .connectedSensors
          .last
          .metadata[cgmAllowSessionActivationMetadataKey],
      'false',
    );

    await controller.disconnect();
    controller.dispose();
    await driver.close();
  });
}

class _ProductionTestDriver implements CgmDriver {
  final DemoCgmDriver _delegate = DemoCgmDriver();

  @override
  String get driverId => _delegate.driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) {
    return _delegate.scan(timeout: timeout, allowDuplicates: allowDuplicates);
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) {
    return _delegate.connect(sensor);
  }
}

class _DisconnectFailingDriver extends _ProductionTestDriver {
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    return _DisconnectFailingSession(await super.connect(sensor));
  }
}

class _BondTransferDriver extends _ProductionTestDriver {
  _BondTransferDriver({
    required this.plan,
    this.executeFailure,
    this.executeFailureAfterAccepted,
    this.executeStarted,
    this.executeRelease,
  });

  final CgmBondTransferPlan plan;
  final Exception? executeFailure;
  final Exception? executeFailureAfterAccepted;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  _BondTransferSession? session;
  int connectCalls = 0;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectCalls += 1;
    return session = _BondTransferSession(
      await super.connect(sensor),
      plan: plan,
      executeFailure: executeFailure,
      executeFailureAfterAccepted: executeFailureAfterAccepted,
      executeStarted: executeStarted,
      executeRelease: executeRelease,
    );
  }
}

class _BondTransferSession implements CgmSession, CgmBondTransferSession {
  _BondTransferSession(
    this._delegate, {
    required this.plan,
    this.executeFailure,
    this.executeFailureAfterAccepted,
    this.executeStarted,
    this.executeRelease,
  });

  final CgmSession _delegate;
  final CgmBondTransferPlan plan;
  final Exception? executeFailure;
  final Exception? executeFailureAfterAccepted;
  final Completer<void>? executeStarted;
  final Completer<void>? executeRelease;
  int inspectCalls = 0;
  int executeCalls = 0;
  int normalDisconnectCalls = 0;

  @override
  Future<CgmBondTransferPlan> inspectBondTransfer() async {
    inspectCalls += 1;
    return plan;
  }

  @override
  Future<void> executeBondTransfer(
    CgmBondTransferPlan plan, {
    required Future<void> Function() onSensorAccepted,
  }) async {
    executeCalls += 1;
    expect(plan, this.plan);
    final started = executeStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final release = executeRelease;
    if (release != null) {
      await release.future;
    }
    final failure = executeFailure;
    if (failure != null) {
      throw failure;
    }
    await onSensorAccepted();
    final acceptedFailure = executeFailureAfterAccepted;
    if (acceptedFailure != null) {
      throw acceptedFailure;
    }
  }

  @override
  CgmSessionSnapshot get currentSnapshot => _delegate.currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => _delegate.logs;

  @override
  DiscoveredSensor get sensor => _delegate.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _delegate.snapshots;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => _delegate.unsafeAdmin;

  @override
  Future<void> disconnect() async {
    normalDisconnectCalls += 1;
    await _delegate.disconnect();
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() =>
      _delegate.fetchCalibrations();

  @override
  Future<void> refresh() => _delegate.refresh();

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() =>
      _delegate.refreshDiagnostics();

  @override
  Future<void> refreshLiveData() => _delegate.refreshLiveData();

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) => _delegate.submitCalibration(
    glucoseMgdl: glucoseMgdl,
    sensorMinute: sensorMinute,
    recordedAt: recordedAt,
  );

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) => _delegate.syncHistory(
    includeRawHistory: includeRawHistory,
    requestedStartOffset: requestedStartOffset,
  );
}

class _DisconnectFailingSession implements CgmSession {
  _DisconnectFailingSession(this._delegate);

  final CgmSession _delegate;

  @override
  CgmSessionSnapshot get currentSnapshot => _delegate.currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => _delegate.logs;

  @override
  DiscoveredSensor get sensor => _delegate.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _delegate.snapshots;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => _delegate.unsafeAdmin;

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() {
    return _delegate.fetchCalibrations();
  }

  @override
  Future<void> refresh() => _delegate.refresh();

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() {
    return _delegate.refreshDiagnostics();
  }

  @override
  Future<void> refreshLiveData() => _delegate.refreshLiveData();

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) {
    return _delegate.submitCalibration(
      glucoseMgdl: glucoseMgdl,
      sensorMinute: sensorMinute,
      recordedAt: recordedAt,
    );
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) {
    return _delegate.syncHistory(
      includeRawHistory: includeRawHistory,
      requestedStartOffset: requestedStartOffset,
    );
  }

  @override
  Future<void> disconnect() async {
    await _delegate.disconnect();
    throw StateError('simulated BLE teardown failure');
  }
}

class _LibreArchiveFixture {
  _LibreArchiveFixture({_ControllableHealthStateStore? store})
    : store = store ?? _ControllableHealthStateStore();

  final binding = LibreGen1ObservationBinding(
    bootstrapId: 'synthetic-delta-receiver',
    sensorBindingDigest: 'b' * 64,
  );
  late final sensor = DiscoveredSensor(
    driverId: binding.driverId,
    deviceId: 'synthetic-delta-device',
    displayName: 'Libre 2',
    storageKey: binding.storageKey,
    rssi: -45,
    capabilities: const CgmCapabilities(),
  );
  final _ControllableHealthStateStore store;
  late final repository = SensorHistoryRepository(store);
  final readings = List<CgmReading>.generate(
    32,
    (index) => _reading(
      valueMgdl: 110,
      sensorMinute: 100 + index,
      recordedAt: DateTime.utc(2026, 9, 1, 12).add(Duration(minutes: index)),
    ),
  );
  final archiveBytes = <String, String>{};
  CgmAppController? _controller;
  _ControlledDriver? _driver;

  Future<void> prepare() async {
    final archives = <ArchivedSensorSession>[];
    for (final range in [(0, 10), (10, 20), (20, 32)]) {
      final segment = readings.sublist(range.$1, range.$2);
      final receipt = segment.last.recordedAt!;
      final id = base64Url
          .encode(
            utf8.encode(
              '${binding.driverId}|${binding.storageKey}|${receipt.millisecondsSinceEpoch}',
            ),
          )
          .replaceAll('=', '');
      final key = 'openHealth.history.archive.$id';
      final archive = ArchivedSensorSession(
        id: id,
        historyKey: key,
        storageKey: binding.storageKey,
        driverId: binding.driverId,
        deviceId: sensor.deviceId,
        displayName: sensor.displayName,
        reason: SensorArchiveReason.disconnected,
        readingCount: segment.length,
        endedAt: receipt,
        lastReadingAt: receipt,
      );
      final raw = jsonEncode(segment.map((entry) => entry.toJson()).toList());
      archiveBytes[key] = raw;
      await store.setString(key, raw);
      archives.add(archive);
    }
    await store.setString(
      'openHealth.sensorArchive',
      jsonEncode(archives.map((entry) => entry.toJson()).toList()),
    );
    await repository.loadLibre(binding);
  }

  Future<CgmAppController> controller(List<List<CgmReading>> histories) async {
    final driver = _ControlledDriver(
      [
        for (final history in histories)
          _ControlledSession(
            _testSnapshot(
              sensor,
              stage: CgmSyncStage.ready,
              history: history,
              verifiedLibreReception: true,
            ),
          ),
      ],
      driverId: binding.driverId,
    );
    _driver = driver;
    final controller = CgmAppController(
      preferences: await SharedPreferences.getInstance(),
      driver: driver,
      healthStateStore: store,
      historyRepository: repository,
    );
    _controller = controller;
    await controller.initialize();
    return controller;
  }

  Future<void> commit(CgmReading reading) async {
    await repository.commitLibre(
      binding,
      sensorMinute: reading.sensorMinute!,
      receivedAt: reading.recordedAt!,
      reading: reading,
    );
  }

  void expectArchiveBytes(Map<String, String> expected) {
    for (final entry in expected.entries) {
      expect(store.getString(entry.key), entry.value);
    }
  }

  Future<void> dispose() async {
    _controller?.dispose();
    await _driver?.close();
  }
}

class _ControllableHealthStateStore implements HealthStateStore {
  _ControllableHealthStateStore({
    this.failSetPrefix,
    this.failRemovePrefix,
    Map<String, String> initialValues = const <String, String>{},
  }) {
    _values.addAll(initialValues);
  }

  String? failSetPrefix;
  String? failRemovePrefix;
  final Map<String, String> _values = <String, String>{};
  final List<String> setAttempts = <String>[];
  final List<String> removeAttempts = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    setAttempts.add(key);
    if (failSetPrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state write failure');
    }
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removeAttempts.add(key);
    if (failRemovePrefix case final prefix? when key.startsWith(prefix)) {
      throw StateError('simulated restricted-state delete failure');
    }
    _values.remove(key);
  }
}

class _LostAcknowledgementHistoryStore extends _ControllableHealthStateStore {
  String? loseNextWriteFor;

  @override
  Future<void> setString(String key, String value) async {
    await super.setString(key, value);
    if (key == loseNextWriteFor) {
      loseNextWriteFor = null;
      throw StateError('Synthetic write acknowledgement lost');
    }
  }
}

class _GatedSelectionHealthStateStore extends _ControllableHealthStateStore {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'openHealth.lastSensor' && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.setString(key, value);
  }
}

class _GatedHistoryHealthStateStore extends _ControllableHealthStateStore {
  bool gateNextHistoryWrite = false;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (gateNextHistoryWrite && key.startsWith('openHealth.history.')) {
      gateNextHistoryWrite = false;
      started.complete();
      await release.future;
    }
    await super.setString(key, value);
  }
}

class _GatedArchiveHealthStateStore extends _ControllableHealthStateStore {
  bool gateNextArchiveWrite = false;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (gateNextArchiveWrite && key.startsWith('openHealth.history.archive.')) {
      gateNextArchiveWrite = false;
      started.complete();
      await release.future;
    }
    await super.setString(key, value);
  }
}

CgmSessionSnapshot _committedTimingSnapshot(
  DiscoveredSensor sensor, {
  int elapsed = 20,
}) => _testSnapshot(
  sensor,
  stage: CgmSyncStage.syncing,
  sessionInfo: CgmSessionInfo(elapsedMinutes: elapsed),
  metadata: const {
    'cgm.libre2.phase': 'validatedPacket',
    'cgm.libre2.timing': 'observed',
    'cgm.libre2.observationCommitted': 'true',
  },
);

String _historyStateKey(DiscoveredSensor sensor) => sensor.driverId == 'aidex'
    ? 'openHealth.history.${sensor.storageKey}'
    : 'openHealth.history.v2.${_encodedStateIdentity(sensor)}';

String _bondTransferStateKey(DiscoveredSensor sensor) =>
    sensor.driverId == 'aidex'
    ? 'openHealth.bondTransfer.${sensor.storageKey}'
    : 'openHealth.bondTransfer.v2.${_encodedStateIdentity(sensor)}';

String _encodedStateIdentity(DiscoveredSensor sensor) => base64Url
    .encode(
      utf8.encode(jsonEncode(<String>[sensor.driverId, sensor.storageKey])),
    )
    .replaceAll('=', '');

DiscoveredSensor _testSensor({
  Map<String, String> metadata = const <String, String>{'serial': 'TEST-1'},
}) {
  return DiscoveredSensor(
    driverId: 'controlled',
    deviceId: 'controlled-device',
    displayName: 'Controlled sensor',
    storageKey: 'controlled:test-1',
    rssi: -45,
    capabilities: const CgmCapabilities(supportsHistory: true),
    metadata: metadata,
  );
}

CgmReading _reading({
  required double valueMgdl,
  required int sensorMinute,
  required DateTime recordedAt,
}) {
  return CgmReading(
    valueMgdl: valueMgdl,
    source: CgmRecordSource.vendor,
    sensorMinute: sensorMinute,
    recordedAt: recordedAt,
  );
}

CgmSessionSnapshot _testSnapshot(
  DiscoveredSensor sensor, {
  required CgmSyncStage stage,
  List<CgmReading> history = const <CgmReading>[],
  CgmSessionInfo sessionInfo = const CgmSessionInfo(),
  Map<String, String> metadata = const <String, String>{},
  String? lastError,
  bool verifiedLibreReception = false,
}) {
  assert(
    !verifiedLibreReception || sensor.driverId == 'libre2-gen1',
    'Only a Libre fixture may claim verified Libre reception.',
  );
  return CgmSessionSnapshot(
    stage: stage,
    statusText: stage.name,
    sensor: sensor,
    capabilities: sensor.capabilities,
    history: history,
    latestReading: history.isEmpty ? null : history.last,
    sessionInfo: verifiedLibreReception
        ? sessionInfo.copyWith(
            elapsedMinutes:
                sessionInfo.elapsedMinutes ??
                (history.isEmpty ? 100 : history.last.sensorMinute ?? 100),
          )
        : sessionInfo,
    metadata: {
      if (verifiedLibreReception) ...{
        'cgm.libre2.observationCommitted': 'true',
        'cgm.libre2.phase': 'validatedPacket',
        'cgm.libre2.timing': 'observed',
      },
      ...metadata,
    },
    lastError: lastError,
  );
}

Future<void> _drainEventQueue() async {
  for (var index = 0; index < 12; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ControlledDriver implements CgmDriver {
  _ControlledDriver(
    this._sessions, {
    this.driverId = 'controlled',
    this.connectStarted,
    this.connectGate,
    this.connectError,
  });

  final List<_ControlledSession> _sessions;
  final List<DiscoveredSensor> connectedSensors = <DiscoveredSensor>[];
  int _nextSession = 0;
  final Completer<void>? connectStarted;
  final Future<void>? connectGate;
  final Exception? connectError;

  @override
  final String driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    connectedSensors.add(sensor);
    if (connectStarted?.isCompleted == false) connectStarted!.complete();
    if (connectGate != null) await connectGate;
    if (connectError case final error?) throw error;
    return _sessions[_nextSession++];
  }

  Future<void> close() async {
    for (final session in _sessions) {
      await session.close();
    }
  }
}

final class _ScannableControlledDriver extends _ControlledDriver {
  _ScannableControlledDriver(this.sensor, _ControlledSession session)
    : super([session], driverId: sensor.driverId);

  final DiscoveredSensor sensor;
  int scanCalls = 0;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    scanCalls++;
    yield sensor;
  }
}

final class _OneShotBleTransport implements BleTransport {
  const _OneShotBleTransport();

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => Stream<BleScanResult>.fromIterable(const <BleScanResult>[
    BleScanResult(
      deviceId: 'shared-platform-id',
      deviceName: 'alpha',
      rssi: -42,
    ),
    BleScanResult(
      deviceId: 'shared-platform-id',
      deviceName: 'beta',
      rssi: -42,
    ),
  ]);

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();
}

final class _BlockingBleTransport implements BleTransport {
  final Completer<void> cancelled = Completer<void>();
  bool scanStarted = false;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) {
    scanStarted = true;
    return StreamController<BleScanResult>(
      onCancel: () {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      },
    ).stream;
  }

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();
}

DiscoveredSensor _multiDriverSensor({
  required String driverId,
  required String storageKey,
}) => DiscoveredSensor(
  driverId: driverId,
  deviceId: 'shared-platform-id',
  displayName: 'Synthetic sensor',
  storageKey: storageKey,
  rssi: -42,
  capabilities: const CgmCapabilities(supportsDirectBle: true),
);

class _ControlledSession implements CgmSession {
  _ControlledSession(
    this._current, {
    this.disconnectError,
    this.disconnectStarted,
    this.disconnectGate,
    this.refreshLiveDataStarted,
    this.refreshLiveDataGate,
    CgmSessionSnapshot? snapshotOnSnapshotsAccess,
    CgmSessionSnapshot? snapshotOnRefreshLiveData,
    CgmSessionSnapshot? snapshotOnDisconnect,
  }) : _snapshotOnSnapshotsAccess = snapshotOnSnapshotsAccess,
       _snapshotOnRefreshLiveData = snapshotOnRefreshLiveData,
       _snapshotOnDisconnect = snapshotOnDisconnect;

  CgmSessionSnapshot _current;
  final Exception? disconnectError;
  final Completer<void>? disconnectStarted;
  final Future<void>? disconnectGate;
  final Completer<void>? refreshLiveDataStarted;
  final Future<void>? refreshLiveDataGate;
  int disconnectCalls = 0;
  CgmSessionSnapshot? _snapshotOnSnapshotsAccess;
  CgmSessionSnapshot? _snapshotOnRefreshLiveData;
  CgmSessionSnapshot? _snapshotOnDisconnect;
  int refreshLiveDataCalls = 0;
  int syncHistoryCalls = 0;
  int refreshDiagnosticsCalls = 0;
  int fetchCalibrationsCalls = 0;
  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);

  bool get hasSnapshotListener => _snapshots.hasListener;

  void emit(CgmSessionSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  Future<void> close() => _snapshots.close();

  @override
  CgmSessionSnapshot get currentSnapshot => _current;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  DiscoveredSensor get sensor => _current.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots {
    final racedSnapshot = _snapshotOnSnapshotsAccess;
    if (racedSnapshot != null) {
      _snapshotOnSnapshotsAccess = null;
      emit(racedSnapshot);
    }
    return _snapshots.stream;
  }

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (disconnectStarted?.isCompleted == false) disconnectStarted!.complete();
    if (disconnectGate != null) await disconnectGate;
    final finalSnapshot = _snapshotOnDisconnect;
    if (finalSnapshot != null) {
      _snapshotOnDisconnect = null;
      _current = finalSnapshot;
    }
    final error = disconnectError;
    if (error != null) throw error;
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async {
    fetchCalibrationsCalls += 1;
    return const <CgmCalibrationEntry>[];
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async {
    refreshDiagnosticsCalls += 1;
    return const <CgmDiagnosticItem>[];
  }

  @override
  Future<void> refreshLiveData() async {
    refreshLiveDataCalls += 1;
    if (refreshLiveDataStarted?.isCompleted == false) {
      refreshLiveDataStarted!.complete();
    }
    if (refreshLiveDataGate != null) await refreshLiveDataGate;
    final refreshedSnapshot = _snapshotOnRefreshLiveData;
    if (refreshedSnapshot != null) {
      _snapshotOnRefreshLiveData = null;
      emit(refreshedSnapshot);
    }
  }

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
  }) async {
    syncHistoryCalls += 1;
  }
}
