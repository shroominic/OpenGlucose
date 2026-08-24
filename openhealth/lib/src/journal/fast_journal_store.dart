import 'package:cgm_core/cgm_core.dart';

/// The manual entry types that the optional fast journal supports.
///
/// These values are deliberately separate from [HealthEventType]. The journal
/// has its own isolated local-storage protocol so a v0.1.4 app does not try to
/// decode new sleep or observed-rise data as an older health event.
enum FastJournalKind {
  meal,
  activity,
  sleep
  ;

  String get label => switch (this) {
    FastJournalKind.meal => 'Meal',
    FastJournalKind.activity => 'Activity',
    FastJournalKind.sleep => 'Sleep',
  };

  static FastJournalKind fromKey(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    throw FormatException('Unsupported fast-journal kind: $value');
  }
}

/// A local reference to an observed glucose-rise episode near a journal entry.
///
/// The reference preserves only its observed time bounds. It is not a causal
/// statement and intentionally does not persist glucose values.
class FastJournalRiseReference {
  const FastJournalRiseReference({
    required this.startedAt,
    required this.lastObservedAt,
  });

  final DateTime startedAt;
  final DateTime lastObservedAt;

  Map<String, Object?> toJson() {
    _validate();
    return <String, Object?>{
      'startedAt': startedAt.toUtc().toIso8601String(),
      'lastObservedAt': lastObservedAt.toUtc().toIso8601String(),
    };
  }

  factory FastJournalRiseReference.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'startedAt', 'lastObservedAt'},
      context: 'fast-journal rise reference',
    );
    final reference = FastJournalRiseReference(
      startedAt: _readRequiredUtcDate(json, 'startedAt'),
      lastObservedAt: _readRequiredUtcDate(json, 'lastObservedAt'),
    );
    reference._validate();
    return reference;
  }

  void _validate() {
    if (lastObservedAt.isBefore(startedAt)) {
      throw const FormatException('lastObservedAt must not precede startedAt');
    }
  }
}

/// One local, user-authored fast-journal entry.
///
/// The entry has an explicit manual source, an editable occurrence time, and
/// an isolated versioned serialization contract. It is not written to the
/// legacy `health_events` JSON table.
class FastJournalEntry {
  const FastJournalEntry({
    required this.id,
    required this.kind,
    required this.occurredAt,
    this.label,
    this.duration,
    this.riseReference,
  });

  static const int formatVersion = 1;

  final String id;
  final FastJournalKind kind;
  final DateTime occurredAt;
  final String? label;
  final Duration? duration;
  final FastJournalRiseReference? riseReference;

  /// All entries in this protocol are local and manually authored.
  DataSource get source => DataSource.manual;

  FastJournalEntry copyWith({
    String? id,
    FastJournalKind? kind,
    DateTime? occurredAt,
    String? label,
    Duration? duration,
    FastJournalRiseReference? riseReference,
    bool clearLabel = false,
    bool clearDuration = false,
    bool clearRiseReference = false,
  }) => FastJournalEntry(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    occurredAt: occurredAt ?? this.occurredAt,
    label: clearLabel ? null : (label ?? this.label),
    duration: clearDuration ? null : (duration ?? this.duration),
    riseReference: clearRiseReference
        ? null
        : (riseReference ?? this.riseReference),
  );

  Map<String, Object?> toJson() {
    _validate();
    return <String, Object?>{
      'formatVersion': formatVersion,
      'id': id,
      'kind': kind.name,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      'label': label,
      'durationMs': duration?.inMilliseconds,
      'riseReference': riseReference?.toJson(),
      'source': source.key,
    };
  }

  factory FastJournalEntry.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{
        'formatVersion',
        'id',
        'kind',
        'occurredAt',
        'label',
        'durationMs',
        'riseReference',
        'source',
      },
      context: 'fast-journal entry',
    );
    final version = json['formatVersion'];
    if (version is! int || version != formatVersion) {
      throw FormatException('Unsupported fast-journal formatVersion: $version');
    }
    final source = _readRequiredString(json, 'source');
    if (source != DataSource.manual.key) {
      throw FormatException('Unsupported fast-journal source: $source');
    }
    return FastJournalEntry(
      id: _readRequiredString(json, 'id', nonEmpty: true),
      kind: FastJournalKind.fromKey(_readRequiredString(json, 'kind')),
      occurredAt: _readRequiredUtcDate(json, 'occurredAt'),
      label: _readOptionalString(json, 'label'),
      duration: _readOptionalDuration(json, 'durationMs'),
      riseReference: _readOptionalRiseReference(json),
    ).._validate();
  }

  void _validate() {
    if (id.trim().isEmpty) {
      throw const FormatException('id must not be empty');
    }
    if (label != null && label!.length > _maxJournalLabelLength) {
      throw const FormatException(
        'Use at most $_maxJournalLabelLength characters.',
      );
    }
    if (duration != null && duration!.isNegative) {
      throw const FormatException('durationMs must not be negative');
    }
    riseReference?._validate();
  }
}

/// Isolated persistence for optional manual-journal records.
///
/// `saveFastJournalEntry` is the single claim operation for an optional rise.
/// It either writes the one requested, unclaimed rise reference with the entry
/// or writes the entry without a reference. Implementations must make that
/// decision atomically.
abstract interface class FastJournalStore {
  /// Returns local manual entries, newest first.
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    required int limit,
  });

  /// Whether the rise episode beginning at [riseStartedAt] already has its
  /// durable one-time observational claim.
  Future<bool> isFastJournalRiseClaimed({required DateTime riseStartedAt});

  /// Saves [entry] and atomically claims [requestedRise] when still unclaimed.
  ///
  /// [entry] must have no [FastJournalEntry.riseReference]; the store returns
  /// the exact persisted entry, with a reference only when its claim succeeded.
  Future<FastJournalEntry> saveFastJournalEntry({
    required FastJournalEntry entry,
    FastJournalRiseReference? requestedRise,
  });
}

/// Resolves the journal protocol from the app-owned health repository.
typedef FastJournalStoreResolver =
    FastJournalStore Function(
      HealthRepository repository,
    );

/// Obtains the optional journal store from the app-owned health repository.
///
/// Production storage implements both interfaces. A different repository is a
/// composition error and fails closed instead of opening another database.
FastJournalStore fastJournalStoreFor(HealthRepository repository) {
  if (repository is FastJournalStore) return repository as FastJournalStore;
  throw StateError(
    'The app health repository does not support local diary storage.',
  );
}

const int _maxJournalLabelLength = 160;

String _readRequiredString(
  Map<String, Object?> json,
  String key, {
  bool nonEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (nonEmpty && value.trim().isEmpty)) {
    throw FormatException(
      '$key must be ${nonEmpty ? 'a non-empty ' : ''}String',
    );
  }
  return value;
}

String? _readOptionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a String or null');
  return value;
}

Duration? _readOptionalDuration(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('$key must be a non-negative integer or null');
  }
  return Duration(milliseconds: value);
}

FastJournalRiseReference? _readOptionalRiseReference(
  Map<String, Object?> json,
) {
  final value = json['riseReference'];
  if (value == null) return null;
  if (value is! Map<String, Object?>) {
    throw const FormatException('riseReference must be an object or null');
  }
  return FastJournalRiseReference.fromJson(value);
}

DateTime _readRequiredUtcDate(Map<String, Object?> json, String key) {
  final value = _readRequiredString(json, key);
  final match = RegExp(
    r'^([+-]?\d{4,6})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) {
    throw FormatException('$key must be an ISO-8601 timestamp with a timezone');
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final zone = match.group(8)!;
  final zoneHour = zone == 'Z' ? 0 : int.parse(zone.substring(1, 3));
  final zoneMinute = zone == 'Z' ? 0 : int.parse(zone.substring(4, 6));
  final validDay =
      month >= 1 && month <= 12 && day >= 1 && day <= _daysInMonth(year, month);
  if (!validDay ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      zoneHour > 23 ||
      zoneMinute > 59) {
    throw FormatException('$key contains an invalid date or time');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key is not a valid timestamp');
  return parsed.toUtc();
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> allowed, {
  required String context,
}) {
  if (json.keys.any((key) => !allowed.contains(key)) ||
      json.length != allowed.length) {
    throw FormatException('Unsupported $context fields');
  }
}

int _daysInMonth(int year, int month) => switch (month) {
  2 when year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
  2 => 28,
  4 || 6 || 9 || 11 => 30,
  _ => 31,
};
