import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/context_bridge/context_attachment_fact.dart';
import 'package:openglucose/src/context_bridge/context_bridge.dart';
import 'package:openglucose/src/context_bridge/context_bridge_models.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _now = DateTime.utc(2026, 8, 24, 12);

const RecentObservedRisePolicy _risePolicy = RecentObservedRisePolicy(
  minimumRiseMgdl: 20,
  lookbackWindow: Duration(hours: 2),
  maximumCandidateAge: Duration(minutes: 45),
  maximumReadingAge: Duration(minutes: 6),
  maximumGap: Duration(minutes: 6),
  minimumWindowReadings: 5,
  minimumEpisodeReadings: 4,
  minimumEpisodeSpan: Duration(minutes: 15),
  attachmentWindowBeforeEpisode: Duration(minutes: 30),
  attachmentWindowAfterEpisode: Duration(minutes: 15),
);

void main() {
  group('ContextBridge', () {
    test(
      'maps local context with opaque identities and leaves prompts disabled by default',
      () async {
        final repository = _BridgeRepository();
        await repository.upsertActivitySamples(<ActivitySample>[
          _activity(
            externalId: 'external-activity-id-must-not-leak',
            source: DataSource.appleHealth,
            start: _now.subtract(const Duration(minutes: 50)),
          ),
          _activity(
            externalId: 'external-activity-id-must-not-leak',
            source: DataSource.healthConnect,
            start: _now.subtract(const Duration(minutes: 40)),
          ),
          ActivitySample(
            start: _now.subtract(const Duration(minutes: 30)),
            end: _now.subtract(const Duration(minutes: 20)),
            type: ActivityType.workout,
            source: DataSource.manual,
            workoutLabel: 'manual activity stays outside imported context',
          ),
        ]);
        repository.entries['internal-diary-id'] = FastJournalEntry(
          id: 'internal-diary-id',
          kind: FastJournalKind.meal,
          occurredAt: _now.subtract(const Duration(minutes: 20)),
          label: 'Lunch',
        );

        final harness = await _BridgeHarness.create(repository: repository);
        addTearDown(harness.dispose);

        final snapshot = harness.bridge.snapshot;
        expect(snapshot.loadState, ContextBridgeLoadState.ready);
        expect(snapshot.suggestionsEnabled, isFalse);
        expect(
          snapshot.suggestionAvailability,
          ContextBridgeSuggestionAvailability.disabledByPolicy,
        );
        expect(snapshot.attachmentSuggestion, isNull);
        expect(
          snapshot.importedAvailability,
          ContextBridgeContextAvailability.partial,
        );
        expect(snapshot.importedItems, hasLength(2));
        expect(
          snapshot.importedItems.map((item) => item.source),
          <DataSource>[DataSource.appleHealth, DataSource.healthConnect],
        );
        expect(
          snapshot.importedItems.map((item) => item.id).toSet(),
          hasLength(2),
        );
        expect(
          snapshot.diaryAvailability,
          ContextBridgeContextAvailability.available,
        );
        expect(snapshot.diaryItems, hasLength(1));
        expect(snapshot.glucoseReadings, hasLength(8));
        expect(
          repository.lastJournalWindow?.start,
          _now.subtract(const Duration(days: 7)),
        );
        expect(
          repository.lastJournalWindow?.end,
          _now.add(const Duration(milliseconds: 1)),
        );
        expect(repository.lastJournalLimit, 250);

        final publicValues = <Object?>[
          snapshot.glucoseReadings
              .map(
                (reading) => <Object?>[
                  reading.id,
                  reading.recordedAt,
                  reading.valueMgdl,
                  reading.source,
                ],
              )
              .toList(growable: false),
          snapshot.importedItems
              .map(
                (item) => <Object?>[
                  item.id,
                  item.kind,
                  item.start,
                  item.end,
                  item.source,
                  item.recordingMethod,
                ],
              )
              .toList(growable: false),
          snapshot.diaryItems
              .map(
                (item) => <Object?>[
                  item.id,
                  item.kind,
                  item.occurredAt,
                  item.label,
                ],
              )
              .toList(growable: false),
        ].toString();
        for (final sensitive in <String>[
          'bridge:alpha:restricted-storage-key',
          'device-alpha-private-address',
          'LIVE-SERIAL-alpha',
          'raw-packet-alpha',
          'external-activity-id-must-not-leak',
          'internal-diary-id',
        ]) {
          expect(publicValues, isNot(contains(sensitive)));
        }
        for (final id in <String>[
          ...snapshot.glucoseReadings.map((reading) => reading.id),
          ...snapshot.importedItems.map((item) => item.id),
          ...snapshot.diaryItems.map((item) => item.id),
        ]) {
          expect(id, startsWith('ctx-'));
        }
      },
    );

    test(
      'uses the full post-warmup active history, not chart crop settings',
      () async {
        final harness = await _BridgeHarness.create();
        addTearDown(harness.dispose);

        harness.controller.updateDisplayPreferences(
          harness.controller.displayPreferences.copyWith(cropFirstSamples: 6),
        );
        await harness.bridge.reload();

        expect(harness.controller.visibleHistory, hasLength(2));
        expect(harness.bridge.snapshot.glucoseReadings, hasLength(8));
      },
    );

    test(
      'isolates opaque reading identities when the active session changes',
      () async {
        final harness = await _BridgeHarness.create();
        addTearDown(harness.dispose);
        final firstIds = harness.bridge.snapshot.glucoseReadings
            .map((reading) => reading.id)
            .toList(growable: false);
        final beta = _sensor('beta');

        harness.session.emit(
          _sessionSnapshot(beta, history: _qualifiedHistory()),
        );
        await harness.bridge.reload();

        final second = harness.bridge.snapshot;
        expect(second.glucoseReadings, hasLength(8));
        expect(
          second.glucoseReadings.map((reading) => reading.id),
          isNot(orderedEquals(firstIds)),
        );
        expect(
          second.glucoseReadings.map((reading) => reading.valueMgdl),
          _qualifiedHistory().map((reading) => reading.valueMgdl),
        );
      },
    );

    test(
      'suppresses an explicit candidate after its bounded attachment fact',
      () async {
        final repository = _BridgeRepository();
        repository.entries['linked-diary'] = FastJournalEntry(
          id: 'linked-diary',
          kind: FastJournalKind.meal,
          occurredAt: _now.subtract(const Duration(minutes: 20)),
          label: 'Dinner',
        );
        final harness = await _BridgeHarness.create(
          repository: repository,
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final candidate = harness.bridge.snapshot.attachmentSuggestion;
        expect(candidate, isNotNull);

        repository.facts['attachment-fact'] = ContextAttachmentFact(
          id: 'attachment-fact',
          journalEntryId: 'linked-diary',
          candidateId: candidate!.id,
          calculationVersion: candidate.calculationVersion,
          episodeStart: candidate.episodeStart,
          peakAt: candidate.peakAt,
          attachmentWindowStart: candidate.attachmentWindowStart,
          attachmentWindowEnd: candidate.attachmentWindowEnd,
          occurredAt: _now.subtract(const Duration(minutes: 20)),
        );
        await harness.bridge.reload();

        expect(
          harness.bridge.snapshot.suggestionAvailability,
          ContextBridgeSuggestionAvailability.attachmentAlreadyRecorded,
        );
        expect(harness.bridge.snapshot.attachmentSuggestion, isNull);
      },
    );

    test(
      'reloads its cache from a local context signal and controller updates',
      () async {
        final repository = _BridgeRepository();
        final signal = ChangeNotifier();
        final harness = await _BridgeHarness.create(
          repository: repository,
          contextSignal: signal,
        );
        addTearDown(() async {
          signal.dispose();
          await harness.dispose();
        });
        expect(harness.bridge.snapshot.diaryItems, isEmpty);

        repository.entries['new-diary'] = FastJournalEntry(
          id: 'new-diary',
          kind: FastJournalKind.meal,
          occurredAt: _now.subtract(const Duration(minutes: 10)),
          label: 'Dinner',
        );
        signal.notifyListeners();
        await _drainBridgeQueue();
        expect(harness.bridge.snapshot.diaryItems, hasLength(1));

        final expandedHistory = <CgmReading>[
          ..._qualifiedHistory(),
          _reading(
            _now.subtract(const Duration(minutes: 2)),
            123,
            sensorMinute: 178,
          ),
        ];
        harness.session.emit(
          _sessionSnapshot(_sensor('alpha'), history: expandedHistory),
        );
        await _drainBridgeQueue();
        expect(harness.bridge.snapshot.glucoseReadings, hasLength(9));
      },
    );

    test('reports empty or incomplete local context conservatively', () async {
      final empty = await _BridgeHarness.create();
      addTearDown(empty.dispose);
      expect(
        empty.bridge.snapshot.importedAvailability,
        ContextBridgeContextAvailability.noLocalRecords,
      );
      expect(
        empty.bridge.snapshot.diaryAvailability,
        ContextBridgeContextAvailability.noLocalRecords,
      );

      final partialRepository = _BridgeRepository()..failActivityQuery = true;
      final partial = await _BridgeHarness.create(
        repository: partialRepository,
      );
      addTearDown(partial.dispose);
      expect(
        partial.bridge.snapshot.importedAvailability,
        ContextBridgeContextAvailability.partial,
      );
      expect(
        partial.bridge.snapshot.diaryAvailability,
        ContextBridgeContextAvailability.noLocalRecords,
      );
    });

    for (final scenario
        in <
          ({
            String name,
            List<CgmReading> Function() history,
            ContextBridgeSuggestionAvailability availability,
          })
        >[
          (
            name: 'invalid readings',
            history: () => <CgmReading>[
              ..._qualifiedHistory(),
              _reading(
                _now.subtract(const Duration(minutes: 2)),
                double.nan,
                sensorMinute: 178,
              ),
            ],
            availability: ContextBridgeSuggestionAvailability.invalidReading,
          ),
          (
            name: 'mixed sources',
            history: () => <CgmReading>[
              ..._qualifiedHistory().take(7),
              _reading(
                _now,
                124,
                sensorMinute: 176,
                source: CgmRecordSource.broadcast,
              ),
            ],
            availability: ContextBridgeSuggestionAvailability.mixedSources,
          ),
          (
            name: 'duplicate timestamps',
            history: () => <CgmReading>[
              ..._qualifiedHistory(),
              _reading(
                _now.subtract(const Duration(minutes: 5)),
                127,
                sensorMinute: 175,
              ),
            ],
            availability:
                ContextBridgeSuggestionAvailability.duplicateTimestamp,
          ),
          (
            name: 'provisional readings',
            history: () => <CgmReading>[
              ..._qualifiedHistory(),
              _reading(
                _now.subtract(const Duration(minutes: 2)),
                123,
                sensorMinute: 178,
                provisional: true,
              ),
            ],
            availability:
                ContextBridgeSuggestionAvailability.provisionalReading,
          ),
          (
            name: 'future readings',
            history: () => <CgmReading>[
              ..._qualifiedHistory(),
              _reading(
                _now.add(const Duration(minutes: 1)),
                123,
                sensorMinute: 178,
              ),
            ],
            availability: ContextBridgeSuggestionAvailability.futureReading,
          ),
        ]) {
      test(
        'fails observed-rise suggestions closed for ${scenario.name}',
        () async {
          final harness = await _BridgeHarness.create(
            history: scenario.history(),
            suggestionPolicy:
                ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                  recentRisePolicy: _risePolicy,
                  disclosure: 'This is non-clinical and not medical advice.',
                ),
          );
          addTearDown(harness.dispose);

          expect(harness.bridge.snapshot.suggestionsEnabled, isTrue);
          expect(
            harness.bridge.snapshot.suggestionAvailability,
            scenario.availability,
          );
          expect(harness.bridge.snapshot.attachmentSuggestion, isNull);
        },
      );
    }
  });
}

ActivitySample _activity({
  required String externalId,
  required DataSource source,
  required DateTime start,
}) {
  final platform = HealthSourcePlatform.fromDataSource(source)!;
  return ActivitySample(
    start: start,
    end: start.add(const Duration(minutes: 20)),
    type: ActivityType.workout,
    source: source,
    workoutLabel: 'Workout',
    provenance: HealthSampleProvenance(
      identity: HealthImportIdentity(
        platform: platform,
        externalId: externalId,
      ),
      sourceApplicationId: 'source.application.secret',
      sourceDevice: 'source-device-secret',
      recordingMethod: HealthRecordingMethod.automatic,
    ),
  );
}

DiscoveredSensor _sensor(String suffix) => DiscoveredSensor(
  driverId: 'context-bridge-driver',
  deviceId: 'device-$suffix-private-address',
  displayName: 'Test sensor $suffix',
  storageKey: 'bridge:$suffix:restricted-storage-key',
  rssi: -45,
  capabilities: const CgmCapabilities(supportsHistory: true),
  metadata: <String, String>{
    'serial': 'LIVE-SERIAL-$suffix',
    'rawPacket': 'raw-packet-$suffix',
  },
);

CgmSessionSnapshot _sessionSnapshot(
  DiscoveredSensor sensor, {
  required List<CgmReading> history,
}) => CgmSessionSnapshot(
  stage: CgmSyncStage.ready,
  statusText: 'Ready',
  sensor: sensor,
  capabilities: sensor.capabilities,
  history: history,
  latestReading: history.last,
  sessionInfo: CgmSessionInfo(
    sessionStart: _now.subtract(const Duration(hours: 3)),
    serial: 'LIVE-SERIAL-${sensor.storageKey.split(':')[1]}',
  ),
  metadata: <String, String>{'packet': 'raw-packet-${sensor.storageKey}'},
);

List<CgmReading> _qualifiedHistory() => <CgmReading>[
  _reading(_now.subtract(const Duration(minutes: 35)), 120, sensorMinute: 143),
  _reading(_now.subtract(const Duration(minutes: 30)), 100, sensorMinute: 148),
  _reading(_now.subtract(const Duration(minutes: 25)), 110, sensorMinute: 153),
  _reading(_now.subtract(const Duration(minutes: 20)), 125, sensorMinute: 158),
  _reading(_now.subtract(const Duration(minutes: 15)), 130, sensorMinute: 163),
  _reading(_now.subtract(const Duration(minutes: 10)), 128, sensorMinute: 168),
  _reading(_now.subtract(const Duration(minutes: 5)), 126, sensorMinute: 173),
  _reading(_now, 124, sensorMinute: 176),
];

CgmReading _reading(
  DateTime recordedAt,
  double valueMgdl, {
  required int sensorMinute,
  CgmRecordSource source = CgmRecordSource.vendor,
  bool provisional = false,
}) => CgmReading(
  valueMgdl: valueMgdl,
  source: source,
  sensorMinute: sensorMinute,
  recordedAt: recordedAt,
  isDisplayProvisional: provisional,
);

Future<void> _drainBridgeQueue() async {
  for (var index = 0; index < 16; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _BridgeHarness {
  _BridgeHarness({
    required this.controller,
    required this.session,
    required this.bridge,
    required this.lifecycle,
  });

  final CgmAppController controller;
  final _BridgeSession session;
  final ContextBridge bridge;
  final AppHealthRepositoryLifecycle lifecycle;

  static Future<_BridgeHarness> create({
    _BridgeRepository? repository,
    List<CgmReading>? history,
    ContextBridgeSuggestionPolicy suggestionPolicy =
        const ContextBridgeSuggestionPolicy.disabled(),
    Listenable? contextSignal,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _sensor('alpha');
    final session = _BridgeSession(
      _sessionSnapshot(sensor, history: history ?? _qualifiedHistory()),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: _BridgeDriver(session),
      reconnectDelay: Duration.zero,
    );
    await controller.initialize();
    await controller.connect(sensor);
    final lifecycle = AppHealthRepositoryLifecycle(
      () async => repository ?? _BridgeRepository(),
    );
    final bridge = ContextBridge(
      controller: controller,
      repositoryLifecycle: lifecycle,
      clock: () => _now,
      suggestionPolicy: suggestionPolicy,
      contextChangeSignal: contextSignal,
    );
    await bridge.start();
    // Connecting a controller can still emit its final ready snapshot while
    // the bridge starts. A second explicit reload gives this fixture the same
    // settled state a presentation consumer observes after that emission.
    await bridge.reload();
    return _BridgeHarness(
      controller: controller,
      session: session,
      bridge: bridge,
      lifecycle: lifecycle,
    );
  }

  Future<void> dispose() async {
    bridge.dispose();
    controller.dispose();
    await session.close();
    await lifecycle.dispose();
  }
}

class _BridgeRepository extends InMemoryHealthRepository
    implements FastJournalStore, ContextAttachmentFactStore {
  final Map<String, FastJournalEntry> entries = <String, FastJournalEntry>{};
  final Map<String, ContextAttachmentFact> facts =
      <String, ContextAttachmentFact>{};
  TimeWindow? lastJournalWindow;
  int? lastJournalLimit;
  bool failActivityQuery = false;

  @override
  Future<List<ActivitySample>> queryActivitySamples({
    TimeWindow window = TimeWindow.all,
    Set<ActivityType>? types,
  }) async {
    if (failActivityQuery) {
      throw StateError('Simulated local activity read failure');
    }
    return super.queryActivitySamples(window: window, types: types);
  }

  @override
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    TimeWindow window = TimeWindow.all,
    required int limit,
  }) async {
    lastJournalWindow = window;
    lastJournalLimit = limit;
    final values =
        entries.values
            .where((entry) => window.contains(entry.occurredAt))
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = right.occurredAt.compareTo(left.occurredAt);
            return byTime != 0 ? byTime : right.id.compareTo(left.id);
          });
    return values.take(limit).toList(growable: false);
  }

  @override
  Future<bool> isFastJournalRiseClaimed({
    required DateTime riseStartedAt,
  }) async => entries.values.any(
    (entry) =>
        entry.riseReference?.startedAt.toUtc().isAtSameMomentAs(
          riseStartedAt.toUtc(),
        ) ??
        false,
  );

  @override
  Future<FastJournalEntry> saveFastJournalEntry({
    required FastJournalEntry entry,
    FastJournalRiseReference? requestedRise,
  }) async {
    final saved = requestedRise == null
        ? entry
        : entry.copyWith(riseReference: requestedRise);
    entries[saved.id] = saved;
    return saved;
  }

  @override
  Future<void> saveContextAttachmentFact(ContextAttachmentFact fact) async {
    fact.toJson();
    facts[fact.id] = fact;
  }

  @override
  Future<List<ContextAttachmentFact>> queryContextAttachmentFacts({
    TimeWindow window = TimeWindow.all,
    String? candidateId,
  }) async => facts.values
      .where((fact) => window.contains(fact.occurredAt))
      .where((fact) => candidateId == null || fact.candidateId == candidateId)
      .toList(growable: false);
}

class _BridgeDriver implements CgmDriver {
  _BridgeDriver(this.session);

  final _BridgeSession session;

  @override
  String get driverId => 'context-bridge-driver';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor _) async => session;
}

class _BridgeSession implements CgmSession {
  _BridgeSession(this._current);

  CgmSessionSnapshot _current;
  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);

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
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

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
}
