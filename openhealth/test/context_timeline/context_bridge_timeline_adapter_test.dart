import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_bridge/context_bridge_models.dart';
import 'package:openglucose/src/context_timeline/context_bridge_timeline_adapter.dart';
import 'package:openglucose/src/context_timeline/context_timeline_models.dart';

void main() {
  final now = DateTime.utc(2026, 8, 24, 12);
  final start = now.subtract(const Duration(days: 7));

  ContextBridgeSnapshot snapshot() => ContextBridgeSnapshot(
    loadState: ContextBridgeLoadState.ready,
    window: ContextBridgeWindow(start: start, end: now),
    glucoseAvailability: ContextBridgeGlucoseAvailability.available,
    importedAvailability: ContextBridgeContextAvailability.available,
    diaryAvailability: ContextBridgeContextAvailability.available,
    suggestionAvailability:
        ContextBridgeSuggestionAvailability.disabledByPolicy,
    suggestionsEnabled: false,
    glucoseReadings: <ContextBridgeReading>[
      ContextBridgeReading(
        id: 'opaque-reading-id',
        recordedAt: now.subtract(const Duration(minutes: 5)),
        valueMgdl: 110,
        source: CgmRecordSource.vendor,
      ),
    ],
    importedItems: <ContextBridgeImportedItem>[
      ContextBridgeImportedItem(
        id: 'opaque-apple-workout',
        kind: ContextBridgeImportedKind.activity,
        start: now.subtract(const Duration(minutes: 50)),
        end: now.subtract(const Duration(minutes: 20)),
        source: DataSource.appleHealth,
        activityType: ActivityType.workout,
      ),
      ContextBridgeImportedItem(
        id: 'opaque-apple-sleep',
        kind: ContextBridgeImportedKind.sleep,
        start: now.subtract(const Duration(hours: 8)),
        end: now.subtract(const Duration(hours: 2)),
        source: DataSource.appleHealth,
        sleepStage: SleepStage.asleep,
      ),
      ContextBridgeImportedItem(
        id: 'opaque-raw-heart-rate',
        kind: ContextBridgeImportedKind.heartRate,
        start: now.subtract(const Duration(minutes: 10)),
        end: now.subtract(const Duration(minutes: 10)),
        source: DataSource.appleHealth,
        heartRateBpm: 72,
      ),
    ],
    diaryItems: <ContextBridgeDiaryItem>[
      ContextBridgeDiaryItem(
        id: 'opaque-diary-meal',
        kind: 'meal',
        occurredAt: now.subtract(const Duration(minutes: 35)),
        label: 'private dinner label must not become a generic timeline label',
        hasObservationLink: false,
      ),
      ContextBridgeDiaryItem(
        id: 'opaque-diary-note',
        kind: 'note',
        occurredAt: now.subtract(const Duration(minutes: 15)),
        label: 'private note body must not become a generic timeline label',
        hasObservationLink: false,
      ),
    ],
  );

  test('uses only bridge-safe generic fields and leaves heart rate out', () {
    final source = ContextBridgeTimelineAdapter(snapshot());
    final projected = ContextTimelineProjection.compose(
      snapshot: source(
        ContextTimelineQuery(
          window: ContextTimelineWindow.endingAt(
            now,
            ContextTimelineRange.oneDay,
          ),
        ),
      ),
      now: now,
      range: ContextTimelineRange.oneDay,
    );

    expect(projected.glucoseReadings, hasLength(1));
    expect(projected.heartRateSamples, isEmpty);
    expect(
      projected.items.map((item) => item.title),
      containsAll(<String>['Meal', 'Note', 'Workout', 'Sleep']),
    );
    expect(
      projected.items.map((item) => item.source).toSet(),
      containsAll(<DataSource>[DataSource.manual, DataSource.appleHealth]),
    );
    final visibleText = projected.items
        .map(
          (item) => '${item.title} ${item.detail} ${item.source.contextLabel}',
        )
        .join(' ');
    expect(visibleText, isNot(contains('private dinner')));
    expect(visibleText, isNot(contains('private note')));
    expect(visibleText, isNot(contains('opaque-raw')));
  });

  test('fails closed when a query is outside the local bridge cache', () {
    final source = ContextBridgeTimelineAdapter(snapshot());
    final result = source(
      ContextTimelineQuery(
        window: ContextTimelineWindow(
          start: start.subtract(const Duration(minutes: 1)),
          end: now,
        ),
      ),
    );

    expect(
      result.statusFor(ContextTimelineLane.activity).availability,
      ContextDataAvailability.noAccessibleData,
    );
    expect(
      result.statusFor(ContextTimelineLane.mealsAndNotes).availability,
      ContextDataAvailability.noAccessibleData,
    );
  });

  test('keeps Health Connect records out of the first Apple Health lane', () {
    final source = ContextBridgeTimelineAdapter(
      snapshot().copyWith(
        importedItems: <ContextBridgeImportedItem>[
          ContextBridgeImportedItem(
            id: 'opaque-health-connect-workout',
            kind: ContextBridgeImportedKind.activity,
            start: now.subtract(const Duration(minutes: 50)),
            end: now.subtract(const Duration(minutes: 20)),
            source: DataSource.healthConnect,
            activityType: ActivityType.workout,
          ),
        ],
      ),
    );
    final projected = ContextTimelineProjection.compose(
      snapshot: source(
        ContextTimelineQuery(
          window: ContextTimelineWindow.endingAt(
            now,
            ContextTimelineRange.oneDay,
          ),
        ),
      ),
      now: now,
      range: ContextTimelineRange.oneDay,
    );

    expect(
      projected.items.where(
        (item) =>
            item.kind == ContextTimelineItemKind.workout ||
            item.kind == ContextTimelineItemKind.movement,
      ),
      isEmpty,
    );
    expect(
      projected.statusFor(ContextTimelineLane.activity).availability,
      ContextDataAvailability.noAccessibleData,
    );
    expect(
      projected.statusFor(ContextTimelineLane.activity).source,
      isNull,
    );
  });

  test(
    'does not turn filtered Health Connect partial data into a visible lane',
    () {
      final source = ContextBridgeTimelineAdapter(
        snapshot().copyWith(
          importedAvailability: ContextBridgeContextAvailability.partial,
          importedActivityAvailability:
              ContextBridgeContextAvailability.partial,
          importedSleepAvailability:
              ContextBridgeContextAvailability.noLocalRecords,
          importedItems: <ContextBridgeImportedItem>[
            ContextBridgeImportedItem(
              id: 'opaque-health-connect-workout',
              kind: ContextBridgeImportedKind.activity,
              start: now.subtract(const Duration(minutes: 50)),
              end: now.subtract(const Duration(minutes: 20)),
              source: DataSource.healthConnect,
              activityType: ActivityType.workout,
            ),
          ],
        ),
      );
      final result = source(
        ContextTimelineQuery(
          window: ContextTimelineWindow.endingAt(
            now,
            ContextTimelineRange.oneDay,
          ),
        ),
      );

      expect(
        result.statusFor(ContextTimelineLane.activity).availability,
        ContextDataAvailability.noAccessibleData,
      );
      expect(result.statusFor(ContextTimelineLane.activity).source, isNull);
    },
  );

  test('keeps manual activity available without an imported source', () {
    final source = ContextBridgeTimelineAdapter(
      snapshot().copyWith(
        importedAvailability: ContextBridgeContextAvailability.noLocalRecords,
        importedActivityAvailability:
            ContextBridgeContextAvailability.noLocalRecords,
        importedSleepAvailability:
            ContextBridgeContextAvailability.noLocalRecords,
        importedItems: const <ContextBridgeImportedItem>[],
        diaryItems: <ContextBridgeDiaryItem>[
          ContextBridgeDiaryItem(
            id: 'opaque-manual-activity',
            kind: 'activity',
            occurredAt: now.subtract(const Duration(minutes: 30)),
            hasObservationLink: false,
            duration: const Duration(minutes: 30),
          ),
        ],
      ),
    );
    final result = source(
      ContextTimelineQuery(
        window: ContextTimelineWindow.endingAt(
          now,
          ContextTimelineRange.oneDay,
        ),
      ),
    );

    expect(
      result.statusFor(ContextTimelineLane.activity).availability,
      ContextDataAvailability.available,
    );
    expect(
      result.statusFor(ContextTimelineLane.activity).source,
      DataSource.manual,
    );
    expect(
      result.statusFor(ContextTimelineLane.mealsAndNotes).availability,
      ContextDataAvailability.noAccessibleData,
    );
  });

  test('keeps only the diary lane partial when its cache is truncated', () {
    final source = ContextBridgeTimelineAdapter(
      snapshot().copyWith(
        diaryAvailability: ContextBridgeContextAvailability.partial,
      ),
    );
    final result = source(
      ContextTimelineQuery(
        window: ContextTimelineWindow.endingAt(
          now,
          ContextTimelineRange.oneDay,
        ),
      ),
    );

    expect(
      result.statusFor(ContextTimelineLane.mealsAndNotes).availability,
      ContextDataAvailability.partial,
    );
    expect(
      result.statusFor(ContextTimelineLane.activity).availability,
      ContextDataAvailability.available,
    );
    expect(
      result.statusFor(ContextTimelineLane.sleep).availability,
      ContextDataAvailability.available,
    );
  });

  test(
    'fails closed for idle, loading, unavailable, and HR-only bridge snapshots',
    () {
      for (final loadState in <ContextBridgeLoadState>[
        ContextBridgeLoadState.idle,
        ContextBridgeLoadState.loading,
        ContextBridgeLoadState.unavailable,
      ]) {
        final source = ContextBridgeTimelineAdapter(
          snapshot().copyWith(loadState: loadState),
        );
        final result = source(
          ContextTimelineQuery(
            window: ContextTimelineWindow.endingAt(
              now,
              ContextTimelineRange.oneDay,
            ),
          ),
        );
        expect(result.events, isEmpty);
        expect(result.activitySamples, isEmpty);
        expect(result.sleepSamples, isEmpty);
        for (final lane in <ContextTimelineLane>[
          ContextTimelineLane.mealsAndNotes,
          ContextTimelineLane.activity,
          ContextTimelineLane.sleep,
        ]) {
          expect(
            result.statusFor(lane).availability,
            ContextDataAvailability.noAccessibleData,
            reason: '$loadState must fail closed for ${lane.name}',
          );
        }
      }

      final hrOnly =
          ContextBridgeTimelineAdapter(
            snapshot().copyWith(
              importedAvailability:
                  ContextBridgeContextAvailability.noLocalRecords,
              importedActivityAvailability:
                  ContextBridgeContextAvailability.noLocalRecords,
              importedSleepAvailability:
                  ContextBridgeContextAvailability.noLocalRecords,
              importedItems: <ContextBridgeImportedItem>[
                ContextBridgeImportedItem(
                  id: 'opaque-heart-rate-only',
                  kind: ContextBridgeImportedKind.heartRate,
                  start: now.subtract(const Duration(minutes: 10)),
                  end: now.subtract(const Duration(minutes: 10)),
                  source: DataSource.appleHealth,
                  heartRateBpm: 75,
                ),
              ],
            ),
          )(
            ContextTimelineQuery(
              window: ContextTimelineWindow.endingAt(
                now,
                ContextTimelineRange.oneDay,
              ),
            ),
          );
      expect(hrOnly.heartRateSamples, isEmpty);
      expect(
        hrOnly.statusFor(ContextTimelineLane.activity).availability,
        ContextDataAvailability.noAccessibleData,
      );
      expect(
        hrOnly.statusFor(ContextTimelineLane.sleep).availability,
        ContextDataAvailability.noAccessibleData,
      );
    },
  );
}
