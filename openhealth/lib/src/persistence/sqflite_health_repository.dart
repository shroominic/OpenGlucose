import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:sqflite/sqflite.dart';

import '../journal/fast_journal_store.dart';

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
class SqfliteHealthRepository implements HealthRepository, FastJournalStore {
  SqfliteHealthRepository({
    required String path,
    DatabaseFactory? databaseFactory,
  }) : _path = path,
       // Defaults to the on-device sqflite plugin factory; tests inject
       // `databaseFactoryFfi` for an on-host, in-memory database.
       _databaseFactory = databaseFactory ?? databaseFactorySqflitePlugin;

  /// Current schema version. Bump and extend [_migrate] for changes.
  static const int schemaVersion = 3;

  static const String tableEvents = 'health_events';
  static const String tableActivity = 'activity_samples';
  static const String tableSleep = 'sleep_samples';
  static const String tableHeartRate = 'heart_rate_samples';
  static const String tableImportTombstones = 'health_import_tombstones';
  static const String tableInsights = 'ai_insights';
  static const String tableFastJournalEntries = 'fast_journal_entries';

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
        onDowngrade: _rejectDowngrade,
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
          identity_platform TEXT,
          external_id TEXT,
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
        'CREATE UNIQUE INDEX idx_activity_import_identity ON $tableActivity('
        ' identity_platform, external_id) WHERE identity_platform IS NOT NULL '
        'AND external_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableSleep (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_ms INTEGER NOT NULL,
          identity_platform TEXT,
          external_id TEXT,
          data TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_sleep_start ON $tableSleep(start_ms)');
      await db.execute(
        'CREATE UNIQUE INDEX idx_sleep_import_identity ON $tableSleep('
        ' identity_platform, external_id) WHERE identity_platform IS NOT NULL '
        'AND external_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableHeartRate (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp_ms INTEGER NOT NULL,
          identity_platform TEXT,
          external_id TEXT,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_hr_ts ON $tableHeartRate(timestamp_ms)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX idx_hr_import_identity ON $tableHeartRate('
        ' identity_platform, external_id) WHERE identity_platform IS NOT NULL '
        'AND external_id IS NOT NULL',
      );

      await db.execute('''
        CREATE TABLE $tableImportTombstones (
          sample_kind TEXT NOT NULL,
          identity_platform TEXT NOT NULL,
          external_id TEXT NOT NULL,
          data TEXT NOT NULL,
          PRIMARY KEY (sample_kind, identity_platform, external_id)
        )
      ''');

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
    if (from < 2 && to >= 2) {
      // A schema-v1 binary has no downgrade callback. sqflite therefore lowers
      // `user_version` when that binary opens a v2 database, while retaining
      // these additive v2 columns. Probe before every ALTER so a later v2
      // launch repairs that version marker instead of treating the database as
      // corrupt and failing on duplicate columns.
      //
      // Existing v1 rows remain untouched and nullable so legacy/manual rows
      // retain their append-only semantics.
      await _addColumnIfMissing(
        db,
        tableActivity,
        'identity_platform',
      );
      await _addColumnIfMissing(db, tableActivity, 'external_id');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_import_identity '
        'ON $tableActivity(identity_platform, external_id) '
        'WHERE identity_platform IS NOT NULL AND external_id IS NOT NULL',
      );
      await _addColumnIfMissing(db, tableSleep, 'identity_platform');
      await _addColumnIfMissing(db, tableSleep, 'external_id');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_sleep_import_identity '
        'ON $tableSleep(identity_platform, external_id) '
        'WHERE identity_platform IS NOT NULL AND external_id IS NOT NULL',
      );
      await _addColumnIfMissing(db, tableHeartRate, 'identity_platform');
      await _addColumnIfMissing(db, tableHeartRate, 'external_id');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_hr_import_identity '
        'ON $tableHeartRate(identity_platform, external_id) '
        'WHERE identity_platform IS NOT NULL AND external_id IS NOT NULL',
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableImportTombstones (
          sample_kind TEXT NOT NULL,
          identity_platform TEXT NOT NULL,
          external_id TEXT NOT NULL,
          data TEXT NOT NULL,
          PRIMARY KEY (sample_kind, identity_platform, external_id)
        )
      ''');
    }
    if (from < 3 && to >= 3) {
      // Fast-journal records use a dedicated, versioned protocol. They are not
      // stored in `health_events`, so a v0.1.4 binary can continue to read its
      // known health-event JSON while ignoring this table entirely.
      //
      // `IF NOT EXISTS` also repairs the version marker after a legacy binary
      // has lowered SQLite's user_version but left the additive table intact.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableFastJournalEntries (
          id TEXT PRIMARY KEY,
          occurred_at_ms INTEGER NOT NULL,
          kind TEXT NOT NULL,
          rise_started_at_us INTEGER,
          data TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fast_journal_occurred '
        'ON $tableFastJournalEntries(occurred_at_ms DESC, id DESC)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_fast_journal_rise_claim '
        'ON $tableFastJournalEntries(rise_started_at_us) '
        'WHERE rise_started_at_us IS NOT NULL',
      );
    }
  }

  /// Adds one nullable schema-v2 identity column if a downgraded v1 binary
  /// already reset the SQLite version marker while leaving the v2 table shape.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((entry) => entry['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
    }
  }

  /// Keeps a future schema from being silently relabelled as this version.
  ///
  /// Version one shipped without this guard, so [_migrate] separately repairs
  /// the historical v2 -> v1 -> v2 marker rollback. Future downgrades fail
  /// closed instead of risking an unknown schema being written by this binary.
  static Future<void> _rejectDowngrade(
    Database _,
    int from,
    int to,
  ) => throw StateError(
    'Refusing local health database downgrade from schema $from to $to. '
    'Use a schema-version-$from or newer build.',
  );

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;

  /// Preserves the complete episode key used by the one-time rise claim.
  static int _us(DateTime t) => t.toUtc().microsecondsSinceEpoch;

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

  // --- Fast journal -------------------------------------------------------

  @override
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    required int limit,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Expected a positive limit.');
    }
    final rows = await _database.query(
      tableFastJournalEntries,
      columns: const <String>['data'],
      orderBy: 'occurred_at_ms DESC, id DESC',
      limit: limit,
    );
    return rows
        .map((row) => FastJournalEntry.fromJson(_decode(row['data'])))
        .toList(growable: false);
  }

  @override
  Future<bool> isFastJournalRiseClaimed({
    required DateTime riseStartedAt,
  }) async {
    final rows = await _database.query(
      tableFastJournalEntries,
      columns: const <String>['id'],
      where: 'rise_started_at_us = ?',
      whereArgs: <Object?>[_us(riseStartedAt)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<FastJournalEntry> saveFastJournalEntry({
    required FastJournalEntry entry,
    FastJournalRiseReference? requestedRise,
  }) async {
    if (entry.riseReference != null) {
      throw ArgumentError.value(
        entry,
        'entry',
        'The store owns the atomic observed-rise claim.',
      );
    }
    entry.toJson();
    requestedRise?.toJson();
    final database = _database;
    return database.transaction((transaction) async {
      final withoutRise = entry.toJson();
      if (requestedRise == null) {
        await transaction.insert(tableFastJournalEntries, <String, Object?>{
          'id': entry.id,
          'occurred_at_ms': _ms(entry.occurredAt),
          'kind': entry.kind.name,
          'rise_started_at_us': null,
          'data': jsonEncode(withoutRise),
        });
        return entry;
      }

      final attached = entry.copyWith(riseReference: requestedRise);
      final attachedData = attached.toJson();
      final requestedStart = _us(requestedRise.startedAt);
      final inserted = await transaction.rawInsert(
        '''
        INSERT OR IGNORE INTO $tableFastJournalEntries(
          id, occurred_at_ms, kind, rise_started_at_us, data
        ) SELECT ?, ?, ?, ?, ?
        WHERE NOT EXISTS (
          SELECT 1 FROM $tableFastJournalEntries
          WHERE rise_started_at_us = ?
        )
        ''',
        <Object?>[
          attached.id,
          _ms(attached.occurredAt),
          attached.kind.name,
          requestedStart,
          jsonEncode(attachedData),
          requestedStart,
        ],
      );
      if (inserted != 0) return attached;

      // Another serialized transaction already claimed the newest episode.
      // Preserve this manual entry without overstating a rise relationship.
      await transaction.insert(tableFastJournalEntries, <String, Object?>{
        'id': entry.id,
        'occurred_at_ms': _ms(entry.occurredAt),
        'kind': entry.kind.name,
        'rise_started_at_us': null,
        'data': jsonEncode(withoutRise),
      });
      return entry;
    });
  }

  // --- Activity samples ----------------------------------------------------

  @override
  Future<void> upsertActivitySamples(Iterable<ActivitySample> samples) async {
    final values = samples.toList(growable: false);
    _validateSampleBatch(
      values,
      kind: HealthSampleKind.activity,
      provenanceOf: (sample) => sample.provenance,
      encode: (sample) => sample.toJson(),
    );
    final batch = _database.batch();
    for (final s in values) {
      _clearTombstoneInBatch(batch, HealthSampleKind.activity, s.provenance);
      batch.insert(tableActivity, {
        'start_ms': _ms(s.start),
        'type': s.type.key,
        ..._identityColumns(s.provenance),
        'data': jsonEncode(s.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    final values = samples.toList(growable: false);
    _validateSampleBatch(
      values,
      kind: HealthSampleKind.sleep,
      provenanceOf: (sample) => sample.provenance,
      encode: (sample) => sample.toJson(),
    );
    final batch = _database.batch();
    for (final s in values) {
      _clearTombstoneInBatch(batch, HealthSampleKind.sleep, s.provenance);
      batch.insert(tableSleep, {
        'start_ms': _ms(s.start),
        ..._identityColumns(s.provenance),
        'data': jsonEncode(s.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    final values = samples.toList(growable: false);
    _validateSampleBatch(
      values,
      kind: HealthSampleKind.heartRate,
      provenanceOf: (sample) => sample.provenance,
      encode: (sample) => sample.toJson(),
    );
    final batch = _database.batch();
    for (final s in values) {
      _clearTombstoneInBatch(batch, HealthSampleKind.heartRate, s.provenance);
      batch.insert(tableHeartRate, {
        'timestamp_ms': _ms(s.timestamp),
        ..._identityColumns(s.provenance),
        'data': jsonEncode(s.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  @override
  Future<int> purgeImportedSamplesBefore({
    required HealthSampleKind kind,
    required HealthSourcePlatform platform,
    required DateTime cutoff,
  }) {
    final (table, timestampColumn) = switch (kind) {
      HealthSampleKind.activity => (tableActivity, 'start_ms'),
      HealthSampleKind.sleep => (tableSleep, 'start_ms'),
      HealthSampleKind.heartRate => (tableHeartRate, 'timestamp_ms'),
    };
    return _database.delete(
      table,
      where: '$timestampColumn < ? AND identity_platform = ?',
      whereArgs: <Object?>[
        _ms(cutoff),
        platform.key,
      ],
    );
  }

  // --- Imported-record tombstones -----------------------------------------

  @override
  Future<void> reconcileImportTombstones(
    Iterable<HealthImportTombstone> tombstones,
  ) async {
    final values = tombstones.toList(growable: false);
    _validateTombstoneBatch(values);
    final batch = _database.batch();
    for (final tombstone in values) {
      final identity = tombstone.provenance.identity;
      batch.delete(
        _tableFor(tombstone.kind),
        where: 'identity_platform = ? AND external_id = ?',
        whereArgs: [identity.platform.key, identity.externalId],
      );
      batch.insert(tableImportTombstones, {
        'sample_kind': tombstone.kind.key,
        'identity_platform': identity.platform.key,
        'external_id': identity.externalId,
        'data': jsonEncode(tombstone.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<HealthImportTombstone>> queryImportTombstones({
    HealthSampleKind? kind,
    HealthSourcePlatform? platform,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (kind != null) {
      clauses.add('sample_kind = ?');
      args.add(kind.key);
    }
    if (platform != null) {
      clauses.add('identity_platform = ?');
      args.add(platform.key);
    }
    final rows = await _database.query(
      tableImportTombstones,
      columns: ['data'],
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'sample_kind ASC, identity_platform ASC, external_id ASC',
    );
    return rows
        .map((row) => HealthImportTombstone.fromJson(_decode(row['data'])))
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
      tableImportTombstones,
      tableInsights,
      tableFastJournalEntries,
    ].forEach(batch.delete);
    await batch.commit(noResult: true);
  }

  static Map<String, Object?> _identityColumns(
    HealthSampleProvenance? provenance,
  ) => <String, Object?>{
    'identity_platform': provenance?.identity.platform.key,
    'external_id': provenance?.identity.externalId,
  };

  static void _clearTombstoneInBatch(
    Batch batch,
    HealthSampleKind kind,
    HealthSampleProvenance? provenance,
  ) {
    if (provenance == null) return;
    final identity = provenance.identity;
    batch.delete(
      tableImportTombstones,
      where: 'sample_kind = ? AND identity_platform = ? AND external_id = ?',
      whereArgs: [kind.key, identity.platform.key, identity.externalId],
    );
  }

  static void _validateSampleBatch<T>(
    Iterable<T> samples, {
    required HealthSampleKind kind,
    required HealthSampleProvenance? Function(T) provenanceOf,
    required Map<String, Object?> Function(T) encode,
  }) {
    final seen = <String>{};
    for (final sample in samples) {
      encode(sample);
      final provenance = provenanceOf(sample);
      if (provenance == null) continue;
      if (provenance.isDeleted) {
        throw ArgumentError(
          'Use reconcileImportTombstones for source-reported deletions.',
        );
      }
      if (!seen.add(_identityKey(kind, provenance.identity))) {
        throw ArgumentError(
          'A sample batch must not contain a duplicate import identity.',
        );
      }
    }
  }

  static void _validateTombstoneBatch(
    Iterable<HealthImportTombstone> tombstones,
  ) {
    final seen = <String>{};
    for (final tombstone in tombstones) {
      tombstone.toJson();
      if (!seen.add(
        _identityKey(tombstone.kind, tombstone.provenance.identity),
      )) {
        throw ArgumentError(
          'A tombstone batch must not contain a duplicate import identity.',
        );
      }
    }
  }

  static String _identityKey(
    HealthSampleKind kind,
    HealthImportIdentity identity,
  ) => '${kind.key}:${identity.stableKey}';

  static String _tableFor(HealthSampleKind kind) => switch (kind) {
    HealthSampleKind.activity => tableActivity,
    HealthSampleKind.sleep => tableSleep,
    HealthSampleKind.heartRate => tableHeartRate,
  };

  static Map<String, Object?> _decode(Object? data) {
    return jsonDecode(data! as String) as Map<String, Object?>;
  }
}
