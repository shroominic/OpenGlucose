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
}
