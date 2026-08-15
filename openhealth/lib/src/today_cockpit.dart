import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'body_timeline.dart';
import 'display_preferences.dart';
import 'evidence_observation_card.dart';

/// A compact, non-clinical summary of the current day.
///
/// This is intentionally a presentation-only widget. It reports the amount
/// of available context and simple glucose observations; it does not score
/// health, make recommendations, or turn sparse data into a conclusion.
class TodayCockpit extends StatelessWidget {
  const TodayCockpit({
    super.key,
    required this.readings,
    required this.preferences,
    this.now,
    this.onAddContext,
    this.journalSummary,
    this.journalSummaryBuilder,
    this.journalListenable,
    this.bodyTimelineContext,
    this.bodyTimelineObservations = const <MetabolicObservation>[],
    this.showBodyTimeline = false,
    this.observations = const <MetabolicObservation>[],
    this.safetyBoundary = AiDisclaimer.short,
  });

  final List<CgmReading> readings;
  final DisplayPreferences preferences;
  final DateTime? now;
  final VoidCallback? onAddContext;
  final String? journalSummary;
  final String? Function()? journalSummaryBuilder;
  final Listenable? journalListenable;
  final JournalContext? bodyTimelineContext;
  final List<MetabolicObservation> bodyTimelineObservations;
  final bool showBodyTimeline;
  final List<MetabolicObservation> observations;
  final String safetyBoundary;

  String _formatGlucose(double valueMgdl) {
    final value = preferences.unit.convertFromMgdl(valueMgdl);
    final digits = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${preferences.unit.label}';
  }

  @override
  Widget build(BuildContext context) {
    final listenable = journalListenable;
    if (listenable != null) {
      return AnimatedBuilder(
        animation: listenable,
        builder: (context, _) => _buildCockpit(context),
      );
    }
    return _buildCockpit(context);
  }

  Widget _buildCockpit(BuildContext context) {
    final currentJournalSummary =
        journalSummaryBuilder?.call() ?? journalSummary;
    final reference = now ?? DateTime.now();
    final stats = GlucoseAnalytics.summarize(
      readings,
      timeframe: AnalyticsTimeframe.last24h,
      bounds: preferences.targetRange,
      now: reference,
    );
    final current = readings
        .where((reading) => reading.recordedAt != null)
        .where((reading) => !reading.recordedAt!.isAfter(reference))
        .fold<CgmReading?>(null, (latest, reading) {
          if (latest == null ||
              reading.recordedAt!.isAfter(latest.recordedAt!)) {
            return reading;
          }
          return latest;
        });
    final coverage = GlucoseAnalytics.assessCoverage(
      readings,
      AnalyticsTimeframe.last24h,
      now: reference,
    );
    final effectiveObservations = observations.isNotEmpty
        ? observations
        : coverage.isSufficient
        ? MetabolicObservationEngine.generate(
            readings: readings,
            events: const <HealthEvent>[],
            windowStart: reference.subtract(const Duration(hours: 24)),
            windowEnd: reference,
            bounds: preferences.targetRange,
            unit: preferences.unit,
          )
        : const <MetabolicObservation>[];
    final theme = Theme.of(context);

    return Column(
      key: const ValueKey<String>('todayCockpit'),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Today at a glance',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (onAddContext != null)
                      IconButton.filledTonal(
                        key: const ValueKey<String>('todayAddContextButton'),
                        tooltip: 'Add context',
                        onPressed: onAddContext,
                        icon: const Icon(Icons.add_rounded),
                      ),
                  ],
                ),
                if (currentJournalSummary != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    currentJournalSummary,
                    key: const ValueKey<String>('todayJournalSummary'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF5B6E6A),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _TodayTile(
                        label: 'Latest',
                        value: current == null
                            ? '--'
                            : _formatGlucose(current.valueMgdl),
                        detail: current == null
                            ? 'Waiting for a reading'
                            : _relativeAge(current.recordedAt!, reference),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TodayTile(
                        label: '24h average',
                        value: stats.averageMgdl == null
                            ? '--'
                            : _formatGlucose(stats.averageMgdl!),
                        detail: coverage.isSufficient
                            ? '${stats.readingCount} readings'
                            : 'More context needed',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: Color(0xFF0B6E69),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _summaryText(stats, coverage),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF49615D),
                              height: 1.3,
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
        ),
        if (effectiveObservations.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          EvidenceObservationCard(
            observations: effectiveObservations,
            safetyBoundary: safetyBoundary,
          ),
        ],
        if (showBodyTimeline) ...<Widget>[
          const SizedBox(height: 10),
          BodyTimelineCard(
            readings: readings,
            context: bodyTimelineContext,
            observations: bodyTimelineObservations,
            now: reference,
            preferences: preferences,
          ),
        ],
      ],
    );
  }

  String _summaryText(GlucoseStats stats, AnalyticsCoverage coverage) {
    if (!coverage.isSufficient) {
      if (stats.readingCount == 0) {
        return 'Your day will take shape as readings arrive.';
      }
      return 'Keep collecting readings to unlock a more useful day view.';
    }
    return '${stats.timeInRangePercent.round()}% of readings are in your '
        'selected target band. Use context to explore what changed.';
  }

  String _relativeAge(DateTime recordedAt, DateTime reference) {
    final age = reference.difference(recordedAt);
    if (age.inMinutes < 1) return 'Just now';
    if (age.inHours < 1) return '${age.inMinutes} min ago';
    if (age.inDays < 1) return '${age.inHours} hr ago';
    return 'Recorded ${age.inDays} days ago';
  }
}

class _TodayTile extends StatelessWidget {
  const _TodayTile({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3EF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF5B6E6A),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF183C3B),
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF5B6E6A), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
