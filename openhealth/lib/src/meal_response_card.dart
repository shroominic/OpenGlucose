import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

/// Compact presentation of local meal-response coverage and aggregates.
///
/// This widget never computes or fetches data. It renders the already-derived
/// [MealResponseSummary] and keeps the core safety boundary visible, including
/// when the summary is incomplete.
class MealResponseCard extends StatelessWidget {
  const MealResponseCard({
    super.key,
    required this.summary,
    this.unit = GlucoseUnit.mgdl,
  });

  final MealResponseSummary summary;
  final GlucoseUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showMetrics =
        summary.averagePeakDeltaMgdl != null &&
        summary.averageTimeToPeak != null;
    return Card(
      key: const ValueKey<String>('mealResponseCard'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.restaurant_outlined,
                  color: Color(0xFF0B6E69),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Meal response',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF183C3B),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  'Local',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xFF5B6E6A),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _headline,
              key: const ValueKey<String>('mealResponseHeadline'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF49615D),
                height: 1.25,
              ),
            ),
            if (showMetrics) ...<Widget>[
              const SizedBox(height: 11),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Metric(
                      label: 'Peak delta',
                      value: _formatDelta(summary.averagePeakDeltaMgdl!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Metric(
                      label: 'Time to peak',
                      value: _formatDuration(summary.averageTimeToPeak!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Metric(
                      label: 'Coverage',
                      value: _formatPercent(summary.averageCoveragePercent),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.info_outline_rounded,
                        size: 16,
                        color: Color(0xFF49615D),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _safetyBoundary,
                        key: const ValueKey<String>('mealResponseSafety'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF49615D),
                          height: 1.25,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _headline => switch (summary.status) {
    MealResponseSummaryStatus.noMeals =>
      'Log a meal to see its local glucose response.',
    MealResponseSummaryStatus.noGlucoseReadings =>
      'No glucose readings overlap your logged meals yet.',
    MealResponseSummaryStatus.insufficientData =>
      'Not enough readings yet. Collect readings across the two-hour window '
          'to unlock this local view.',
    MealResponseSummaryStatus.partial =>
      '${summary.sufficientMealCount} of ${summary.mealCount} meals have a '
          'complete two-hour window.',
    MealResponseSummaryStatus.ready =>
      'Across ${summary.mealCount} logged '
          '${summary.mealCount == 1 ? 'meal' : 'meals'} · local timing only.',
  };

  String get _safetyBoundary {
    final value = summary.safetyBoundary.trim();
    return value.isEmpty ? mealResponseSafetyBoundary : value;
  }

  String _formatDelta(double valueMgdl) {
    final value = unit.convertFromMgdl(valueMgdl);
    final digits = unit == GlucoseUnit.mgdl ? 0 : 1;
    final sign = value > 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(digits)} ${unit.label}';
  }

  String _formatPercent(double? value) =>
      value == null ? '--' : '${value.round()}%';

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remainder = minutes.remainder(60);
    return remainder == 0 ? '${hours}h' : '${hours}h ${remainder}m';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3EF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5B6E6A),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF183C3B),
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
