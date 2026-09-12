import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

final DateTime _mealAt = DateTime.utc(2026, 8, 15, 8);

IdentifiedGlucoseReading _reading(
  String id,
  DateTime at,
  double value, {
  CgmRecordSource source = CgmRecordSource.vendor,
  bool provisional = false,
}) {
  return IdentifiedGlucoseReading(
    id: id,
    reading: CgmReading(
      valueMgdl: value,
      source: source,
      recordedAt: at,
      isDisplayProvisional: provisional,
    ),
  );
}

HealthEvent _meal(String id, DateTime at, {double? carbs}) => HealthEvent(
  id: id,
  timestamp: at,
  type: HealthEventType.meal,
  payload: MealPayload(carbsGrams: carbs),
);

List<IdentifiedGlucoseReading> _qualifiedResponse({
  DateTime? mealAt,
  CgmRecordSource source = CgmRecordSource.vendor,
}) {
  final at = mealAt ?? _mealAt;
  return <IdentifiedGlucoseReading>[
    _reading(
      'baseline-30',
      at.subtract(const Duration(minutes: 30)),
      100,
      source: source,
    ),
    _reading(
      'baseline-15',
      at.subtract(const Duration(minutes: 15)),
      100,
      source: source,
    ),
    _reading('post-0', at, 100, source: source),
    _reading(
      'post-30',
      at.add(const Duration(minutes: 30)),
      140,
      source: source,
    ),
    _reading('post-60', at.add(const Duration(hours: 1)), 160, source: source),
    _reading(
      'post-90',
      at.add(const Duration(minutes: 90)),
      140,
      source: source,
    ),
    _reading('post-120', at.add(const Duration(hours: 2)), 120, source: source),
  ];
}

void main() {
  group('MealResponseAnalytics', () {
    test('produces an evidence-linked, known-answer meal response', () {
      final result = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt, carbs: 45)],
        readings: _qualifiedResponse(),
      );

      expect(result.status, MealResponseSummaryStatus.ready);
      expect(result.mealCount, 1);
      expect(result.sufficientMealCount, 1);
      expect(result.averageCoveragePercent, 100);
      expect(result.averagePeakDeltaMgdl, 60);
      expect(result.averageTimeToPeak, const Duration(hours: 1));

      final response = result.responses.single;
      expect(response.status, MealResponseStatus.sufficient);
      expect(response.baselineMgdl, 100);
      expect(response.peakMgdl, 160);
      expect(response.peakDeltaMgdl, 60);
      expect(response.timeToPeak, const Duration(hours: 1));
      expect(response.observedDeltaAreaMgdlMinutes, 4500);
      expect(response.carbsGrams, 45);
      expect(
        response.evidence.calculationVersion,
        mealResponseCalculationVersion,
      );
      expect(response.evidence.mealEventId, 'meal-1');
      expect(response.evidence.baselineSampleIds, <String>[
        'baseline-30',
        'baseline-15',
      ]);
      expect(response.evidence.postMealSampleIds, <String>[
        'post-0',
        'post-30',
        'post-60',
        'post-90',
        'post-120',
      ]);
      expect(response.evidence.activeSampleSpan, const Duration(hours: 2));
      expect(response.evidence.observedResponseSpan, const Duration(hours: 2));
      expect(response.evidence.firstPostMealDelay, Duration.zero);
      expect(response.evidence.trailingGap, Duration.zero);
      expect(response.evidence.largestGap, const Duration(minutes: 30));
      expect(
        response.evidence.averagePostMealCadence,
        const Duration(minutes: 30),
      );
      expect(response.evidence.sources, <CgmRecordSource>[
        CgmRecordSource.vendor,
      ]);
      expect(result.safetyBoundary, contains('not causal'));
    });

    test(
      'uses inclusive response bounds and excludes readings outside them',
      () {
        final readings = <IdentifiedGlucoseReading>[
          ..._qualifiedResponse(),
          _reading(
            'too-early',
            _mealAt.subtract(const Duration(minutes: 31)),
            50,
          ),
          _reading(
            'too-late',
            _mealAt.add(const Duration(hours: 2, seconds: 1)),
            250,
          ),
        ];

        final response = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: readings,
        ).responses.single;

        expect(response.status, MealResponseStatus.sufficient);
        expect(response.baselineReadingCount, 2);
        expect(response.postMealReadingCount, 5);
        expect(
          response.evidence.baselineSampleIds,
          isNot(contains('too-early')),
        );
        expect(
          response.evidence.postMealSampleIds,
          isNot(contains('too-late')),
        );
      },
    );

    test('reports explicit no-meal and no-glucose states', () {
      final noMeals = MealResponseAnalytics.analyze(
        events: const <HealthEvent>[],
        readings: const <IdentifiedGlucoseReading>[],
      );
      expect(noMeals.status, MealResponseSummaryStatus.noMeals);

      final noReadings = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt)],
        readings: const <IdentifiedGlucoseReading>[],
      );
      expect(noReadings.status, MealResponseSummaryStatus.noGlucoseReadings);
      expect(
        noReadings.responses.single.status,
        MealResponseStatus.noPostMealReadings,
      );
      expect(noReadings.responses.single.peakDeltaMgdl, isNull);
    });

    test(
      'reports insufficient baseline, count, coverage, and cadence separately',
      () {
        final baselineMissing = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[
            _reading('post-0', _mealAt, 100),
            _reading('post-30', _mealAt.add(const Duration(minutes: 30)), 140),
            _reading('post-60', _mealAt.add(const Duration(hours: 1)), 150),
            _reading('post-90', _mealAt.add(const Duration(minutes: 90)), 140),
            _reading('post-120', _mealAt.add(const Duration(hours: 2)), 120),
          ],
        ).responses.single;
        expect(baselineMissing.status, MealResponseStatus.insufficientBaseline);

        final countMissing = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[
            _reading(
              'baseline-30',
              _mealAt.subtract(const Duration(minutes: 30)),
              100,
            ),
            _reading(
              'baseline-15',
              _mealAt.subtract(const Duration(minutes: 15)),
              100,
            ),
            _reading('post-0', _mealAt, 100),
            _reading('post-30', _mealAt.add(const Duration(minutes: 30)), 140),
          ],
        ).responses.single;
        expect(
          countMissing.status,
          MealResponseStatus.insufficientPostMealReadings,
        );

        final coverageMissing = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[
            _reading(
              'baseline-30',
              _mealAt.subtract(const Duration(minutes: 30)),
              100,
            ),
            _reading(
              'baseline-15',
              _mealAt.subtract(const Duration(minutes: 15)),
              100,
            ),
            _reading('post-0', _mealAt, 100),
            _reading('post-15', _mealAt.add(const Duration(minutes: 15)), 130),
            _reading('post-30', _mealAt.add(const Duration(minutes: 30)), 140),
          ],
        ).responses.single;
        expect(coverageMissing.status, MealResponseStatus.insufficientCoverage);
        expect(coverageMissing.coveragePercent, 25);

        final gapMissing = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[
            _reading(
              'baseline-30',
              _mealAt.subtract(const Duration(minutes: 30)),
              100,
            ),
            _reading(
              'baseline-15',
              _mealAt.subtract(const Duration(minutes: 15)),
              100,
            ),
            _reading('post-0', _mealAt, 100),
            _reading('post-30', _mealAt.add(const Duration(minutes: 30)), 140),
            _reading('post-60', _mealAt.add(const Duration(hours: 1)), 160),
            _reading('post-120', _mealAt.add(const Duration(hours: 2)), 120),
          ],
        ).responses.single;
        expect(gapMissing.status, MealResponseStatus.excessiveGap);
        expect(gapMissing.evidence.largestGap, const Duration(hours: 1));
        expect(gapMissing.observedDeltaAreaMgdlMinutes, isNull);
      },
    );

    test(
      'sorts out-of-order inputs and normalizes cross-DST instants to UTC',
      () {
        final mealAt = DateTime.parse('2026-03-08T01:45:00-05:00');
        final readings = _qualifiedResponse(mealAt: mealAt).reversed.toList();
        final response = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', mealAt)],
          readings: readings,
        ).responses.single;

        expect(response.status, MealResponseStatus.sufficient);
        expect(response.mealAt.isUtc, isTrue);
        expect(response.evidence.baselineStart.isUtc, isTrue);
        expect(response.evidence.postMealSampleIds.first, 'post-0');
        expect(response.timeToPeak, const Duration(hours: 1));
      },
    );

    test(
      'fails closed for duplicate timestamps with deterministic selection',
      () {
        final readings = _qualifiedResponse()
          ..add(
            _reading(
              'aaa-duplicate',
              _mealAt.add(const Duration(minutes: 30)),
              200,
            ),
          );
        final response = MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: readings.reversed.toList(),
        ).responses.single;

        expect(response.status, MealResponseStatus.duplicateTimestamps);
        expect(response.evidence.duplicateTimestampCount, 1);
        expect(response.evidence.postMealSampleIds, contains('aaa-duplicate'));
        expect(response.evidence.postMealSampleIds, isNot(contains('post-30')));
        expect(response.peakDeltaMgdl, isNull);
      },
    );

    test('fails closed for mixed sources unless policy opts in', () {
      final readings = _qualifiedResponse();
      readings[3] = _reading(
        'post-30',
        _mealAt.add(const Duration(minutes: 30)),
        140,
        source: CgmRecordSource.standard,
      );
      final defaultResponse = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt)],
        readings: readings,
      ).responses.single;
      expect(defaultResponse.status, MealResponseStatus.mixedSources);
      expect(defaultResponse.evidence.hasMixedSources, isTrue);

      final optedInResponse = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt)],
        readings: readings,
        policy: const MealResponsePolicy(allowMixedSources: true),
      ).responses.single;
      expect(optedInResponse.status, MealResponseStatus.sufficient);
    });

    test('accepted provisional readings are explicitly disqualifying', () {
      final readings = _qualifiedResponse()
        ..[3] = _reading(
          'post-30',
          _mealAt.add(const Duration(minutes: 30)),
          140,
          provisional: true,
        );
      final response = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt)],
        readings: readings,
        policy: const MealResponsePolicy(includeProvisionalReadings: true),
      ).responses.single;

      expect(response.status, MealResponseStatus.provisionalReadings);
      expect(response.isSufficient, isFalse);
      expect(response.peakDeltaMgdl, isNull);
      expect(response.timeToPeak, isNull);
      expect(response.observedDeltaAreaMgdlMinutes, isNull);
      expect(response.evidence.hasAcceptedProvisionalReadings, isTrue);
      expect(response.evidence.acceptedProvisionalBaselineSampleCount, 0);
      expect(response.evidence.acceptedProvisionalPostMealSampleCount, 1);
      expect(response.evidence.acceptedProvisionalSampleCount, 1);
    });

    test('reports excluded samples for each meal window only', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading(
          'baseline-30',
          _mealAt.subtract(const Duration(minutes: 30)),
          100,
        ),
        _reading(
          'baseline-provisional',
          _mealAt.subtract(const Duration(minutes: 15)),
          100,
          provisional: true,
        ),
        _reading('post-0', _mealAt, 100),
        _reading('post-30', _mealAt.add(const Duration(minutes: 30)), 140),
        _reading('post-60', _mealAt.add(const Duration(hours: 1)), 150),
        _reading(
          'post-provisional',
          _mealAt.add(const Duration(minutes: 45)),
          145,
          provisional: true,
        ),
        _reading('post-future', _mealAt.add(const Duration(minutes: 90)), 140),
        _reading(
          'outside-window',
          _mealAt.add(const Duration(hours: 3)),
          120,
          provisional: true,
        ),
      ];
      final response = MealResponseAnalytics.analyze(
        events: <HealthEvent>[_meal('meal-1', _mealAt)],
        readings: readings,
        now: _mealAt.add(const Duration(hours: 1)),
      ).responses.single;

      expect(response.evidence.excludedProvisionalBaselineSampleCount, 1);
      expect(response.evidence.excludedProvisionalPostMealSampleCount, 1);
      expect(response.evidence.excludedFutureBaselineSampleCount, 0);
      expect(response.evidence.excludedFuturePostMealSampleCount, 1);
      expect(response.evidence.excludedProvisionalSampleCount, 2);
      expect(response.evidence.excludedFutureSampleCount, 1);
      expect(response.evidence.baselineSampleIds, <String>['baseline-30']);
    });

    test('requires non-empty, unique glucose sample IDs', () {
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[_reading('', _mealAt, 100)],
        ),
        throwsArgumentError,
      );
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('meal-1', _mealAt)],
          readings: <IdentifiedGlucoseReading>[
            _reading('same', _mealAt, 100),
            _reading('same', _mealAt.add(const Duration(minutes: 5)), 105),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('requires non-empty, unique selected meal IDs', () {
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('', _mealAt)],
          readings: _qualifiedResponse(),
        ),
        throwsArgumentError,
      );
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[_meal('  ', _mealAt)],
          readings: _qualifiedResponse(),
        ),
        throwsArgumentError,
      );
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[
            _meal('same', _mealAt),
            _meal('same', _mealAt.add(const Duration(minutes: 1))),
          ],
          readings: _qualifiedResponse(),
        ),
        throwsArgumentError,
      );
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[
            _meal('same', _mealAt),
            _meal(' same ', _mealAt.add(const Duration(minutes: 1))),
          ],
          readings: _qualifiedResponse(),
        ),
        throwsArgumentError,
      );
      expect(
        () => MealResponseAnalytics.analyze(
          events: <HealthEvent>[
            _meal('meal-1', _mealAt),
            _meal('', _mealAt.add(const Duration(minutes: 1))),
          ],
          readings: _qualifiedResponse(),
          now: _mealAt,
        ),
        returnsNormally,
      );
    });

    test('rejects non-finite coverage requirements', () {
      for (final coverage in <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => MealResponseAnalytics.analyze(
            events: <HealthEvent>[_meal('meal-1', _mealAt)],
            readings: _qualifiedResponse(),
            policy: MealResponsePolicy(minimumCoverage: coverage),
          ),
          throwsArgumentError,
        );
      }
    });
  });
}
