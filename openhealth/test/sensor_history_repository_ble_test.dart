import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre_gen1_observation_store.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_history_repository.dart';

void main() {
  late _Harness h;
  setUp(() => h = _Harness());

  test(
    'current-only commits keep schema one and no fabricated NFC age',
    () async {
      await h.commit(120);
      expect(h.envelope['schemaVersion'], 1);
      expect(h.envelope.containsKey('lastNfcScanMinute'), isFalse);
      await h.repository.loadLibre(h.binding);
      expect(h.envelope['schemaVersion'], 1);
    },
  );

  test(
    'adapter commits frontier, current and all nine sparse slots once',
    () async {
      final before = h.store.writes;
      final result = await h.commit(121, history: h.slots(121));
      expect(result.advanced, isTrue);
      expect(h.store.writes - before, 1);
      expect(result.state.observedMinute, 121);
      expect(result.state.replayBarrierMinute, 121);
      expect(result.state.history.length, 10);
      expect(h.envelope['schemaVersion'], 3);
      expect(h.envelope['lastNfcScanMinute'], isNull);
      expect(h.envelope['clearRevision'], 0);
      final entries = h.repository.readLibreHistoryEntries(h.key);
      expect(
        entries
            .where((entry) => entry.origin == LibreHistoryOrigin.bleTrend)
            .length,
        6,
      );
      expect(
        entries
            .where((entry) => entry.origin == LibreHistoryOrigin.bleHistory)
            .length,
        3,
      );
      for (final entry in entries) {
        expect(entry.firstReceivedAt, h.wall);
        expect(
          entry.reading.recordedAt,
          h.wall.subtract(Duration(minutes: 121 - entry.reading.sensorMinute!)),
        );
        expect(entry.reading.source, CgmRecordSource.vendor);
        expect(entry.reading.isDisplayProvisional, isTrue);
        expect(
          h.repository.confirmedLibreLiveReading(h.key, entry.reading) != null,
          entry.origin == LibreHistoryOrigin.bleLive,
        );
      }
      final beforeRestart = h.bytes;
      final restored = await h.restart().loadLibre(h.binding);
      expect(
        restored.history.map((reading) => reading.toJson()),
        result.state.history.map((reading) => reading.toJson()),
      );
      expect(h.bytes, beforeRestart);
    },
  );

  test(
    'a rejected current value can still commit accepted historical slots',
    () async {
      final result = await h.commit(121, current: false, history: h.slots(121));
      expect(result.state.history.length, 9);
      expect(result.state.observedMinute, 121);
      expect(
        h.repository
            .readLibreHistoryEntries(h.key)
            .every(
              (entry) =>
                  h.repository.confirmedLibreLiveReading(
                    h.key,
                    entry.reading,
                  ) ==
                  null,
            ),
        isTrue,
      );
    },
  );

  test(
    'first retained acquisition wins across real overlapping slot kinds',
    () async {
      final trend = h.slot(120, 105, LibreGen1BleHistoryKind.trend);
      final history = h.slot(
        120,
        105,
        LibreGen1BleHistoryKind.history,
        value: 200,
      );
      await h.commit(120, history: [trend, history]);
      final original = h.repository.readLibreHistoryEntries(h.key).first;
      expect(original.origin, LibreHistoryOrigin.bleTrend);
      expect(original.reading.valueMgdl, 100);
      h.wall = h.wall.add(const Duration(minutes: 1));
      await h.commit(
        121,
        history: [
          h.slot(121, 105, LibreGen1BleHistoryKind.history, value: 300),
        ],
      );
      final retained = h.repository.readLibreHistoryEntries(h.key).first;
      expect(retained.reading.toJson(), original.reading.toJson());
      expect(retained.origin, original.origin);
      expect(retained.firstReceivedAt, original.firstReceivedAt);
    },
  );

  test(
    'accepted history survives without a rejected overlapping trend',
    () async {
      await h.commit(
        120,
        history: [h.slot(120, 105, LibreGen1BleHistoryKind.history)],
      );
      expect(
        h.repository.readLibreHistoryEntries(h.key).first.origin,
        LibreHistoryOrigin.bleHistory,
      );
    },
  );

  test('schema-one overlap stays legacy unknown after lazy upgrade', () async {
    await h.commit(105);
    final original = h.repository.readCommittedHistory(h.key).single;
    await h.commit(
      120,
      history: [h.slot(120, 105, LibreGen1BleHistoryKind.trend, value: 200)],
    );
    final first = h.repository.readLibreHistoryEntries(h.key).first;
    expect(first.reading.toJson(), original.toJson());
    expect(first.origin, LibreHistoryOrigin.legacyUnknown);
    expect(first.firstReceivedAt, isNull);
    expect(
      h.repository.confirmedLibreLiveReading(h.key, first.reading),
      isNull,
    );
  });

  test(
    'repeated and regressed packets never refresh or upgrade a record',
    () async {
      await h.commit(121);
      final before = h.bytes;
      final writes = h.store.writes;
      for (final minute in [121, 120]) {
        expect(
          (await h.commit(minute, history: h.slots(minute))).advanced,
          isFalse,
        );
      }
      expect(h.bytes, before);
      expect(h.store.writes, writes);
    },
  );

  test(
    'mixed NFC and BLE keep separate frontiers and immutable first evidence',
    () async {
      await h.commit(120);
      await h.nfc(150, [135]);
      expect(h.envelope['schemaVersion'], 2);
      final nfc = h.repository
          .readLibreHistoryEntries(h.key)
          .singleWhere(
            (entry) => entry.reading.sensorMinute == 135,
          );
      final bytes = h.bytes;
      expect((await h.commit(150, history: h.slots(150))).advanced, isFalse);
      expect(h.bytes, bytes);
      await h.commit(151, history: h.slots(151));
      expect(h.envelope['schemaVersion'], 3);
      expect(h.envelope['observedMinute'], 151);
      expect(h.envelope['lastNfcScanMinute'], 150);
      final retained = h.repository
          .readLibreHistoryEntries(h.key)
          .singleWhere((entry) => entry.reading.sensorMinute == 135);
      expect(retained.reading.toJson(), nfc.reading.toJson());
      expect(retained.origin, LibreHistoryOrigin.nfcHistory);
      await h.nfc(180, [165]);
      expect(h.envelope['schemaVersion'], 3);
      expect(h.envelope['observedMinute'], 151);
      expect(h.envelope['lastNfcScanMinute'], 180);
      final restored = await h.restart().loadLibre(h.binding);
      expect(restored.observedMinute, 151);
      expect(restored.replayBarrierMinute, 180);
    },
  );

  test('clear stays schema three and blocks old slots after restart', () async {
    await h.commit(121, history: h.slots(121));
    await h.repository.clear(h.key);
    expect(h.envelope['schemaVersion'], 3);
    expect(h.envelope['clearedThroughMinute'], 121);
    expect(h.envelope['clearRevision'], 1);
    h.repository = h.restart();
    expect((await h.commit(121, history: h.slots(121))).advanced, isFalse);
    await h.commit(123, history: h.slots(123));
    expect(
      h.repository
          .readCommittedHistory(h.key)
          .map((entry) => entry.sensorMinute),
      [123],
    );
    await h.nfc(150, [120, 135]);
    expect(h.envelope['schemaVersion'], 3);
    expect(h.envelope['clearRevision'], 1);
    expect(
      h.repository
          .readCommittedHistory(h.key)
          .map((entry) => entry.sensorMinute),
      containsAll([123, 135]),
    );
    expect(
      h.repository
          .readCommittedHistory(h.key)
          .any((entry) => entry.sensorMinute! <= 121),
      isFalse,
    );
  });

  test('queued clear cannot race a dispatched atomic BLE batch', () async {
    await h.repository.loadLibre(h.binding);
    h.store.gate = Completer<void>();
    final pending = h.commit(121, history: h.slots(121));
    await h.store.entered.future;
    final clearing = h.repository.clear(h.key);
    h.store.gate!.complete();
    await pending;
    await clearing;
    expect(h.envelope['observedMinute'], 121);
    expect(h.envelope['clearedThroughMinute'], 121);
    expect(h.envelope['readings'], isEmpty);
  });

  test(
    'dispatched batch failure quarantines all mutation and preserves display',
    () async {
      await h.commit(100);
      final before = h.bytes;
      h.store.failWrite = true;
      await expectLater(h.commit(121, history: h.slots(121)), throwsStateError);
      expect(h.repository.isQuarantined(h.key), isTrue);
      expect(h.bytes, before);
      expect(h.repository.readCommittedHistory(h.key).single.sensorMinute, 100);
      await expectLater(h.repository.clear(h.key), throwsStateError);
      await expectLater(h.commit(122), throwsStateError);
    },
  );

  test(
    'BLE batch inputs are frozen before waiting for the shared queue',
    () async {
      await h.repository.loadLibre(h.binding);
      h.store.gate = Completer<void>();
      final pending = h.commit(100);
      await h.store.entered.future;
      final samples = h.slots(121);
      final batch = h.commit(121, history: samples);
      samples.clear();
      h.store.gate!.complete();
      await pending;
      expect((await batch).state.history.length, 11);
    },
  );

  for (final fault in [
    'too-many',
    'duplicate-kind-minute',
    'wrong-trend-slot',
    'wrong-history-slot',
    'current-minute',
    'warmup-minute',
    'future-minute',
    'negative-minute',
    'null-minute',
    'null-time',
    'wrong-time',
    'fractional-time',
    'raw-source',
    'not-provisional',
    'zero',
    'negative-value',
    'infinite',
    'nan',
  ]) {
    test(
      'malformed $fault rejects the whole packet without any write',
      () async {
        await h.commit(100);
        final before = h.bytes;
        final writes = h.store.writes;
        final base = h.slot(121, 119, LibreGen1BleHistoryKind.trend);
        final reading = switch (fault) {
          'wrong-trend-slot' =>
            h.slot(121, 118, LibreGen1BleHistoryKind.trend).reading,
          'wrong-history-slot' =>
            h.slot(121, 104, LibreGen1BleHistoryKind.history).reading,
          'current-minute' => h.reading(121),
          'warmup-minute' =>
            h.slot(61, 59, LibreGen1BleHistoryKind.trend).reading,
          'future-minute' => h.reading(122),
          'negative-minute' => h.reading(-1),
          'null-minute' => CgmReading.fromJson({
            ...base.reading.toJson(),
            'sensorMinute': null,
          }),
          'null-time' => CgmReading.fromJson({
            ...base.reading.toJson(),
            'recordedAt': null,
          }),
          'wrong-time' => base.reading.copyWith(recordedAt: h.wall),
          'fractional-time' => base.reading.copyWith(
            recordedAt: base.reading.recordedAt!.add(
              const Duration(seconds: 1),
            ),
          ),
          'raw-source' => CgmReading.fromJson({
            ...base.reading.toJson(),
            'source': 'raw',
          }),
          'not-provisional' => base.reading.copyWith(
            isDisplayProvisional: false,
          ),
          'zero' => base.reading.copyWith(valueMgdl: 0),
          'negative-value' => base.reading.copyWith(valueMgdl: -1),
          'infinite' => base.reading.copyWith(valueMgdl: double.infinity),
          'nan' => base.reading.copyWith(valueMgdl: double.nan),
          _ => base.reading,
        };
        final samples = switch (fault) {
          'too-many' => [...h.slots(121), base],
          'duplicate-kind-minute' => [base, base],
          _ => [
            LibreGen1HistoricalReading(
              reading: reading,
              kind: fault == 'wrong-history-slot'
                  ? LibreGen1BleHistoryKind.history
                  : LibreGen1BleHistoryKind.trend,
            ),
          ],
        };
        await expectLater(
          h.commit(fault == 'warmup-minute' ? 61 : 121, history: samples),
          throwsStateError,
        );
        expect(h.bytes, before);
        expect(h.store.writes, writes);
      },
    );
  }

  for (final fault in [
    'schema-two-origin',
    'schema-two-null-nfc',
    'future-schema',
    'invalid-nfc',
    'invalid-slot',
    'packet-above-frontier',
    'wrong-basis',
    'raw-source',
  ]) {
    test('strict restoration rejects $fault without mutation', () async {
      await h.commit(121, history: h.slots(121));
      final envelope = h.envelope;
      final rows = envelope['readings'] as List;
      final row = rows.first as Map<String, dynamic>;
      final value = row['reading'] as Map<String, dynamic>;
      switch (fault) {
        case 'schema-two-origin':
          envelope['schemaVersion'] = 2;
          envelope['lastNfcScanMinute'] = 121;
        case 'schema-two-null-nfc':
          envelope['schemaVersion'] = 2;
          envelope['readings'] = <Object?>[];
        case 'future-schema':
          envelope['schemaVersion'] = 4;
        case 'invalid-nfc':
          envelope['lastNfcScanMinute'] = -1;
        case 'invalid-slot':
          row['origin'] = 'bleTrend';
        case 'packet-above-frontier':
          envelope['observedMinute'] = 120;
          rows.removeWhere((entry) => (entry as Map)['origin'] == 'bleLive');
        case 'wrong-basis':
          row['timestampBasis'] = 'phoneReceipt';
        case 'raw-source':
          value['source'] = 'raw';
      }
      h.store.values[h.key] = jsonEncode(envelope);
      final before = h.bytes;
      await expectLater(h.restart().loadLibre(h.binding), throwsStateError);
      expect(h.bytes, before);
    });
  }

  test(
    'schema three delta archive keeps full history and exports without active state',
    () async {
      await h.commit(121, history: h.slots(121));
      final delta = await h.repository.unarchivedLibreReadings(
        sensor: h.sensor,
        incoming: const [],
      );
      expect(delta.length, 10);
      final owner = h.archiveOwner(delta.length);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: owner.historyKey,
        incoming: delta,
      );
      h.store.values['openHealth.sensorArchive'] = jsonEncode([owner.toJson()]);
      final archiveBytes = h.store.values[owner.historyKey];
      final encoded = jsonDecode(archiveBytes!) as Map;
      expect(encoded['schemaVersion'], 3);
      expect(
        h.repository
            .readLibreArchivedHistoryGroups()[h.binding.storageKey]!
            .length,
        10,
      );
      expect(
        await h.repository.unarchivedLibreReadings(
          sensor: h.sensor,
          incoming: delta,
        ),
        isEmpty,
      );
      await h.repository.clear(h.key);
      h.store.values.remove(h.key);
      final exported = h.restart().readArchivedSensorExportData(owner);
      expect(exported.hasAcquisitionEvidence, isTrue);
      expect(
        exported.acquisitionEntries!
            .where((entry) => entry.origin == LibreHistoryOrigin.bleTrend)
            .length,
        6,
      );
      expect(
        exported.acquisitionEntries!
            .where((entry) => entry.origin == LibreHistoryOrigin.bleHistory)
            .length,
        3,
      );
      expect(
        exported.readings.map((reading) => reading.toJson()),
        delta.map((reading) => reading.toJson()),
      );
      expect(h.store.values[owner.historyKey], archiveBytes);
    },
  );

  test(
    'schema two archive rejects BLE origins even when active state is absent',
    () async {
      await h.commit(121, history: h.slots(121));
      final owner = h.archiveOwner(10);
      await h.repository.writeLibreArchive(
        sensor: h.sensor,
        archiveKey: owner.historyKey,
        incoming: h.repository.readCommittedHistory(h.key),
      );
      final envelope =
          jsonDecode(h.store.values[owner.historyKey]!) as Map<String, dynamic>;
      envelope['schemaVersion'] = 2;
      h.store.values[owner.historyKey] = jsonEncode(envelope);
      h.store.values['openHealth.sensorArchive'] = jsonEncode([owner.toJson()]);
      h.store.values.remove(h.key);
      final before = Map<String, String>.from(h.store.values);
      expect(
        () => h.restart().readArchivedSensorExportData(owner),
        throwsStateError,
      );
      expect(h.store.values, before);
    },
  );
}

final class _Harness {
  _Harness() {
    repository = restart();
  }
  final store = _Store();
  final binding = LibreGen1ObservationBinding(
    bootstrapId: 'synthetic-bootstrap',
    sensorBindingDigest: 'a' * 64,
  );
  DateTime wall = DateTime.utc(2026, 1, 2, 12);
  late SensorHistoryRepository repository;
  DiscoveredSensor get sensor => DiscoveredSensor(
    driverId: binding.driverId,
    deviceId: 'synthetic-device',
    storageKey: binding.storageKey,
    displayName: 'Synthetic sensor',
    rssi: -50,
    capabilities: const CgmCapabilities(),
  );
  String get key => sensorHistoryKey(sensor);
  String? get bytes => store.values[key];
  Map<String, dynamic> get envelope =>
      jsonDecode(bytes!) as Map<String, dynamic>;
  SensorHistoryRepository restart() => SensorHistoryRepository(
    store,
    monotonicNow: () => Duration.zero,
    utcNow: () => wall,
  );
  CgmReading reading(int minute, {DateTime? at, double value = 100}) =>
      CgmReading(
        valueMgdl: value,
        source: CgmRecordSource.vendor,
        sensorMinute: minute,
        recordedAt: at ?? wall,
        rawValue: 500,
        qualifier: 0,
        isDisplayProvisional: true,
      );
  LibreGen1HistoricalReading slot(
    int packet,
    int minute,
    LibreGen1BleHistoryKind kind, {
    double value = 100,
  }) => LibreGen1HistoricalReading(
    reading: reading(
      minute,
      at: wall.subtract(Duration(minutes: packet - minute)),
      value: value,
    ),
    kind: kind,
  );
  List<LibreGen1HistoricalReading> slots(int packet) => [
    for (final offset in [2, 4, 6, 7, 12, 15])
      slot(packet, packet - offset, LibreGen1BleHistoryKind.trend),
    for (final offset in [0, 15, 30])
      slot(
        packet,
        ((packet - 2) ~/ 15) * 15 - offset,
        LibreGen1BleHistoryKind.history,
      ),
  ];
  Future<LibreGen1ObservationCommit> commit(
    int minute, {
    bool current = true,
    List<LibreGen1HistoricalReading> history = const [],
  }) => LibreGen1HistoryObservationStore(repository).commit(
    binding,
    sensorMinute: minute,
    receivedAt: wall,
    reading: current ? reading(minute) : null,
    historicalReadings: history,
  );
  Future<void> nfc(int scan, List<int> minutes) async {
    final owner = Object();
    final ticket = await repository.beginNfcHistoryImport(
      binding,
      connectionOwner: owner,
    );
    await repository.importNfcHistory(
      ticket,
      connectionOwner: owner,
      scanMinute: scan,
      scanReceivedAt: wall,
      samples: [
        for (final minute in minutes)
          LibreNfcHistorySample(
            reading: reading(
              minute,
              at: wall.subtract(Duration(minutes: scan - minute)),
            ),
            firstReceivedAt: wall,
            origin: LibreHistoryOrigin.nfcHistory,
          ),
      ],
    );
  }

  ArchivedSensorSession archiveOwner(int count) {
    final id = base64Url
        .encode(
          utf8.encode(
            '${binding.driverId}|${binding.storageKey}|${wall.millisecondsSinceEpoch}',
          ),
        )
        .replaceAll('=', '');
    return ArchivedSensorSession(
      id: id,
      historyKey: 'openHealth.history.archive.$id',
      storageKey: binding.storageKey,
      driverId: binding.driverId,
      deviceId: sensor.deviceId,
      displayName: sensor.displayName,
      reason: SensorArchiveReason.disconnected,
      readingCount: count,
      endedAt: wall,
    );
  }
}

final class _Store implements HealthStateStore {
  final values = <String, String>{};
  int writes = 0;
  bool failWrite = false;
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async {
    writes++;
    if (gate case final pending?) {
      if (!entered.isCompleted) entered.complete();
      await pending.future;
    }
    if (failWrite) throw StateError('Synthetic uncertain write.');
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
}
