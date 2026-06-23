import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
  });

  final List<CgmReading> readings;
  final DisplayPreferences preferences;

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
    final recap = WeeklyRecapAnalytics.recap(readings, now: now);
    final dateRange =
        '${DateFormat('MMM d').format(recap.weekStart)} – '
        '${DateFormat('MMM d').format(recap.weekEnd.subtract(const Duration(days: 1)))}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weekly recap'),
        centerTitle: false,
      ),
      body: ListView(
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
            'Patterns and observations from your last 7 days — for '
            'self-experimentation, not medical advice.',
            style: theme.textTheme.bodySmall?.copyWith(color: _muted),
          ),
          const SizedBox(height: 16),
          if (!recap.hasData)
            _EmptyState(theme: theme)
          else ...<Widget>[
            _OverviewCard(recap: recap, screen: this, theme: theme),
            const SizedBox(height: 14),
            _TrendCard(recap: recap, screen: this, theme: theme),
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
    );
  }

  // --- shared rendering helpers used by the cards below --------------------

  Color _deltaColor(double delta, {required bool higherIsBetter}) {
    if (delta == 0) return _muted;
    final good = higherIsBetter ? delta > 0 : delta < 0;
    return good ? _up : _down;
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
    final stats = recap.thisWeek;
    final activeDays = recap.days.where((d) => d.hasData).length;
    return _SectionCard(
      title: 'This week at a glance',
      subtitle:
          '$activeDays of 7 days with readings · '
          '${stats.readingCount} readings.',
      child: Column(
        children: <Widget>[
          _StatRow(
            label: 'Time in range',
            value: '${stats.timeInRangePercent.round()}%',
            explanation:
                'Share of readings between '
                '${screen._formatGlucose(stats.bounds.lowMgdl)} and '
                '${screen._formatGlucose(stats.bounds.highMgdl)}.',
          ),
          _StatRow(
            label: 'Average',
            value: screen._formatGlucose(stats.averageMgdl!),
            explanation: 'Mean of every reading this week.',
          ),
          _StatRow(
            label: 'Variability (CV)',
            value:
                '${stats.coefficientOfVariationPercent!.toStringAsFixed(0)}%',
            explanation:
                'How spread out readings are around the average. '
                'Lower looks steadier.',
          ),
          _StatRow(
            label: 'Spikes',
            value: '${stats.spikeCount}',
            explanation:
                'Times readings rose past '
                '${screen._formatGlucose(stats.bounds.highMgdl)}.',
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
  });

  final WeeklyRecap recap;
  final WeeklyRecapScreen screen;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    if (!recap.lastWeek.hasData) {
      return _SectionCard(
        title: 'Versus last week',
        subtitle: 'Week-over-week change.',
        child: Text(
          'No readings from the previous week yet — comparisons appear once '
          'you have two weeks of history.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: WeeklyRecapScreen._muted,
          ),
        ),
      );
    }
    return _SectionCard(
      title: 'Versus last week',
      subtitle: 'How this week compares with the seven days before.',
      child: Column(
        children: <Widget>[
          _DeltaRow(
            label: 'Time in range',
            delta: recap.timeInRangeDelta,
            format: (v) => '${v.round()}%',
            formatDelta: (v) => '${v > 0 ? '+' : ''}${v.round()} pts',
            higherIsBetter: true,
            screen: screen,
          ),
          _DeltaRow(
            label: 'Average',
            delta: recap.averageDelta,
            format: (v) => screen._formatGlucose(v),
            formatDelta: screen._formatGlucoseDelta,
            higherIsBetter: false,
            screen: screen,
          ),
          _DeltaRow(
            label: 'Variability (CV)',
            delta: recap.variabilityDelta,
            format: (v) => '${v.toStringAsFixed(0)}%',
            formatDelta: (v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)} pts',
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

  String _dayLine(DailyRecap day) {
    final name = DateFormat('EEEE').format(day.date);
    return '$name · ${day.stats.timeInRangePercent.round()}% in range · '
        'avg ${screen._formatGlucose(day.stats.averageMgdl!)}';
  }

  @override
  Widget build(BuildContext context) {
    final best = recap.bestDay;
    final worst = recap.worstDay;
    return _SectionCard(
      title: 'Steadiest & bumpiest day',
      subtitle: 'Ranked by time spent in range.',
      child: Column(
        children: <Widget>[
          _StatRow(
            label: 'Steadiest',
            value: '${best!.stats.timeInRangePercent.round()}%',
            explanation: _dayLine(best),
          ),
          _StatRow(
            label: 'Bumpiest',
            value: '${worst!.stats.timeInRangePercent.round()}%',
            explanation: _dayLine(worst),
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
    if (recap.topSpikes.isEmpty) {
      return _SectionCard(
        title: 'Top spikes',
        subtitle: 'Biggest upward swings this week.',
        child: Text(
          'No readings rose past '
          '${screen._formatGlucose(recap.bounds.highMgdl)} this week.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: WeeklyRecapScreen._muted,
          ),
        ),
      );
    }
    return _SectionCard(
      title: 'Top spikes',
      subtitle: 'Biggest upward swings this week.',
      child: Column(
        children: <Widget>[
          for (var i = 0; i < recap.topSpikes.length; i++)
            _StatRow(
              label: DateFormat('EEE, MMM d · HH:mm').format(
                recap.topSpikes[i].at,
              ),
              value: screen._formatGlucose(recap.topSpikes[i].peakMgdl),
              explanation:
                  'Rose ${screen._formatGlucose(recap.topSpikes[i].amplitudeMgdl)} '
                  'from ${screen._formatGlucose(recap.topSpikes[i].riseFromMgdl)}.',
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

  static const List<String> _short = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

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
      title: 'Day-of-week pattern',
      subtitle: 'Average reading by weekday — spot recurring days.',
      child: Column(
        children: <Widget>[
          for (var i = 0; i < entries.length; i++)
            _DayBar(
              label: _short[i],
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
    final current = delta.current;
    final change = delta.delta;
    final color = change == null
        ? WeeklyRecapScreen._muted
        : screen._deltaColor(change, higherIsBetter: higherIsBetter);
    final changeText = change == null
        ? 'no prior week'
        : (delta.isFlat() ? 'about the same' : formatDelta(change));

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
  const _EmptyState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
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
              'Not enough readings yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Once you have a few days of readings this week, your recap '
              'will show time-in-range, trends, your steadiest day and more.',
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
              'These are wellness observations for self-experimentation. '
              'OpenGlucose is not a medical device and this recap is not a '
              'diagnosis or medical advice. Talk to a professional for health '
              'decisions.',
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
