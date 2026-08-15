import 'dart:math';

import 'health_event.dart';
import 'health_repository.dart';
import 'health_samples.dart';
import 'timeline.dart';

/// Creates a stable identifier for a manually entered journal event.
///
/// The callback is injectable so callers can use a platform UUID implementation
/// and tests can use deterministic identifiers. The repository treats the
/// returned value as the event's replacement key, so callers must not reuse an
/// identifier for two independent entries.
typedef JournalIdGenerator = String Function();

/// A read-only snapshot of context records for a time window.
///
/// The individual streams remain available for type-specific rendering. The
/// [timeline] getter provides one chronologically ordered stream for a compact
/// Today/journal view without requiring UI code to know each repository API.
class JournalContext {
  JournalContext({
    required this.window,
    required Iterable<HealthEvent> events,
    required Iterable<ActivitySample> activitySamples,
    required Iterable<SleepSample> sleepSamples,
    required Iterable<HeartRateSample> heartRateSamples,
  }) : events = List<HealthEvent>.unmodifiable(events),
       activitySamples = List<ActivitySample>.unmodifiable(activitySamples),
       sleepSamples = List<SleepSample>.unmodifiable(sleepSamples),
       heartRateSamples = List<HeartRateSample>.unmodifiable(heartRateSamples);

  /// The half-open window used to load this snapshot.
  final TimeWindow window;

  /// User-authored events such as meals, exercise, and notes.
  final List<HealthEvent> events;

  /// Imported or manually entered activity intervals.
  final List<ActivitySample> activitySamples;

  /// Imported sleep intervals.
  final List<SleepSample> sleepSamples;

  /// Imported heart-rate samples.
  final List<HeartRateSample> heartRateSamples;

  /// All context entries ordered by their timeline timestamp.
  List<TimelineEntry> get timeline => mergeTimelines(<Iterable<TimelineEntry>>[
    events,
    activitySamples,
    sleepSamples,
    heartRateSamples,
  ]);
}

/// Local-first facade for fast meal, exercise, and note journaling.
///
/// [JournalService] deliberately only depends on the pure-Dart
/// [HealthRepository]. It does not add a network client, AI provider, or
/// Flutter state-management dependency. The app can therefore use the same
/// API with SQLite in production and [InMemoryHealthRepository] in tests.
///
/// The service stores all timestamps as UTC instants while
/// [loadContextForDay]
/// interprets a day in the device's local calendar. This keeps persistence
/// unambiguous without forcing the UI to perform timezone arithmetic.
class JournalService {
  JournalService({
    required HealthRepository repository,
    JournalIdGenerator? idGenerator,
    DateTime Function()? clock,
  }) : _repository = repository,
       _idGenerator = idGenerator ?? _defaultJournalId,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final HealthRepository _repository;
  final JournalIdGenerator _idGenerator;
  final DateTime Function() _clock;

  /// Initializes the underlying repository. Safe to call more than once.
  Future<void> init() => _repository.init();

  /// Closes the underlying repository.
  Future<void> close() => _repository.close();

  /// Persists an already-normalized event and returns it for optimistic UI
  /// updates. Serialization is validated before touching storage.
  Future<HealthEvent> saveEvent(HealthEvent event) async {
    // Validate the public contract before writing. This also prevents a
    // malformed event from being hidden behind a backend-specific error.
    event.toJson();
    await _repository.upsertEvent(event);
    return event;
  }

  /// Logs a meal with optional macros and a short description.
  Future<HealthEvent> logMeal({
    DateTime? at,
    String? id,
    double? carbsGrams,
    double? proteinGrams,
    double? fatGrams,
    double? caloriesKcal,
    String? description,
    Iterable<String> tags = const <String>[],
  }) {
    return saveEvent(
      HealthEvent(
        id: id ?? _newId(HealthEventType.meal),
        timestamp: _timestamp(at),
        type: HealthEventType.meal,
        payload: MealPayload(
          carbsGrams: carbsGrams,
          proteinGrams: proteinGrams,
          fatGrams: fatGrams,
          caloriesKcal: caloriesKcal,
          description: description,
        ),
        tags: List<String>.unmodifiable(tags),
      ),
    );
  }

  /// Logs a manually entered exercise session.
  Future<HealthEvent> logExercise({
    DateTime? at,
    String? id,
    String? activity,
    Duration? duration,
    ExerciseIntensity? intensity,
    double? energyKcal,
    Iterable<String> tags = const <String>[],
  }) {
    return saveEvent(
      HealthEvent(
        id: id ?? _newId(HealthEventType.exercise),
        timestamp: _timestamp(at),
        type: HealthEventType.exercise,
        payload: ExercisePayload(
          activity: activity,
          duration: duration,
          intensity: intensity,
          energyKcal: energyKcal,
        ),
        tags: List<String>.unmodifiable(tags),
      ),
    );
  }

  /// Logs a free-text note. Empty notes are rejected so the journal cannot
  /// accumulate entries that render as an unexplained blank marker.
  Future<HealthEvent> logNote({
    required String text,
    DateTime? at,
    String? id,
    Iterable<String> tags = const <String>[],
  }) {
    if (text.trim().isEmpty) {
      throw const FormatException('text must not be empty');
    }
    return saveEvent(
      HealthEvent(
        id: id ?? _newId(HealthEventType.note),
        timestamp: _timestamp(at),
        type: HealthEventType.note,
        payload: NotePayload(text: text),
        tags: List<String>.unmodifiable(tags),
      ),
    );
  }

  /// Deletes one journal event. Missing identifiers are a no-op.
  Future<void> deleteEvent(String id) => _repository.deleteEvent(id);

  /// Queries journal events for a half-open [window].
  Future<List<HealthEvent>> queryEvents({
    TimeWindow window = TimeWindow.all,
    Set<HealthEventType>? types,
  }) => _repository.queryEvents(window: window, types: types);

  /// Stores imported activity samples in one repository operation.
  Future<void> importActivity(Iterable<ActivitySample> samples) =>
      _repository.upsertActivitySamples(samples);

  /// Stores imported sleep samples in one repository operation.
  Future<void> importSleep(Iterable<SleepSample> samples) =>
      _repository.upsertSleepSamples(samples);

  /// Stores imported heart-rate samples in one repository operation.
  Future<void> importHeartRate(Iterable<HeartRateSample> samples) =>
      _repository.upsertHeartRateSamples(samples);

  /// Loads all local context streams for [window] concurrently.
  Future<JournalContext> loadContext({
    TimeWindow window = TimeWindow.all,
  }) async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      _repository.queryEvents(window: window),
      _repository.queryActivitySamples(window: window),
      _repository.querySleepSamples(window: window),
      _repository.queryHeartRateSamples(window: window),
    ]);
    return JournalContext(
      window: window,
      events: results[0]! as List<HealthEvent>,
      activitySamples: results[1]! as List<ActivitySample>,
      sleepSamples: results[2]! as List<SleepSample>,
      heartRateSamples: results[3]! as List<HeartRateSample>,
    );
  }

  /// Loads local context for one device-local calendar day.
  ///
  /// The returned SQL window is still represented as UTC instants. Local
  /// boundaries are computed before conversion so daylight-saving transitions
  /// do not silently turn a user's calendar day into a fixed 24-hour period.
  Future<JournalContext> loadContextForDay(DateTime day) {
    final local = day.toLocal();
    final start = DateTime(local.year, local.month, local.day);
    final end = DateTime(local.year, local.month, local.day + 1);
    return loadContext(
      window: TimeWindow(start: start.toUtc(), end: end.toUtc()),
    );
  }

  DateTime _timestamp(DateTime? timestamp) => (timestamp ?? _clock()).toUtc();

  String _newId(HealthEventType type) {
    final suffix = _idGenerator().trim();
    if (suffix.isEmpty) {
      throw StateError('JournalIdGenerator returned an empty identifier.');
    }
    return '${type.key}-$suffix';
  }
}

final Random _journalRandom = Random.secure();

String _defaultJournalId() {
  final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
  final entropy = List<String>.generate(
    12,
    (_) => _journalRandom.nextInt(16).toRadixString(16),
    growable: false,
  ).join();
  return '$timestamp-$entropy';
}
