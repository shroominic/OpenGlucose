import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

/// A controllable fake provider so tests never touch the network.
class _FakeProvider implements AiProvider {
  _FakeProvider({this.enabled = true, this.error});

  bool enabled;
  String? model = 'fake-model';
  String response = 'You might notice steadier mornings.';
  Object? error;
  AiRequest? lastRequest;
  int calls = 0;

  @override
  bool get isEnabled => enabled;

  @override
  String? get modelId => model;

  @override
  Future<String> generate(AiRequest request) async {
    calls++;
    lastRequest = request;
    if (error != null) {
      throw error is AiGenerationException
          ? error! as AiGenerationException
          : AiGenerationException('boom', cause: error);
    }
    return response;
  }
}

List<CgmReading> _synthReadings(DateTime start, int n) {
  return List<CgmReading>.generate(n, (i) {
    // Oscillate 90..160 mg/dL deterministically.
    final value = 90.0 + (i % 8) * 10;
    return CgmReading(
      valueMgdl: value,
      source: CgmRecordSource.vendor,
      recordedAt: start.add(Duration(minutes: i * 5)),
    );
  });
}

void main() {
  group('GlucoseSummary', () {
    test('computes aggregates and event counts', () {
      final start = DateTime.utc(2026, 6, 1, 8);
      final readings = _synthReadings(start, 24); // 2h of 5-min readings
      final events = <HealthEvent>[
        HealthEvent(
          id: 'm1',
          timestamp: start.add(const Duration(minutes: 10)),
          type: HealthEventType.meal,
          payload: const MealPayload(carbsGrams: 45),
        ),
        HealthEvent(
          id: 'e1',
          timestamp: start.add(const Duration(minutes: 30)),
          type: HealthEventType.exercise,
        ),
      ];
      final summary = GlucoseSummary.fromData(
        windowStart: start,
        windowEnd: start.add(const Duration(hours: 2)),
        readings: readings,
        events: events,
      );
      expect(summary.hasData, isTrue);
      expect(summary.readingCount, 24);
      expect(summary.average, greaterThan(0));
      expect(summary.minimum, lessThanOrEqualTo(summary.maximum!));
      expect(summary.mealCount, 1);
      expect(summary.exerciseCount, 1);
      expect(summary.totalCarbsGrams, 45);
      expect(summary.timeInRangePercent, inInclusiveRange(0, 100));
    });

    test('empty readings yields hasData=false but keeps event counts', () {
      final start = DateTime.utc(2026, 6, 1);
      final summary = GlucoseSummary.fromData(
        windowStart: start,
        windowEnd: start.add(const Duration(hours: 1)),
        readings: const <CgmReading>[],
        events: <HealthEvent>[
          HealthEvent(id: 'n1', timestamp: start, type: HealthEventType.note),
        ],
      );
      expect(summary.hasData, isFalse);
      expect(summary.noteCount, 1);
      expect(summary.average, isNull);
    });
  });

  group('InsightService.buildPrompt', () {
    test('includes aggregate stats but no raw readings', () {
      final start = DateTime.utc(2026, 6, 1, 8);
      final summary = GlucoseSummary.fromData(
        windowStart: start,
        windowEnd: start.add(const Duration(hours: 2)),
        readings: _synthReadings(start, 24),
        events: const <HealthEvent>[],
      );
      final prompt = InsightService.buildPrompt(summary);
      expect(prompt, contains('Average glucose'));
      expect(prompt, contains('Time in 70'));
      expect(prompt, contains('No medical advice'));
      expect(prompt, isNot(contains('Estimated A1c')));
    });

    test('system message carries the wellness guardrail', () {
      final start = DateTime.utc(2026, 6, 1, 8);
      final summary = GlucoseSummary.fromData(
        windowStart: start,
        windowEnd: start.add(const Duration(hours: 2)),
        readings: _synthReadings(start, 12),
        events: const <HealthEvent>[],
      );
      final messages = InsightService.buildMessages(summary);
      expect(messages.first.role, 'system');
      expect(messages.first.content, contains('NEVER give medical advice'));
    });
  });

  group('InsightService.generateSummaryInsight', () {
    late InMemoryHealthRepository repo;
    final start = DateTime.utc(2026, 6, 1, 8);
    final end = start.add(const Duration(hours: 24));

    setUp(() async {
      repo = InMemoryHealthRepository();
      await repo.init();
    });

    test('generates, tags disclaimer, and persists round-trip', () async {
      final provider = _FakeProvider();
      final service = InsightService(
        repository: repo,
        provider: provider,
        idFactory: () => 'fixed-id',
        clock: () => DateTime.utc(2026, 6, 1, 10),
      );

      final insight = await service.generateSummaryInsight(
        readings: _synthReadings(start, 145),
        windowStart: start,
        windowEnd: end,
      );

      expect(insight, isNotNull);
      expect(provider.calls, 1);
      expect(insight!.id, 'fixed-id');
      expect(insight.model, 'fake-model');
      expect(insight.tags, contains(AiDisclaimer.tag));
      expect(insight.body, contains(AiDisclaimer.short));
      expect(insight.body, contains('steadier mornings'));
      expect(insight.hasEvidence, isTrue);
      expect(insight.isWellnessBounded, isTrue);
      expect(
        provider.lastRequest!.messages.last.content,
        contains('Evidence available'),
      );

      // Persisted and queryable.
      final stored = await repo.queryInsights();
      expect(stored, hasLength(1));
      expect(stored.single.id, 'fixed-id');
    });

    test('pulls journal events from the repo into the summary', () async {
      await repo.upsertEvent(
        HealthEvent(
          id: 'meal-in',
          timestamp: start.add(const Duration(minutes: 15)),
          type: HealthEventType.meal,
          payload: const MealPayload(carbsGrams: 60),
        ),
      );
      // An event outside the window must be ignored.
      await repo.upsertEvent(
        HealthEvent(
          id: 'meal-out',
          timestamp: end.add(const Duration(hours: 5)),
          type: HealthEventType.meal,
        ),
      );

      final provider = _FakeProvider();
      final service = InsightService(repository: repo, provider: provider);
      await service.generateSummaryInsight(
        readings: _synthReadings(start, 145),
        windowStart: start,
        windowEnd: end,
      );

      final userMsg = provider.lastRequest!.messages.last.content;
      expect(userMsg, contains('1 meals'));
      expect(userMsg, contains('60g carbs'));
    });

    test('disabled provider returns null and does no I/O', () async {
      final provider = _FakeProvider(enabled: false);
      final service = InsightService(repository: repo, provider: provider);
      final result = await service.generateSummaryInsight(
        readings: _synthReadings(start, 145),
        windowStart: start,
        windowEnd: end,
      );
      expect(result, isNull);
      expect(provider.calls, 0);
      expect(await repo.queryInsights(), isEmpty);
    });

    test('empty window throws without persisting', () async {
      final provider = _FakeProvider();
      final service = InsightService(repository: repo, provider: provider);
      await expectLater(
        service.generateSummaryInsight(
          readings: const <CgmReading>[],
          windowStart: start,
          windowEnd: end,
        ),
        throwsA(isA<AiGenerationException>()),
      );
      expect(await repo.queryInsights(), isEmpty);
    });

    test(
      'sparse nonempty window throws without calling the provider',
      () async {
        final provider = _FakeProvider();
        final service = InsightService(repository: repo, provider: provider);
        await expectLater(
          service.generateSummaryInsight(
            readings: _synthReadings(start, 3),
            windowStart: start,
            windowEnd: end,
          ),
          throwsA(isA<AiGenerationException>()),
        );
        expect(provider.calls, 0);
        expect(await repo.queryInsights(), isEmpty);
      },
    );

    test('provider error propagates and nothing is persisted', () async {
      final provider = _FakeProvider(
        error: const AiGenerationException('network failure'),
      );
      final service = InsightService(repository: repo, provider: provider);
      await expectLater(
        service.generateSummaryInsight(
          readings: _synthReadings(start, 145),
          windowStart: start,
          windowEnd: end,
        ),
        throwsA(isA<AiGenerationException>()),
      );
      expect(await repo.queryInsights(), isEmpty);
    });

    test('unsafe provider output fails closed and is not persisted', () async {
      final provider = _FakeProvider()
        ..response = 'You have diabetes; take insulin.';
      final service = InsightService(repository: repo, provider: provider);
      await expectLater(
        service.generateSummaryInsight(
          readings: _synthReadings(start, 145),
          windowStart: start,
          windowEnd: end,
        ),
        throwsA(isA<AiGenerationException>()),
      );
      expect(await repo.queryInsights(), isEmpty);
    });
  });
}
