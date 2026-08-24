import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

final DateTime _now = DateTime.utc(2026, 8, 24, 12);

const RecentObservedRisePolicy _policy = RecentObservedRisePolicy(
  minimumRiseMgdl: 20,
  lookbackWindow: Duration(hours: 2),
  maximumCandidateAge: Duration(minutes: 45),
  maximumReadingAge: Duration(minutes: 6),
  maximumGap: Duration(minutes: 6),
  minimumWindowReadings: 5,
  minimumEpisodeReadings: 4,
  minimumEpisodeSpan: Duration(minutes: 15),
  attachmentWindowBeforeEpisode: Duration(minutes: 30),
  attachmentWindowAfterEpisode: Duration(minutes: 15),
);

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

/// A fresh, source-homogeneous, five-minute cadence with one bounded rise.
List<IdentifiedGlucoseReading> _qualifiedReadings({
  DateTime? now,
  CgmRecordSource source = CgmRecordSource.vendor,
}) {
  final reference = now ?? _now;
  return <IdentifiedGlucoseReading>[
    _reading(
      'before',
      reference.subtract(const Duration(minutes: 35)),
      120,
      source: source,
    ),
    _reading(
      'start',
      reference.subtract(const Duration(minutes: 30)),
      100,
      source: source,
    ),
    _reading(
      'climb-1',
      reference.subtract(const Duration(minutes: 25)),
      110,
      source: source,
    ),
    _reading(
      'climb-2',
      reference.subtract(const Duration(minutes: 20)),
      125,
      source: source,
    ),
    _reading(
      'peak',
      reference.subtract(const Duration(minutes: 15)),
      130,
      source: source,
    ),
    _reading(
      'after-1',
      reference.subtract(const Duration(minutes: 10)),
      128,
      source: source,
    ),
    _reading(
      'after-2',
      reference.subtract(const Duration(minutes: 5)),
      126,
      source: source,
    ),
    _reading('latest', reference, 124, source: source),
  ];
}

RecentObservedRiseAssessment _assess(
  Iterable<IdentifiedGlucoseReading> readings, {
  DateTime? now,
  RecentObservedRisePolicy policy = _policy,
}) {
  return RecentObservedRiseAnalytics.assess(
    readings: readings,
    now: now ?? _now,
    policy: policy,
  );
}

void main() {
  group('RecentObservedRiseAnalytics', () {
    test(
      'returns one newest evidence-bound candidate for fresh observations',
      () {
        final assessment = _assess(_qualifiedReadings());

        expect(assessment.status, RecentObservedRiseAssessmentStatus.qualified);
        final candidate = assessment.candidate!;
        expect(candidate.id, 'recent-observed-rise-v1:5:start:4:peak');
        expect(
          candidate.episodeStart,
          _now.subtract(const Duration(minutes: 30)),
        );
        expect(candidate.peakAt, _now.subtract(const Duration(minutes: 15)));
        expect(candidate.observedRiseMgdl, 30);
        expect(
          candidate.attachmentWindowStart,
          _now.subtract(const Duration(minutes: 60)),
        );
        expect(candidate.attachmentWindowEnd, _now);
        expect(
          candidate.canAttachAt(_now.subtract(const Duration(minutes: 61))),
          isFalse,
        );
        expect(candidate.canAttachAt(_now), isTrue);
        expect(
          candidate.evidence.calculationVersion,
          recentObservedRiseCalculationVersion,
        );
        expect(candidate.evidence.startReadingId, 'start');
        expect(candidate.evidence.peakReadingId, 'peak');
        expect(candidate.evidence.latestReadingId, 'latest');
        expect(candidate.evidence.episodeReadingIds, <String>[
          'start',
          'climb-1',
          'climb-2',
          'peak',
        ]);
        expect(candidate.evidence.episodeReadingCount, 4);
        expect(candidate.evidence.episodeSpan, const Duration(minutes: 15));
        expect(candidate.evidence.largestGap, const Duration(minutes: 5));
        expect(candidate.evidence.latestReadingAge, Duration.zero);
        expect(candidate.evidence.source, CgmRecordSource.vendor);
        expect(
          candidate.safetyBoundary,
          contains('does not identify its cause'),
        );
      },
    );

    test('is deterministic across input order and equivalent UTC instants', () {
      final inOrder = _assess(_qualifiedReadings());
      final shuffled = _assess(_qualifiedReadings().reversed);

      expect(shuffled.status, RecentObservedRiseAssessmentStatus.qualified);
      expect(shuffled.candidate!.id, inOrder.candidate!.id);
      expect(
        shuffled.candidate!.evidence.qualifiedWindowReadingIds,
        inOrder.candidate!.evidence.qualifiedWindowReadingIds,
      );
      expect(shuffled.candidate!.episodeStart.isUtc, isTrue);
      expect(shuffled.candidate!.peakAt.isUtc, isTrue);
    });

    test('selects only the newest eligible observed episode', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('before-1', _now.subtract(const Duration(minutes: 60)), 140),
        _reading(
          'first-start',
          _now.subtract(const Duration(minutes: 55)),
          100,
        ),
        _reading('first-up-1', _now.subtract(const Duration(minutes: 50)), 110),
        _reading('first-up-2', _now.subtract(const Duration(minutes: 45)), 125),
        _reading('first-peak', _now.subtract(const Duration(minutes: 40)), 130),
        _reading('down-1', _now.subtract(const Duration(minutes: 35)), 120),
        _reading(
          'second-start-1',
          _now.subtract(const Duration(minutes: 30)),
          110,
        ),
        _reading(
          'second-start',
          _now.subtract(const Duration(minutes: 25)),
          110,
        ),
        _reading(
          'second-up-1',
          _now.subtract(const Duration(minutes: 20)),
          120,
        ),
        _reading(
          'second-up-2',
          _now.subtract(const Duration(minutes: 15)),
          135,
        ),
        _reading(
          'second-peak',
          _now.subtract(const Duration(minutes: 10)),
          145,
        ),
        _reading(
          'second-after',
          _now.subtract(const Duration(minutes: 5)),
          140,
        ),
        _reading('latest', _now, 138),
      ];

      final candidate = _assess(readings).candidate!;
      expect(candidate.evidence.startReadingId, 'second-start');
      expect(candidate.evidence.peakReadingId, 'second-peak');
      expect(candidate.observedRiseMgdl, 35);
    });

    test(
      'uses the newest eligible episode when a newer small rise is below policy',
      () {
        final readings = <IdentifiedGlucoseReading>[
          _reading('before-1', _now.subtract(const Duration(minutes: 60)), 140),
          _reading(
            'first-start',
            _now.subtract(const Duration(minutes: 55)),
            100,
          ),
          _reading(
            'first-up-1',
            _now.subtract(const Duration(minutes: 50)),
            110,
          ),
          _reading(
            'first-up-2',
            _now.subtract(const Duration(minutes: 45)),
            125,
          ),
          _reading(
            'first-peak',
            _now.subtract(const Duration(minutes: 40)),
            130,
          ),
          _reading('down-1', _now.subtract(const Duration(minutes: 35)), 120),
          _reading(
            'second-start-1',
            _now.subtract(const Duration(minutes: 30)),
            110,
          ),
          _reading(
            'second-start',
            _now.subtract(const Duration(minutes: 25)),
            110,
          ),
          _reading(
            'second-up-1',
            _now.subtract(const Duration(minutes: 20)),
            115,
          ),
          _reading(
            'second-up-2',
            _now.subtract(const Duration(minutes: 15)),
            118,
          ),
          _reading(
            'second-peak',
            _now.subtract(const Duration(minutes: 10)),
            125,
          ),
          _reading(
            'second-after',
            _now.subtract(const Duration(minutes: 5)),
            120,
          ),
          _reading('latest', _now, 118),
        ];

        final candidate = _assess(readings).candidate!;
        expect(candidate.evidence.peakReadingId, 'first-peak');
        expect(candidate.observedRiseMgdl, 30);
      },
    );

    test('uses the final values of flat trough and peak plateaus', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('before', _now.subtract(const Duration(minutes: 35)), 130),
        _reading(
          'trough-first',
          _now.subtract(const Duration(minutes: 30)),
          100,
        ),
        _reading(
          'trough-final',
          _now.subtract(const Duration(minutes: 25)),
          100,
        ),
        _reading('up-1', _now.subtract(const Duration(minutes: 20)), 115),
        _reading('peak-first', _now.subtract(const Duration(minutes: 15)), 130),
        _reading('peak-final', _now.subtract(const Duration(minutes: 10)), 130),
        _reading('after', _now.subtract(const Duration(minutes: 5)), 125),
        _reading('latest', _now, 120),
      ];

      final candidate = _assess(readings).candidate!;
      expect(candidate.evidence.startReadingId, 'trough-final');
      expect(candidate.evidence.peakReadingId, 'peak-final');
    });

    test('requires a bounded observed trough, not a monotonic window edge', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('a', _now.subtract(const Duration(minutes: 20)), 100),
        _reading('b', _now.subtract(const Duration(minutes: 15)), 110),
        _reading('c', _now.subtract(const Duration(minutes: 10)), 120),
        _reading('d', _now.subtract(const Duration(minutes: 5)), 130),
        _reading('e', _now, 140),
      ];

      final assessment = _assess(readings);
      expect(assessment.candidate, isNull);
      expect(
        assessment.status,
        RecentObservedRiseAssessmentStatus.noObservedRise,
      );
    });

    test('has no implicit big-rise threshold', () {
      final readings = _qualifiedReadings();
      final exactThreshold = _assess(
        readings,
        policy: const RecentObservedRisePolicy(
          minimumRiseMgdl: 30,
          lookbackWindow: Duration(hours: 2),
          maximumCandidateAge: Duration(minutes: 45),
          maximumReadingAge: Duration(minutes: 6),
          maximumGap: Duration(minutes: 6),
          minimumWindowReadings: 5,
          minimumEpisodeReadings: 4,
          minimumEpisodeSpan: Duration(minutes: 15),
        ),
      );
      final higherThreshold = _assess(
        readings,
        policy: const RecentObservedRisePolicy(
          minimumRiseMgdl: 30.1,
          lookbackWindow: Duration(hours: 2),
          maximumCandidateAge: Duration(minutes: 45),
          maximumReadingAge: Duration(minutes: 6),
          maximumGap: Duration(minutes: 6),
          minimumWindowReadings: 5,
          minimumEpisodeReadings: 4,
          minimumEpisodeSpan: Duration(minutes: 15),
        ),
      );

      expect(exactThreshold.hasCandidate, isTrue);
      expect(
        higherThreshold.status,
        RecentObservedRiseAssessmentStatus.belowConfiguredRise,
      );
      expect(higherThreshold.candidate, isNull);
    });

    test('fails closed for stale, old, sparse, and gapped data', () {
      final stale = _assess(
        _qualifiedReadings(now: _now.subtract(const Duration(minutes: 10))),
      );
      expect(
        stale.status,
        RecentObservedRiseAssessmentStatus.staleLatestReading,
      );

      final old = _assess(
        _qualifiedReadings(now: _now.subtract(const Duration(hours: 3))),
      );
      expect(old.status, RecentObservedRiseAssessmentStatus.noRecentReadings);

      final sparse = _assess(<IdentifiedGlucoseReading>[
        _reading(
          'sparse-before',
          _now.subtract(const Duration(minutes: 15)),
          120,
        ),
        _reading(
          'sparse-start',
          _now.subtract(const Duration(minutes: 10)),
          100,
        ),
        _reading('sparse-peak', _now.subtract(const Duration(minutes: 5)), 125),
        _reading('sparse-latest', _now, 120),
      ]);
      expect(
        sparse.status,
        RecentObservedRiseAssessmentStatus.insufficientWindowReadings,
      );

      final gapped = <IdentifiedGlucoseReading>[
        _reading('before', _now.subtract(const Duration(minutes: 35)), 120),
        _reading('start', _now.subtract(const Duration(minutes: 30)), 100),
        _reading('up-1', _now.subtract(const Duration(minutes: 25)), 110),
        _reading('up-2', _now.subtract(const Duration(minutes: 20)), 125),
        _reading('peak', _now.subtract(const Duration(minutes: 15)), 130),
        _reading('late', _now.subtract(const Duration(minutes: 5)), 125),
        _reading('latest', _now, 124),
      ];
      expect(
        _assess(gapped).status,
        RecentObservedRiseAssessmentStatus.excessiveGap,
      );

      const tailGapPolicy = RecentObservedRisePolicy(
        minimumRiseMgdl: 20,
        lookbackWindow: Duration(hours: 2),
        maximumCandidateAge: Duration(minutes: 45),
        maximumReadingAge: Duration(minutes: 10),
        maximumGap: Duration(minutes: 6),
        minimumWindowReadings: 5,
        minimumEpisodeReadings: 4,
        minimumEpisodeSpan: Duration(minutes: 15),
      );
      final tailGap = _assess(
        _qualifiedReadings(now: _now.subtract(const Duration(minutes: 7))),
        policy: tailGapPolicy,
      );
      expect(tailGap.status, RecentObservedRiseAssessmentStatus.excessiveGap);
    });

    test('returns no candidate when a otherwise-qualified peak is too old', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('before', _now.subtract(const Duration(minutes: 60)), 120),
        _reading('start', _now.subtract(const Duration(minutes: 55)), 100),
        _reading('up-1', _now.subtract(const Duration(minutes: 50)), 110),
        _reading('up-2', _now.subtract(const Duration(minutes: 45)), 125),
        _reading('peak', _now.subtract(const Duration(minutes: 40)), 130),
        _reading('after-1', _now.subtract(const Duration(minutes: 35)), 125),
        _reading('after-2', _now.subtract(const Duration(minutes: 30)), 120),
        _reading('after-3', _now.subtract(const Duration(minutes: 25)), 115),
        _reading('after-4', _now.subtract(const Duration(minutes: 20)), 110),
        _reading('after-5', _now.subtract(const Duration(minutes: 15)), 108),
        _reading('after-6', _now.subtract(const Duration(minutes: 10)), 106),
        _reading('after-7', _now.subtract(const Duration(minutes: 5)), 104),
        _reading('latest', _now, 102),
      ];
      const policy = RecentObservedRisePolicy(
        minimumRiseMgdl: 20,
        lookbackWindow: Duration(hours: 2),
        maximumCandidateAge: Duration(minutes: 30),
        maximumReadingAge: Duration(minutes: 6),
        maximumGap: Duration(minutes: 6),
        minimumWindowReadings: 5,
        minimumEpisodeReadings: 4,
        minimumEpisodeSpan: Duration(minutes: 15),
      );

      final assessment = _assess(readings, policy: policy);
      expect(assessment.candidate, isNull);
      expect(
        assessment.status,
        RecentObservedRiseAssessmentStatus.candidateTooOld,
      );
    });

    test('requires enough episode samples and duration', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('before', _now.subtract(const Duration(minutes: 25)), 120),
        _reading('start', _now.subtract(const Duration(minutes: 20)), 100),
        _reading('up-1', _now.subtract(const Duration(minutes: 15)), 115),
        _reading('peak', _now.subtract(const Duration(minutes: 10)), 130),
        _reading('after', _now.subtract(const Duration(minutes: 5)), 125),
        _reading('latest', _now, 120),
      ];
      final assessment = _assess(readings);
      expect(assessment.candidate, isNull);
      expect(
        assessment.status,
        RecentObservedRiseAssessmentStatus.insufficientEpisodeData,
      );
    });

    test('does not combine threshold and coverage from different episodes', () {
      final readings = <IdentifiedGlucoseReading>[
        _reading('before-1', _now.subtract(const Duration(minutes: 65)), 120),
        _reading(
          'first-start',
          _now.subtract(const Duration(minutes: 60)),
          100,
        ),
        _reading('first-up-1', _now.subtract(const Duration(minutes: 55)), 105),
        _reading('first-up-2', _now.subtract(const Duration(minutes: 50)), 110),
        _reading('first-peak', _now.subtract(const Duration(minutes: 45)), 115),
        _reading(
          'first-after',
          _now.subtract(const Duration(minutes: 40)),
          110,
        ),
        _reading(
          'second-before',
          _now.subtract(const Duration(minutes: 35)),
          100,
        ),
        _reading(
          'second-start',
          _now.subtract(const Duration(minutes: 30)),
          100,
        ),
        _reading('second-up', _now.subtract(const Duration(minutes: 25)), 115),
        _reading(
          'second-peak',
          _now.subtract(const Duration(minutes: 20)),
          135,
        ),
        _reading(
          'second-after',
          _now.subtract(const Duration(minutes: 15)),
          130,
        ),
        _reading('after-2', _now.subtract(const Duration(minutes: 10)), 128),
        _reading('after-3', _now.subtract(const Duration(minutes: 5)), 126),
        _reading('latest', _now, 124),
      ];

      final assessment = _assess(readings);
      expect(assessment.candidate, isNull);
      expect(
        assessment.status,
        RecentObservedRiseAssessmentStatus.insufficientEpisodeData,
      );
    });

    test(
      'can retain an older eligible episode when newer episodes are ineligible',
      () {
        final readings = <IdentifiedGlucoseReading>[
          _reading('before-1', _now.subtract(const Duration(minutes: 65)), 140),
          _reading(
            'first-start',
            _now.subtract(const Duration(minutes: 60)),
            100,
          ),
          _reading(
            'first-up-1',
            _now.subtract(const Duration(minutes: 55)),
            110,
          ),
          _reading(
            'first-up-2',
            _now.subtract(const Duration(minutes: 50)),
            125,
          ),
          _reading(
            'first-peak',
            _now.subtract(const Duration(minutes: 45)),
            130,
          ),
          _reading(
            'first-after',
            _now.subtract(const Duration(minutes: 40)),
            120,
          ),
          _reading(
            'second-before',
            _now.subtract(const Duration(minutes: 35)),
            110,
          ),
          _reading(
            'second-start',
            _now.subtract(const Duration(minutes: 30)),
            110,
          ),
          _reading(
            'second-up',
            _now.subtract(const Duration(minutes: 25)),
            120,
          ),
          _reading(
            'second-peak',
            _now.subtract(const Duration(minutes: 20)),
            145,
          ),
          _reading(
            'second-after',
            _now.subtract(const Duration(minutes: 15)),
            135,
          ),
          _reading('after-2', _now.subtract(const Duration(minutes: 10)), 130),
          _reading('after-3', _now.subtract(const Duration(minutes: 5)), 128),
          _reading('latest', _now, 126),
        ];

        final candidate = _assess(readings).candidate!;
        expect(candidate.evidence.peakReadingId, 'first-peak');
      },
    );

    test(
      'fails closed for duplicate timestamps, mixed sources, provisional, and future records',
      () {
        final duplicateTimestamp = <IdentifiedGlucoseReading>[
          ..._qualifiedReadings(),
          _reading(
            'same-instant',
            _now.subtract(const Duration(minutes: 20)),
            126,
          ),
        ];
        expect(
          _assess(duplicateTimestamp).status,
          RecentObservedRiseAssessmentStatus.duplicateTimestamps,
        );

        final mixedSource = _qualifiedReadings();
        mixedSource[3] = _reading(
          'climb-2',
          _now.subtract(const Duration(minutes: 20)),
          125,
          source: CgmRecordSource.broadcast,
        );
        expect(
          _assess(mixedSource).status,
          RecentObservedRiseAssessmentStatus.mixedSources,
        );

        final provisional = _qualifiedReadings();
        provisional[3] = _reading(
          'climb-2',
          _now.subtract(const Duration(minutes: 20)),
          125,
          provisional: true,
        );
        expect(
          _assess(provisional).status,
          RecentObservedRiseAssessmentStatus.provisionalReading,
        );

        final future = <IdentifiedGlucoseReading>[
          ..._qualifiedReadings(),
          _reading('future', _now.add(const Duration(minutes: 1)), 125),
        ];
        expect(
          _assess(future).status,
          RecentObservedRiseAssessmentStatus.futureReading,
        );
      },
    );

    test(
      'fails closed for malformed identifiers, timestamps, and glucose values',
      () {
        expect(
          _assess(<IdentifiedGlucoseReading>[
            ..._qualifiedReadings(),
            IdentifiedGlucoseReading(
              id: '',
              reading: CgmReading(
                valueMgdl: 120,
                source: CgmRecordSource.vendor,
                recordedAt: _now,
              ),
            ),
          ]).status,
          RecentObservedRiseAssessmentStatus.invalidReadingId,
        );

        expect(
          _assess(<IdentifiedGlucoseReading>[
            ..._qualifiedReadings(),
            IdentifiedGlucoseReading(
              id: 'missing-time',
              reading: const CgmReading(
                valueMgdl: 120,
                source: CgmRecordSource.vendor,
              ),
            ),
          ]).status,
          RecentObservedRiseAssessmentStatus.missingTimestamp,
        );

        expect(
          _assess(<IdentifiedGlucoseReading>[
            ..._qualifiedReadings(),
            _reading('bad-value', _now, 0),
          ]).status,
          RecentObservedRiseAssessmentStatus.invalidGlucoseValue,
        );

        expect(
          _assess(<IdentifiedGlucoseReading>[
            ..._qualifiedReadings(),
            _reading('start', _now.subtract(const Duration(hours: 1)), 120),
          ]).status,
          RecentObservedRiseAssessmentStatus.duplicateReadingId,
        );
      },
    );

    test('ignores old source records outside the bounded lookback window', () {
      final assessment = _assess(<IdentifiedGlucoseReading>[
        _reading(
          'old-other-source',
          _now.subtract(const Duration(hours: 3)),
          120,
          source: CgmRecordSource.broadcast,
        ),
        ..._qualifiedReadings(),
      ]);

      expect(assessment.status, RecentObservedRiseAssessmentStatus.qualified);
      expect(assessment.candidate!.evidence.source, CgmRecordSource.vendor);
    });

    test('keeps attachment range bounded at evaluation time', () {
      const policy = RecentObservedRisePolicy(
        minimumRiseMgdl: 20,
        lookbackWindow: Duration(hours: 2),
        maximumCandidateAge: Duration(minutes: 45),
        maximumReadingAge: Duration(minutes: 6),
        maximumGap: Duration(minutes: 6),
        minimumWindowReadings: 5,
        minimumEpisodeReadings: 4,
        minimumEpisodeSpan: Duration(minutes: 15),
        attachmentWindowAfterEpisode: Duration(minutes: 30),
      );
      final candidate = _assess(
        _qualifiedReadings(),
        policy: policy,
      ).candidate!;

      expect(candidate.peakAt, _now.subtract(const Duration(minutes: 15)));
      expect(candidate.attachmentWindowEnd, _now);
      expect(
        candidate.canAttachAt(_now.add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('keeps evidence ID lists immutable', () {
      final candidate = _assess(_qualifiedReadings()).candidate!;

      expect(
        () => candidate.evidence.qualifiedWindowReadingIds.add('mutation'),
        throwsUnsupportedError,
      );
      expect(
        () => candidate.evidence.episodeReadingIds.add('mutation'),
        throwsUnsupportedError,
      );
    });

    test('supports DST-crossing instants through UTC normalization', () {
      final now = DateTime.parse('2026-03-08T03:15:00-04:00');
      final readings = <IdentifiedGlucoseReading>[
        _reading('before', DateTime.parse('2026-03-08T01:40:00-05:00'), 120),
        _reading('start', DateTime.parse('2026-03-08T01:45:00-05:00'), 100),
        _reading('up-1', DateTime.parse('2026-03-08T01:50:00-05:00'), 110),
        _reading('up-2', DateTime.parse('2026-03-08T01:55:00-05:00'), 125),
        _reading('peak', DateTime.parse('2026-03-08T03:00:00-04:00'), 130),
        _reading('after-1', DateTime.parse('2026-03-08T03:05:00-04:00'), 128),
        _reading('after-2', DateTime.parse('2026-03-08T03:10:00-04:00'), 126),
        _reading('latest', now, 124),
      ];

      final assessment = _assess(readings, now: now);
      expect(assessment.status, RecentObservedRiseAssessmentStatus.qualified);
      expect(
        assessment.candidate!.evidence.episodeSpan,
        const Duration(minutes: 15),
      );
      expect(assessment.candidate!.peakAt.isUtc, isTrue);
    });

    test('rejects invalid policy values before assessing data', () {
      const invalidOrdering = RecentObservedRisePolicy(
        minimumRiseMgdl: 20,
        lookbackWindow: Duration(minutes: 30),
        maximumCandidateAge: Duration(hours: 1),
      );

      expect(
        () => _assess(_qualifiedReadings(), policy: invalidOrdering),
        throwsArgumentError,
      );
    });
  });
}
