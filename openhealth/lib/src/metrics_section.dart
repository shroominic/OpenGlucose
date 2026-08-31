import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'app_localizations_extension.dart';
import 'display_preferences.dart';

/// Explainable, wellness-framed metrics section for the dashboard.
///
/// Renders Time-in-Range, variability (CV/SD), average, an estimated
/// GMI-style indicator and a spike count for a selectable timeframe, each with
/// a one-line plain-language explanation. These are observations and patterns
/// for self-experimentation, not medical metrics or diagnosis.
class MetricsSection extends StatefulWidget {
  const MetricsSection({
    super.key,
    required this.readings,
    required this.preferences,
    this.now,
  });

  final List<CgmReading> readings;
  final DisplayPreferences preferences;
  final DateTime? now;

  @override
  State<MetricsSection> createState() => _MetricsSectionState();
}

class _MetricsSectionState extends State<MetricsSection> {
  AnalyticsTimeframe _timeframe = AnalyticsTimeframe.last24h;

  static const Color _muted = Color(0xFF5B6E6A);

  String _formatGlucose(double mgdl) {
    final value = widget.preferences.unit.convertFromMgdl(mgdl);
    final digits = widget.preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${widget.preferences.unit.label}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final stats = GlucoseAnalytics.summarize(
      widget.readings,
      timeframe: _timeframe,
      bounds: widget.preferences.targetRange,
      now: widget.now,
    );
    final coverage = GlucoseAnalytics.assessCoverage(
      widget.readings,
      _timeframe,
      now: widget.now,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.patterns,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                _TimeframeSelector(
                  value: _timeframe,
                  onChanged: (value) => setState(() => _timeframe = value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.patternsDescription,
              style: theme.textTheme.bodySmall?.copyWith(color: _muted),
            ),
            const SizedBox(height: 14),
            if (!coverage.isSufficient)
              _InsufficientCoverage(coverage: coverage)
            else
              Column(
                children: <Widget>[
                  _MetricRow(
                    label: l10n.timeInRange,
                    value: '${stats.timeInRangePercent.round()}%',
                    explanation: l10n.timeInRangeExplanation(
                      _formatGlucose(stats.bounds.lowMgdl),
                      _formatGlucose(stats.bounds.highMgdl),
                    ),
                  ),
                  _MetricRow(
                    label: l10n.belowAbove,
                    value:
                        '${stats.timeBelowRangePercent.round()}% / '
                        '${stats.timeAboveRangePercent.round()}%',
                    explanation: l10n.belowAboveExplanation,
                  ),
                  _MetricRow(
                    label: l10n.average,
                    value: _formatGlucose(stats.averageMgdl!),
                    explanation: l10n.averageExplanation,
                  ),
                  _MetricRow(
                    label: l10n.variabilityCv,
                    value: stats.coefficientOfVariationPercent == null
                        ? l10n.unavailable
                        : '${stats.coefficientOfVariationPercent!.toStringAsFixed(0)}%',
                    explanation: l10n.variabilityExplanation(
                      stats.standardDeviationMgdl == null
                          ? l10n.unavailable
                          : _formatGlucose(stats.standardDeviationMgdl!),
                    ),
                  ),
                  if (_timeframe == AnalyticsTimeframe.last14d)
                    _MetricRow(
                      label: l10n.estimatedGmi,
                      value:
                          '~${stats.estimatedGmiPercent!.toStringAsFixed(1)}%',
                      explanation: l10n.estimatedGmiExplanation,
                    ),
                  _MetricRow(
                    label: l10n.spikes,
                    value: '${stats.spikeCount}',
                    explanation: l10n.spikesExplanation(
                      _formatGlucose(stats.bounds.highMgdl),
                    ),
                    isLast: true,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _InsufficientCoverage extends StatelessWidget {
  const _InsufficientCoverage({required this.coverage});

  final AnalyticsCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Container(
      key: const ValueKey<String>('patternsInsufficientData'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.hourglass_empty_rounded,
            size: 20,
            color: _MetricsSectionState._muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.patternsInsufficientCoverage(
                _analyticsTimeframeLabel(context, coverage.timeframe),
                coverage.readingCount,
                coverage.activeDays,
                coverage.minimumReadings,
                coverage.minimumActiveDays,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _MetricsSectionState._muted,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeframeSelector extends StatelessWidget {
  const _TimeframeSelector({required this.value, required this.onChanged});

  final AnalyticsTimeframe value;
  final ValueChanged<AnalyticsTimeframe> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<AnalyticsTimeframe>(
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: <ButtonSegment<AnalyticsTimeframe>>[
        for (final timeframe in AnalyticsTimeframe.values)
          ButtonSegment<AnalyticsTimeframe>(
            value: timeframe,
            label: Text(_analyticsTimeframeLabel(context, timeframe)),
          ),
      ],
      selected: <AnalyticsTimeframe>{value},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

String _analyticsTimeframeLabel(
  BuildContext context,
  AnalyticsTimeframe timeframe,
) {
  final l10n = context.l10n;
  return switch (timeframe) {
    AnalyticsTimeframe.last24h => l10n.timeframeHoursShort(24),
    AnalyticsTimeframe.last7d => l10n.timeframeDaysShort(7),
    AnalyticsTimeframe.last14d => l10n.timeframeDaysShort(14),
  };
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    required this.explanation,
    this.isLast = false,
  });

  final String label;
  final String value;
  final String explanation;
  final bool isLast;

  static const Color _muted = Color(0xFF5B6E6A);
  static const Color _accent = Color(0xFF24443F);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: _accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            explanation,
            style: theme.textTheme.bodySmall?.copyWith(color: _muted),
          ),
        ],
      ),
    );
  }
}
