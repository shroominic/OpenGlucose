import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A user-visible, wellness-only glucose freshness/threshold condition.
enum GlucoseAlertType { low, high, stale }

/// The result of evaluating a set of readings at one instant.
///
/// This model deliberately contains no platform notification payload. Native
/// notification/widget adapters can consume the result later while the same
/// deterministic evaluator remains testable and useful in the foreground UI.
class GlucoseAlertEvaluation {
  const GlucoseAlertEvaluation({
    required this.evaluatedAt,
    this.activeType,
    this.readingAt,
    this.valueMgdl,
    this.age,
  });

  /// The clock instant used for this evaluation.
  final DateTime evaluatedAt;

  /// The currently active condition, or `null` when the signal is healthy,
  /// unavailable, or explicitly suppressed during sensor warmup.
  final GlucoseAlertType? activeType;

  /// Timestamp of the latest usable reading, when one exists.
  final DateTime? readingAt;

  /// Raw glucose value in mg/dL for low/high conditions.
  final double? valueMgdl;

  /// Age of [readingAt] at [evaluatedAt], clamped to zero for clock skew.
  final Duration? age;

  bool get isActive => activeType != null;
}

/// Deterministically evaluates low, high, and stale conditions.
///
/// Values are compared in mg/dL, independent of the user's display unit. A
/// reading at exactly either configured bound is considered out of range. A
/// stale condition takes precedence over low/high so old values are never
/// presented as current alerts. Callers should set `suppressGlucoseAlerts`
/// while a sensor is warming up or the reading window is otherwise known to
/// be provisional.
class GlucoseAlertEvaluator {
  GlucoseAlertEvaluator({
    required this.lowThresholdMgdl,
    required this.highThresholdMgdl,
    this.staleAfter = const Duration(minutes: 15),
  }) {
    if (!lowThresholdMgdl.isFinite || lowThresholdMgdl <= 0) {
      throw ArgumentError.value(
        lowThresholdMgdl,
        'lowThresholdMgdl',
        'must be finite and greater than zero',
      );
    }
    if (!highThresholdMgdl.isFinite || highThresholdMgdl <= lowThresholdMgdl) {
      throw ArgumentError.value(
        highThresholdMgdl,
        'highThresholdMgdl',
        'must be finite and greater than lowThresholdMgdl',
      );
    }
    if (staleAfter <= Duration.zero) {
      throw ArgumentError.value(
        staleAfter,
        'staleAfter',
        'must be greater than zero',
      );
    }
  }

  final double lowThresholdMgdl;
  final double highThresholdMgdl;
  final Duration staleAfter;

  /// Evaluates the latest timestamped reading no later than [now].
  GlucoseAlertEvaluation evaluate({
    required Iterable<CgmReading> readings,
    required DateTime now,
    bool suppressGlucoseAlerts = false,
  }) {
    final evaluatedAt = now.toUtc();
    CgmReading? latest;
    for (final reading in readings) {
      final recordedAt = reading.recordedAt?.toUtc();
      if (recordedAt == null ||
          recordedAt.isAfter(evaluatedAt) ||
          !reading.valueMgdl.isFinite ||
          reading.valueMgdl <= 0) {
        continue;
      }
      if (latest == null || recordedAt.isAfter(latest.recordedAt!.toUtc())) {
        latest = reading;
      }
    }
    if (latest == null) {
      return GlucoseAlertEvaluation(evaluatedAt: evaluatedAt);
    }

    final readingAt = latest.recordedAt!.toUtc();
    final age = evaluatedAt.difference(readingAt);
    final nonNegativeAge = age.isNegative ? Duration.zero : age;
    // Warmup and other explicitly provisional windows suppress every alert,
    // including stale, so initialization data cannot create an episode.
    if (suppressGlucoseAlerts) {
      return GlucoseAlertEvaluation(
        evaluatedAt: evaluatedAt,
        readingAt: readingAt,
        valueMgdl: latest.valueMgdl,
        age: nonNegativeAge,
      );
    }
    if (nonNegativeAge > staleAfter) {
      return GlucoseAlertEvaluation(
        evaluatedAt: evaluatedAt,
        activeType: GlucoseAlertType.stale,
        readingAt: readingAt,
        valueMgdl: latest.valueMgdl,
        age: nonNegativeAge,
      );
    }
    if (latest.isDisplayProvisional) {
      return GlucoseAlertEvaluation(
        evaluatedAt: evaluatedAt,
        readingAt: readingAt,
        valueMgdl: latest.valueMgdl,
        age: nonNegativeAge,
      );
    }

    final activeType = latest.valueMgdl <= lowThresholdMgdl
        ? GlucoseAlertType.low
        : latest.valueMgdl >= highThresholdMgdl
        ? GlucoseAlertType.high
        : null;
    return GlucoseAlertEvaluation(
      evaluatedAt: evaluatedAt,
      activeType: activeType,
      readingAt: readingAt,
      valueMgdl: latest.valueMgdl,
      age: nonNegativeAge,
    );
  }
}

/// A persisted alert episode. One episode remains open until the evaluator
/// returns a different condition or no condition.
class GlucoseAlertRecord {
  const GlucoseAlertRecord({
    required this.id,
    required this.type,
    required this.startedAt,
    required this.readingAt,
    this.valueMgdl,
    this.endedAt,
  });

  final String id;
  final GlucoseAlertType type;
  final DateTime startedAt;
  final DateTime readingAt;
  final double? valueMgdl;
  final DateTime? endedAt;

  bool get isActive => endedAt == null;

  GlucoseAlertRecord copyWith({DateTime? endedAt}) {
    return GlucoseAlertRecord(
      id: id,
      type: type,
      startedAt: startedAt,
      readingAt: readingAt,
      valueMgdl: valueMgdl,
      endedAt: endedAt ?? this.endedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': 1,
    'id': id,
    'type': type.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'readingAt': readingAt.toUtc().toIso8601String(),
    'valueMgdl': valueMgdl,
    'endedAt': endedAt?.toUtc().toIso8601String(),
  };

  factory GlucoseAlertRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (json['formatVersion'] != 1 ||
        id is! String ||
        id.isEmpty ||
        json['type'] is! String) {
      throw const FormatException('Unsupported glucose alert record');
    }
    final type = GlucoseAlertType.values.asNameMap()[json['type']];
    final startedAt = _parseTimestamp(json['startedAt'], 'startedAt');
    final readingAt = _parseTimestamp(json['readingAt'], 'readingAt');
    final endedAt = json['endedAt'] == null
        ? null
        : _parseTimestamp(json['endedAt'], 'endedAt');
    if (endedAt != null && endedAt.isBefore(startedAt)) {
      throw const FormatException('endedAt must not precede startedAt');
    }
    final value = json['valueMgdl'];
    if (value != null && (value is! num || !value.toDouble().isFinite)) {
      throw const FormatException('valueMgdl must be finite or null');
    }
    if (type == null) {
      throw const FormatException('Unsupported glucose alert type');
    }
    return GlucoseAlertRecord(
      id: id,
      type: type,
      startedAt: startedAt,
      readingAt: readingAt,
      valueMgdl: (value as num?)?.toDouble(),
      endedAt: endedAt,
    );
  }
}

/// Immutable append-only alert history with open-episode transition logic.
class GlucoseAlertHistory {
  GlucoseAlertHistory(Iterable<GlucoseAlertRecord> records)
    : records = List<GlucoseAlertRecord>.unmodifiable(
        records.toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt)),
      );

  factory GlucoseAlertHistory.empty() => GlucoseAlertHistory(const []);

  final List<GlucoseAlertRecord> records;

  /// Applies one evaluation and returns a new history snapshot.
  GlucoseAlertHistory transition({
    required GlucoseAlertEvaluation evaluation,
    required String Function() idGenerator,
  }) {
    final open = records.where((record) => record.isActive).toList();
    final next = List<GlucoseAlertRecord>.of(records);
    if (evaluation.activeType == null) {
      if (open.isEmpty) return this;
      for (final record in open) {
        final index = next.indexOf(record);
        next[index] = record.copyWith(endedAt: evaluation.evaluatedAt);
      }
      return GlucoseAlertHistory(next);
    }
    if (open.length == 1 && open.single.type == evaluation.activeType) {
      return this;
    }
    for (final record in open) {
      final index = next.indexOf(record);
      next[index] = record.copyWith(endedAt: evaluation.evaluatedAt);
    }
    final id = idGenerator().trim();
    if (id.isEmpty) {
      throw StateError('Alert id generator returned an empty identifier.');
    }
    next.add(
      GlucoseAlertRecord(
        id: id,
        type: evaluation.activeType!,
        startedAt: evaluation.evaluatedAt,
        readingAt: evaluation.readingAt ?? evaluation.evaluatedAt,
        valueMgdl: evaluation.valueMgdl,
      ),
    );
    return GlucoseAlertHistory(next);
  }

  List<Map<String, Object?>> toJson() =>
      records.map((record) => record.toJson()).toList(growable: false);

  factory GlucoseAlertHistory.fromJson(List<Object?> json) {
    return GlucoseAlertHistory(
      json.map((entry) {
        if (entry is! Map<String, Object?>) {
          throw const FormatException('Alert history entry must be an object');
        }
        return GlucoseAlertRecord.fromJson(entry);
      }),
    );
  }
}

/// Persistence boundary for local alert history.
abstract interface class GlucoseAlertHistoryPersistence {
  Future<GlucoseAlertHistory> load();

  Future<void> save(GlucoseAlertHistory history);

  Future<void> clear();
}

/// SharedPreferences-backed local history with a bounded retention window.
class SharedPreferencesGlucoseAlertHistory
    implements GlucoseAlertHistoryPersistence {
  SharedPreferencesGlucoseAlertHistory(
    this.preferences, {
    this.maxRecords = 200,
  }) : assert(maxRecords > 0, 'maxRecords must be greater than zero');

  static const storageKey = 'openHealth.glucoseAlertHistory.v1';

  final SharedPreferences preferences;
  final int maxRecords;

  @override
  Future<GlucoseAlertHistory> load() async {
    final raw = preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return GlucoseAlertHistory.empty();
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      throw const FormatException('Alert history must be a JSON list');
    }
    return GlucoseAlertHistory.fromJson(decoded);
  }

  @override
  Future<void> save(GlucoseAlertHistory history) async {
    final records = history.records.length <= maxRecords
        ? history.records
        : history.records.skip(history.records.length - maxRecords);
    final encoded = jsonEncode(
      records.map((record) => record.toJson()).toList(growable: false),
    );
    if (!await preferences.setString(storageKey, encoded)) {
      throw StateError('Could not persist local glucose alert history.');
    }
  }

  @override
  Future<void> clear() async {
    if (!await preferences.remove(storageKey) &&
        preferences.containsKey(storageKey)) {
      throw StateError('Could not clear local glucose alert history.');
    }
  }
}

/// Foreground monitor that evaluates readings and persists only episode
/// transitions, avoiding one record per refresh tick.
class GlucoseAlertMonitor {
  GlucoseAlertMonitor({
    required this.evaluator,
    required this.persistence,
    String Function()? idGenerator,
  }) : _idGenerator = idGenerator ?? _defaultAlertId;

  final GlucoseAlertEvaluator evaluator;
  final GlucoseAlertHistoryPersistence persistence;
  final String Function() _idGenerator;
  GlucoseAlertHistory _history = GlucoseAlertHistory.empty();
  bool _initialized = false;

  GlucoseAlertHistory get history => _history;

  Future<void> initialize() async {
    if (_initialized) return;
    _history = await persistence.load();
    _initialized = true;
  }

  Future<GlucoseAlertEvaluation> evaluate({
    required Iterable<CgmReading> readings,
    required DateTime now,
    bool suppressGlucoseAlerts = false,
  }) async {
    await initialize();
    final evaluation = evaluator.evaluate(
      readings: readings,
      now: now,
      suppressGlucoseAlerts: suppressGlucoseAlerts,
    );
    final next = _history.transition(
      evaluation: evaluation,
      idGenerator: _idGenerator,
    );
    if (!identical(next, _history)) {
      await persistence.save(next);
      _history = next;
    }
    return evaluation;
  }
}

DateTime _parseTimestamp(Object? value, String field) {
  if (value is! String) {
    throw FormatException('$field must be an ISO-8601 timestamp');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !value.contains(RegExp(r'(Z|[+-]\d\d:\d\d)$'))) {
    throw FormatException('$field must include a timezone');
  }
  return parsed.toUtc();
}

String _defaultAlertId() =>
    'alert-${DateTime.now().toUtc().microsecondsSinceEpoch}';
