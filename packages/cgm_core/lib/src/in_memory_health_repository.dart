import 'ai_insight.dart';
import 'health_event.dart';
import 'health_repository.dart';
import 'health_samples.dart';
import 'timeline.dart';

/// An in-memory [HealthRepository] for tests and ephemeral usage.
///
/// It mirrors the semantics the on-device store must honor (id-keyed upserts
/// for events/insights, window + type filtering, chronological ordering,
/// window-scoped deletes), so unit tests can exercise the repository contract
/// with no device, file system, or sqflite dependency.
///
/// Samples have no stable identity, so [upsertActivitySamples] and friends
/// append rather than de-duplicate — matching how the relational store treats
/// bulk-imported samples as append-only rows.
class InMemoryHealthRepository implements HealthRepository {
  final Map<String, HealthEvent> _events = <String, HealthEvent>{};
  final List<ActivitySample> _activity = <ActivitySample>[];
  final List<SleepSample> _sleep = <SleepSample>[];
  final List<HeartRateSample> _heartRate = <HeartRateSample>[];
  final Map<String, AiInsight> _insights = <String, AiInsight>{};

  @override
  Future<void> init() async {}

  @override
  Future<void> close() async {}

  // --- Health events -------------------------------------------------------

  @override
  Future<void> upsertEvent(HealthEvent event) async {
    _events[event.id] = event;
  }

  @override
  Future<void> upsertEvents(Iterable<HealthEvent> events) async {
    for (final event in events) {
      _events[event.id] = event;
    }
  }

  @override
  Future<void> deleteEvent(String id) async {
    _events.remove(id);
  }

  @override
  Future<HealthEvent?> getEvent(String id) async => _events[id];

  @override
  Future<List<HealthEvent>> queryEvents({
    TimeWindow window = TimeWindow.all,
    Set<HealthEventType>? types,
  }) async {
    return _events.values
        .where((e) => window.contains(e.timestamp))
        .where((e) => types == null || types.contains(e.type))
        .toList()
        .sortedByTime();
  }

  // --- Activity samples ----------------------------------------------------

  @override
  Future<void> upsertActivitySamples(Iterable<ActivitySample> samples) async {
    _activity.addAll(samples);
  }

  @override
  Future<int> deleteActivitySamples({TimeWindow window = TimeWindow.all}) async {
    return _removeWhere(_activity, (s) => window.contains(s.start));
  }

  @override
  Future<List<ActivitySample>> queryActivitySamples({
    TimeWindow window = TimeWindow.all,
    Set<ActivityType>? types,
  }) async {
    return _activity
        .where((s) => window.contains(s.start))
        .where((s) => types == null || types.contains(s.type))
        .toList()
        .sortedByTime();
  }

  // --- Sleep samples -------------------------------------------------------

  @override
  Future<void> upsertSleepSamples(Iterable<SleepSample> samples) async {
    _sleep.addAll(samples);
  }

  @override
  Future<int> deleteSleepSamples({TimeWindow window = TimeWindow.all}) async {
    return _removeWhere(_sleep, (s) => window.contains(s.start));
  }

  @override
  Future<List<SleepSample>> querySleepSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    return _sleep
        .where((s) => window.contains(s.start))
        .toList()
        .sortedByTime();
  }

  // --- Heart-rate samples --------------------------------------------------

  @override
  Future<void> upsertHeartRateSamples(Iterable<HeartRateSample> samples) async {
    _heartRate.addAll(samples);
  }

  @override
  Future<int> deleteHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    return _removeWhere(_heartRate, (s) => window.contains(s.timestamp));
  }

  @override
  Future<List<HeartRateSample>> queryHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    return _heartRate
        .where((s) => window.contains(s.timestamp))
        .toList()
        .sortedByTime();
  }

  // --- AI insights ---------------------------------------------------------

  @override
  Future<void> upsertInsight(AiInsight insight) async {
    _insights[insight.id] = insight;
  }

  @override
  Future<void> deleteInsight(String id) async {
    _insights.remove(id);
  }

  @override
  Future<List<AiInsight>> queryInsights({
    TimeWindow window = TimeWindow.all,
    Set<AiInsightCategory>? categories,
  }) async {
    return _insights.values
        .where((i) => window.contains(i.createdAt))
        .where((i) => categories == null || categories.contains(i.category))
        .toList()
        .sortedByTime();
  }

  @override
  Future<void> clear() async {
    _events.clear();
    _activity.clear();
    _sleep.clear();
    _heartRate.clear();
    _insights.clear();
  }

  static int _removeWhere<T>(List<T> list, bool Function(T) test) {
    final before = list.length;
    list.removeWhere(test);
    return before - list.length;
  }
}
