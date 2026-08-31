import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_localizations_extension.dart';
import '../display_preferences.dart';

/// Weekly recap / trends screen.
///
/// Summarises the last seven days of glucose readings as plain-language
/// patterns and observations for self-experimentation. It is NOT a medical
/// report, diagnosis, or a substitute for clinical measurement.
class WeeklyRecapScreen extends StatelessWidget {
  const WeeklyRecapScreen({
    super.key,
    required this.readings,
    required this.preferences,
    this.now,
    this.isSampleData = false,
  });

  final List<CgmReading> readings;
  final DisplayPreferences preferences;
  final bool isSampleData;

  /// Injectable clock for deterministic tests; defaults to [DateTime.now].
  final DateTime? now;

  static const Color _muted = Color(0xFF5B6E6A);
  static const Color _accent = Color(0xFF24443F);
  static const Color _up = Color(0xFF1C7C54);
  static const Color _down = Color(0xFFB23A48);

  String _formatGlucose(double mgdl, {bool withUnit = true}) {
    final value = preferences.unit.convertFromMgdl(mgdl);
    final digits = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    final text = value.toStringAsFixed(digits);
    return withUnit ? '$text ${preferences.unit.label}' : text;
  }

  /// Signed glucose delta in the user's unit, e.g. "+12 mg/dL" / "-0.7 mmol/L".
  String _formatGlucoseDelta(double mgdl) {
    final value = preferences.unit.convertFromMgdl(mgdl);
    final digits = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    final sign = value > 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(digits)} ${preferences.unit.label}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final recap = WeeklyRecapAnalytics.recap(
      readings,
      now: now,
      bounds: preferences.targetRange,
    );
    final coverage = recap.thisWeekCoverage;
    final previousCoverage = recap.lastWeekCoverage;
    final dateFormat = DateFormat.MMMd(_dateLocaleName(context));
    final dateRange =
        '${dateFormat.format(recap.weekStart)} – '
        '${dateFormat.format(recap.days.last.date)}';

    return Scaffold(
      appBar: AppBar(
        title: Text(isSampleData ? l10n.sampleWeeklyRecap : l10n.weeklyRecap),
        centerTitle: false,
      ),
      body: Column(
        children: <Widget>[
          if (isSampleData) _SampleDataBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: <Widget>[
                Text(
                  dateRange,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.weeklyRecapDescription,
                  style: theme.textTheme.bodySmall?.copyWith(color: _muted),
                ),
                const SizedBox(height: 16),
                if (!coverage.isSufficient)
                  _EmptyState(theme: theme, coverage: coverage)
                else ...<Widget>[
                  _CoverageCard(coverage: coverage),
                  const SizedBox(height: 14),
                  _OverviewCard(recap: recap, screen: this, theme: theme),
                  const SizedBox(height: 14),
                  _TrendCard(
                    recap: recap,
                    screen: this,
                    theme: theme,
                    previousCoverage: previousCoverage,
                  ),
                  const SizedBox(height: 14),
                  _BestWorstCard(recap: recap, screen: this, theme: theme),
                  const SizedBox(height: 14),
                  _SpikesCard(recap: recap, screen: this, theme: theme),
                  const SizedBox(height: 14),
                  _DayPatternCard(recap: recap, screen: this, theme: theme),
                  const SizedBox(height: 14),
                ],
                _DisclaimerCard(theme: theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- shared rendering helpers used by the cards below --------------------

  Color _deltaColor(double delta, {required bool higherIsBetter}) {
    if (delta == 0) return _muted;
    final good = higherIsBetter ? delta > 0 : delta < 0;
    return good ? _up : _down;
  }
}

class _SampleDataBanner extends StatelessWidget {
  const _SampleDataBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey<String>('sampleWeeklyRecapBanner'),
      color: Color(0xFFFFD166),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.visibility_outlined, size: 19),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  context.l10n.sampleDataNotSensor,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF4A2B00),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: WeeklyRecapScreen._muted,
              ),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.recap,
    required this.screen,
    required this.theme,
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stats = recap.thisWeek;
    final activeDays = recap.days.where((d) => d.hasData).length;
    return _SectionCard(
      title: l10n.weeklyOverviewTitle,
      subtitle: l10n.weeklyOverviewSubtitle(activeDays, stats.readingCount),
      child: Column(
        children: <Widget>[
          _StatRow(
            label: l10n.timeInRange,
            value: '${stats.timeInRangePercent.round()}%',
            explanation: l10n.timeInRangeExplanation(
              screen._formatGlucose(stats.bounds.lowMgdl),
              screen._formatGlucose(stats.bounds.highMgdl),
            ),
          ),
          _StatRow(
            label: l10n.belowAboveRange,
            value:
                '${stats.timeBelowRangePercent.round()}% / '
                '${stats.timeAboveRangePercent.round()}%',
            explanation: l10n.belowAboveRangeExplanation,
          ),
          _StatRow(
            label: l10n.average,
            value: screen._formatGlucose(stats.averageMgdl!),
            explanation: l10n.weeklyAverageExplanation,
          ),
          _StatRow(
            label: l10n.lowestHighest,
            value:
                '${screen._formatGlucose(stats.minMgdl!, withUnit: false)} / '
                '${screen._formatGlucose(stats.maxMgdl!)}',
            explanation: l10n.observedRangeExplanation,
          ),
          _StatRow(
            label: l10n.variabilityCv,
            value:
                '${stats.coefficientOfVariationPercent!.toStringAsFixed(0)}%',
            explanation: l10n.variabilityExplanationNoSd,
          ),
          _StatRow(
            label: l10n.spikes,
            value: '${stats.spikeCount}',
            explanation: l10n.spikesExplanation(
              screen._formatGlucose(stats.bounds.highMgdl),
            ),
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.coverage});

  final AnalyticsCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hours = coverage.observedSpan.inHours;
    final spanText = hours >= 24
        ? l10n.durationDays((hours / 24).toStringAsFixed(1))
        : l10n.durationHours(hours);
    return _SectionCard(
      title: l10n.dataCoverage,
      subtitle: l10n.dataCoverageDescription,
      child: Column(
        children: <Widget>[
          _StatRow(
            label: l10n.readings,
            value: '${coverage.readingCount}',
            explanation: l10n.timestampedReadingsExplanation,
          ),
          _StatRow(
            label: l10n.daysRepresented,
            value: l10n.daysOfSeven(coverage.activeDays),
            explanation: l10n.daysRepresentedExplanation,
          ),
          _StatRow(
            label: l10n.observedSpan,
            value: spanText,
            explanation: l10n.observedSpanExplanation,
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.recap,
    required this.screen,
    required this.theme,
    required this.previousCoverage,
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;
  final AnalyticsCoverage previousCoverage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!previousCoverage.isSufficient) {
      return _SectionCard(
        title: l10n.versusLastWeek,
        subtitle: l10n.weekOverWeekChange,
        child: Text(
          l10n.previousWeekComparisonDescription(
            previousCoverage.readingCount,
            previousCoverage.activeDays,
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: WeeklyRecapScreen._muted,
          ),
        ),
      );
    }
    return _SectionCard(
      title: l10n.versusLastWeek,
      subtitle: l10n.versusLastWeekDescription,
      child: Column(
        children: <Widget>[
          _DeltaRow(
            label: l10n.timeInRange,
            delta: recap.timeInRangeDelta,
            format: (v) => '${v.round()}%',
            formatDelta: (v) =>
                l10n.percentagePoints('${v > 0 ? '+' : ''}${v.round()}'),
            higherIsBetter: true,
            screen: screen,
          ),
          _DeltaRow(
            label: l10n.average,
            delta: recap.averageDelta,
            format: screen._formatGlucose,
            formatDelta: screen._formatGlucoseDelta,
            higherIsBetter: false,
            screen: screen,
          ),
          _DeltaRow(
            label: l10n.variabilityCv,
            delta: recap.variabilityDelta,
            format: (v) => '${v.toStringAsFixed(0)}%',
            formatDelta: (v) => l10n.percentagePoints(
              '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)}',
            ),
            higherIsBetter: false,
            screen: screen,
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _BestWorstCard extends StatelessWidget {
  const _BestWorstCard({
    required this.recap,
    required this.screen,
    required this.theme,
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;

  String _dayLine(BuildContext context, DailyRecap day) {
    final name = DateFormat.EEEE(_dateLocaleName(context)).format(day.date);
    return context.l10n.weekdayRangeSummary(
      name,
      day.stats.timeInRangePercent.round(),
      screen._formatGlucose(day.stats.averageMgdl!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final best = recap.bestDay;
    final worst = recap.worstDay;
    return _SectionCard(
      title: l10n.daysByTimeInRange,
      subtitle: l10n.daysByTimeInRangeDescription,
      child: Column(
        children: <Widget>[
          _StatRow(
            label: l10n.mostInRange,
            value: '${best!.stats.timeInRangePercent.round()}%',
            explanation: _dayLine(context, best),
          ),
          _StatRow(
            label: l10n.leastInRange,
            value: '${worst!.stats.timeInRangePercent.round()}%',
            explanation: _dayLine(context, worst),
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _SpikesCard extends StatelessWidget {
  const _SpikesCard({
    required this.recap,
    required this.screen,
    required this.theme,
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (recap.topSpikes.isEmpty) {
      return _SectionCard(
        title: l10n.topSpikes,
        subtitle: l10n.topSpikesDescription,
        child: Text(
          l10n.noSpikesThisWeek(screen._formatGlucose(recap.bounds.highMgdl)),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: WeeklyRecapScreen._muted,
          ),
        ),
      );
    }
    return _SectionCard(
      title: l10n.topSpikes,
      subtitle: l10n.topSpikesDescription,
      child: Column(
        children: <Widget>[
          for (var i = 0; i < recap.topSpikes.length; i++)
            _StatRow(
              label: DateFormat.MMMEd(
                _dateLocaleName(context),
              ).add_Hm().format(recap.topSpikes[i].at.toLocal()),
              value: screen._formatGlucose(recap.topSpikes[i].peakMgdl),
              explanation: l10n.spikeRiseExplanation(
                screen._formatGlucose(recap.topSpikes[i].amplitudeMgdl),
                screen._formatGlucose(recap.topSpikes[i].riseFromMgdl),
              ),
              isLast: i == recap.topSpikes.length - 1,
            ),
        ],
      ),
    );
  }
}

class _DayPatternCard extends StatelessWidget {
  const _DayPatternCard({
    required this.recap,
    required this.screen,
    required this.theme,
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final entries = recap.dayOfWeekAverages;
    final withData = entries.where((e) => e.averageMgdl != null).toList();
    if (withData.isEmpty) {
      return const SizedBox.shrink();
    }
    final maxAvg = withData
        .map((e) => e.averageMgdl!)
        .reduce((a, b) => a > b ? a : b);

    return _SectionCard(
      title: context.l10n.weeklyDailyAveragesTitle,
      subtitle: context.l10n.weeklyDailyAveragesDescription,
      child: Column(
        children: <Widget>[
          for (var i = 0; i < entries.length; i++)
            _DayBar(
              // 2024-01-01 was a Monday. [dayOfWeekAverages] is always
              // Monday through Sunday, independently of the recap window.
              label: DateFormat.E(
                _dateLocaleName(context),
              ).format(DateTime(2024, 1, entries[i].weekday)),
              averageMgdl: entries[i].averageMgdl,
              maxMgdl: maxAvg,
              valueText: entries[i].averageMgdl == null
                  ? '—'
                  : screen._formatGlucose(
                      entries[i].averageMgdl!,
                      withUnit: false,
                    ),
            ),
        ],
      ),
    );
  }
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.label,
    required this.averageMgdl,
    required this.maxMgdl,
    required this.valueText,
  });

  final String label;
  final double? averageMgdl;
  final double maxMgdl;
  final String valueText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = (averageMgdl == null || maxMgdl <= 0)
        ? 0.0
        : (averageMgdl! / maxMgdl).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: WeeklyRecapScreen._accent,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 12,
                backgroundColor: const Color(0xFFE7EDEB),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF3E7C70),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: averageMgdl == null
                    ? WeeklyRecapScreen._muted
                    : WeeklyRecapScreen._accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.explanation,
    this.isLast = false,
  });

  final String label;
  final String value;
  final String explanation;
  final bool isLast;

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
                  color: WeeklyRecapScreen._accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            explanation,
            style: theme.textTheme.bodySmall?.copyWith(
              color: WeeklyRecapScreen._muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeltaRow extends StatelessWidget {
  const _DeltaRow({
    required this.label,
    required this.delta,
    required this.format,
    required this.formatDelta,
    required this.higherIsBetter,
    required this.screen,
    this.isLast = false,
  });

  final String label;
  final WeekDelta delta;
  final String Function(double) format;
  final String Function(double) formatDelta;
  final bool higherIsBetter;
  final WeeklyRecapScreen screen;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final current = delta.current;
    final change = delta.delta;
    final color = change == null
        ? WeeklyRecapScreen._muted
        : screen._deltaColor(change, higherIsBetter: higherIsBetter);
    final changeText = change == null
        ? l10n.noPriorWeek
        : (delta.isFlat() ? l10n.aboutTheSame : formatDelta(change));

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Row(
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                current == null ? '—' : format(current),
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: WeeklyRecapScreen._accent,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                changeText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.theme, required this.coverage});

  final ThemeData theme;
  final AnalyticsCoverage coverage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.insights_rounded,
              size: 36,
              color: WeeklyRecapScreen._accent,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.notEnoughReadingsYet,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.weeklyInsufficientCoverage(
                coverage.readingCount,
                coverage.activeDays,
                coverage.minimumReadings,
                coverage.minimumActiveDays,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: WeeklyRecapScreen._muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisclaimerCard extends StatelessWidget {
  const _DisclaimerCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: WeeklyRecapScreen._muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.weeklyRecapDisclaimer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: WeeklyRecapScreen._muted,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _dateLocaleName(BuildContext context) {
  return Localizations.localeOf(context).languageCode.toLowerCase() == 'zh'
      ? 'zh'
      : 'en';
}
