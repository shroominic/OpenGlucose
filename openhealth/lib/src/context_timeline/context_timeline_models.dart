import 'package:cgm_core/cgm_core.dart';

/// User-selectable windows for the compact, read-only context preview.
///
/// The preview has no persistence. A future coordinator can own the selected
/// range and pass it to a [ContextTimelineSource].
enum ContextTimelineRange {
  threeHours('3h', Duration(hours: 3)),
  twelveHours('12h', Duration(hours: 12)),
  oneDay('24h', Duration(days: 1)),
  sevenDays('7d', Duration(days: 7))
  ;

  const ContextTimelineRange(this.label, this.duration);

  final String label;
  final Duration duration;
}

/// An inclusive time window used by the preview and its typed source seam.
class ContextTimelineWindow {
  const ContextTimelineWindow({required this.start, required this.end});

  factory ContextTimelineWindow.endingAt(
    DateTime end,
    ContextTimelineRange range,
  ) => ContextTimelineWindow(start: end.subtract(range.duration), end: end);

  final DateTime start;
  final DateTime end;

  bool contains(DateTime value) =>
      !value.isBefore(start) && !value.isAfter(end);

  bool intersects(DateTime intervalStart, DateTime intervalEnd) =>
      !intervalEnd.isBefore(start) && !intervalStart.isAfter(end);
}

/// The context lane that owns an availability and provenance statement.
enum ContextTimelineLane { mealsAndNotes, sleep, activity, heartRate }

extension ContextTimelineLaneCopy on ContextTimelineLane {
  String get label => switch (this) {
    ContextTimelineLane.mealsAndNotes => 'Meals and notes',
    ContextTimelineLane.sleep => 'Sleep',
    ContextTimelineLane.activity => 'Movement',
    ContextTimelineLane.heartRate => 'Heart rate',
  };
}

/// Honest qualification state for an optional context source.
///
/// These states deliberately distinguish unavailable data from stale,
/// incomplete, and conflicting data. The preview never replaces any of them
/// with a zero or an implied permission result.
enum ContextDataAvailability {
  available,
  noAccessibleData,
  partial,
  stale,
  conflict,
}

extension ContextDataAvailabilityCopy on ContextDataAvailability {
  String get title => switch (this) {
    ContextDataAvailability.available => 'Available',
    ContextDataAvailability.noAccessibleData => 'No accessible data',
    ContextDataAvailability.partial => 'Partial data',
    ContextDataAvailability.stale => 'Stale data',
    ContextDataAvailability.conflict => 'Source conflict',
  };

  String get description => switch (this) {
    ContextDataAvailability.available =>
      'This context is available for the selected time window.',
    ContextDataAvailability.noAccessibleData =>
      'No accessible data is available for this context. This does not say why.',
    ContextDataAvailability.partial =>
      'Only part of this context is available for the selected time window.',
    ContextDataAvailability.stale =>
      'This context is older than the selected window needs. Treat it as reference only.',
    ContextDataAvailability.conflict =>
      'Sources disagree. Open an item to review its source before using it as context.',
  };
}

/// One source/lane availability declaration supplied by an upstream adapter.
class ContextTimelineLaneStatus {
  const ContextTimelineLaneStatus({
    required this.lane,
    required this.availability,
    this.source,
  });

  final ContextTimelineLane lane;
  final ContextDataAvailability availability;
  final DataSource? source;
}

/// A time-bounded, optional prompt to prepare a context draft.
///
/// This is not glucose evidence, a pattern assessment, or a causal conclusion.
/// The isolated preview uses it only for a generic, non-medical draft action.
/// A future product surface that calls out a glucose pattern must instead use a
/// deterministic, evidence-bound policy.
///
/// One optional value keeps the preview to at most one draft prompt.
class ContextAttachmentPrompt {
  const ContextAttachmentPrompt({
    required this.id,
    required this.start,
    required this.end,
    this.hasAttachedContext = false,
  });

  final String id;
  final DateTime start;
  final DateTime end;
  final bool hasAttachedContext;
}

/// An unsaved attachment intent emitted by the preview.
///
/// The receiving feature owns validation, editing, and persistence. This UI
/// package only opens a draft flow and never writes journal or imported data.
class ContextAttachmentDraft {
  const ContextAttachmentDraft({required this.prompt, required this.kind});

  final ContextAttachmentPrompt prompt;
  final ContextAttachmentKind kind;
}

enum ContextAttachmentKind { meal, activity, note }

extension ContextAttachmentKindCopy on ContextAttachmentKind {
  String get label => switch (this) {
    ContextAttachmentKind.meal => 'Meal',
    ContextAttachmentKind.activity => 'Activity',
    ContextAttachmentKind.note => 'Note',
  };
}

/// A typed, read-only snapshot for the visual layer.
///
/// Existing core types preserve their source and exact timestamps. Import,
/// repository, and journal features can implement [ContextTimelineSource]
/// later without making this preview own their data lifecycle.
class ContextTimelineSnapshot {
  const ContextTimelineSnapshot({
    this.glucoseReadings = const <CgmReading>[],
    this.events = const <HealthEvent>[],
    this.sleepSamples = const <SleepSample>[],
    this.activitySamples = const <ActivitySample>[],
    this.heartRateSamples = const <HeartRateSample>[],
    this.laneStatuses = const <ContextTimelineLaneStatus>[],
    this.attachmentPrompt,
    this.isSampleData = false,
  });

  final List<CgmReading> glucoseReadings;
  final List<HealthEvent> events;
  final List<SleepSample> sleepSamples;
  final List<ActivitySample> activitySamples;
  final List<HeartRateSample> heartRateSamples;
  final List<ContextTimelineLaneStatus> laneStatuses;
  final ContextAttachmentPrompt? attachmentPrompt;
  final bool isSampleData;

  /// Returns an explicit source status, or an honest fallback for [window].
  ///
  /// A [ContextTimelineSource] must provide explicit statuses for the exact
  /// query window when it has source knowledge. The fallback never turns data
  /// outside the selected window into an in-window partial-data claim.
  ContextTimelineLaneStatus statusFor(
    ContextTimelineLane lane, {
    ContextTimelineWindow? window,
  }) {
    for (final status in laneStatuses) {
      if (status.lane == lane) return status;
    }
    return ContextTimelineLaneStatus(
      lane: lane,
      availability: _hasDataFor(lane, window: window)
          ? ContextDataAvailability.partial
          : ContextDataAvailability.noAccessibleData,
    );
  }

  bool _hasDataFor(
    ContextTimelineLane lane, {
    ContextTimelineWindow? window,
  }) => switch (lane) {
    ContextTimelineLane.mealsAndNotes => events.any(
      (event) =>
          (event.type == HealthEventType.meal ||
              event.type == HealthEventType.note) &&
          (window == null || window.contains(event.timestamp)),
    ),
    ContextTimelineLane.sleep => sleepSamples.any(
      (sample) => window == null || window.intersects(sample.start, sample.end),
    ),
    ContextTimelineLane.activity =>
      activitySamples.any(
            (sample) =>
                window == null || window.intersects(sample.start, sample.end),
          ) ||
          events.any(
            (event) =>
                event.type == HealthEventType.exercise &&
                (window == null || window.contains(event.timestamp)),
          ),
    ContextTimelineLane.heartRate => heartRateSamples.any(
      (sample) => window == null || window.contains(sample.timestamp),
    ),
  };
}

/// Query boundary for a future timeline coordinator.
class ContextTimelineQuery {
  const ContextTimelineQuery({required this.window});

  final ContextTimelineWindow window;
}

/// Read-only adapter seam for context repositories and fixture sources.
///
/// A future coordinator can adapt a repository method to this typed provider
/// without giving this visual package ownership of asynchronous import or
/// persistence behavior. It must return explicit lane statuses for the query
/// window when an upstream source can distinguish unavailable, stale, partial,
/// or conflicting data.
typedef ContextTimelineSource =
    ContextTimelineSnapshot Function(ContextTimelineQuery query);

/// Simple fixture/source adapter for visual development and widget tests.
class FixedContextTimelineSource {
  const FixedContextTimelineSource(this.snapshot);

  final ContextTimelineSnapshot snapshot;

  ContextTimelineSnapshot call(ContextTimelineQuery query) => snapshot;
}

enum ContextTimelineItemKind { meal, note, workout, movement, sleep, heartRate }

extension ContextTimelineItemKindCopy on ContextTimelineItemKind {
  String get label => switch (this) {
    ContextTimelineItemKind.meal => 'Meal',
    ContextTimelineItemKind.note => 'Note',
    ContextTimelineItemKind.workout => 'Workout',
    ContextTimelineItemKind.movement => 'Movement',
    ContextTimelineItemKind.sleep => 'Sleep',
    ContextTimelineItemKind.heartRate => 'Heart rate',
  };
}

/// A normalized, source-attributed item ready for a small visual lane.
class ContextTimelineItem {
  const ContextTimelineItem({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
    required this.source,
    required this.qualification,
    required this.title,
    required this.detail,
  });

  final String id;
  final ContextTimelineItemKind kind;
  final DateTime start;
  final DateTime end;
  final DataSource source;
  final ContextDataAvailability qualification;
  final String title;
  final String detail;

  bool get isInterval => end.isAfter(start);
}

/// Deterministic, presentation-only projection for one selected time range.
class ContextTimelineProjection {
  const ContextTimelineProjection({
    required this.window,
    required this.glucoseReadings,
    required this.items,
    required this.heartRateSamples,
    required this.laneStatuses,
    required this.attachmentPrompt,
    required this.isSampleData,
  });

  factory ContextTimelineProjection.compose({
    required ContextTimelineSnapshot snapshot,
    required DateTime now,
    required ContextTimelineRange range,
  }) {
    final window = ContextTimelineWindow.endingAt(now, range);
    final statuses = <ContextTimelineLaneStatus>[
      for (final lane in ContextTimelineLane.values)
        snapshot.statusFor(lane, window: window),
    ];
    final items =
        <ContextTimelineItem>[
          ..._eventItems(snapshot.events, window, snapshot),
          ..._sleepItems(snapshot.sleepSamples, window, snapshot),
          ..._activityItems(snapshot.activitySamples, window, snapshot),
          ..._heartRateItems(snapshot.heartRateSamples, window, snapshot),
        ]..sort((left, right) {
          final byTime = left.start.compareTo(right.start);
          return byTime == 0 ? left.id.compareTo(right.id) : byTime;
        });

    final readings =
        snapshot.glucoseReadings
            .where((reading) {
              final recordedAt = reading.recordedAt;
              return recordedAt != null && window.contains(recordedAt);
            })
            .toList(growable: false)
          ..sort(
            (left, right) =>
                left.timelineTimestamp.compareTo(right.timelineTimestamp),
          );

    final heartRate =
        snapshot.heartRateSamples
            .where((sample) => window.contains(sample.timestamp))
            .toList(growable: false)
          ..sort((left, right) => left.timestamp.compareTo(right.timestamp));

    final prompt = snapshot.attachmentPrompt;
    final visiblePrompt =
        prompt != null &&
            !prompt.hasAttachedContext &&
            window.intersects(prompt.start, prompt.end)
        ? prompt
        : null;

    return ContextTimelineProjection(
      window: window,
      glucoseReadings: readings,
      items: items,
      heartRateSamples: heartRate,
      laneStatuses: statuses,
      attachmentPrompt: visiblePrompt,
      isSampleData: snapshot.isSampleData,
    );
  }

  final ContextTimelineWindow window;
  final List<CgmReading> glucoseReadings;
  final List<ContextTimelineItem> items;
  final List<HeartRateSample> heartRateSamples;
  final List<ContextTimelineLaneStatus> laneStatuses;
  final ContextAttachmentPrompt? attachmentPrompt;
  final bool isSampleData;

  ContextTimelineLaneStatus statusFor(ContextTimelineLane lane) =>
      laneStatuses.firstWhere((status) => status.lane == lane);

  static List<ContextTimelineItem> _eventItems(
    List<HealthEvent> events,
    ContextTimelineWindow window,
    ContextTimelineSnapshot snapshot,
  ) {
    final items = <ContextTimelineItem>[];
    for (final event in events) {
      if (!window.contains(event.timestamp)) continue;
      final kind = switch (event.type) {
        HealthEventType.meal => ContextTimelineItemKind.meal,
        HealthEventType.note => ContextTimelineItemKind.note,
        HealthEventType.exercise => ContextTimelineItemKind.workout,
        _ => null,
      };
      if (kind == null) continue;
      final lane =
          kind == ContextTimelineItemKind.meal ||
              kind == ContextTimelineItemKind.note
          ? ContextTimelineLane.mealsAndNotes
          : ContextTimelineLane.activity;
      items.add(
        ContextTimelineItem(
          id: 'event:${event.id}',
          kind: kind,
          start: event.timestamp,
          end: _eventEnd(event),
          source: event.source,
          qualification: snapshot.statusFor(lane, window: window).availability,
          title: _eventTitle(event, kind),
          detail: _eventDetail(event, kind),
        ),
      );
    }
    return items;
  }

  static List<ContextTimelineItem> _sleepItems(
    List<SleepSample> samples,
    ContextTimelineWindow window,
    ContextTimelineSnapshot snapshot,
  ) => <ContextTimelineItem>[
    for (final sample in samples)
      if (window.intersects(sample.start, sample.end))
        ContextTimelineItem(
          id: 'sleep:${sample.start.toUtc().toIso8601String()}:${sample.end.toUtc().toIso8601String()}',
          kind: ContextTimelineItemKind.sleep,
          start: sample.start,
          end: sample.end,
          source: sample.source,
          qualification: snapshot
              .statusFor(ContextTimelineLane.sleep, window: window)
              .availability,
          title: 'Sleep',
          detail: _sleepStageLabel(sample.stage),
        ),
  ];

  static List<ContextTimelineItem> _activityItems(
    List<ActivitySample> samples,
    ContextTimelineWindow window,
    ContextTimelineSnapshot snapshot,
  ) => <ContextTimelineItem>[
    for (final sample in samples)
      if (window.intersects(sample.start, sample.end))
        ContextTimelineItem(
          id: 'activity:${sample.type.name}:${sample.start.toUtc().toIso8601String()}:${sample.end.toUtc().toIso8601String()}',
          kind: sample.type == ActivityType.workout
              ? ContextTimelineItemKind.workout
              : ContextTimelineItemKind.movement,
          start: sample.start,
          end: sample.end,
          source: sample.source,
          qualification: snapshot
              .statusFor(ContextTimelineLane.activity, window: window)
              .availability,
          title: sample.type == ActivityType.workout ? 'Workout' : 'Movement',
          detail: _activityDetail(sample),
        ),
  ];

  static List<ContextTimelineItem> _heartRateItems(
    List<HeartRateSample> samples,
    ContextTimelineWindow window,
    ContextTimelineSnapshot snapshot,
  ) => <ContextTimelineItem>[
    for (final sample in samples)
      if (window.contains(sample.timestamp))
        ContextTimelineItem(
          id: 'heart-rate:${sample.timestamp.toUtc().toIso8601String()}',
          kind: ContextTimelineItemKind.heartRate,
          start: sample.timestamp,
          end: sample.timestamp,
          source: sample.source,
          qualification: snapshot
              .statusFor(ContextTimelineLane.heartRate, window: window)
              .availability,
          title: 'Heart rate',
          detail: '${sample.bpm.round()} bpm',
        ),
  ];

  static DateTime _eventEnd(HealthEvent event) {
    final payload = event.payload;
    if (payload is ExercisePayload && payload.duration != null) {
      return event.timestamp.add(payload.duration!);
    }
    return event.timestamp;
  }

  static String _eventTitle(HealthEvent event, ContextTimelineItemKind kind) {
    if (kind == ContextTimelineItemKind.meal) {
      final payload = event.payload;
      if (payload is MealPayload &&
          payload.description != null &&
          payload.description!.trim().isNotEmpty) {
        return payload.description!.trim();
      }
      return 'Meal';
    }
    if (kind == ContextTimelineItemKind.note) return 'Note';
    final payload = event.payload;
    if (payload is ExercisePayload &&
        payload.activity != null &&
        payload.activity!.trim().isNotEmpty) {
      return payload.activity!.trim();
    }
    return 'Workout';
  }

  static String _eventDetail(HealthEvent event, ContextTimelineItemKind kind) {
    final payload = event.payload;
    if (kind == ContextTimelineItemKind.note && payload is NotePayload) {
      return payload.text;
    }
    if (kind == ContextTimelineItemKind.meal && payload is MealPayload) {
      final carbs = payload.carbsGrams;
      return carbs == null ? 'Meal marker' : '${carbs.round()} g carbohydrate';
    }
    if (payload is ExercisePayload && payload.duration != null) {
      return '${payload.duration!.inMinutes} min';
    }
    return kind.label;
  }

  static String _sleepStageLabel(SleepStage stage) => switch (stage) {
    SleepStage.awake => 'Awake',
    SleepStage.light => 'Light sleep',
    SleepStage.deep => 'Deep sleep',
    SleepStage.rem => 'REM sleep',
    SleepStage.asleep => 'Asleep',
    SleepStage.inBed => 'In bed',
  };

  static String _activityDetail(ActivitySample sample) => switch (sample.type) {
    ActivityType.steps => '${sample.steps ?? 0} steps',
    ActivityType.workout => sample.workoutLabel ?? 'Workout interval',
    ActivityType.distance => '${(sample.distanceMeters ?? 0).round()} m',
    ActivityType.activeEnergy => '${(sample.energyKcal ?? 0).round()} kcal',
    ActivityType.other => 'Activity interval',
  };
}

extension DataSourceContextCopy on DataSource {
  String get contextLabel => switch (this) {
    DataSource.appleHealth => 'Apple Health',
    DataSource.healthConnect => 'Health Connect',
    DataSource.manual => 'Manual entry',
  };
}
