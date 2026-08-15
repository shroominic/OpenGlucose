import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/alerts/glucose_alerts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cgm_core/cgm_core.dart';

void main() {
  final first = DateTime.utc(2026, 8, 15, 8);
  CgmReading reading(double value, DateTime at, {bool provisional = false}) =>
      CgmReading(
        valueMgdl: value,
        source: CgmRecordSource.vendor,
        recordedAt: at,
        isDisplayProvisional: provisional,
      );

  group('GlucoseAlertEvaluator', () {
    late GlucoseAlertEvaluator evaluator;

    setUp(() {
      evaluator = GlucoseAlertEvaluator(
        lowThresholdMgdl: 70,
        highThresholdMgdl: 180,
      );
    });

    test(
      'chooses the latest timestamped reading regardless of input order',
      () {
        final result = evaluator.evaluate(
          readings: <CgmReading>[
            reading(190, first.add(const Duration(minutes: 5))),
            reading(110, first),
          ],
          now: first.add(const Duration(minutes: 6)),
        );

        expect(result.activeType, GlucoseAlertType.high);
        expect(result.valueMgdl, 190);
        expect(result.age, const Duration(minutes: 1));
      },
    );

    test('marks low and high bounds as active', () {
      final low = evaluator.evaluate(
        readings: <CgmReading>[reading(70, first)],
        now: first,
      );
      final high = evaluator.evaluate(
        readings: <CgmReading>[reading(180, first)],
        now: first,
      );

      expect(low.activeType, GlucoseAlertType.low);
      expect(high.activeType, GlucoseAlertType.high);
    });

    test(
      'stale wins over a threshold value and future readings are ignored',
      () {
        final result = evaluator.evaluate(
          readings: <CgmReading>[
            reading(190, first.subtract(const Duration(minutes: 20))),
            reading(50, first.add(const Duration(minutes: 1))),
          ],
          now: first,
        );

        expect(result.activeType, GlucoseAlertType.stale);
        expect(result.valueMgdl, 190);
        expect(result.age, const Duration(minutes: 20));
      },
    );

    test('suppression and provisional values do not create glucose alerts', () {
      final suppressed = evaluator.evaluate(
        readings: <CgmReading>[reading(200, first)],
        now: first,
        suppressGlucoseAlerts: true,
      );
      final provisional = evaluator.evaluate(
        readings: <CgmReading>[reading(200, first, provisional: true)],
        now: first,
      );

      expect(suppressed.activeType, isNull);
      expect(provisional.activeType, isNull);
      expect(suppressed.valueMgdl, 200);
    });

    test('warmup suppression also hides stale conditions', () {
      final result = evaluator.evaluate(
        readings: <CgmReading>[
          reading(200, first.subtract(const Duration(minutes: 30))),
        ],
        now: first,
        suppressGlucoseAlerts: true,
      );

      expect(result.activeType, isNull);
      expect(result.readingAt, isNotNull);
    });

    test('ignores non-finite and non-positive readings', () {
      final result = evaluator.evaluate(
        readings: <CgmReading>[
          reading(double.nan, first),
          reading(0, first.add(const Duration(minutes: 1))),
        ],
        now: first.add(const Duration(minutes: 2)),
      );

      expect(result.activeType, isNull);
      expect(result.readingAt, isNull);
    });

    test('rejects invalid thresholds', () {
      expect(
        () =>
            GlucoseAlertEvaluator(lowThresholdMgdl: 0, highThresholdMgdl: 180),
        throwsArgumentError,
      );
      expect(
        () =>
            GlucoseAlertEvaluator(lowThresholdMgdl: 70, highThresholdMgdl: 70),
        throwsArgumentError,
      );
    });
  });

  group('GlucoseAlertHistory', () {
    test('records only transitions and closes an episode when resolved', () {
      final evaluator = GlucoseAlertEvaluator(
        lowThresholdMgdl: 70,
        highThresholdMgdl: 180,
      );
      var sequence = 0;
      String id() => 'a-${++sequence}';
      var history = GlucoseAlertHistory.empty();
      final highAt = first.add(const Duration(minutes: 1));

      history = history.transition(
        evaluation: evaluator.evaluate(
          readings: <CgmReading>[reading(200, highAt)],
          now: highAt,
        ),
        idGenerator: id,
      );
      history = history.transition(
        evaluation: evaluator.evaluate(
          readings: <CgmReading>[reading(210, highAt)],
          now: highAt.add(const Duration(minutes: 1)),
        ),
        idGenerator: id,
      );
      expect(history.records, hasLength(1));
      expect(history.records.single.isActive, isTrue);

      history = history.transition(
        evaluation: evaluator.evaluate(
          readings: <CgmReading>[reading(120, highAt)],
          now: highAt.add(const Duration(minutes: 2)),
        ),
        idGenerator: id,
      );
      expect(
        history.records.single.endedAt,
        highAt.add(const Duration(minutes: 2)),
      );
    });

    test('switching conditions closes the old record and opens a new one', () {
      final evaluator = GlucoseAlertEvaluator(
        lowThresholdMgdl: 70,
        highThresholdMgdl: 180,
      );
      var sequence = 0;
      var history = GlucoseAlertHistory.empty();
      final highAt = first.add(const Duration(minutes: 1));
      final lowAt = first.add(const Duration(minutes: 2));
      history = history.transition(
        evaluation: evaluator.evaluate(
          readings: <CgmReading>[reading(200, highAt)],
          now: highAt,
        ),
        idGenerator: () => 'id-${++sequence}',
      );
      history = history.transition(
        evaluation: evaluator.evaluate(
          readings: <CgmReading>[reading(50, lowAt)],
          now: lowAt,
        ),
        idGenerator: () => 'id-${++sequence}',
      );

      expect(history.records, hasLength(2));
      expect(history.records[0].type, GlucoseAlertType.high);
      expect(history.records[0].endedAt, lowAt);
      expect(history.records[1].type, GlucoseAlertType.low);
      expect(history.records[1].isActive, isTrue);
    });

    test('round-trips records with timezone-aware timestamps', () {
      final record = GlucoseAlertRecord(
        id: 'id-1',
        type: GlucoseAlertType.stale,
        startedAt: first,
        readingAt: first.subtract(const Duration(minutes: 16)),
        valueMgdl: 200,
        endedAt: first.add(const Duration(minutes: 1)),
      );
      final out = GlucoseAlertRecord.fromJson(record.toJson());

      expect(out.id, record.id);
      expect(out.type, record.type);
      expect(out.startedAt, record.startedAt);
      expect(out.endedAt, record.endedAt);
    });
  });

  group('SharedPreferencesGlucoseAlertHistory', () {
    test('persists locally and caps retained records', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = SharedPreferencesGlucoseAlertHistory(
        preferences,
        maxRecords: 1,
      );
      final history = GlucoseAlertHistory(<GlucoseAlertRecord>[
        GlucoseAlertRecord(
          id: 'old',
          type: GlucoseAlertType.low,
          startedAt: first,
          readingAt: first,
        ),
        GlucoseAlertRecord(
          id: 'new',
          type: GlucoseAlertType.high,
          startedAt: first.add(const Duration(hours: 1)),
          readingAt: first.add(const Duration(hours: 1)),
        ),
      ]);

      await store.save(history);
      final restored = await store.load();
      expect(restored.records.map((record) => record.id), <String>['new']);

      await store.clear();
      expect(await store.load(), isA<GlucoseAlertHistory>());
      expect((await store.load()).records, isEmpty);
    });
  });

  test('monitor persists transitions and initializes lazily', () async {
    final saved = <GlucoseAlertHistory>[];
    final persistence = _FakeAlertPersistence(saved);
    final monitor = GlucoseAlertMonitor(
      evaluator: GlucoseAlertEvaluator(
        lowThresholdMgdl: 70,
        highThresholdMgdl: 180,
      ),
      persistence: persistence,
      idGenerator: () => 'monitor-1',
    );
    final at = first.add(const Duration(minutes: 2));

    await monitor.evaluate(readings: <CgmReading>[reading(200, at)], now: at);
    await monitor.evaluate(
      readings: <CgmReading>[reading(205, at)],
      now: at.add(const Duration(minutes: 1)),
    );

    expect(saved, hasLength(1));
    expect(monitor.history.records.single.id, 'monitor-1');
    expect(persistence.loads, 1);
  });
}

class _FakeAlertPersistence implements GlucoseAlertHistoryPersistence {
  _FakeAlertPersistence(this.saved);

  final List<GlucoseAlertHistory> saved;
  int loads = 0;

  @override
  Future<GlucoseAlertHistory> load() async {
    loads += 1;
    return saved.isEmpty ? GlucoseAlertHistory.empty() : saved.last;
  }

  @override
  Future<void> save(GlucoseAlertHistory history) async {
    saved.add(history);
  }

  @override
  Future<void> clear() async {
    saved.clear();
  }
}
