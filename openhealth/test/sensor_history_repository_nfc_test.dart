import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/sensor_history_repository.dart';

void main() {
  late _Harness h;
  setUp(() => h = _Harness());

  test(
    'constructor, ticket and cancellation do not write or upgrade schema one',
    () async {
      expect(h.store.reads, 0);
      expect(h.store.writes, 0);
      await h.live(10);
      final before = h.bytes;
      final writes = h.store.writes;
      final ticket = await h.ticket();
      await h.repository.cancelNfcHistoryImport(ticket);
      expect(h.bytes, before);
      expect(h.store.writes, writes);
      expect(h.envelope['schemaVersion'], 1);
    },
  );

  test(
    'outage import advances separate replay barrier without a BLE observation',
    () async {
      final original = h.reading(10);
      await h.live(10, reading: original);
      final ticket = await h.ticket();
      h.advance(const Duration(seconds: 1));
      final result = await h.import(ticket, scan: 40, minutes: [20, 30]);
      expect(result.importedReadingCount, 2);
      expect(result.state.observedMinute, 10);
      expect(result.state.replayBarrierMinute, 40);
      expect(
        result.state.history.map((entry) => entry.sensorMinute),
        containsAll([10, 20, 30]),
      );
      expect(h.envelope['schemaVersion'], 2);
      expect(h.envelope['lastNfcScanMinute'], 40);
      final entries = h.repository.readLibreHistoryEntries(h.key);
      final legacy = entries.singleWhere(
        (entry) => entry.reading.sensorMinute == 10,
      );
      expect(legacy.reading.toJson(), original.toJson());
      expect(legacy.origin, LibreHistoryOrigin.legacyUnknown);
      expect(legacy.timestampBasis, LibreHistoryTimestampBasis.legacyUnknown);
      expect(legacy.firstReceivedAt, isNull);
      final history = entries.singleWhere(
        (entry) => entry.reading.sensorMinute == 20,
      );
      expect(history.origin, LibreHistoryOrigin.nfcHistory);
      expect(history.timestampBasis, LibreHistoryTimestampBasis.sensorRelative);
      expect(history.firstReceivedAt, h.wall);
      expect(
        history.reading.recordedAt,
        h.wall.subtract(const Duration(minutes: 20)),
      );
      expect(
        h.repository.confirmedLibreLiveReading(h.key, history.reading),
        isNull,
      );
      expect(h.repository.confirmedLibreLiveReading(h.key, original), isNull);
    },
  );

  test('NFC import can establish history with no prior BLE minute', () async {
    final ticket = await h.ticket();
    final result = await h.import(ticket, scan: 40, minutes: [25]);
    expect(result.state.observedMinute, isNull);
    expect(result.state.replayBarrierMinute, 40);
    expect(result.state.history.single.sensorMinute, 25);
    expect(h.envelope['frontierProvenance'], 'none');
    final restart = h.restart();
    expect((await restart.loadLibre(h.binding)).observedMinute, isNull);
  });

  test(
    'NFC scan age consumes replay even if quality accepts no samples',
    () async {
      await h.live(10);
      final result = await h.import(await h.ticket(), scan: 40, minutes: []);
      expect(result.importedReadingCount, 0);
      expect(result.state.observedMinute, 10);
      expect(result.state.replayBarrierMinute, 40);
      expect((await h.live(40)).advanced, isFalse);
      expect((await h.live(41)).advanced, isTrue);
    },
  );

  test(
    'live commit after NFC barrier has BLE origin and exact current matching',
    () async {
      await h.live(10);
      await h.import(await h.ticket(), scan: 40, minutes: [20]);
      h.advance(const Duration(minutes: 1));
      final live = h.reading(41);
      expect((await h.live(41, reading: live)).advanced, isTrue);
      final entry = h.repository
          .readLibreHistoryEntries(h.key)
          .singleWhere((entry) => entry.reading.sensorMinute == 41);
      expect(entry.origin, LibreHistoryOrigin.bleLive);
      expect(entry.timestampBasis, LibreHistoryTimestampBasis.phoneReceipt);
      expect(entry.firstReceivedAt, live.recordedAt);
      expect(h.repository.confirmedLibreLiveReading(h.key, live), isNotNull);
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(valueMgdl: 101),
        ),
        isNull,
      );
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(recordedAt: h.wall.add(const Duration(seconds: 1))),
        ),
        isNull,
      );
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(rawValue: 600),
        ),
        isNull,
      );
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(qualifier: 1),
        ),
        isNull,
      );
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(isDisplayProvisional: false),
        ),
        isNull,
      );
      expect(h.restart().confirmedLibreLiveReading(h.key, live), isNotNull);
    },
  );

  test(
    'schema one current confirmation requires exact fields but remains supported',
    () async {
      final live = h.reading(10);
      await h.live(10, reading: live);
      expect(h.repository.confirmedLibreLiveReading(h.key, live), isNotNull);
      expect(
        h.repository.confirmedLibreLiveReading(
          h.key,
          live.copyWith(valueMgdl: 99),
        ),
        isNull,
      );
      expect(h.restart().confirmedLibreLiveReading(h.key, live), isNotNull);
    },
  );

  test(
    'replayed BLE minute cannot replace an NFC historical receipt',
    () async {
      await h.live(10);
      await h.import(await h.ticket(), scan: 40, minutes: [20]);
      final before = h.bytes;
      final replay = h.reading(20);
      expect((await h.live(20, reading: replay)).advanced, isFalse);
      expect((await h.live(40)).advanced, isFalse);
      expect(h.bytes, before);
      expect(h.repository.confirmedLibreLiveReading(h.key, replay), isNull);
    },
  );

  test(
    'repeated scan preserves first receipt, origin and timestamp of overlap',
    () async {
      await h.live(10);
      await h.import(await h.ticket(), scan: 40, minutes: [20]);
      final before = h.repository.readLibreHistoryEntries(h.key).single;
      h.advance(const Duration(minutes: 1));
      final result = await h.import(await h.ticket(), scan: 41, minutes: [20]);
      expect(result.importedReadingCount, 0);
      final after = h.repository.readLibreHistoryEntries(h.key).single;
      expect(after.reading.toJson(), before.reading.toJson());
      expect(after.firstReceivedAt, before.firstReceivedAt);
      expect(after.origin, before.origin);
    },
  );

  test(
    'overlap cannot change a committed BLE reading or infer legacy origin',
    () async {
      final original = h.reading(10);
      await h.live(10, reading: original);
      await h.import(await h.ticket(), scan: 40, minutes: [10, 20]);
      final found = h.repository
          .readCommittedHistory(h.key)
          .singleWhere((reading) => reading.sensorMinute == 10);
      expect(found.toJson(), original.toJson());
    },
  );

  test(
    'clear covers NFC scan barrier and invalidates a pre-clear ticket',
    () async {
      await h.live(10);
      await h.import(await h.ticket(), scan: 40, minutes: [20, 30]);
      final stale = await h.ticket();
      await h.repository.clear(h.key);
      expect(h.envelope['clearedThroughMinute'], 40);
      expect(h.envelope['clearRevision'], 1);
      final cleared = h.bytes;
      await expectLater(
        h.import(stale, scan: 50, minutes: [45]),
        throwsStateError,
      );
      expect(h.bytes, cleared);
      final result = await h.import(
        await h.ticket(),
        scan: 60,
        minutes: [30, 50],
      );
      expect(result.importedReadingCount, 1);
      expect(result.state.history.single.sensorMinute, 50);
      expect(result.state.observedMinute, 10);
      expect(result.state.replayBarrierMinute, 60);
    },
  );

  test(
    'schema one clear invalidates ticket without a schema upgrade',
    () async {
      await h.live(10, reading: h.reading(10));
      final stale = await h.ticket();
      await h.repository.clear(h.key);
      expect(h.envelope['schemaVersion'], 1);
      final before = h.bytes;
      await expectLater(
        h.import(stale, scan: 20, minutes: [15]),
        throwsStateError,
      );
      expect(h.bytes, before);
    },
  );

  test(
    'clear queued after dispatched import removes imported history',
    () async {
      await h.live(10);
      final ticket = await h.ticket();
      h.store.gate = Completer<void>();
      final imported = h.import(ticket, scan: 40, minutes: [20]);
      await h.store.entered.future;
      final clear = h.repository.clear(h.key);
      h.store.gate!.complete();
      await imported;
      await clear;
      expect(h.repository.readCommittedHistory(h.key), isEmpty);
      expect(h.envelope['clearedThroughMinute'], 40);
    },
  );

  test(
    'immediate cancellation blocks an import waiting behind a live write',
    () async {
      await h.live(10);
      final ticket = await h.ticket();
      h.store.gate = Completer<void>();
      final live = h.live(11);
      await h.store.entered.future;
      final imported = h.import(ticket, scan: 40, minutes: [20]);
      final expectation = expectLater(imported, throwsStateError);
      final cancelled = h.repository.cancelNfcHistoryImport(ticket);
      h.store.gate!.complete();
      await live;
      await expectation;
      await cancelled;
      expect(h.envelope['schemaVersion'], 1);
    },
  );

  test('tickets are single-use after successful or rejected imports', () async {
    final ticket = await h.ticket();
    await h.import(ticket, scan: 40, minutes: [20]);
    await expectLater(
      h.import(ticket, scan: 40, minutes: [20]),
      throwsStateError,
    );
    final rejected = await h.ticket();
    await expectLater(
      h.import(rejected, scan: -1, minutes: []),
      throwsStateError,
    );
    await expectLater(
      h.import(rejected, scan: 40, minutes: []),
      throwsStateError,
    );
  });

  test('connection-owner mismatch consumes ticket and never writes', () async {
    final ticket = await h.ticket();
    final before = h.bytes;
    await expectLater(
      h.repository.importNfcHistory(
        ticket,
        connectionOwner: Object(),
        scanMinute: 40,
        scanReceivedAt: h.wall,
        samples: [],
      ),
      throwsStateError,
    );
    await expectLater(
      h.import(ticket, scan: 40, minutes: []),
      throwsStateError,
    );
    expect(h.bytes, before);
  });

  test(
    'different repository and forged tickets cannot confer import authority',
    () async {
      final ticket = await h.ticket();
      final other = h.restart();
      await expectLater(
        other.importNfcHistory(
          ticket,
          connectionOwner: h.owner,
          scanMinute: 40,
          scanReceivedAt: h.wall,
          samples: [],
        ),
        throwsStateError,
      );
      await expectLater(
        h.import(_ForgedTicket(), scan: 40, minutes: []),
        throwsStateError,
      );
      expect(
        (await h.import(
          ticket,
          scan: 40,
          minutes: [],
        )).state.replayBarrierMinute,
        40,
      );
    },
  );

  test(
    'ticket requires existing exact bound record and rejects changed binding',
    () async {
      await expectLater(
        h.repository.beginNfcHistoryImport(h.binding, connectionOwner: h.owner),
        throwsStateError,
      );
      await h.live(10);
      final before = h.bytes;
      final different = LibreGen1ObservationBinding(
        bootstrapId: h.binding.bootstrapId,
        sensorBindingDigest: 'b' * 64,
      );
      await expectLater(
        h.repository.beginNfcHistoryImport(different, connectionOwner: h.owner),
        throwsStateError,
      );
      expect(h.bytes, before);
    },
  );

  for (final validity in [
    Duration.zero,
    const Duration(seconds: -1),
    const Duration(minutes: 4),
  ]) {
    test('rejects invalid ticket validity ${validity.inSeconds}', () async {
      await h.live(10);
      await expectLater(
        h.repository.beginNfcHistoryImport(
          h.binding,
          connectionOwner: h.owner,
          validity: validity,
        ),
        throwsStateError,
      );
    });
  }

  test(
    'exact monotonic deadline rejects even if delayed timers have not fired',
    () async {
      final ticket = await h.ticket();
      h.advance(const Duration(minutes: 3));
      final before = h.bytes;
      await expectLater(
        h.import(ticket, scan: 40, minutes: []),
        throwsStateError,
      );
      expect(h.bytes, before);
    },
  );

  test(
    'clock jump larger than tolerance rejects without timestamp rewriting',
    () async {
      final ticket = await h.ticket();
      h.wall = h.wall.add(const Duration(seconds: 6));
      await expectLater(
        h.import(ticket, scan: 40, minutes: []),
        throwsStateError,
      );
      expect(h.envelope['schemaVersion'], 1);
    },
  );

  test(
    'clock rollback rejects fresh import but keeps prior future-relative history readable',
    () async {
      await h.import(await h.ticket(), scan: 40, minutes: [20]);
      final saved = h.repository.readLibreHistoryEntries(h.key).single;
      final ticket = await h.ticket();
      h.wall = h.wall.subtract(const Duration(hours: 1));
      await expectLater(
        h.import(ticket, scan: 50, minutes: [30]),
        throwsStateError,
      );
      final restored = h.restart().readLibreHistoryEntries(h.key).single;
      expect(restored.reading.recordedAt, saved.reading.recordedAt);
      expect(restored.firstReceivedAt, saved.firstReceivedAt);
    },
  );

  test(
    'small consistent clock difference is within named host tolerance',
    () async {
      final ticket = await h.ticket();
      h.wall = h.wall.add(const Duration(seconds: 5));
      expect(
        (await h.import(
          ticket,
          scan: 40,
          minutes: [],
        )).state.replayBarrierMinute,
        40,
      );
    },
  );

  test('receipt outside ticket wall interval is rejected', () async {
    final before = await h.ticket();
    await expectLater(
      h.repository.importNfcHistory(
        before,
        connectionOwner: h.owner,
        scanMinute: 40,
        scanReceivedAt: h.wall.subtract(const Duration(microseconds: 1)),
        samples: [],
      ),
      throwsStateError,
    );
    final future = await h.ticket();
    await expectLater(
      h.repository.importNfcHistory(
        future,
        connectionOwner: h.owner,
        scanMinute: 40,
        scanReceivedAt: h.wall.add(const Duration(microseconds: 1)),
        samples: [],
      ),
      throwsStateError,
    );
  });

  for (final invalid in [
    'raw-source',
    'non-provisional',
    'bad-first-receipt',
    'bad-recorded-time',
    'unknown-origin',
    'future-minute',
    'duplicate',
  ]) {
    test('NFC policy rejects $invalid without schema migration', () async {
      final ticket = await h.ticket();
      final sample = h.sample(20, 40);
      final samples = [
        LibreNfcHistorySample(
          reading: switch (invalid) {
            'raw-source' => sample.reading.copyWith(
              source: CgmRecordSource.raw,
            ),
            'non-provisional' => sample.reading.copyWith(
              isDisplayProvisional: false,
            ),
            'bad-recorded-time' => sample.reading.copyWith(recordedAt: h.wall),
            'future-minute' => sample.reading.copyWith(sensorMinute: 41),
            _ => sample.reading,
          },
          firstReceivedAt: invalid == 'bad-first-receipt'
              ? h.wall.subtract(const Duration(seconds: 1))
              : h.wall,
          origin: invalid == 'unknown-origin'
              ? LibreHistoryOrigin.legacyUnknown
              : LibreHistoryOrigin.nfcHistory,
        ),
        if (invalid == 'duplicate') sample,
      ];
      final before = h.bytes;
      await expectLater(
        h.repository.importNfcHistory(
          ticket,
          connectionOwner: h.owner,
          scanMinute: 40,
          scanReceivedAt: h.wall,
          samples: samples,
        ),
        throwsStateError,
      );
      expect(h.bytes, before);
    });
  }

  test(
    'strict version two restart is read-only and rejects unknown metadata',
    () async {
      await h.import(await h.ticket(), scan: 40, minutes: [20]);
      final before = h.bytes;
      final writes = h.store.writes;
      final restored = await h.restart().loadLibre(h.binding);
      expect(restored.history.single.sensorMinute, 20);
      expect(h.bytes, before);
      expect(h.store.writes, writes);
      final corrupted = h.envelope;
      ((corrupted['readings'] as List).single
              as Map<String, dynamic>)['futureField'] =
          true;
      h.store.values[h.key] = jsonEncode(corrupted);
      final malformed = h.bytes;
      await expectLater(h.restart().loadLibre(h.binding), throwsStateError);
      expect(h.bytes, malformed);
    },
  );

  test('regressed scan cannot precede BLE frontier at ticket issue', () async {
    await h.live(50);
    final ticket = await h.ticket();
    final before = h.bytes;
    await expectLater(
      h.import(ticket, scan: 49, minutes: [20]),
      throwsStateError,
    );
    expect(h.bytes, before);
  });

  test('deadline is rechecked immediately before the durable effect', () async {
    await h.live(10);
    var ticks = 0;
    final repository = SensorHistoryRepository(
      h.store,
      utcNow: () => h.wall,
      monotonicNow: () =>
          ++ticks < 3 ? Duration.zero : const Duration(minutes: 3),
    );
    final ticket = await repository.beginNfcHistoryImport(
      h.binding,
      connectionOwner: h.owner,
    );
    final before = h.bytes;
    final writes = h.store.writes;
    await expectLater(
      repository.importNfcHistory(
        ticket,
        connectionOwner: h.owner,
        scanMinute: 40,
        scanReceivedAt: h.wall,
        samples: [h.sample(20, 40)],
      ),
      throwsStateError,
    );
    expect(h.bytes, before);
    expect(h.store.writes, writes);
  });

  test(
    'time waiting behind another durable write counts against the ticket',
    () async {
      await h.live(10);
      final ticket = await h.ticket();
      h.store.gate = Completer<void>();
      final live = h.live(11);
      await h.store.entered.future;
      final imported = h.import(ticket, scan: 40, minutes: [20]);
      final rejected = expectLater(imported, throwsStateError);
      h.advance(const Duration(minutes: 3));
      h.store.gate!.complete();
      await live;
      await rejected;
      expect(h.envelope['schemaVersion'], 1);
    },
  );

  test(
    'schema two cannot silently discard its historical replay frontier',
    () async {
      await h.import(await h.ticket(), scan: 40, minutes: []);
      final corrupted = h.envelope;
      corrupted['lastNfcScanMinute'] = null;
      h.store.values[h.key] = jsonEncode(corrupted);
      final before = h.bytes;
      await expectLater(h.restart().loadLibre(h.binding), throwsStateError);
      expect(h.bytes, before);
    },
  );

  test(
    'queued newer scan wins and older ticket cannot regress NFC age',
    () async {
      final older = await h.ticket();
      final newer = await h.ticket();
      await h.import(newer, scan: 50, minutes: [30]);
      final before = h.bytes;
      await expectLater(
        h.import(older, scan: 49, minutes: [20]),
        throwsStateError,
      );
      expect(h.bytes, before);
    },
  );

  test(
    'same-age NFC scan is a no-write no-op even with additional candidates',
    () async {
      await h.import(await h.ticket(), scan: 50, minutes: [30]);
      final before = h.bytes;
      final writes = h.store.writes;
      final result = await h.import(
        await h.ticket(),
        scan: 50,
        minutes: [30, 40],
      );
      expect(result.importedReadingCount, 0);
      expect(result.state.history.single.sensorMinute, 30);
      expect(h.bytes, before);
      expect(h.store.writes, writes);
    },
  );

  test(
    'live observation after ticket issuance can exceed the historical scan',
    () async {
      await h.live(10);
      final ticket = await h.ticket();
      await h.live(60);
      final result = await h.import(ticket, scan: 50, minutes: [30]);
      expect(result.state.observedMinute, 60);
      expect(result.state.replayBarrierMinute, 60);
      expect(result.state.history.single.sensorMinute, 30);
    },
  );

  for (final origin in [
    LibreHistoryOrigin.nfcTrend,
    LibreHistoryOrigin.nfcHistory,
  ]) {
    test(
      'ring capacity bound for ${origin.name} rejects excess candidates',
      () async {
        final ticket = await h.ticket();
        final count = origin == LibreHistoryOrigin.nfcTrend ? 17 : 33;
        final samples = [
          for (var minute = 1; minute <= count; minute++)
            LibreNfcHistorySample(
              reading: h.sample(minute, 50).reading,
              firstReceivedAt: h.wall,
              origin: origin,
            ),
        ];
        final before = h.bytes;
        await expectLater(
          h.repository.importNfcHistory(
            ticket,
            connectionOwner: h.owner,
            scanMinute: 50,
            scanReceivedAt: h.wall,
            samples: samples,
          ),
          throwsStateError,
        );
        expect(h.bytes, before);
      },
    );
  }

  test(
    'new archive preserves NFC provenance and omits no outage history',
    () async {
      await h.live(10, reading: h.reading(10));
      final staleSession = h.repository.readCommittedHistory(h.key);
      await h.import(await h.ticket(), scan: 50, minutes: [30, 40]);
      final delta = await h.repository.unarchivedLibreReadings(
        sensor: h.sensor,
        incoming: staleSession,
      );
      expect(delta.length, 3);
      final key = h.archiveKey(1);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: delta,
      );
      h.manifest(key, delta.length);
      final stored = jsonDecode(h.store.values[key]!) as Map<String, dynamic>;
      expect(stored['schemaVersion'], 2);
      expect(stored['kind'], 'libreHistoryArchive');
      expect(h.repository.readCommittedHistory(key).length, 3);
      final entries = h.repository.readLibreHistoryEntries(key);
      final nfc = entries.singleWhere(
        (entry) => entry.reading.sensorMinute == 30,
      );
      expect(nfc.origin, LibreHistoryOrigin.nfcHistory);
      expect(nfc.timestampBasis, LibreHistoryTimestampBasis.sensorRelative);
      expect(nfc.firstReceivedAt, h.wall);
      expect(
        h.repository
            .readLibreArchivedHistoryGroups()[h.binding.storageKey]!
            .length,
        3,
      );
      expect(
        await h.repository.unarchivedLibreReadings(
          sensor: h.sensor,
          incoming: staleSession,
        ),
        isEmpty,
      );
      final before = h.store.values[key];
      await h.repository.clear(h.key);
      expect(h.store.values[key], before);
      expect(h.repository.readLibreHistoryEntries(key).length, 3);
    },
  );

  test('schema one archive remains an immutable ordinary list', () async {
    final reading = h.reading(10);
    await h.live(10, reading: reading);
    final key = h.archiveKey(1);
    await h.repository.writeLibreArchive(
      sensor: h.sensor,
      archiveKey: key,
      incoming: [reading],
    );
    final before = h.store.values[key];
    expect(jsonDecode(before!), isA<List<dynamic>>());
    expect(before, jsonEncode([reading.toJson()]));
    await h.import(await h.ticket(), scan: 50, minutes: [30]);
    await expectLater(
      h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: [reading],
      ),
      throwsStateError,
    );
    expect(h.store.values[key], before);
  });

  test(
    'archive write rejects stale uncommitted and altered candidate values',
    () async {
      await h.import(await h.ticket(), scan: 50, minutes: [30]);
      final entry = h.repository.readCommittedHistory(h.key).single;
      final key = h.archiveKey(1);
      await expectLater(
        h.repository.writeLibreArchive(
          sensor: h.sensor,
          archiveKey: key,
          incoming: [entry.copyWith(valueMgdl: 101)],
        ),
        throwsStateError,
      );
      expect(h.store.values.containsKey(key), isFalse);
      await h.repository.clear(h.key);
      await expectLater(
        h.repository.writeLibreArchive(
          sensor: h.sensor,
          archiveKey: key,
          incoming: [entry],
        ),
        throwsStateError,
      );
      expect(h.store.values.containsKey(key), isFalse);
    },
  );

  test(
    'provenance archive cannot restore a missing active envelope as BLE',
    () async {
      await h.import(await h.ticket(), scan: 50, minutes: [30]);
      final key = h.archiveKey(1);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: h.repository.readCommittedHistory(h.key),
      );
      h.manifest(key, 1);
      h.store.values.remove(h.key);
      final before = Map<String, String>.of(h.store.values);
      await expectLater(h.restart().loadLibre(h.binding), throwsStateError);
      expect(h.store.values, before);
    },
  );

  test(
    'strict archive reader rejects changed binding and preserves bytes',
    () async {
      await h.import(await h.ticket(), scan: 50, minutes: [30]);
      final key = h.archiveKey(1);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: h.repository.readCommittedHistory(h.key),
      );
      h.manifest(key, 1);
      final value = jsonDecode(h.store.values[key]!) as Map<String, dynamic>;
      value['sensorBindingDigest'] = 'b' * 64;
      h.store.values[key] = jsonEncode(value);
      final before = h.store.values[key];
      expect(h.repository.readLibreArchivedHistoryGroups, throwsStateError);
      expect(() => h.repository.readCommittedHistory(key), throwsStateError);
      expect(h.store.values[key], before);
    },
  );

  test(
    'generic list writer cannot erase archive acquisition provenance',
    () async {
      await h.import(await h.ticket(), scan: 50, minutes: [30]);
      final readings = h.repository.readCommittedHistory(h.key);
      final key = h.archiveKey(1);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: readings,
      );
      final before = h.store.values[key];
      await expectLater(h.repository.merge(key, readings), throwsStateError);
      expect(h.store.values[key], before);
    },
  );

  test('uncertain new archive write quarantines that segment', () async {
    await h.import(await h.ticket(), scan: 50, minutes: [30]);
    final readings = h.repository.readCommittedHistory(h.key);
    final key = h.archiveKey(1);
    h.store.failWrite = true;
    await expectLater(
      h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: readings,
      ),
      throwsStateError,
    );
    expect(h.repository.isQuarantined(key), isTrue);
    final writes = h.store.writes;
    h.store.failWrite = false;
    await expectLater(
      h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: key,
        incoming: readings,
      ),
      throwsStateError,
    );
    expect(h.store.writes, writes);
    expect(h.repository.readCommittedHistory(h.key).single.sensorMinute, 30);
  });

  test('invalid archive identity returns only a closed error', () async {
    await h.live(10);
    await expectLater(
      h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: 'openHealth.history.archive.synthetic-invalid!',
        incoming: [],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'closed message',
          'Stored sensor history is unavailable.',
        ),
      ),
    );
  });

  for (final field in ['origin', 'timestampBasis', 'firstReceivedAt']) {
    test(
      'strict version two rejects malformed $field without rewriting',
      () async {
        await h.import(await h.ticket(), scan: 40, minutes: [20]);
        final corrupted = h.envelope;
        ((corrupted['readings'] as List).single
                as Map<String, dynamic>)[field] =
            'future-invalid';
        h.store.values[h.key] = jsonEncode(corrupted);
        final malformed = h.bytes;
        await expectLater(h.restart().loadLibre(h.binding), throwsStateError);
        expect(h.bytes, malformed);
      },
    );
  }

  test(
    'uncertain import write quarantines authority and retains confirmed display',
    () async {
      await h.live(10, reading: h.reading(10));
      final ticket = await h.ticket();
      h.store.failWrite = true;
      await expectLater(
        h.import(ticket, scan: 40, minutes: [20]),
        throwsStateError,
      );
      expect(h.repository.isQuarantined(h.key), isTrue);
      expect(h.repository.readCommittedHistory(h.key).single.sensorMinute, 10);
      final writes = h.store.writes;
      await expectLater(h.repository.clear(h.key), throwsStateError);
      await expectLater(h.repository.loadLibre(h.binding), throwsStateError);
      await expectLater(
        h.repository.beginNfcHistoryImport(h.binding, connectionOwner: h.owner),
        throwsStateError,
      );
      expect(h.store.writes, writes);
    },
  );
}

final class _Harness {
  _Harness() {
    repository = SensorHistoryRepository(
      store,
      monotonicNow: () => monotonic,
      utcNow: () => wall,
    );
  }

  final store = _Store();
  final owner = Object();
  final binding = LibreGen1ObservationBinding(
    bootstrapId: 'synthetic-nfc-bootstrap',
    sensorBindingDigest: 'a' * 64,
  );
  late final SensorHistoryRepository repository;
  DateTime wall = DateTime.utc(2026, 1, 2, 12);
  Duration monotonic = Duration.zero;
  DiscoveredSensor get sensor => DiscoveredSensor(
    driverId: binding.driverId,
    deviceId: 'synthetic-target',
    storageKey: binding.storageKey,
    displayName: 'Synthetic',
    rssi: 0,
    capabilities: const CgmCapabilities(),
  );
  String get key => sensorHistoryKey(sensor);
  String archiveKey(int segment) =>
      'openHealth.history.archive.${base64Url.encode(utf8.encode('${binding.driverId}|${binding.storageKey}|$segment')).replaceAll('=', '')}';
  void manifest(String key, int count) {
    store.values['openHealth.sensorArchive'] = jsonEncode([
      {
        'id': key.substring('openHealth.history.archive.'.length),
        'historyKey': key,
        'driverId': binding.driverId,
        'storageKey': binding.storageKey,
        'readingCount': count,
      },
    ]);
  }

  String? get bytes => store.values[key];
  Map<String, dynamic> get envelope =>
      jsonDecode(bytes!) as Map<String, dynamic>;
  SensorHistoryRepository restart() => SensorHistoryRepository(
    store,
    monotonicNow: () => monotonic,
    utcNow: () => wall,
  );
  void advance(Duration duration) {
    monotonic += duration;
    wall = wall.add(duration);
  }

  CgmReading reading(int minute, {DateTime? at}) => CgmReading(
    valueMgdl: 100,
    source: CgmRecordSource.vendor,
    sensorMinute: minute,
    recordedAt: at ?? wall,
    rawValue: 500,
    qualifier: 0,
    isDisplayProvisional: true,
  );
  Future<LibreGen1ObservationCommit> live(int minute, {CgmReading? reading}) =>
      repository.commitLibre(
        binding,
        sensorMinute: minute,
        receivedAt: reading?.recordedAt ?? wall,
        reading: reading,
      );
  Future<LibreNfcHistoryImportTicket> ticket() async {
    await repository.loadLibre(binding);
    return repository.beginNfcHistoryImport(binding, connectionOwner: owner);
  }

  LibreNfcHistorySample sample(int minute, int scan) => LibreNfcHistorySample(
    reading: reading(
      minute,
      at: wall.subtract(Duration(minutes: scan - minute)),
    ),
    firstReceivedAt: wall,
    origin: LibreHistoryOrigin.nfcHistory,
  );
  Future<LibreNfcHistoryImportResult> import(
    LibreNfcHistoryImportTicket ticket, {
    required int scan,
    required List<int> minutes,
  }) => repository.importNfcHistory(
    ticket,
    connectionOwner: owner,
    scanMinute: scan,
    scanReceivedAt: wall,
    samples: [for (final minute in minutes) sample(minute, scan)],
  );
}

final class _ForgedTicket implements LibreNfcHistoryImportTicket {}

final class _Store implements HealthStateStore {
  final values = <String, String>{};
  int reads = 0;
  int writes = 0;
  bool failWrite = false;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) {
    reads++;
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    writes++;
    final pending = gate;
    if (pending != null) {
      if (!entered.isCompleted) entered.complete();
      await pending.future;
    }
    if (failWrite) throw StateError('Synthetic uncertain write.');
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
}
