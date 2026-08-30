import 'package:cgm_core/cgm_core.dart';

import '../context_bridge/context_bridge_models.dart';
import 'context_timeline_models.dart';

/// Read-only adapter from the app-owned context cache to the visual timeline.
///
/// This adapter never opens a repository, starts an import, or exposes raw
/// platform IDs, source-app/device details, sensor identities, or diary labels.
/// It preserves only generic source families and the exact local time windows
/// that the bridge has already made available to presentation.
class ContextBridgeTimelineAdapter {
  const ContextBridgeTimelineAdapter(this.snapshot);

  final ContextBridgeSnapshot snapshot;

  ContextTimelineSnapshot call(ContextTimelineQuery query) {
    final cacheCoversQuery =
        snapshot.loadState == ContextBridgeLoadState.ready &&
        snapshot.window.contains(query.window.start) &&
        snapshot.window.contains(query.window.end);
    // The bridge can remain source-neutral for other app surfaces. This first
    // opt-in reader deliberately presents only the Apple Health import path;
    // it neither enables nor displays Health Connect data.
    final appleHealthItems = cacheCoversQuery
        ? snapshot.importedItems
              .where((item) => item.source == DataSource.appleHealth)
              .toList(growable: false)
        : const <ContextBridgeImportedItem>[];
    final activities = <ActivitySample>[
      for (final item in appleHealthItems)
        if (item.kind == ContextBridgeImportedKind.activity)
          ActivitySample(
            start: item.start,
            end: item.end,
            type: item.activityType ?? ActivityType.other,
            source: item.source,
          ),
    ];
    final sleep = <SleepSample>[
      for (final item in appleHealthItems)
        if (item.kind == ContextBridgeImportedKind.sleep)
          SleepSample(
            start: item.start,
            end: item.end,
            stage: item.sleepStage ?? SleepStage.asleep,
            source: item.source,
          ),
    ];
    final events = cacheCoversQuery
        ? <HealthEvent>[
            for (final item in snapshot.diaryItems) _eventForDiary(item),
          ]
        : const <HealthEvent>[];
    final visibleAppleActivities = activities
        .where((item) => query.window.intersects(item.start, item.end))
        .toList(growable: false);
    final visibleAppleSleep = sleep
        .where((item) => query.window.intersects(item.start, item.end))
        .toList(growable: false);
    final visibleManualMealsOrNotes = events
        .where(
          (item) =>
              (item.type == HealthEventType.meal ||
                  item.type == HealthEventType.note) &&
              query.window.contains(item.timestamp),
        )
        .toList(growable: false);
    final visibleManualActivity = events
        .where(
          (item) =>
              item.type == HealthEventType.exercise &&
              query.window.contains(item.timestamp),
        )
        .toList(growable: false);
    final mealAvailability = _availabilityFor(
      snapshot.diaryAvailability,
      cacheCoversQuery: cacheCoversQuery,
      hasVisibleRecords: visibleManualMealsOrNotes.isNotEmpty,
    );
    final manualActivityAvailability = _availabilityFor(
      snapshot.diaryAvailability,
      cacheCoversQuery: cacheCoversQuery,
      hasVisibleRecords: visibleManualActivity.isNotEmpty,
    );
    final importedActivityAvailability = _appleHealthAvailability(
      _visibleSourceAvailability(
        kind: ContextBridgeImportedKind.activity,
        fallback: snapshot.activityAvailability,
      ),
      visibleAppleActivities,
      cacheCoversQuery: cacheCoversQuery,
    );
    final importedSleepAvailability = _appleHealthAvailability(
      _visibleSourceAvailability(
        kind: ContextBridgeImportedKind.sleep,
        fallback: snapshot.sleepAvailability,
      ),
      visibleAppleSleep,
      cacheCoversQuery: cacheCoversQuery,
    );
    final activityAvailability = _combinedActivityAvailability(
      importedActivityAvailability,
      manualActivityAvailability,
    );
    return ContextTimelineSnapshot(
      glucoseReadings: <CgmReading>[
        for (final reading in snapshot.glucoseReadings)
          CgmReading(
            valueMgdl: reading.valueMgdl,
            source: reading.source,
            recordedAt: reading.recordedAt,
          ),
      ],
      events: events,
      sleepSamples: sleep,
      activitySamples: activities,
      // Heart rate is intentionally not part of the first production context
      // visual lane. A later, separately reviewed surface may opt in.
      laneStatuses: <ContextTimelineLaneStatus>[
        ContextTimelineLaneStatus(
          lane: ContextTimelineLane.mealsAndNotes,
          availability: mealAvailability,
          source: visibleManualMealsOrNotes.isEmpty ? null : DataSource.manual,
        ),
        ContextTimelineLaneStatus(
          lane: ContextTimelineLane.sleep,
          availability: importedSleepAvailability,
          source: visibleAppleSleep.isEmpty ? null : DataSource.appleHealth,
        ),
        ContextTimelineLaneStatus(
          lane: ContextTimelineLane.activity,
          availability: activityAvailability,
          source: _activitySource(
            hasAppleHealth: visibleAppleActivities.isNotEmpty,
            hasManual: visibleManualActivity.isNotEmpty,
          ),
        ),
      ],
    );
  }

  static HealthEvent _eventForDiary(ContextBridgeDiaryItem item) {
    final kind = switch (item.kind) {
      'meal' => HealthEventType.meal,
      'activity' => HealthEventType.exercise,
      'note' => HealthEventType.note,
      // Legacy local sleep entries continue to be represented generically and
      // are never relabelled as Apple Health data.
      'sleep' => HealthEventType.note,
      _ => HealthEventType.note,
    };
    return HealthEvent(
      id: item.id,
      timestamp: item.occurredAt,
      type: kind,
      payload: kind == HealthEventType.exercise && item.duration != null
          ? ExercisePayload(duration: item.duration)
          : null,
      source: DataSource.manual,
    );
  }

  ContextBridgeContextAvailability _visibleSourceAvailability({
    required ContextBridgeImportedKind kind,
    required ContextBridgeContextAvailability fallback,
  }) {
    final scoped = snapshot.importedAvailabilityFor(
      source: DataSource.appleHealth,
      kind: kind,
    );
    if (scoped != null) return scoped;
    // A bridge that supplied source-scoped state but has no Apple Health
    // entry must not borrow Health Connect availability for this Apple-only
    // first surface. Old snapshots retain the reviewed type-wide fallback.
    return snapshot.hasImportedSourceAvailabilities
        ? ContextBridgeContextAvailability.noLocalRecords
        : fallback;
  }

  static ContextDataAvailability _availabilityFor(
    ContextBridgeContextAvailability availability, {
    required bool cacheCoversQuery,
    required bool hasVisibleRecords,
  }) {
    // An idle, loading, unavailable, or insufficient cache never becomes a
    // partial-data claim. The UI has no safe proof for the selected range.
    if (!cacheCoversQuery) return ContextDataAvailability.noAccessibleData;
    if (!hasVisibleRecords) return ContextDataAvailability.noAccessibleData;
    return switch (availability) {
      ContextBridgeContextAvailability.available =>
        ContextDataAvailability.available,
      ContextBridgeContextAvailability.noLocalRecords =>
        ContextDataAvailability.noAccessibleData,
      ContextBridgeContextAvailability.partial =>
        ContextDataAvailability.partial,
      ContextBridgeContextAvailability.unavailable =>
        ContextDataAvailability.noAccessibleData,
    };
  }

  static ContextDataAvailability _appleHealthAvailability<T>(
    ContextBridgeContextAvailability availability,
    List<T> visibleAppleItems, {
    required bool cacheCoversQuery,
  }) {
    if (!cacheCoversQuery || visibleAppleItems.isEmpty) {
      return ContextDataAvailability.noAccessibleData;
    }
    // A source-neutral cache can be ready while containing only data this
    // narrow Apple Health reader does not support. Do not imply a platform
    // error or permission result; simply state no accessible data here.
    return _availabilityFor(
      availability,
      cacheCoversQuery: true,
      hasVisibleRecords: true,
    );
  }

  static ContextDataAvailability _combinedActivityAvailability(
    ContextDataAvailability imported,
    ContextDataAvailability manual,
  ) {
    if (manual == ContextDataAvailability.partial ||
        imported == ContextDataAvailability.partial) {
      return ContextDataAvailability.partial;
    }
    if (manual == ContextDataAvailability.available ||
        imported == ContextDataAvailability.available) {
      return ContextDataAvailability.available;
    }
    return ContextDataAvailability.noAccessibleData;
  }

  static DataSource? _activitySource({
    required bool hasAppleHealth,
    required bool hasManual,
  }) {
    if (hasAppleHealth == hasManual) return null;
    return hasAppleHealth ? DataSource.appleHealth : DataSource.manual;
  }
}
