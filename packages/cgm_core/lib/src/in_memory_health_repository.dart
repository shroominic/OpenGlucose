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
/// Samples with platform provenance are de-duplicated by their typed import
/// identity. Legacy/manual samples without provenance retain the historical
/// append-only behavior.
class InMemoryHealthRepository implements HealthRepository {
  final Map<String, HealthEvent> _events = <String, HealthEvent>{};
  final List<ActivitySample> _activity = <ActivitySample>[];
  final List<SleepSample> _sleep = <SleepSample>[];
  final List<HeartRateSample> _heartRate = <HeartRateSample>[];
  final Map<String, HealthImportTombstone> _importTombstones =
      <String, HealthImportTombstone>{};
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
    final values = samples.toList(growable: false);
    _validateImportBatch(
      values,
      kind: HealthSampleKind.activity,
      provenanceOf: (sample) => sample.provenance,
      validate: (sample) => sample.toJson(),
    );
    for (final sample in values) {
      _replaceImportedSample(
        _activity,
        sample,
        kind: HealthSampleKind.activity,
        provenanceOf: (value) => value.provenance,
      );
    }
  }

  @override
  Future<int> deleteActivitySamples({
    TimeWindow window = TimeWindow.all,
  }) async {
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
    final values = samples.toList(growable: false);
    _validateImportBatch(
      values,
      kind: HealthSampleKind.sleep,
      provenanceOf: (sample) => sample.provenance,
      validate: (sample) => sample.toJson(),
    );
    for (final sample in values) {
      _replaceImportedSample(
        _sleep,
        sample,
        kind: HealthSampleKind.sleep,
        provenanceOf: (value) => value.provenance,
      );
    }
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
    final values = samples.toList(growable: false);
    _validateImportBatch(
      values,
      kind: HealthSampleKind.heartRate,
      provenanceOf: (sample) => sample.provenance,
      validate: (sample) => sample.toJson(),
    );
    for (final sample in values) {
      _replaceImportedSample(
        _heartRate,
        sample,
        kind: HealthSampleKind.heartRate,
        provenanceOf: (value) => value.provenance,
      );
    }
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

  // --- Imported-record tombstones -----------------------------------------

  @override
  Future<void> reconcileImportTombstones(
    Iterable<HealthImportTombstone> tombstones,
  ) async {
    final values = tombstones.toList(growable: false);
    final seen = <String>{};
    for (final tombstone in values) {
      tombstone.toJson();
      final key = _tombstoneKey(tombstone.kind, tombstone.provenance.identity);
      if (!seen.add(key)) {
        throw ArgumentError(
          'A tombstone batch must not contain a duplicate import identity.',
        );
      }
    }

    for (final tombstone in values) {
      final identity = tombstone.provenance.identity;
      switch (tombstone.kind) {
        case HealthSampleKind.activity:
          _activity.removeWhere(
            (sample) => _hasIdentity(sample.provenance, identity),
          );
          break;
        case HealthSampleKind.sleep:
          _sleep.removeWhere(
            (sample) => _hasIdentity(sample.provenance, identity),
          );
          break;
        case HealthSampleKind.heartRate:
          _heartRate.removeWhere(
            (sample) => _hasIdentity(sample.provenance, identity),
          );
          break;
      }
      _importTombstones[_tombstoneKey(tombstone.kind, identity)] = tombstone;
    }
  }

  @override
  Future<List<HealthImportTombstone>> queryImportTombstones({
    HealthSampleKind? kind,
    HealthSourcePlatform? platform,
  }) async {
    final values =
        _importTombstones.values
            .where((tombstone) => kind == null || tombstone.kind == kind)
            .where(
              (tombstone) =>
                  platform == null ||
                  tombstone.provenance.identity.platform == platform,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byKind = left.kind.key.compareTo(right.kind.key);
            if (byKind != 0) return byKind;
            final byPlatform = left.provenance.identity.platform.key.compareTo(
              right.provenance.identity.platform.key,
            );
            if (byPlatform != 0) return byPlatform;
            return left.provenance.identity.externalId.compareTo(
              right.provenance.identity.externalId,
            );
          });
    return values;
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
    _importTombstones.clear();
    _insights.clear();
  }

  static int _removeWhere<T>(List<T> list, bool Function(T) test) {
    final before = list.length;
    list.removeWhere(test);
    return before - list.length;
  }

  void _replaceImportedSample<T>(
    List<T> list,
    T sample, {
    required HealthSampleKind kind,
    required HealthSampleProvenance? Function(T) provenanceOf,
  }) {
    final provenance = provenanceOf(sample);
    if (provenance == null) {
      list.add(sample);
      return;
    }
    final identity = provenance.identity;
    _importTombstones.remove(_tombstoneKey(kind, identity));
    list.removeWhere(
      (existing) => _hasIdentity(provenanceOf(existing), identity),
    );
    list.add(sample);
  }

  static void _validateImportBatch<T>(
    Iterable<T> samples, {
    required HealthSampleKind kind,
    required HealthSampleProvenance? Function(T) provenanceOf,
    required Map<String, Object?> Function(T) validate,
  }) {
    final seen = <String>{};
    for (final sample in samples) {
      validate(sample);
      final provenance = provenanceOf(sample);
      if (provenance == null) continue;
      if (provenance.isDeleted) {
        throw ArgumentError(
          'Use reconcileImportTombstones for source-reported deletions.',
        );
      }
      if (!seen.add(_tombstoneKey(kind, provenance.identity))) {
        throw ArgumentError(
          'A sample batch must not contain a duplicate import identity.',
        );
      }
    }
  }

  static bool _hasIdentity(
    HealthSampleProvenance? provenance,
    HealthImportIdentity identity,
  ) =>
      provenance != null &&
      provenance.identity.platform == identity.platform &&
      provenance.identity.externalId == identity.externalId;

  static String _tombstoneKey(
    HealthSampleKind kind,
    HealthImportIdentity identity,
  ) => '${kind.key}:${identity.stableKey}';
}
