import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export_data.dart';
import 'package:openglucose/src/sensor_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture h;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    h = _Fixture();
  });

  test('schema two preserves every stored evidence pair and order', () {
    final before = Map<String, String>.of(h.store.values);
    final data = h.read();
    expect(data.hasAcquisitionEvidence, isTrue);
    expect(data.session.toJson(), h.owner.toJson());
    expect(data.acquisitionEntries!.map(_entryJson), h.entries.map(_entryJson));
    expect(
      data.readings.map((entry) => entry.toJson()),
      h.entries.map((entry) => entry.reading.toJson()),
    );
    expect(() => data.acquisitionEntries!.clear(), throwsUnsupportedError);
    expect(data.readings.clear, throwsUnsupportedError);
    expect(h.store.values, before);
    expect(h.store.mutations, 0);
    expect(h.store.readKeys, isNot(contains(h.activeKey)));
    expect(data.toString(), 'ArchivedSensorExportData(data: <redacted>)');
  });

  test(
    'active removal, corruption, clear tombstone and quarantine do not own immutable archive export',
    () async {
      h.store.values[h.activeKey] = 'not-json';
      expect(h.read().readings, hasLength(4));
      h.store.values.remove(h.activeKey);
      expect(h.read().readings, hasLength(4));
      h.store.values[h.activeKey] = jsonEncode(h.activeEnvelope);
      await h.repository.clear(h.activeKey);
      expect(h.repository.readCommittedHistory(h.activeKey), isEmpty);
      expect(h.read().readings, hasLength(4));
      h.store.failAfterWrite = h.activeKey;
      final receipt = DateTime.now().toUtc();
      await expectLater(
        h.repository.commitLibre(
          h.binding,
          sensorMinute: 181,
          receivedAt: receipt,
        ),
        throwsStateError,
      );
      expect(h.repository.isQuarantined(h.activeKey), isTrue);
      expect(
        h.read().acquisitionEntries!.map(_entryJson),
        h.entries.map(_entryJson),
      );
    },
  );

  test(
    'other same-bootstrap archives are never merged or used as provenance',
    () {
      final other = h.ownerJson
        ..['id'] = _archiveId(h.owner.driverId, h.owner.storageKey, 2)
        ..['historyKey'] =
            'openHealth.history.archive.${_archiveId(h.owner.driverId, h.owner.storageKey, 2)}';
      h.store.values['openHealth.sensorArchive'] = jsonEncode([
        h.ownerJson,
        other,
      ]);
      h.store.values[other['historyKey']! as String] =
          'corrupt unrelated segment';
      expect(h.read().readings, hasLength(4));
      expect(h.store.readKeys, isNot(contains(other['historyKey'])));
    },
  );

  for (final field in [
    'id',
    'historyKey',
    'driverId',
    'storageKey',
    'readingCount',
    'displayName',
    'reason',
    'warmupMinutes',
    'endedAt',
  ]) {
    test('stale or substituted requested $field is rejected', () {
      final changed = h.ownerJson;
      changed[field] = switch (field) {
        'readingCount' => 3,
        'warmupMinutes' => 61,
        'reason' => 'expired',
        'endedAt' => '2026-09-01T00:00:00.000Z',
        _ => 'substituted',
      };
      final requested = ArchivedSensorSession.fromJson(changed);
      h.expectUnavailable(
        () => h.repository.readArchivedSensorExportData(requested),
      );
    });
  }

  for (final field in ['id', 'historyKey', 'driverId', 'storageKey']) {
    test('missing persisted $field never reconstructs an owner', () {
      h.manifest(h.ownerJson..remove(field));
      h.expectUnavailable(h.read);
    });
  }

  test(
    'duplicate or conflicting owner references reject instead of selecting first',
    () {
      for (final second in [h.ownerJson, h.ownerJson..['id'] = 'conflicting']) {
        h.store.values['openHealth.sensorArchive'] = jsonEncode([
          h.ownerJson,
          second,
        ]);
        h.expectUnavailable(h.read);
      }
    },
  );

  test('missing manifest and removed owner reject even with intact bytes', () {
    h.store.values.remove('openHealth.sensorArchive');
    h.expectUnavailable(h.read);
    h.store.values['openHealth.sensorArchive'] = '[]';
    h.expectUnavailable(h.read);
  });

  for (final change in <String, Object?>{
    'unknownField': 'future',
    'readingCount': 4.0,
    'reason': 'future',
    'warmupMinutes': -1,
    'startedAt': 'not-a-date',
    'deviceId': 42,
    'sensorVariant': {'source': 'future', 'model': 'Libre 2'},
  }.entries) {
    test(
      'malformed or unknown manifest ${change.key} fails without normalization',
      () {
        h.manifest(h.ownerJson..[change.key] = change.value);
        h.expectUnavailable(h.read);
      },
    );
  }

  test(
    'valid variant preserved; trimmed and unknown nested fields rejected',
    () {
      final variant = {'model': 'Libre 2', 'source': 'nfcPatchInfo'};
      final metadata = h.ownerJson..['sensorVariant'] = variant;
      final requested = ArchivedSensorSession.fromJson(metadata);
      h.manifest(metadata);
      final parsed = CgmSensorVariant.fromJson(variant).toJson();
      // Use only the shared typed source vocabulary, without inventing support.
      metadata['sensorVariant'] = parsed;
      h.manifest(metadata);
      final canonical = ArchivedSensorSession.fromJson(metadata);
      expect(
        h.repository
            .readArchivedSensorExportData(canonical)
            .session
            .sensorVariant!
            .toJson(),
        parsed,
      );
      metadata['sensorVariant'] = {...parsed, 'model': ' Libre 2 '};
      h.manifest(metadata);
      h.expectUnavailable(
        () => h.repository.readArchivedSensorExportData(requested),
      );
      metadata['sensorVariant'] = {...parsed, 'future': 'field'};
      h.manifest(metadata);
      h.expectUnavailable(
        () => h.repository.readArchivedSensorExportData(canonical),
      );
    },
  );

  for (final change in <String, Object?>{
    'schemaVersion': 4,
    'kind': 'futureArchive',
    'driverId': 'aidex',
    'storageKey': 'libre2-gen1:other-bootstrap',
    'sensorBindingDigest': 'invalid',
    'readings': [],
    'unexpected': 1,
  }.entries) {
    test('invalid archive ${change.key} has no plain-reading fallback', () {
      h.store.values[h.owner.historyKey] = jsonEncode(
        h.envelope..[change.key] = change.value,
      );
      h.expectUnavailable(h.read);
    });
  }

  test(
    'missing nonempty schema two fails; corrupted entry cannot become empty export',
    () {
      h.store.values.remove(h.owner.historyKey);
      h.expectUnavailable(h.read);
      h.store.values[h.owner.historyKey] = jsonEncode(
        h.envelope..['readings'] = [null],
      );
      h.expectUnavailable(h.read);
    },
  );

  test(
    'archive provenance source, timestamp and quality contradictions reject',
    () {
      for (final edit in <void Function(Map<String, Object?>)>[
        (entry) => entry['origin'] = 'future',
        (entry) => entry['timestampBasis'] = 'phoneReceipt',
        (entry) => entry['firstReceivedAt'] = null,
        (entry) =>
            (entry['reading']!
                    as Map<String, Object?>)['isDisplayProvisional'] =
                false,
        (entry) => (entry['reading']! as Map<String, Object?>)['recordedAt'] =
            '2026-09-10T13:00:00Z',
      ]) {
        final entries = h.entries.map(_entryJson).toList();
        edit(entries.first);
        h.store.values[h.owner.historyKey] = jsonEncode(
          h.envelope..['readings'] = entries,
        );
        h.expectUnavailable(h.read);
      }
    },
  );

  test('known schema two cannot silently downgrade to a legacy list', () {
    expect(h.read().hasAcquisitionEvidence, isTrue);
    h.store.values[h.owner.historyKey] = jsonEncode(
      h.entries.map((entry) => entry.reading.toJson()).toList(),
    );
    h.expectUnavailable(h.read);
  });

  test(
    'zero-count missing legacy allowed but known empty provenance missing fails',
    () {
      final metadata = h.ownerJson..['readingCount'] = 0;
      final emptyOwner = ArchivedSensorSession.fromJson(metadata);
      h.manifest(metadata);
      h.store.values.remove(emptyOwner.historyKey);
      expect(
        h.repository
            .readArchivedSensorExportData(emptyOwner)
            .hasAcquisitionEvidence,
        isFalse,
      );
      h.store.values[emptyOwner.historyKey] = jsonEncode(
        h.envelope..['readings'] = [],
      );
      expect(
        h.repository
            .readArchivedSensorExportData(emptyOwner)
            .hasAcquisitionEvidence,
        isTrue,
      );
      h.store.values.remove(emptyOwner.historyKey);
      h.expectUnavailable(
        () => h.repository.readArchivedSensorExportData(emptyOwner),
      );
      // No manifest format discriminator exists for historical zero-count rows.
      // A new process can preserve that legacy behavior, not infer a lost format.
      expect(
        SensorHistoryRepository(
          h.store,
        ).readArchivedSensorExportData(emptyOwner).hasAcquisitionEvidence,
        isFalse,
      );
    },
  );

  test(
    'explicit legacy active-history references preserve raw untimed and duplicate rows',
    () {
      final readings = [
        const CgmReading(
          valueMgdl: 72,
          source: CgmRecordSource.raw,
          rawValue: 700,
          qualifier: 9,
          isDisplayProvisional: true,
        ),
        CgmReading(
          valueMgdl: 103.125,
          source: CgmRecordSource.vendor,
          sensorMinute: 100,
          recordedAt: DateTime.parse('2026-08-01T09:02:03.123456+07:00'),
        ),
        CgmReading(
          valueMgdl: 104,
          source: CgmRecordSource.vendor,
          sensorMinute: 100,
          recordedAt: DateTime.utc(2026, 8, 1, 2, 3),
        ),
      ];
      final owner = ArchivedSensorSession(
        id: 'legacy:explicit-owner',
        historyKey: 'openHealth.history.synthetic-legacy',
        storageKey: 'synthetic-legacy',
        driverId: 'aidex',
        deviceId: 'synthetic',
        displayName: 'Sensor',
        reason: SensorArchiveReason.disconnected,
        readingCount: readings.length,
      );
      h.manifest(owner.toJson());
      h.store.values[owner.historyKey] = jsonEncode(
        readings.map((reading) => reading.toJson()).toList(),
      );
      final before = Map<String, String>.of(h.store.values);
      final data = h.repository.readArchivedSensorExportData(owner);
      expect(data.hasAcquisitionEvidence, isFalse);
      expect(data.acquisitionEntries, isNull);
      expect(
        data.readings.map((reading) => reading.toJson()),
        readings.map((reading) => reading.toJson()),
      );
      expect(h.store.values, before);
      expect(h.store.mutations, 0);
    },
  );

  test('opaque non-Libre archive IDs retain exact stored mapping', () {
    for (final id in ['feedback-session', 'session/42']) {
      final owner = ArchivedSensorSession(
        id: id,
        historyKey: 'openHealth.history.archive.$id',
        storageKey: 'synthetic-legacy',
        driverId: 'aidex',
        deviceId: 'synthetic',
        displayName: 'Sensor',
        reason: SensorArchiveReason.disconnected,
        readingCount: 1,
      );
      h.manifest(owner.toJson());
      h.store.values[owner.historyKey] = jsonEncode([
        h.entries.first.reading.toJson(),
      ]);
      final data = h.repository.readArchivedSensorExportData(owner);
      expect(data.session.id, id);
      expect(data.hasAcquisitionEvidence, isFalse);
      expect(data.readings, hasLength(1));
    }
  });

  test(
    'ordinary export does not apply Libre glucose or wire-minute bounds',
    () {
      final owner = ArchivedSensorSession(
        id: 'ordinary-range',
        historyKey: 'openHealth.history.archive.ordinary-range',
        storageKey: 'synthetic-ordinary',
        driverId: 'other-protocol',
        deviceId: 'synthetic',
        displayName: 'Sensor',
        reason: SensorArchiveReason.disconnected,
        readingCount: 3,
      );
      final readings = [
        const CgmReading(
          valueMgdl: 0,
          source: CgmRecordSource.raw,
          rawValue: 0,
        ),
        const CgmReading(
          valueMgdl: -1,
          source: CgmRecordSource.raw,
          sensorMinute: -1,
        ),
        const CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.vendor,
          sensorMinute: 70000,
        ),
      ];
      h.manifest(owner.toJson());
      h.store.values[owner.historyKey] = jsonEncode(
        readings.map((entry) => entry.toJson()).toList(),
      );
      final data = h.repository.readArchivedSensorExportData(owner);
      expect(data.hasAcquisitionEvidence, isFalse);
      expect(
        data.readings.map((entry) => entry.toJson()),
        readings.map((entry) => entry.toJson()),
      );
      final malformed = readings.map((entry) => entry.toJson()).toList();
      malformed.first['sensorMinute'] = 1.5;
      h.store.values[owner.historyKey] = jsonEncode(malformed);
      h.expectUnavailable(
        () => h.repository.readArchivedSensorExportData(owner),
      );
    },
  );

  test('Libre legacy list export retains its strict numeric bounds', () {
    h.store.values[h.owner.historyKey] = jsonEncode([
      for (var i = 0; i < 4; i++)
        CgmReading(
          valueMgdl: i == 0 ? 0 : 100,
          source: CgmRecordSource.raw,
          sensorMinute: i,
        ).toJson(),
    ]);
    h.expectUnavailable(h.read);
    h.store.values[h.owner.historyKey] = jsonEncode([
      for (var i = 0; i < 4; i++)
        CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.vendor,
          sensorMinute: 70000 + i,
        ).toJson(),
    ]);
    h.expectUnavailable(h.read);
  });

  test(
    'uncertain archive write fails closed even if backend bytes look complete',
    () async {
      h.store.values[h.activeKey] = jsonEncode(h.activeEnvelope);
      h.store.values.remove(h.owner.historyKey);
      h.store.failAfterWrite = h.owner.historyKey;
      await expectLater(
        h.repository.writeLibreArchive(
          sensor: h.sensor,
          archiveKey: h.owner.historyKey,
          incoming: h.entries.map((entry) => entry.reading),
        ),
        throwsStateError,
      );
      expect(h.store.values[h.owner.historyKey], isNotNull);
      expect(h.repository.isQuarantined(h.owner.historyKey), isTrue);
      h.expectUnavailable(h.read);
    },
  );

  test(
    'controller uses strict archive export read, not display fallback or a receiver',
    () async {
      final driver = _NoRadioDriver();
      final controller = CgmAppController(
        preferences: await SharedPreferences.getInstance(),
        driver: driver,
        healthStateStore: h.store,
        historyRepository: h.repository,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      final session = controller.archivedSensors.single;
      final data = controller.archivedSensorExportData(session);
      expect(data.hasAcquisitionEvidence, isTrue);
      expect(
        data.acquisitionEntries!.map(_entryJson),
        h.entries.map(_entryJson),
      );
      final before = Map<String, String>.of(h.store.values);
      h.store.values[session.historyKey] = '{';
      h.expectUnavailable(() => controller.archivedSensorExportData(session));
      h.store.values[session.historyKey] = before[session.historyKey]!;
      h.store.values['openHealth.sensorArchive'] = '[]';
      h.expectUnavailable(() => controller.archivedSensorExportData(session));
      expect(driver.calls, 0);
    },
  );
}

class _Fixture {
  _Fixture() {
    manifest(ownerJson);
    store.values[owner.historyKey] = jsonEncode(envelope);
  }
  final store = _Store();
  late final repository = SensorHistoryRepository(store);
  final binding = LibreGen1ObservationBinding(
    bootstrapId: 'synthetic-export-bootstrap',
    sensorBindingDigest: 'a' * 64,
  );
  late final sensor = DiscoveredSensor(
    driverId: binding.driverId,
    deviceId: 'synthetic-device',
    displayName: 'Libre 2',
    storageKey: binding.storageKey,
    rssi: -40,
    capabilities: const CgmCapabilities(),
  );
  String get activeKey => sensorHistoryKey(sensor);
  late final owner = ArchivedSensorSession(
    id: _archiveId(binding.driverId, binding.storageKey, 1),
    historyKey:
        'openHealth.history.archive.${_archiveId(binding.driverId, binding.storageKey, 1)}',
    storageKey: binding.storageKey,
    driverId: binding.driverId,
    deviceId: 'synthetic-device',
    displayName: 'Libre 2',
    reason: SensorArchiveReason.disconnected,
    readingCount: 4,
    warmupMinutes: 60,
    endedAt: DateTime.utc(2026, 9, 10, 12),
  );
  Map<String, Object?> get ownerJson => owner.toJson();
  final receipt = DateTime.utc(2026, 9, 10, 12, 0, 0, 123, 456);
  late final entries = [
    LibreHistoryEntry(
      reading: _reading(165, receipt.subtract(const Duration(minutes: 15))),
      origin: LibreHistoryOrigin.nfcHistory,
      firstReceivedAt: receipt,
      timestampBasis: LibreHistoryTimestampBasis.sensorRelative,
    ),
    LibreHistoryEntry(
      reading: _reading(100, receipt.subtract(const Duration(minutes: 80))),
      origin: LibreHistoryOrigin.legacyUnknown,
      firstReceivedAt: null,
      timestampBasis: LibreHistoryTimestampBasis.legacyUnknown,
    ),
    LibreHistoryEntry(
      reading: _reading(180, receipt),
      origin: LibreHistoryOrigin.nfcTrend,
      firstReceivedAt: receipt,
      timestampBasis: LibreHistoryTimestampBasis.sensorRelative,
    ),
    LibreHistoryEntry(
      reading: _reading(101, receipt.subtract(const Duration(minutes: 79))),
      origin: LibreHistoryOrigin.bleLive,
      firstReceivedAt: receipt.subtract(const Duration(minutes: 79)),
      timestampBasis: LibreHistoryTimestampBasis.phoneReceipt,
    ),
  ];
  Map<String, Object?> get envelope => {
    'schemaVersion': 2,
    'kind': 'libreHistoryArchive',
    'driverId': binding.driverId,
    'storageKey': binding.storageKey,
    'sensorBindingDigest': binding.sensorBindingDigest,
    'readings': entries.map(_entryJson).toList(),
  };
  Map<String, Object?> get activeEnvelope => {
    ...envelope..remove('kind'),
    'observedMinute': 101,
    'frontierProvenance': 'observed',
    'clearedThroughMinute': null,
    'lastNfcScanMinute': 180,
    'clearRevision': 0,
  };
  void manifest(Map<String, Object?> value) =>
      store.values['openHealth.sensorArchive'] = jsonEncode([value]);
  ArchivedSensorExportData read() =>
      repository.readArchivedSensorExportData(owner);
  void expectUnavailable(Object? Function() operation) {
    final before = Map<String, String>.of(store.values);
    final mutations = store.mutations;
    expect(
      operation,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'closed message',
          'Stored sensor history is unavailable.',
        ),
      ),
    );
    expect(store.values, before);
    expect(store.mutations, mutations);
  }
}

CgmReading _reading(int minute, DateTime at) => CgmReading(
  valueMgdl: 100.125,
  source: CgmRecordSource.vendor,
  sensorMinute: minute,
  recordedAt: at,
  isDisplayProvisional: true,
);
String _archiveId(String driver, String storage, int discriminator) => base64Url
    .encode(utf8.encode('$driver|$storage|$discriminator'))
    .replaceAll('=', '');
Map<String, Object?> _entryJson(LibreHistoryEntry entry) => {
  'reading': entry.reading.toJson(),
  'origin': entry.origin.name,
  'firstReceivedAt': entry.firstReceivedAt?.toUtc().toIso8601String(),
  'timestampBasis': entry.timestampBasis.name,
};

class _Store implements HealthStateStore {
  final values = <String, String>{};
  final readKeys = <String>[];
  int mutations = 0;
  String? failAfterWrite;
  @override
  Future<void> initialize() async {}
  @override
  String? getString(String key) {
    readKeys.add(key);
    return values[key];
  }

  @override
  Future<void> remove(String key) async {
    mutations++;
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    mutations++;
    values[key] = value;
    if (failAfterWrite == key) {
      failAfterWrite = null;
      throw StateError('synthetic-private-write-failure');
    }
  }
}

class _NoRadioDriver implements CgmDriver {
  int calls = 0;
  @override
  String get driverId => 'aidex';
  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    calls++;
    throw StateError('No receiver required for export');
  }

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    calls++;
  }
}
