import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

/// Compact rendering of deterministic, evidence-backed observations.
///
/// This widget is presentation-only: it receives already-computed local
/// observations and never calls a provider or starts network work. Evidence is
/// shown as bounded aggregates so users can see what supports each statement.
class EvidenceObservationCard extends StatelessWidget {
  const EvidenceObservationCard({
    super.key,
    required this.observations,
    this.safetyBoundary = AiDisclaimer.short,
    this.maxObservations = 3,
  });

  final List<MetabolicObservation> observations;
  final String safetyBoundary;
  final int maxObservations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = observations
        .where((observation) => observation.isEvidenceBacked)
        .take(maxObservations < 1 ? 1 : maxObservations)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    return Card(
      key: const ValueKey<String>('evidenceObservationCard'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.auto_graph_rounded, color: Color(0xFF0B6E69)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'What your data shows',
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
            const SizedBox(height: 10),
            for (var index = 0; index < visible.length; index++) ...<Widget>[
              if (index > 0) const Divider(height: 18),
              _ObservationRow(observation: visible[index]),
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
                        safetyBoundary,
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
}

class _ObservationRow extends StatelessWidget {
  const _ObservationRow({required this.observation});

  final MetabolicObservation observation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final evidence = observation.evidence.take(2).toList(growable: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          _iconFor(observation.kind),
          size: 20,
          color: const Color(0xFF0B6E69),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                observation.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF183C3B),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                observation.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF49615D),
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: evidence
                    .map((item) => _EvidenceChip(evidence: item))
                    .toList(growable: false),
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _iconFor(ObservationKind kind) {
    return switch (kind) {
      ObservationKind.coverage => Icons.timeline_rounded,
      ObservationKind.glucoseLevel => Icons.water_drop_outlined,
      ObservationKind.glucoseRange => Icons.straighten_rounded,
      ObservationKind.variability => Icons.multiline_chart_rounded,
      ObservationKind.spike => Icons.trending_up_rounded,
      ObservationKind.mealContext => Icons.restaurant_outlined,
      ObservationKind.activityContext => Icons.directions_run_rounded,
      ObservationKind.sleepContext => Icons.bedtime_outlined,
      ObservationKind.heartRateContext => Icons.favorite_border_rounded,
    };
  }
}

class _EvidenceChip extends StatelessWidget {
  const _EvidenceChip({required this.evidence});

  final ObservationEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final value = evidence.value == null
        ? 'n/a'
        : evidence.value!.toStringAsFixed(evidence.unit == '%' ? 1 : 0);
    final unit = evidence.unit == null ? '' : ' ${evidence.unit}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3EF),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '$value$unit · ${evidence.sampleCount} samples',
          style: const TextStyle(
            color: Color(0xFF49615D),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
