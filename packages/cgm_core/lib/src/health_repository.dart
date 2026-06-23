import 'ai_insight.dart';
import 'health_event.dart';
import 'health_samples.dart';

/// A half-open `[start, end)` time window used to scope timeline queries.
///
/// `start` is inclusive and `end` is exclusive, which composes cleanly when
/// paging adjacent windows (no double-counting at the boundary). Either bound
/// may be omitted to leave that side unbounded.
class TimeWindow {
  const TimeWindow({this.start, this.end});

  /// Inclusive lower bound, or `null` for "from the beginning".
  final DateTime? start;

  /// Exclusive upper bound, or `null` for "until now".
  final DateTime? end;

  /// An unbounded window matching every record.
  static const TimeWindow all = TimeWindow();

  /// Whether [timestamp] falls inside this window.
  bool contains(DateTime timestamp) {
    if (start != null && timestamp.isBefore(start!)) return false;
    if (end != null && !timestamp.isBefore(end!)) return false;
    return true;
  }
}

/// The local-first persistence contract for journaled events, imported health
/// samples (activity / sleep / heart-rate), and AI insights.
///
/// This is a pure-Dart interface so it can be implemented by an in-memory
/// fake for tests and by a concrete on-device store (sqflite) in the Flutter
/// app. It is intentionally local-only: nothing here implies or permits any
/// cloud sync. CGM reading history is owned by the existing reading-history
/// persistence and is deliberately out of scope.
///
/// All timestamps are compared in their absolute instant; callers are
/// encouraged to store UTC. Queries return results sorted chronologically
/// ascending unless noted otherwise.
abstract interface class HealthRepository {
  /// Opens/initializes the store (runs migrations). Safe to call more than
  /// once; implementations should be idempotent.
  Future<void> init();

  /// Releases any resources (closes the database). After [close] the
  /// repository must not be used without calling [init] again.
  Future<void> close();

  // --- Health events -------------------------------------------------------

  /// Inserts a new event or replaces the existing one with the same
  /// [HealthEvent.id].
  Future<void> upsertEvent(HealthEvent event);

  /// Inserts/replaces many events in a single transaction. Intended for
  /// imports; ordering of [events] is not significant.
  Future<void> upsertEvents(Iterable<HealthEvent> events);

  /// Removes the event with [id]. No-op if it does not exist.
  Future<void> deleteEvent(String id);

  /// Returns the event with [id], or `null` if absent.
  Future<HealthEvent?> getEvent(String id);

  /// Returns events whose [HealthEvent.timestamp] falls in [window], optionally
  /// filtered to [types], sorted chronologically ascending.
  Future<List<HealthEvent>> queryEvents({
    TimeWindow window = TimeWindow.all,
    Set<HealthEventType>? types,
  });

  // --- Activity samples ----------------------------------------------------

  /// Inserts/replaces many activity samples in a single transaction.
  Future<void> upsertActivitySamples(Iterable<ActivitySample> samples);

  /// Removes every activity sample whose [ActivitySample.start] falls in
  /// [window]. Returns the number of rows removed.
  Future<int> deleteActivitySamples({TimeWindow window = TimeWindow.all});

  /// Returns activity samples whose [ActivitySample.start] falls in [window],
  /// optionally filtered to [types], sorted chronologically ascending.
  Future<List<ActivitySample>> queryActivitySamples({
    TimeWindow window = TimeWindow.all,
    Set<ActivityType>? types,
  });

  // --- Sleep samples -------------------------------------------------------

  /// Inserts/replaces many sleep samples in a single transaction.
  Future<void> upsertSleepSamples(Iterable<SleepSample> samples);

  /// Removes every sleep sample whose [SleepSample.start] falls in [window].
  /// Returns the number of rows removed.
  Future<int> deleteSleepSamples({TimeWindow window = TimeWindow.all});

  /// Returns sleep samples whose [SleepSample.start] falls in [window], sorted
  /// chronologically ascending.
  Future<List<SleepSample>> querySleepSamples({
    TimeWindow window = TimeWindow.all,
  });

  // --- Heart-rate samples --------------------------------------------------

  /// Inserts/replaces many heart-rate samples in a single transaction.
  Future<void> upsertHeartRateSamples(Iterable<HeartRateSample> samples);

  /// Removes every heart-rate sample whose [HeartRateSample.timestamp] falls in
  /// [window]. Returns the number of rows removed.
  Future<int> deleteHeartRateSamples({TimeWindow window = TimeWindow.all});

  /// Returns heart-rate samples whose [HeartRateSample.timestamp] falls in
  /// [window], sorted chronologically ascending.
  Future<List<HeartRateSample>> queryHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  });

  // --- AI insights ---------------------------------------------------------

  /// Inserts a new insight or replaces the existing one with the same
  /// [AiInsight.id].
  Future<void> upsertInsight(AiInsight insight);

  /// Removes the insight with [id]. No-op if it does not exist.
  Future<void> deleteInsight(String id);

  /// Returns insights whose [AiInsight.createdAt] falls in [window], optionally
  /// filtered to [categories], sorted chronologically ascending.
  Future<List<AiInsight>> queryInsights({
    TimeWindow window = TimeWindow.all,
    Set<AiInsightCategory>? categories,
  });

  /// Removes every record (events, all sample types, insights). Intended for
  /// "reset local data" / test teardown. Does not touch CGM reading history.
  Future<void> clear();
}
