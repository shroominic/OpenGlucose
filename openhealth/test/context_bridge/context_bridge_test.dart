import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/context_bridge/context_attachment_fact.dart';
import 'package:openglucose/src/context_bridge/context_attachment_writer.dart';
import 'package:openglucose/src/context_bridge/context_bridge.dart';
import 'package:openglucose/src/context_bridge/context_bridge_models.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';
import 'package:openglucose/src/session_presentation.dart';
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
        expect(repository.lastJournalLimit, 251);
        expect(repository.heartRateQueryCalls, 0);

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
      'does not query local context until the reader surface is enabled',
      () async {
        final repository = _BridgeRepository();
        final enabled = ValueNotifier<bool>(false);
        final harness = await _BridgeHarness.create(
          repository: repository,
          contextSettingsSignal: enabled,
          isContextViewEnabled: () => enabled.value,
        );
        addTearDown(() async {
          enabled.dispose();
          await harness.dispose();
        });

        expect(repository.acquireCalls, 0);
        expect(harness.bridge.snapshot.loadState, ContextBridgeLoadState.idle);
        expect(harness.bridge.snapshot.glucoseReadings, isEmpty);

        enabled.value = true;
        await _drainBridgeQueue();

        expect(repository.acquireCalls, 1);
        expect(harness.bridge.snapshot.loadState, ContextBridgeLoadState.ready);
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
        final harness = await _BridgeHarness.create(
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final first = harness.bridge.snapshot;
        final firstIds = first.glucoseReadings
            .map((reading) => reading.id)
            .toList(growable: false);
        final firstEpisode = first.attachmentSuggestion?.episodeKey;
        expect(firstEpisode, isNotNull);
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
        expect(
          second.attachmentSuggestion?.episodeKey.value,
          isNot(firstEpisode?.value),
        );
      },
    );

    test(
      'rejects readings whose post-warmup placement cannot be proven',
      () async {
        final unplaced = List<CgmReading>.generate(
          8,
          (_) => const CgmReading(
            valueMgdl: 120,
            source: CgmRecordSource.vendor,
          ),
          growable: false,
        );
        final harness = await _BridgeHarness.create(
          history: unplaced,
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);

        expect(
          harness.bridge.snapshot.glucoseAvailability,
          ContextBridgeGlucoseAvailability.noPostWarmupReadings,
        );
        expect(
          harness.bridge.snapshot.suggestionAvailability,
          ContextBridgeSuggestionAvailability.unprovenPostWarmupReading,
        );
        expect(harness.bridge.snapshot.glucoseReadings, isEmpty);
        expect(harness.bridge.snapshot.attachmentSuggestion, isNull);
      },
    );

    test(
      'settles retained unproven, non-ready, stopped, and expired sessions as inactive',
      () async {
        final cases = <({String name, CgmSessionSnapshot snapshot})>[
          (
            name: 'non-ready',
            snapshot: _sessionSnapshot(
              _sensor('alpha'),
              history: _qualifiedHistory(),
              stage: CgmSyncStage.connecting,
            ),
          ),
          (
            name: 'unknown session start',
            snapshot: _sessionSnapshot(
              _sensor('alpha'),
              history: _qualifiedHistory(),
              sessionInfo: const CgmSessionInfo(),
            ),
          ),
          (
            name: 'stopped',
            snapshot: _sessionSnapshot(
              _sensor('alpha'),
              history: _qualifiedHistory(),
              sessionInfo: CgmSessionInfo(
                sessionStart: _now.subtract(const Duration(hours: 3)),
                sessionStopped: true,
              ),
            ),
          ),
          (
            name: 'expired',
            snapshot: _sessionSnapshot(
              _sensor('alpha'),
              history: _qualifiedHistory(),
              health: const CgmHealthSnapshot(expired: true),
            ),
          ),
        ];
        for (final testCase in cases) {
          final harness = await _BridgeHarness.create(
            suggestionPolicy:
                ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                  recentRisePolicy: _risePolicy,
                  disclosure: 'This is non-clinical and not medical advice.',
                ),
          );
          try {
            harness.session.emit(testCase.snapshot);
            // The app controller deliberately retires stopped/expired sensor
            // sessions. Let that normal lifecycle settle before disposing the
            // fixture, then verify the bridge did not retain its history.
            await _drainBridgeQueue();
            await harness.bridge.reload();

            expect(
              harness.bridge.snapshot.loadState,
              ContextBridgeLoadState.ready,
              reason: testCase.name,
            );
            expect(
              harness.bridge.snapshot.glucoseAvailability,
              ContextBridgeGlucoseAvailability.noActiveSession,
              reason: testCase.name,
            );
            expect(
              harness.bridge.snapshot.suggestionAvailability,
              ContextBridgeSuggestionAvailability.noActiveSession,
              reason: testCase.name,
            );
            expect(
              harness.bridge.snapshot.glucoseReadings,
              isEmpty,
              reason: testCase.name,
            );
          } finally {
            await _drainBridgeQueue();
            await harness.dispose();
          }
        }
      },
    );

    test(
      'rejects a ready unflagged session after its sensor lifetime',
      () async {
        // Use a demo-shaped driver so the app controller deliberately does not
        // retire this snapshot. This proves the bridge admits no readings or
        // suggestion during the controller's normal retirement window.
        final harness = await _BridgeHarness.create(
          demoDriver: true,
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final pastLifetime = _sessionSnapshot(
          _sensor('alpha'),
          history: _qualifiedHistory(),
          sessionInfo: CgmSessionInfo(
            sessionStart: _now.subtract(
              kSensorLifeDuration + const Duration(seconds: 1),
            ),
          ),
        );

        expect(pastLifetime.stage, CgmSyncStage.ready);
        expect(pastLifetime.health.expired, isFalse);
        harness.session.emit(pastLifetime);
        await harness.bridge.reload();

        expect(
          harness.bridge.snapshot.loadState,
          ContextBridgeLoadState.ready,
        );
        expect(
          harness.bridge.snapshot.glucoseAvailability,
          ContextBridgeGlucoseAvailability.noActiveSession,
        );
        expect(
          harness.bridge.snapshot.suggestionAvailability,
          ContextBridgeSuggestionAvailability.noActiveSession,
        );
        expect(harness.bridge.snapshot.glucoseReadings, isEmpty);
        expect(harness.bridge.snapshot.attachmentSuggestion, isNull);
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
          candidateId: candidate!.candidateId,
          episodeKey: candidate.episodeKey,
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
      'suppresses a claimed episode after a later peak changes its candidate',
      () async {
        final repository = _BridgeRepository();
        repository.entries['linked-diary'] = FastJournalEntry(
          id: 'linked-diary',
          kind: FastJournalKind.meal,
          occurredAt: _now.subtract(const Duration(minutes: 10)),
          label: 'Dinner',
        );
        final harness = await _BridgeHarness.create(
          repository: repository,
          history: _evolvingPeakHistory(),
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final initial = harness.bridge.snapshot.attachmentSuggestion;
        expect(initial, isNotNull);
        final initialSuggestion = initial!;
        expect(initialSuggestion.id, startsWith('ctx-candidate-'));
        expect(initialSuggestion.episodeKey.value, startsWith('ctx-episode-'));
        expect(
          <Object?>[
            initialSuggestion.id,
            initialSuggestion.episodeKey.value,
          ].toString(),
          isNot(
            contains('bridge:alpha:restricted-storage-key'),
          ),
        );

        harness.session.emit(
          _sessionSnapshot(
            _sensor('alpha'),
            history: _evolvingPeakHistory(includeLaterPeak: true),
          ),
        );
        await harness.bridge.reload();
        final evolved = harness.bridge.snapshot.attachmentSuggestion;
        expect(evolved, isNotNull);
        expect(evolved!.id, isNot(initialSuggestion.id));
        expect(evolved.episodeKey.value, initialSuggestion.episodeKey.value);

        repository.facts['attachment-fact'] = ContextAttachmentFact(
          id: 'attachment-fact',
          journalEntryId: 'linked-diary',
          candidateId: initialSuggestion.candidateId,
          episodeKey: initialSuggestion.episodeKey,
          calculationVersion: initialSuggestion.calculationVersion,
          episodeStart: initialSuggestion.episodeStart,
          peakAt: initialSuggestion.peakAt,
          attachmentWindowStart: initialSuggestion.attachmentWindowStart,
          attachmentWindowEnd: initialSuggestion.attachmentWindowEnd,
          occurredAt: _now.subtract(const Duration(minutes: 10)),
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
      'rejects an attachment when current readings select a newer candidate',
      () async {
        final harness = await _BridgeHarness.create(
          history: _evolvingPeakHistory(),
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final expected = harness.bridge.snapshot.attachmentSuggestion;
        expect(expected, isNotNull);

        harness.session.emit(
          _sessionSnapshot(
            _sensor('alpha'),
            history: _evolvingPeakHistory(includeLaterPeak: true),
          ),
        );
        await _drainBridgeQueue();

        final preparation = await harness.bridge.prepareContextAttachmentSave(
          expected!,
        );
        expect(
          preparation.status,
          ContextBridgeAttachmentPreparationStatus.staleOrSuperseded,
        );
      },
    );

    test('rejects an attachment when its current policy is disabled', () async {
      final policy = ValueNotifier<ContextBridgeSuggestionPolicy>(
        ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
          recentRisePolicy: _risePolicy,
          disclosure: 'This is non-clinical and not medical advice.',
        ),
      );
      final harness = await _BridgeHarness.create(
        suggestionPolicyProvider: () => policy.value,
      );
      addTearDown(() async {
        policy.dispose();
        await harness.dispose();
      });
      final expected = harness.bridge.snapshot.attachmentSuggestion;
      expect(expected, isNotNull);

      policy.value = const ContextBridgeSuggestionPolicy.disabled();
      final preparation = await harness.bridge.prepareContextAttachmentSave(
        expected!,
      );

      expect(
        preparation.status,
        ContextBridgeAttachmentPreparationStatus.staleOrSuperseded,
      );
    });

    test(
      'rejects an attachment after its local freshness window elapses',
      () async {
        var now = _now;
        final harness = await _BridgeHarness.create(
          clock: () => now,
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final expected = harness.bridge.snapshot.attachmentSuggestion;
        expect(expected, isNotNull);

        now = _now.add(const Duration(hours: 1));
        final preparation = await harness.bridge.prepareContextAttachmentSave(
          expected!,
        );

        expect(
          preparation.status,
          ContextBridgeAttachmentPreparationStatus.staleOrSuperseded,
        );
      },
    );

    test(
      'reports an already claimed episode before it offers a writer',
      () async {
        final repository = _BridgeRepository();
        final harness = await _BridgeHarness.create(
          repository: repository,
          suggestionPolicy:
              ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
                recentRisePolicy: _risePolicy,
                disclosure: 'This is non-clinical and not medical advice.',
              ),
        );
        addTearDown(harness.dispose);
        final expected = harness.bridge.snapshot.attachmentSuggestion;
        expect(expected, isNotNull);
        repository.facts['already-claimed'] = _attachmentFactFor(
          expected!,
          journalEntryId: 'existing-entry',
        );

        final preparation = await harness.bridge.prepareContextAttachmentSave(
          expected,
        );

        expect(
          preparation.status,
          ContextBridgeAttachmentPreparationStatus.alreadyClaimed,
        );
        expect(preparation.save, isNull);
      },
    );

    test('requires typed bridge-generated attachment links', () {
      expect(
        () => ContextBridgeCandidateId('ctx-suggestion-not-a-candidate'),
        throwsFormatException,
      );
      expect(
        () => ContextBridgeEpisodeKey('ctx-episode-not-hex'),
        throwsFormatException,
      );
      expect(
        () => ContextAttachmentFact.fromJson(<String, Object?>{
          'formatVersion': ContextAttachmentFact.formatVersion,
          'id': 'attachment-fact',
          'journalEntryId': 'journal-entry',
          'candidateId': 'ctx-candidate-0123456789abcdef01234567',
          'episodeKey': 'not-an-opaque-episode-key',
          'calculationVersion': 'recent-observed-rise-v1',
          'episodeStart': '2026-08-24T11:30:00.000Z',
          'peakAt': '2026-08-24T11:45:00.000Z',
          'attachmentWindowStart': '2026-08-24T11:00:00.000Z',
          'attachmentWindowEnd': '2026-08-24T12:00:00.000Z',
          'occurredAt': '2026-08-24T11:40:00.000Z',
        }),
        throwsFormatException,
      );
    });

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

    test(
      'keeps activity and sleep availability separate and omits heart-rate work',
      () async {
        final repository = _BridgeRepository()..failSleepQuery = true;
        await repository.upsertActivitySamples(<ActivitySample>[
          _activity(
            externalId: 'local-apple-workout',
            source: DataSource.appleHealth,
            start: _now.subtract(const Duration(minutes: 50)),
          ),
        ]);
        final harness = await _BridgeHarness.create(repository: repository);
        addTearDown(harness.dispose);

        expect(
          harness.bridge.snapshot.activityAvailability,
          ContextBridgeContextAvailability.available,
        );
        expect(
          harness.bridge.snapshot.sleepAvailability,
          ContextBridgeContextAvailability.unavailable,
        );
        expect(
          harness.bridge.snapshot.importedAvailability,
          ContextBridgeContextAvailability.partial,
        );
        expect(repository.heartRateQueryCalls, 0);
      },
    );

    test(
      'marks only the bounded diary cache partial when it is truncated',
      () async {
        final repository = _BridgeRepository();
        for (var index = 0; index < 3; index += 1) {
          repository.entries['entry-$index'] = FastJournalEntry(
            id: 'entry-$index',
            kind: FastJournalKind.meal,
            occurredAt: _now.subtract(Duration(minutes: index + 1)),
          );
        }
        final harness = await _BridgeHarness.create(
          repository: repository,
          cachePolicy: const ContextBridgeCachePolicy(maxDiaryEntries: 2),
        );
        addTearDown(harness.dispose);

        expect(repository.lastJournalLimit, 3);
        expect(harness.bridge.snapshot.diaryItems, hasLength(2));
        expect(
          harness.bridge.snapshot.diaryAvailability,
          ContextBridgeContextAvailability.partial,
        );
        expect(
          harness.bridge.snapshot.activityAvailability,
          ContextBridgeContextAvailability.noLocalRecords,
        );
        expect(
          harness.bridge.snapshot.sleepAvailability,
          ContextBridgeContextAvailability.noLocalRecords,
        );
      },
    );

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
  CgmSyncStage stage = CgmSyncStage.ready,
  CgmSessionInfo? sessionInfo,
  CgmHealthSnapshot health = const CgmHealthSnapshot(),
}) => CgmSessionSnapshot(
  stage: stage,
  statusText: stage == CgmSyncStage.ready ? 'Ready' : 'Connecting',
  sensor: sensor,
  capabilities: sensor.capabilities,
  history: history,
  latestReading: history.isEmpty ? null : history.last,
  sessionInfo:
      sessionInfo ??
      CgmSessionInfo(
        sessionStart: _now.subtract(const Duration(hours: 3)),
        serial: 'LIVE-SERIAL-${sensor.storageKey.split(':')[1]}',
      ),
  health: health,
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

List<CgmReading> _evolvingPeakHistory({bool includeLaterPeak = false}) =>
    <CgmReading>[
      _reading(
        _now.subtract(const Duration(minutes: 30)),
        120,
        sensorMinute: 146,
      ),
      _reading(
        _now.subtract(const Duration(minutes: 25)),
        100,
        sensorMinute: 151,
      ),
      _reading(
        _now.subtract(const Duration(minutes: 20)),
        110,
        sensorMinute: 156,
      ),
      _reading(
        _now.subtract(const Duration(minutes: 15)),
        120,
        sensorMinute: 161,
      ),
      _reading(
        _now.subtract(const Duration(minutes: 10)),
        125,
        sensorMinute: 166,
      ),
      _reading(
        _now.subtract(const Duration(minutes: 5)),
        128,
        sensorMinute: 171,
      ),
      if (includeLaterPeak) _reading(_now, 130, sensorMinute: 176),
    ];

CgmReading _reading(
  DateTime recordedAt,
  double valueMgdl, {
  int? sensorMinute,
  CgmRecordSource source = CgmRecordSource.vendor,
  bool provisional = false,
}) => CgmReading(
  valueMgdl: valueMgdl,
  source: source,
  sensorMinute: sensorMinute,
  recordedAt: recordedAt,
  isDisplayProvisional: provisional,
);

ContextAttachmentFact _attachmentFactFor(
  ContextBridgeAttachmentSuggestion suggestion, {
  required String journalEntryId,
}) => ContextAttachmentFact(
  id: 'fact-$journalEntryId',
  journalEntryId: journalEntryId,
  candidateId: suggestion.candidateId,
  episodeKey: suggestion.episodeKey,
  calculationVersion: suggestion.calculationVersion,
  episodeStart: suggestion.episodeStart,
  peakAt: suggestion.peakAt,
  attachmentWindowStart: suggestion.attachmentWindowStart,
  attachmentWindowEnd: suggestion.attachmentWindowEnd,
  occurredAt: suggestion.episodeStart,
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
    ContextBridgeSuggestionPolicyProvider? suggestionPolicyProvider,
    Listenable? contextSignal,
    Listenable? contextSettingsSignal,
    ContextBridgeEnabledProvider? isContextViewEnabled,
    ContextBridgeClock? clock,
    ContextBridgeCachePolicy cachePolicy = const ContextBridgeCachePolicy(),
    bool demoDriver = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final sensor = _sensor('alpha');
    final session = _BridgeSession(
      _sessionSnapshot(sensor, history: history ?? _qualifiedHistory()),
    );
    final controller = CgmAppController(
      preferences: preferences,
      driver: demoDriver ? _BridgeDemoDriver(session) : _BridgeDriver(session),
      reconnectDelay: Duration.zero,
    );
    await controller.initialize();
    await controller.connect(sensor);
    final localRepository = repository ?? _BridgeRepository();
    final lifecycle = AppHealthRepositoryLifecycle(() async {
      localRepository.acquireCalls++;
      return localRepository;
    });
    final bridge = ContextBridge(
      controller: controller,
      repositoryLifecycle: lifecycle,
      clock: clock ?? () => _now,
      cachePolicy: cachePolicy,
      suggestionPolicy: suggestionPolicy,
      suggestionPolicyProvider: suggestionPolicyProvider,
      contextChangeSignal: contextSignal,
      contextSettingsSignal: contextSettingsSignal,
      isContextViewEnabled: isContextViewEnabled,
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
    with ContextAttachmentWriter
    implements FastJournalStore, ContextAttachmentFactStore {
  final Map<String, FastJournalEntry> entries = <String, FastJournalEntry>{};
  final Map<String, ContextAttachmentFact> facts =
      <String, ContextAttachmentFact>{};
  TimeWindow? lastJournalWindow;
  int? lastJournalLimit;
  int acquireCalls = 0;
  bool failActivityQuery = false;
  bool failSleepQuery = false;
  int heartRateQueryCalls = 0;
  int saveAttachmentCalls = 0;

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
  Future<List<SleepSample>> querySleepSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    if (failSleepQuery) {
      throw StateError('Simulated local sleep read failure');
    }
    return super.querySleepSamples(window: window);
  }

  @override
  Future<List<HeartRateSample>> queryHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    heartRateQueryCalls++;
    throw StateError('The first context surface must not query heart rate.');
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
  Future<ContextAttachmentFact?> claimContextAttachmentFact(
    ContextAttachmentFact fact,
  ) async {
    fact.toJson();
    final idConflict = facts[fact.id];
    if (idConflict != null &&
        idConflict.journalEntryId != fact.journalEntryId &&
        idConflict.episodeKey.value != fact.episodeKey.value) {
      throw StateError(
        'Context attachment fact ID collides with a different journal '
        'entry and episode.',
      );
    }
    if (facts.values.any(
      (existing) =>
          existing.journalEntryId == fact.journalEntryId ||
          existing.episodeKey.value == fact.episodeKey.value,
    )) {
      return null;
    }
    facts[fact.id] = fact;
    return fact;
  }

  @override
  Future<List<ContextAttachmentFact>> queryContextAttachmentFacts({
    TimeWindow window = TimeWindow.all,
    ContextBridgeEpisodeKey? episodeKey,
  }) async => facts.values
      .where((fact) => window.contains(fact.occurredAt))
      .where(
        (fact) =>
            episodeKey == null || fact.episodeKey.value == episodeKey.value,
      )
      .toList(growable: false);

  @override
  Future<ContextAttachmentSaveResult> saveContextAttachment({
    required FastJournalEntry entry,
    required ContextAttachmentFact fact,
  }) async {
    saveAttachmentCalls++;
    if (await isFastJournalRiseClaimed(riseStartedAt: fact.episodeStart) ||
        facts.values.any(
          (existing) => existing.episodeKey.value == fact.episodeKey.value,
        )) {
      return const ContextAttachmentSaveResult.alreadyClaimed();
    }
    final saved = entry.copyWith(
      riseReference: FastJournalRiseReference(
        startedAt: fact.episodeStart,
        lastObservedAt: fact.peakAt,
      ),
    );
    entries[saved.id] = saved;
    facts[fact.id] = fact;
    return ContextAttachmentSaveResult.saved(saved);
  }
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

class _BridgeDemoDriver extends DemoCgmDriver {
  _BridgeDemoDriver(this.session) : super(clock: () => _now);

  final _BridgeSession session;

  @override
  String get driverId => 'context-bridge-driver';

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
