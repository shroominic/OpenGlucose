/// The source of one independently decoded V1150 glucose observation.
enum YuwellV1150ObservationSource { history, live }

/// One same-index comparison between the V1150 transmitter field and the
/// official application's native-algorithm output.
///
/// Only sanitized values belong in this model. Keep raw records, calibration
/// coefficients, sensor identifiers, and official-app traces outside Git.
final class YuwellV1150GlucoseObservation {
  factory YuwellV1150GlucoseObservation({
    required int index,
    required int transmitterGlucoseMgDl,
    required int officialGlucoseMgDl,
    required YuwellV1150ObservationSource source,
    required int connectionEpoch,
  }) {
    if (index < 0 || index >= 7695) {
      throw RangeError.range(index, 0, 7694, 'index');
    }
    if (transmitterGlucoseMgDl < 0 || transmitterGlucoseMgDl > 0x0fff) {
      throw RangeError.range(
        transmitterGlucoseMgDl,
        0,
        0x0fff,
        'transmitterGlucoseMgDl',
      );
    }
    if (officialGlucoseMgDl < -0x8000 || officialGlucoseMgDl > 0x7fff) {
      throw RangeError.range(
        officialGlucoseMgDl,
        -0x8000,
        0x7fff,
        'officialGlucoseMgDl',
      );
    }
    if (connectionEpoch < 0) {
      throw RangeError.value(connectionEpoch, 'connectionEpoch');
    }
    return YuwellV1150GlucoseObservation._(
      index: index,
      transmitterGlucoseMgDl: transmitterGlucoseMgDl,
      officialGlucoseMgDl: officialGlucoseMgDl,
      source: source,
      connectionEpoch: connectionEpoch,
    );
  }

  const YuwellV1150GlucoseObservation._({
    required this.index,
    required this.transmitterGlucoseMgDl,
    required this.officialGlucoseMgDl,
    required this.source,
    required this.connectionEpoch,
  });

  final int index;
  final int transmitterGlucoseMgDl;
  final int officialGlucoseMgDl;
  final YuwellV1150ObservationSource source;

  /// A local, non-identifying counter that increments after each reconnect.
  final int connectionEpoch;

  bool get matches => transmitterGlucoseMgDl == officialGlucoseMgDl;

  @override
  String toString() =>
      'YuwellV1150GlucoseObservation(index: <redacted>, values: <redacted>)';
}

/// One closed interval of missing indexes in an otherwise sorted series.
final class YuwellV1150IndexGap {
  const YuwellV1150IndexGap(this.first, this.last)
    : assert(first >= 0),
      assert(last >= first);

  final int first;
  final int last;

  int get length => last - first + 1;

  @override
  String toString() => 'YuwellV1150IndexGap(<redacted>)';
}

/// Explicit requirements for one private V1150 comparison series.
///
/// This is evidence scaffolding, not a clinical-equivalence claim. Cohort and
/// review requirements still belong in the release gate.
final class YuwellV1150ValidationRequirements {
  factory YuwellV1150ValidationRequirements({
    required int minimumUniqueIndexes,
    required int minimumConnectionEpochs,
    required int minimumHistoryLiveOverlapIndexes,
    bool requireStartsAtZero = true,
    bool requireContiguous = true,
    bool requireWarmupTransition = true,
    bool requireExactMatch = true,
    int? requiredLastIndex,
  }) {
    if (minimumUniqueIndexes < 1 || minimumUniqueIndexes > 7695) {
      throw RangeError.range(
        minimumUniqueIndexes,
        1,
        7695,
        'minimumUniqueIndexes',
      );
    }
    if (minimumConnectionEpochs < 1) {
      throw RangeError.value(
        minimumConnectionEpochs,
        'minimumConnectionEpochs',
      );
    }
    if (minimumHistoryLiveOverlapIndexes < 0 ||
        minimumHistoryLiveOverlapIndexes > 7695) {
      throw RangeError.range(
        minimumHistoryLiveOverlapIndexes,
        0,
        7695,
        'minimumHistoryLiveOverlapIndexes',
      );
    }
    if (requiredLastIndex != null &&
        (requiredLastIndex < 0 || requiredLastIndex >= 7695)) {
      throw RangeError.range(requiredLastIndex, 0, 7694, 'requiredLastIndex');
    }
    return YuwellV1150ValidationRequirements._(
      minimumUniqueIndexes: minimumUniqueIndexes,
      minimumConnectionEpochs: minimumConnectionEpochs,
      minimumHistoryLiveOverlapIndexes: minimumHistoryLiveOverlapIndexes,
      requireStartsAtZero: requireStartsAtZero,
      requireContiguous: requireContiguous,
      requireWarmupTransition: requireWarmupTransition,
      requireExactMatch: requireExactMatch,
      requiredLastIndex: requiredLastIndex,
    );
  }

  const YuwellV1150ValidationRequirements._({
    required this.minimumUniqueIndexes,
    required this.minimumConnectionEpochs,
    required this.minimumHistoryLiveOverlapIndexes,
    required this.requireStartsAtZero,
    required this.requireContiguous,
    required this.requireWarmupTransition,
    required this.requireExactMatch,
    required this.requiredLastIndex,
  });

  final int minimumUniqueIndexes;
  final int minimumConnectionEpochs;
  final int minimumHistoryLiveOverlapIndexes;
  final bool requireStartsAtZero;
  final bool requireContiguous;
  final bool requireWarmupTransition;
  final bool requireExactMatch;
  final int? requiredLastIndex;
}

/// A deterministic summary of a private packed-versus-native comparison.
final class YuwellV1150GlucoseValidationReport {
  YuwellV1150GlucoseValidationReport._({
    required this.observationCount,
    required this.uniqueIndexCount,
    required this.firstIndex,
    required this.lastIndex,
    required this.mismatchCount,
    required this.mismatchIndexCount,
    required this.duplicateConflictIndexCount,
    required this.connectionEpochCount,
    required this.historyLiveOverlapIndexCount,
    required List<YuwellV1150IndexGap> gaps,
    required this.includesWarmupTransition,
  }) : gaps = List<YuwellV1150IndexGap>.unmodifiable(gaps);

  factory YuwellV1150GlucoseValidationReport.evaluate(
    Iterable<YuwellV1150GlucoseObservation> input,
  ) {
    final observations = List<YuwellV1150GlucoseObservation>.of(input);
    final byIndex = <int, List<YuwellV1150GlucoseObservation>>{};
    final epochs = <int>{};
    var mismatchCount = 0;
    for (final observation in observations) {
      byIndex.putIfAbsent(observation.index, () => []).add(observation);
      epochs.add(observation.connectionEpoch);
      if (!observation.matches) mismatchCount++;
    }

    final indexes = byIndex.keys.toList()..sort();
    final gaps = <YuwellV1150IndexGap>[];
    for (var position = 1; position < indexes.length; position++) {
      final previous = indexes[position - 1];
      final current = indexes[position];
      if (current > previous + 1) {
        gaps.add(YuwellV1150IndexGap(previous + 1, current - 1));
      }
    }

    var mismatchIndexCount = 0;
    var duplicateConflictIndexCount = 0;
    var historyLiveOverlapIndexCount = 0;
    for (final observationsAtIndex in byIndex.values) {
      if (observationsAtIndex.any((observation) => !observation.matches)) {
        mismatchIndexCount++;
      }
      final transmitterValues = observationsAtIndex
          .map((observation) => observation.transmitterGlucoseMgDl)
          .toSet();
      final officialValues = observationsAtIndex
          .map((observation) => observation.officialGlucoseMgDl)
          .toSet();
      if (transmitterValues.length > 1 || officialValues.length > 1) {
        duplicateConflictIndexCount++;
      }
      final sources = observationsAtIndex
          .map((observation) => observation.source)
          .toSet();
      if (sources.contains(YuwellV1150ObservationSource.history) &&
          sources.contains(YuwellV1150ObservationSource.live)) {
        historyLiveOverlapIndexCount++;
      }
    }

    return YuwellV1150GlucoseValidationReport._(
      observationCount: observations.length,
      uniqueIndexCount: indexes.length,
      firstIndex: indexes.isEmpty ? null : indexes.first,
      lastIndex: indexes.isEmpty ? null : indexes.last,
      mismatchCount: mismatchCount,
      mismatchIndexCount: mismatchIndexCount,
      duplicateConflictIndexCount: duplicateConflictIndexCount,
      connectionEpochCount: epochs.length,
      historyLiveOverlapIndexCount: historyLiveOverlapIndexCount,
      gaps: gaps,
      includesWarmupTransition:
          byIndex.containsKey(14) && byIndex.containsKey(15),
    );
  }

  final int observationCount;
  final int uniqueIndexCount;
  final int? firstIndex;
  final int? lastIndex;
  final int mismatchCount;
  final int mismatchIndexCount;
  final int duplicateConflictIndexCount;
  final int connectionEpochCount;
  final int historyLiveOverlapIndexCount;
  final List<YuwellV1150IndexGap> gaps;
  final bool includesWarmupTransition;

  bool get startsAtZero => firstIndex == 0;
  bool get isContiguous => gaps.isEmpty;
  bool get isExactMatch =>
      observationCount > 0 &&
      mismatchCount == 0 &&
      duplicateConflictIndexCount == 0;

  bool satisfies(YuwellV1150ValidationRequirements requirements) {
    if (uniqueIndexCount < requirements.minimumUniqueIndexes ||
        connectionEpochCount < requirements.minimumConnectionEpochs ||
        historyLiveOverlapIndexCount <
            requirements.minimumHistoryLiveOverlapIndexes) {
      return false;
    }
    if (requirements.requireStartsAtZero && !startsAtZero) return false;
    if (requirements.requireContiguous && !isContiguous) return false;
    if (requirements.requireWarmupTransition && !includesWarmupTransition) {
      return false;
    }
    if (requirements.requireExactMatch && !isExactMatch) return false;
    final requiredLastIndex = requirements.requiredLastIndex;
    return requiredLastIndex == null || lastIndex == requiredLastIndex;
  }

  @override
  String toString() => 'YuwellV1150GlucoseValidationReport(values: <redacted>)';
}
