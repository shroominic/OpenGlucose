import 'package:cgm_yuwell_anytime/cgm_yuwell_anytime.dart';
import 'package:test/test.dart';

void main() {
  group('V1150 packed-versus-native validation', () {
    test('summarizes an exact contiguous synthetic series', () {
      final observations = <YuwellV1150GlucoseObservation>[
        for (var index = 0; index < 60; index++)
          YuwellV1150GlucoseObservation(
            index: index,
            transmitterGlucoseMgDl: index < 14 ? 0 : 80 + index % 7,
            officialGlucoseMgDl: index < 14 ? 0 : 80 + index % 7,
            source: YuwellV1150ObservationSource.history,
            connectionEpoch: index < 30 ? 0 : 1,
          ),
        for (var index = 50; index < 60; index++)
          YuwellV1150GlucoseObservation(
            index: index,
            transmitterGlucoseMgDl: 80 + index % 7,
            officialGlucoseMgDl: 80 + index % 7,
            source: YuwellV1150ObservationSource.live,
            connectionEpoch: 1,
          ),
      ];

      final report = YuwellV1150GlucoseValidationReport.evaluate(observations);

      expect(report.observationCount, 70);
      expect(report.uniqueIndexCount, 60);
      expect(report.startsAtZero, isTrue);
      expect(report.isContiguous, isTrue);
      expect(report.includesWarmupTransition, isTrue);
      expect(report.connectionEpochCount, 2);
      expect(report.historyLiveOverlapIndexCount, 10);
      expect(report.mismatchCount, 0);
      expect(report.isExactMatch, isTrue);
      expect(
        report.satisfies(
          YuwellV1150ValidationRequirements(
            minimumUniqueIndexes: 60,
            minimumConnectionEpochs: 2,
            minimumHistoryLiveOverlapIndexes: 10,
          ),
        ),
        isTrue,
      );
    });

    test('rejects gaps, mismatches, and conflicting duplicate values', () {
      final report = YuwellV1150GlucoseValidationReport.evaluate(
        <YuwellV1150GlucoseObservation>[
          YuwellV1150GlucoseObservation(
            index: 0,
            transmitterGlucoseMgDl: 0,
            officialGlucoseMgDl: 0,
            source: YuwellV1150ObservationSource.history,
            connectionEpoch: 0,
          ),
          YuwellV1150GlucoseObservation(
            index: 2,
            transmitterGlucoseMgDl: 101,
            officialGlucoseMgDl: 100,
            source: YuwellV1150ObservationSource.history,
            connectionEpoch: 0,
          ),
          YuwellV1150GlucoseObservation(
            index: 2,
            transmitterGlucoseMgDl: 102,
            officialGlucoseMgDl: 100,
            source: YuwellV1150ObservationSource.live,
            connectionEpoch: 1,
          ),
        ],
      );

      expect(report.gaps, hasLength(1));
      expect(report.gaps.single.first, 1);
      expect(report.gaps.single.last, 1);
      expect(report.mismatchCount, 2);
      expect(report.mismatchIndexCount, 1);
      expect(report.duplicateConflictIndexCount, 1);
      expect(report.isExactMatch, isFalse);
      expect(
        report.satisfies(
          YuwellV1150ValidationRequirements(
            minimumUniqueIndexes: 2,
            minimumConnectionEpochs: 2,
            minimumHistoryLiveOverlapIndexes: 1,
            requireWarmupTransition: false,
          ),
        ),
        isFalse,
      );
    });

    test('does not treat an empty report as an exact match', () {
      final report = YuwellV1150GlucoseValidationReport.evaluate(
        const <YuwellV1150GlucoseObservation>[],
      );

      expect(report.firstIndex, isNull);
      expect(report.lastIndex, isNull);
      expect(report.isExactMatch, isFalse);
      expect(report.toString(), contains('<redacted>'));
    });

    test('requires the requested last index', () {
      final report = YuwellV1150GlucoseValidationReport.evaluate(
        <YuwellV1150GlucoseObservation>[
          for (var index = 0; index <= 15; index++)
            YuwellV1150GlucoseObservation(
              index: index,
              transmitterGlucoseMgDl: index,
              officialGlucoseMgDl: index,
              source: YuwellV1150ObservationSource.history,
              connectionEpoch: 0,
            ),
        ],
      );

      expect(
        report.satisfies(
          YuwellV1150ValidationRequirements(
            minimumUniqueIndexes: 16,
            minimumConnectionEpochs: 1,
            minimumHistoryLiveOverlapIndexes: 0,
            requiredLastIndex: 7694,
          ),
        ),
        isFalse,
      );
    });
  });

  group('construction-time range validation', () {
    // These two factories are the fail-closed input boundary for the whole
    // evidence-gate report above: every RangeError here is a value that
    // must never silently become part of a promotion decision. Boundary
    // values themselves (the last accepted value on each side) must not
    // throw -- that is the actual admitted range, not just its interior.
    test('YuwellV1150GlucoseObservation rejects out-of-range fields', () {
      YuwellV1150GlucoseObservation build({
        int index = 0,
        int transmitterGlucoseMgDl = 0,
        int officialGlucoseMgDl = 0,
        int connectionEpoch = 0,
      }) => YuwellV1150GlucoseObservation(
        index: index,
        transmitterGlucoseMgDl: transmitterGlucoseMgDl,
        officialGlucoseMgDl: officialGlucoseMgDl,
        source: YuwellV1150ObservationSource.history,
        connectionEpoch: connectionEpoch,
      );

      expect(() => build(index: -1), throwsRangeError);
      expect(() => build(index: 7695), throwsRangeError);
      expect(() => build(transmitterGlucoseMgDl: -1), throwsRangeError);
      expect(() => build(transmitterGlucoseMgDl: 0x1000), throwsRangeError);
      expect(() => build(officialGlucoseMgDl: -0x8001), throwsRangeError);
      expect(() => build(officialGlucoseMgDl: 0x8000), throwsRangeError);
      expect(() => build(connectionEpoch: -1), throwsRangeError);

      expect(() => build(index: 7694), returnsNormally);
      expect(() => build(transmitterGlucoseMgDl: 0x0fff), returnsNormally);
      expect(() => build(officialGlucoseMgDl: -0x8000), returnsNormally);
      expect(() => build(officialGlucoseMgDl: 0x7fff), returnsNormally);
    });

    test('YuwellV1150ValidationRequirements rejects out-of-range fields', () {
      YuwellV1150ValidationRequirements build({
        int minimumUniqueIndexes = 1,
        int minimumConnectionEpochs = 1,
        int minimumHistoryLiveOverlapIndexes = 0,
        int? requiredLastIndex,
      }) => YuwellV1150ValidationRequirements(
        minimumUniqueIndexes: minimumUniqueIndexes,
        minimumConnectionEpochs: minimumConnectionEpochs,
        minimumHistoryLiveOverlapIndexes: minimumHistoryLiveOverlapIndexes,
        requiredLastIndex: requiredLastIndex,
      );

      expect(() => build(minimumUniqueIndexes: 0), throwsRangeError);
      expect(() => build(minimumUniqueIndexes: 7696), throwsRangeError);
      expect(() => build(minimumConnectionEpochs: 0), throwsRangeError);
      expect(
        () => build(minimumHistoryLiveOverlapIndexes: -1),
        throwsRangeError,
      );
      expect(
        () => build(minimumHistoryLiveOverlapIndexes: 7696),
        throwsRangeError,
      );
      expect(() => build(requiredLastIndex: -1), throwsRangeError);
      expect(() => build(requiredLastIndex: 7695), throwsRangeError);

      expect(() => build(minimumUniqueIndexes: 7695), returnsNormally);
      expect(
        () => build(minimumHistoryLiveOverlapIndexes: 7695),
        returnsNormally,
      );
      expect(() => build(requiredLastIndex: 7694), returnsNormally);
      expect(() => build(requiredLastIndex: null), returnsNormally);
    });
  });
}
