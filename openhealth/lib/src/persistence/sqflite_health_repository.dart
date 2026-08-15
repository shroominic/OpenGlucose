import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:sqflite/sqflite.dart';

/// On-device, local-first [HealthRepository] backed by SQLite via `sqflite`.
///
/// Why sqflite (vs. hive/isar): the repository's core access pattern is
/// "give me records of type X in time window [a, b)". A relational store
/// indexes those columns and answers such queries in SQL rather than scanning
/// every record in Dart, and it scales comfortably to the many activity /
/// heart-rate rows a HealthKit import produces. sqflite is the most mature,
/// lowest-risk idiomatic on-device store for Flutter and exposes the
/// schema-version migration hooks (`onCreate`/`onUpgrade`) this layer needs.
///
/// Everything stays on the device — there is no cloud sync. CGM reading
/// history keeps its existing `shared_preferences` persistence and is out of
/// scope here.
///
/// Storage model: domain objects are stored as their JSON map (the same
/// `toJson`/`fromJson` the models already define) in a `data` TEXT column, with
/// the fields used for filtering (timestamps as epoch-millis, type/category
/// keys) promoted to dedicated, indexed columns. This keeps schema churn low as
/// models gain fields while keeping window/type queries index-backed.
class SqfliteHealthRepository implements HealthRepository {
  SqfliteHealthRepository({
    required String path,
    DatabaseFactory? databaseFactory,
  }) : _path = path,
       // Defaults to the on-device sqflite plugin factory; tests inject
       // `databaseFactoryFfi` for an on-host, in-memory database.
       _databaseFactory = databaseFactory ?? databaseFactorySqflitePlugin;

  /// Current schema version. Bump and extend [_migrate] for changes.
  static const int schemaVersion = 2;

  static const String tableEvents = 'health_events';
  static const String tableActivity = 'activity_samples';
  static const String tableSleep = 'sleep_samples';
  static const String tableHeartRate = 'heart_rate_samples';
  static const String tableInsights = 'ai_insights';

  final String _path;
  final DatabaseFactory _databaseFactory;
  Database? _db;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('SqfliteHealthRepository.init() must be called first.');
    }
    return db;
  }

  @override
  Future<void> init() async {
    if (_db != null) return;
    _db = await _databaseFactory.openDatabase(
      _path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          // Create at v0 then run forward migrations so onCreate and onUpgrade
          // share one source of truth.
          await _migrate(db, 0, version);
        },
        onUpgrade: _migrate,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Forward migrations from [from] (exclusive) to [to] (inclusive).
  ///
  /// Each `if (from < N)` block upgrades the schema to version N, so the chain
  /// runs cleanly whether a fresh install jumps 0 -> latest or an existing
  /// install steps one version at a time.
  static Future<void> _migrate(Database db, int from, int to) async {
    if (from < 1) {
      await db.execute('''
        CREATE TABLE $tableEvents (
          id TEXT PRIMARY KEY,
          timestamp_ms INTEGER NOT NULL,
          type TEXT NOT NULL,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_events_ts ON $tableEvents(timestamp_ms)',
      );
      await db.execute('CREATE INDEX idx_events_type ON $tableEvents(type)');

      await db.execute('''
        CREATE TABLE $tableActivity (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_ms INTEGER NOT NULL,
          type TEXT NOT NULL,
          record_id TEXT,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_activity_start ON $tableActivity(start_ms)',
      );
      await db.execute(
        'CREATE INDEX idx_activity_type ON $tableActivity(type)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_activity_record_id ON '
        '$tableActivity(record_id) WHERE record_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableSleep (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_ms INTEGER NOT NULL,
          record_id TEXT,
          data TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_sleep_start ON $tableSleep(start_ms)');
      await db.execute(
        'CREATE UNIQUE INDEX idx_sleep_record_id ON '
        '$tableSleep(record_id) WHERE record_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableHeartRate (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp_ms INTEGER NOT NULL,
          record_id TEXT,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_hr_ts ON $tableHeartRate(timestamp_ms)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_hr_record_id ON '
        '$tableHeartRate(record_id) WHERE record_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableInsights (
          id TEXT PRIMARY KEY,
          created_ms INTEGER NOT NULL,
          category TEXT NOT NULL,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_insights_created ON $tableInsights(created_ms)',
      );
      await db.execute(
        'CREATE INDEX idx_insights_category ON $tableInsights(category)',
      );
    }
    if (from >= 1 && from < 2) {
      // Keep legacy rows intact. New imports use the nullable identity column
      // to replace a source record instead of appending duplicates.
      await db.execute('ALTER TABLE $tableActivity ADD COLUMN record_id TEXT');
      await db.execute('ALTER TABLE $tableSleep ADD COLUMN record_id TEXT');
      await db.execute('ALTER TABLE $tableHeartRate ADD COLUMN record_id TEXT');
      await db.execute(
        'CREATE UNIQUE INDEX idx_activity_record_id ON '
        '$tableActivity(record_id) WHERE record_id IS NOT NULL',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_sleep_record_id ON '
        '$tableSleep(record_id) WHERE record_id IS NOT NULL',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_hr_record_id ON '
        '$tableHeartRate(record_id) WHERE record_id IS NOT NULL',
      );
    }
  }

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;

  /// Builds a `WHERE` clause + args for [column] within [window].
  static (String, List<Object?>) _windowClause(
    String column,
    TimeWindow window,
  ) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (window.start != null) {
      clauses.add('$column >= ?');
      args.add(_ms(window.start!));
    }
    if (window.end != null) {
      clauses.add('$column < ?');
      args.add(_ms(window.end!));
    }
    return (clauses.isEmpty ? '' : clauses.join(' AND '), args);
  }

  /// Combines a window clause with an optional `IN (...)` key filter.
  static (String?, List<Object?>) _whereWith(
    String timeColumn,
    TimeWindow window,
    String? keyColumn,
    Iterable<String>? keys,
  ) {
    final (timeClause, args) = _windowClause(timeColumn, window);
    final parts = <String>[if (timeClause.isNotEmpty) timeClause];
    if (keyColumn != null && keys != null) {
      final list = keys.toList();
      if (list.isEmpty) {
        // Empty filter set => match nothing.
        return ('0 = 1', const <Object?>[]);
      }
      parts.add('$keyColumn IN (${List.filled(list.length, '?').join(', ')})');
      args.addAll(list);
    }
    return (parts.isEmpty ? null : parts.join(' AND '), args);
  }

  // --- Health events -------------------------------------------------------

  @override
  Future<void> upsertEvent(HealthEvent event) => upsertEvents([event]);

  @override
  Future<void> upsertEvents(Iterable<HealthEvent> events) async {
    final batch = _database.batch();
    for (final e in events) {
      batch.insert(tableEvents, {
        'id': e.id,
        'timestamp_ms': _ms(e.timestamp),
        'type': e.type.key,
        'data': jsonEncode(e.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> deleteEvent(String id) async {
    await _database.delete(tableEvents, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<HealthEvent?> getEvent(String id) async {
    final rows = await _database.query(
      tableEvents,
      columns: ['data'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HealthEvent.fromJson(_decode(rows.first['data']));
  }

  @override
  Future<List<HealthEvent>> queryEvents({
    TimeWindow window = TimeWindow.all,
    Set<HealthEventType>? types,
  }) async {
    final (where, args) = _whereWith(
      'timestamp_ms',
      window,
      'type',
      types?.map((t) => t.key),
    );
    final rows = await _database.query(
      tableEvents,
      columns: ['data'],
      where: where,
      whereArgs: args,
      orderBy: 'timestamp_ms ASC',
    );
    return rows
        .map((r) => HealthEvent.fromJson(_decode(r['data'])))
        .toList(growable: false);
  }

  // --- Activity samples ----------------------------------------------------

  @override
  Future<void> upsertActivitySamples(Iterable<ActivitySample> samples) async {
    final batch = _database.batch();
    for (final s in samples) {
      batch.insert(tableActivity, {
        'start_ms': _ms(s.start),
        'type': s.type.key,
        'record_id': _recordId(s.source, s.metadata),
        'data': jsonEncode(s.toJson()),
      });
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<int> deleteActivitySamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    final (clause, args) = _windowClause('start_ms', window);
    return _database.delete(
      tableActivity,
      where: clause.isEmpty ? null : clause,
      whereArgs: args,
    );
  }

  @override
  Future<List<ActivitySample>> queryActivitySamples({
    TimeWindow window = TimeWindow.all,
    Set<ActivityType>? types,
  }) async {
    final (where, args) = _whereWith(
      'start_ms',
      window,
      'type',
      types?.map((t) => t.key),
    );
    final rows = await _database.query(
      tableActivity,
      columns: ['data'],
      where: where,
      whereArgs: args,
      orderBy: 'start_ms ASC',
    );
    return rows
        .map((r) => ActivitySample.fromJson(_decode(r['data'])))
        .toList(growable: false);
  }

  // --- Sleep samples -------------------------------------------------------

  @override
  Future<void> upsertSleepSamples(Iterable<SleepSample> samples) async {
    final batch = _database.batch();
    for (final s in samples) {
      batch.insert(tableSleep, {
        'start_ms': _ms(s.start),
        'record_id': _recordId(s.source, s.metadata),
        'data': jsonEncode(s.toJson()),
      });
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<int> deleteSleepSamples({TimeWindow window = TimeWindow.all}) async {
    final (clause, args) = _windowClause('start_ms', window);
    return _database.delete(
      tableSleep,
      where: clause.isEmpty ? null : clause,
      whereArgs: args,
    );
  }

  @override
  Future<List<SleepSample>> querySleepSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    final (clause, args) = _windowClause('start_ms', window);
    final rows = await _database.query(
      tableSleep,
      columns: ['data'],
      where: clause.isEmpty ? null : clause,
      whereArgs: args,
      orderBy: 'start_ms ASC',
    );
    return rows
        .map((r) => SleepSample.fromJson(_decode(r['data'])))
        .toList(growable: false);
  }

  // --- Heart-rate samples --------------------------------------------------

  @override
  Future<void> upsertHeartRateSamples(Iterable<HeartRateSample> samples) async {
    final batch = _database.batch();
    for (final s in samples) {
      batch.insert(tableHeartRate, {
        'timestamp_ms': _ms(s.timestamp),
        'record_id': _recordId(s.source, s.metadata),
        'data': jsonEncode(s.toJson()),
      });
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<int> deleteHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    final (clause, args) = _windowClause('timestamp_ms', window);
    return _database.delete(
      tableHeartRate,
      where: clause.isEmpty ? null : clause,
      whereArgs: args,
    );
  }

  @override
  Future<List<HeartRateSample>> queryHeartRateSamples({
    TimeWindow window = TimeWindow.all,
  }) async {
    final (clause, args) = _windowClause('timestamp_ms', window);
    final rows = await _database.query(
      tableHeartRate,
      columns: ['data'],
      where: clause.isEmpty ? null : clause,
      whereArgs: args,
      orderBy: 'timestamp_ms ASC',
    );
    return rows
        .map((r) => HeartRateSample.fromJson(_decode(r['data'])))
        .toList(growable: false);
  }

  // --- AI insights ---------------------------------------------------------

  @override
  Future<void> upsertInsight(AiInsight insight) async {
    await _database.insert(tableInsights, {
      'id': insight.id,
      'created_ms': _ms(insight.createdAt),
      'category': insight.category.key,
      'data': jsonEncode(insight.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteInsight(String id) async {
    await _database.delete(tableInsights, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<AiInsight>> queryInsights({
    TimeWindow window = TimeWindow.all,
    Set<AiInsightCategory>? categories,
  }) async {
    final (where, args) = _whereWith(
      'created_ms',
      window,
      'category',
      categories?.map((c) => c.key),
    );
    final rows = await _database.query(
      tableInsights,
      columns: ['data'],
      where: where,
      whereArgs: args,
      orderBy: 'created_ms ASC',
    );
    return rows
        .map((r) => AiInsight.fromJson(_decode(r['data'])))
        .toList(growable: false);
  }

  @override
  Future<void> clear() async {
    final batch = _database.batch();
    const [
      tableEvents,
      tableActivity,
      tableSleep,
      tableHeartRate,
      tableInsights,
    ].forEach(batch.delete);
    await batch.commit(noResult: true);
  }

  static Map<String, Object?> _decode(Object? data) {
    return jsonDecode(data! as String) as Map<String, Object?>;
  }

  static String? _recordId(DataSource source, HealthSampleMetadata? metadata) =>
      metadata?.identityKey(source);
}
