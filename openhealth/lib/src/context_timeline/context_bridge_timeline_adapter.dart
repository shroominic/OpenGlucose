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
    final appleHealthItems = snapshot.importedItems
        .where((item) => item.source == DataSource.appleHealth)
        .toList(growable: false);
    final importedAvailability = _appleHealthAvailability(
      snapshot.importedAvailability,
      appleHealthItems,
    );
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
    final events = <HealthEvent>[
      for (final item in snapshot.diaryItems) _eventForDiary(item),
    ];
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
          availability: _availabilityFor(
            snapshot.diaryAvailability,
            cacheCoversQuery: cacheCoversQuery,
          ),
          source: DataSource.manual,
        ),
        ContextTimelineLaneStatus(
          lane: ContextTimelineLane.sleep,
          availability: _availabilityFor(
            importedAvailability,
            cacheCoversQuery: cacheCoversQuery,
          ),
          source: _singleSourceFor(
            appleHealthItems.where(
              (item) => item.kind == ContextBridgeImportedKind.sleep,
            ),
          ),
        ),
        ContextTimelineLaneStatus(
          lane: ContextTimelineLane.activity,
          availability: _availabilityFor(
            importedAvailability,
            cacheCoversQuery: cacheCoversQuery,
          ),
          source: _singleSourceFor(
            appleHealthItems.where(
              (item) => item.kind == ContextBridgeImportedKind.activity,
            ),
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

  static ContextDataAvailability _availabilityFor(
    ContextBridgeContextAvailability availability, {
    required bool cacheCoversQuery,
  }) {
    if (!cacheCoversQuery) return ContextDataAvailability.partial;
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

  static ContextBridgeContextAvailability _appleHealthAvailability(
    ContextBridgeContextAvailability availability,
    List<ContextBridgeImportedItem> items,
  ) {
    if (items.isNotEmpty ||
        availability != ContextBridgeContextAvailability.available) {
      return availability;
    }
    // A source-neutral cache can be ready while containing only data this
    // narrow Apple Health reader does not support. Do not imply a platform
    // error or permission result; simply state no accessible data here.
    return ContextBridgeContextAvailability.noLocalRecords;
  }

  static DataSource? _singleSourceFor(
    Iterable<ContextBridgeImportedItem> items,
  ) {
    final sources = items.map((item) => item.source).toSet();
    return sources.length == 1 ? sources.single : null;
  }
}
