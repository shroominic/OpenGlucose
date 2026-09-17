import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'body_timeline_context.dart';
import 'display_preferences.dart';

/// Renderable categories in the local body timeline.
enum BodyTimelineItemKind {
  glucose,
  event,
  activity,
  sleep,
  heartRate,
  observation,
}

/// A presentation-safe row assembled from local timeline contracts.
class BodyTimelineItem {
  const BodyTimelineItem({
    required this.timestamp,
    required this.kind,
    required this.title,
    required this.detail,
    required this.sourceLabel,
    required this.freshnessLabel,
    this.glucoseMgdl,
    this.observation,
  });

  final DateTime timestamp;
  final BodyTimelineItemKind kind;
  final String title;
  final String detail;
  final String sourceLabel;
  final String freshnessLabel;
  final double? glucoseMgdl;
  final MetabolicObservation? observation;
}

/// Deterministically combines glucose, journal, imported context, and
/// evidence-backed observations without making clinical or causal claims.
abstract final class BodyTimeline {
  static List<BodyTimelineItem> buildItems({
    required List<CgmReading> readings,
    JournalContext? context,
    List<MetabolicObservation> observations = const <MetabolicObservation>[],
    DateTime? now,
    int maxItems = 8,
  }) {
    final reference = (now ?? DateTime.now()).toUtc();
    final items = <BodyTimelineItem>[];
    for (final reading in readings) {
      final timestamp = reading.recordedAt?.toUtc();
      if (timestamp == null) continue;
      items.add(
        BodyTimelineItem(
          timestamp: timestamp,
          kind: BodyTimelineItemKind.glucose,
          title: 'Glucose',
          detail: '',
          sourceLabel: 'Sensor',
          freshnessLabel: _freshnessLabel(timestamp, reference),
          glucoseMgdl: reading.valueMgdl,
        ),
      );
    }
    if (context != null) {
      for (final entry in context.timeline) {
        final item = _itemForEntry(entry, reference);
        if (item != null) items.add(item);
      }
    }
    for (final observation in observations) {
      if (!observation.isEvidenceBacked) continue;
      final timestamp = observation.windowEnd.toUtc();
      items.add(
        BodyTimelineItem(
          timestamp: timestamp,
          kind: BodyTimelineItemKind.observation,
          title: observation.title,
          detail: observation.summary,
          sourceLabel: 'Local evidence',
          freshnessLabel: _freshnessLabel(timestamp, reference),
          observation: observation,
        ),
      );
    }
    final indexed = items.asMap().entries.toList(growable: false)
      ..sort((left, right) {
        final byTime = right.value.timestamp.compareTo(left.value.timestamp);
        return byTime == 0 ? left.key.compareTo(right.key) : byTime;
      });
    final ordered = indexed.map((entry) => entry.value);
    final limit = maxItems < 1 ? 1 : maxItems;
    return ordered.take(limit).toList(growable: false);
  }

  static BodyTimelineItem? _itemForEntry(
    TimelineEntry entry,
    DateTime reference,
  ) {
    final timestamp = entry.timelineTimestamp.toUtc();
    return switch (entry) {
      final HealthEvent event => BodyTimelineItem(
        timestamp: timestamp,
        kind: BodyTimelineItemKind.event,
        title: _eventTitle(event),
        detail: _eventDetail(event),
        sourceLabel: _dataSourceLabel(event.source),
        freshnessLabel: _freshnessLabel(timestamp, reference),
      ),
      final ActivitySample activity => BodyTimelineItem(
        timestamp: timestamp,
        kind: BodyTimelineItemKind.activity,
        title: _activityTitle(activity),
        detail: _activityDetail(activity),
        sourceLabel: _dataSourceLabel(activity.source),
        freshnessLabel: _freshnessLabel(timestamp, reference),
      ),
      final SleepSample sleep => BodyTimelineItem(
        timestamp: timestamp,
        kind: BodyTimelineItemKind.sleep,
        title: 'Sleep',
        detail:
            '${_titleCase(sleep.stage.name)} · ${_durationLabel(sleep.duration)}',
        sourceLabel: _dataSourceLabel(sleep.source),
        freshnessLabel: _freshnessLabel(timestamp, reference),
      ),
      final HeartRateSample heartRate => BodyTimelineItem(
        timestamp: timestamp,
        kind: BodyTimelineItemKind.heartRate,
        title: 'Heart rate',
        detail: '${heartRate.bpm.toStringAsFixed(0)} bpm',
        sourceLabel: _dataSourceLabel(heartRate.source),
        freshnessLabel: _freshnessLabel(timestamp, reference),
      ),
      _ => null,
    };
  }

  static String _eventTitle(HealthEvent event) => switch (event.type) {
    HealthEventType.meal => 'Meal',
    HealthEventType.exercise => 'Exercise',
    HealthEventType.note => 'Note',
    HealthEventType.insulin => 'Medication',
    HealthEventType.medication => 'Medication',
    HealthEventType.custom => 'Journal entry',
  };

  static String _eventDetail(HealthEvent event) => switch (event.payload) {
    MealPayload(:final description?) when description.trim().isNotEmpty =>
      description.trim(),
    MealPayload(:final carbsGrams?) =>
      '${carbsGrams.toStringAsFixed(0)} g carbs',
    ExercisePayload(:final activity?) when activity.trim().isNotEmpty =>
      activity.trim(),
    ExercisePayload(:final duration?) => _durationLabel(duration),
    NotePayload(:final text) => text.trim(),
    DosePayload(:final name?) when name.trim().isNotEmpty => name.trim(),
    _ => 'Logged locally',
  };

  static String _activityTitle(ActivitySample activity) =>
      switch (activity.type) {
        ActivityType.steps => 'Steps',
        ActivityType.workout =>
          activity.workoutLabel?.trim().isNotEmpty == true
              ? activity.workoutLabel!.trim()
              : 'Workout',
        ActivityType.distance => 'Walking distance',
        ActivityType.activeEnergy => 'Active energy',
        ActivityType.other => 'Activity',
      };

  static String _activityDetail(ActivitySample activity) {
    if (activity.steps != null) return '${activity.steps} steps';
    if (activity.energyKcal != null) {
      return '${activity.energyKcal!.toStringAsFixed(0)} kcal';
    }
    if (activity.distanceMeters != null) {
      final meters = activity.distanceMeters!;
      return meters >= 1000
          ? '${(meters / 1000).toStringAsFixed(1)} km'
          : '${meters.toStringAsFixed(0)} m';
    }
    return _durationLabel(activity.duration);
  }

  static String _dataSourceLabel(DataSource source) => switch (source) {
    DataSource.appleHealth => 'Apple Health',
    DataSource.healthConnect => 'Health Connect',
    DataSource.manual => 'Manual',
  };

  static String _durationLabel(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inMinutes} min';
  }

  static String _titleCase(String value) {
    if (value.isEmpty) return value;
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }

  static String _freshnessLabel(DateTime timestamp, DateTime reference) {
    final delta = reference.difference(timestamp);
    if (delta.isNegative) {
      final future = timestamp.difference(reference);
      if (future.inMinutes < 1) return 'soon';
      return 'in ${future.inMinutes} min';
    }
    if (delta.inMinutes < 1) return 'now';
    if (delta.inHours < 1) return '${delta.inMinutes} min ago';
    if (delta.inDays < 1) return '${delta.inHours} hr ago';
    return '${delta.inDays} days ago';
  }
}

/// Compact local-only rendering for Today and future timeline screens.
class BodyTimelineCard extends StatelessWidget {
  const BodyTimelineCard({
    super.key,
    required this.readings,
    this.context,
    this.observations = const <MetabolicObservation>[],
    this.now,
    this.preferences = const DisplayPreferences(),
    this.maxItems = 8,
    this.contextStatus = BodyTimelineContextStatus.ready,
    this.contextError,
  });

  final List<CgmReading> readings;
  final JournalContext? context;
  final List<MetabolicObservation> observations;
  final DateTime? now;
  final DisplayPreferences preferences;
  final int maxItems;
  final BodyTimelineContextStatus contextStatus;
  final String? contextError;

  @override
  Widget build(BuildContext context) {
    final items = BodyTimeline.buildItems(
      readings: readings,
      context: this.context,
      observations: observations,
      now: now,
      maxItems: maxItems,
    );
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey<String>('bodyTimelineCard'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.timeline_rounded, color: Color(0xFF0B6E69)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Body timeline',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Text(
                  'Local',
                  style: TextStyle(
                    color: Color(0xFF5B6E6A),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Glucose, journal, and body context in time order. Sources and '
              'freshness stay visible.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 10),
            if (contextStatus != BodyTimelineContextStatus.ready) ...<Widget>[
              _ContextStatusMessage(status: contextStatus, error: contextError),
              const SizedBox(height: 10),
            ],
            if (items.isEmpty &&
                (contextStatus == BodyTimelineContextStatus.empty ||
                    contextStatus == BodyTimelineContextStatus.ready))
              const Text(
                'No body context yet. Add a meal, exercise, or note, or sync '
                'health context.',
                style: TextStyle(color: Color(0xFF5B6E6A)),
              )
            else
              for (var index = 0; index < items.length; index++) ...<Widget>[
                if (index > 0) const Divider(height: 16),
                _BodyTimelineRow(item: items[index], preferences: preferences),
              ],
            const SizedBox(height: 10),
            const Text(
              'Local wellness context—not medical advice.',
              style: TextStyle(color: Color(0xFF5B6E6A), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextStatusMessage extends StatelessWidget {
  const _ContextStatusMessage({required this.status, this.error});

  final BodyTimelineContextStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String message) = switch (status) {
      BodyTimelineContextStatus.idle => (
        Icons.sync_outlined,
        'Local context will appear after the first foreground refresh.',
      ),
      BodyTimelineContextStatus.loading => (
        Icons.hourglass_top_rounded,
        'Loading local context…',
      ),
      BodyTimelineContextStatus.empty => (
        Icons.insights_outlined,
        'No activity, sleep, heart-rate, or journal context for today yet.',
      ),
      BodyTimelineContextStatus.error => (
        Icons.warning_amber_rounded,
        error ?? 'Local context is unavailable right now. Try again.',
      ),
      BodyTimelineContextStatus.ready => (Icons.check_rounded, ''),
    };
    if (message.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: status == BodyTimelineContextStatus.error
            ? const Color(0xFFFFF3E8)
            : const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              icon,
              size: 18,
              color: status == BodyTimelineContextStatus.error
                  ? const Color(0xFF9A4D00)
                  : const Color(0xFF0B6E69),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFF49615D)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BodyTimelineRow extends StatelessWidget {
  const _BodyTimelineRow({required this.item, required this.preferences});

  final BodyTimelineItem item;
  final DisplayPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final detail = item.glucoseMgdl == null
        ? item.detail
        : _formatGlucose(item.glucoseMgdl!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(_iconFor(item.kind), size: 19, color: const Color(0xFF0B6E69)),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.title,
                style: const TextStyle(
                  color: Color(0xFF183C3B),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF49615D)),
              ),
              const SizedBox(height: 4),
              Text(
                '${item.sourceLabel} · ${item.freshnessLabel}',
                style: const TextStyle(color: Color(0xFF5B6E6A), fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatGlucose(double valueMgdl) {
    final value = preferences.unit.convertFromMgdl(valueMgdl);
    final digits = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${preferences.unit.label}';
  }

  IconData _iconFor(BodyTimelineItemKind kind) => switch (kind) {
    BodyTimelineItemKind.glucose => Icons.water_drop_outlined,
    BodyTimelineItemKind.event => Icons.edit_note_rounded,
    BodyTimelineItemKind.activity => Icons.directions_run_rounded,
    BodyTimelineItemKind.sleep => Icons.bedtime_outlined,
    BodyTimelineItemKind.heartRate => Icons.favorite_border_rounded,
    BodyTimelineItemKind.observation => Icons.auto_graph_rounded,
  };
}
