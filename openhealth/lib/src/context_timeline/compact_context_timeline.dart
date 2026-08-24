import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'context_timeline_models.dart';

/// A compact, opt-in rendering of source-attributed body context.
///
/// Glucose remains the main visual signal. Context is collapsed by default,
/// read-only, and supplied through [ContextTimelineSource]. This widget does
/// not query a platform, write a journal event, or infer a medical cause.
class CompactContextTimeline extends StatefulWidget {
  const CompactContextTimeline({
    super.key,
    required this.source,
    required this.now,
    this.initialRange = ContextTimelineRange.oneDay,
    this.initiallyExpanded = false,
    this.onAttachmentRequested,
    this.showHeartRate = true,
  });

  final ContextTimelineSource source;
  final DateTime now;
  final ContextTimelineRange initialRange;
  final bool initiallyExpanded;
  final ValueChanged<ContextAttachmentDraft>? onAttachmentRequested;

  /// Whether the optional heart-rate rail belongs in this visual surface.
  /// The production context route starts glucose-first and leaves it off.
  final bool showHeartRate;

  @override
  State<CompactContextTimeline> createState() => _CompactContextTimelineState();
}

class _CompactContextTimelineState extends State<CompactContextTimeline> {
  late bool _expanded = widget.initiallyExpanded;
  late ContextTimelineRange _range = widget.initialRange;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final snapshot = widget.source(
      ContextTimelineQuery(
        window: ContextTimelineWindow.endingAt(widget.now, _range),
      ),
    );
    final projection = ContextTimelineProjection.compose(
      snapshot: snapshot,
      now: widget.now,
      range: _range,
    );

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _TimelineHeader(
            expanded: _expanded,
            onToggle: () => setState(() => _expanded = !_expanded),
          ),
          if (!_expanded) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Optional context stays hidden until you choose to show it.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 16),
            if (projection.isSampleData) const _SampleDataNotice(),
            if (projection.isSampleData) const SizedBox(height: 12),
            _RangePicker(
              selected: _range,
              onSelected: (range) => setState(() => _range = range),
            ),
            const SizedBox(height: 12),
            _ContextTimelinePlot(
              projection: projection,
              showHeartRate: widget.showHeartRate,
            ),
            const SizedBox(height: 12),
            _ContextLegend(
              projection: projection,
              showHeartRate: widget.showHeartRate,
            ),
            const SizedBox(height: 12),
            _AvailabilitySummary(
              projection: projection,
              showHeartRate: widget.showHeartRate,
            ),
            if (projection.attachmentPrompt case final prompt?) ...<Widget>[
              const SizedBox(height: 12),
              _ContextAttachmentPromptCard(
                prompt: prompt,
                onAttachmentRequested: widget.onAttachmentRequested,
              ),
            ],
            if (projection.items.isNotEmpty ||
                (widget.showHeartRate &&
                    projection.heartRateSamples.isNotEmpty)) ...<Widget>[
              const SizedBox(height: 12),
              _ContextItems(
                projection: projection,
                showHeartRate: widget.showHeartRate,
              ),
            ],
          ],
        ],
      ),
    );
    return Card(
      key: const ValueKey<String>('compactContextTimeline'),
      clipBehavior: Clip.antiAlias,
      child: duration == Duration.zero
          ? content
          : AnimatedSize(
              duration: duration,
              curve: Curves.easeOut,
              child: content,
            ),
    );
  }
}

class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final needsStackedControls =
          constraints.maxWidth < 360 ||
          MediaQuery.of(context).textScaler.scale(14) > 18;
      final title = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.layers_outlined),
          const SizedBox(width: 8),
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                'Context timeline',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      );
      final toggle = TextButton.icon(
        key: const ValueKey<String>('contextTimelineToggle'),
        onPressed: onToggle,
        icon: Icon(
          expanded ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
        label: Text(expanded ? 'Hide context' : 'Show context'),
      );
      if (needsStackedControls) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title,
            Align(alignment: Alignment.centerRight, child: toggle),
          ],
        );
      }
      return Row(
        children: <Widget>[
          Expanded(child: title),
          toggle,
        ],
      );
    },
  );
}

class _RangePicker extends StatelessWidget {
  const _RangePicker({required this.selected, required this.onSelected});

  final ContextTimelineRange selected;
  final ValueChanged<ContextTimelineRange> onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Context timeline range',
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final range in ContextTimelineRange.values)
          ChoiceChip(
            key: ValueKey<String>('contextRange-${range.name}'),
            label: Text(range.label),
            selected: selected == range,
            onSelected: (_) => onSelected(range),
          ),
      ],
    ),
  );
}

class _ContextTimelinePlot extends StatelessWidget {
  const _ContextTimelinePlot({
    required this.projection,
    required this.showHeartRate,
  });

  final ContextTimelineProjection projection;
  final bool showHeartRate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semanticLabel = StringBuffer(
      'Glucose-first contextual timeline. '
      '${projection.glucoseReadings.length} glucose readings, '
      '${projection.items.where((item) => item.kind != ContextTimelineItemKind.heartRate).length} context items'
      '${showHeartRate ? ', ${projection.heartRateSamples.length} heart-rate samples' : ''}.',
    );
    if (projection.glucoseReadings.isEmpty) {
      semanticLabel.write(' No glucose readings are available in this window.');
    }
    return Semantics(
      key: const ValueKey<String>('contextTimelinePlot'),
      label: semanticLabel.toString(),
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: 1.72,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: CustomPaint(
              painter: _ContextTimelinePainter(
                projection: projection,
                colorScheme: theme.colorScheme,
                showHeartRate: showHeartRate,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextTimelinePainter extends CustomPainter {
  const _ContextTimelinePainter({
    required this.projection,
    required this.colorScheme,
    required this.showHeartRate,
  });

  final ContextTimelineProjection projection;
  final ColorScheme colorScheme;
  final bool showHeartRate;

  @override
  void paint(Canvas canvas, Size size) {
    final chartRect = Rect.fromLTWH(
      12,
      12,
      size.width - 24,
      size.height - (showHeartRate ? 42 : 24),
    );
    final heartRateRect = showHeartRate
        ? Rect.fromLTWH(chartRect.left, size.height - 22, chartRect.width, 10)
        : null;
    final grid = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var index = 1; index <= 3; index++) {
      final y = chartRect.top + chartRect.height * index / 4;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        grid,
      );
    }

    _paintIntervals(
      canvas,
      chartRect,
      ContextTimelineItemKind.sleep,
      colorScheme.tertiaryContainer.withValues(alpha: 0.56),
      0.06,
      0.42,
    );
    _paintIntervals(
      canvas,
      chartRect,
      ContextTimelineItemKind.workout,
      colorScheme.secondaryContainer.withValues(alpha: 0.72),
      0.70,
      0.92,
    );
    _paintIntervals(
      canvas,
      chartRect,
      ContextTimelineItemKind.movement,
      colorScheme.secondaryContainer.withValues(alpha: 0.42),
      0.74,
      0.89,
    );
    _paintGlucose(canvas, chartRect);
    _paintMarkers(canvas, chartRect);
    if (heartRateRect != null) _paintHeartRate(canvas, heartRateRect);
  }

  void _paintIntervals(
    Canvas canvas,
    Rect chartRect,
    ContextTimelineItemKind kind,
    Color color,
    double topFraction,
    double bottomFraction,
  ) {
    final paint = Paint()..color = color;
    for (final item in projection.items.where((item) => item.kind == kind)) {
      final start = _xFor(item.start, chartRect);
      final end = _xFor(item.end, chartRect);
      final left = math.min(start, end);
      final right = math.max(start, end);
      final rect = Rect.fromLTRB(
        left,
        chartRect.top + chartRect.height * topFraction,
        math.max(right, left + 3),
        chartRect.top + chartRect.height * bottomFraction,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        paint,
      );
    }
  }

  void _paintGlucose(Canvas canvas, Rect chartRect) {
    final readings = projection.glucoseReadings;
    if (readings.isEmpty) return;
    final values = readings.map((reading) => reading.valueMgdl).toList();
    final minValue = values.reduce(math.min).toDouble();
    final maxValue = values.reduce(math.max).toDouble();
    final paddedMin = minValue - 12;
    final paddedMax = math.max(paddedMin + 24, maxValue + 12);
    final path = Path();
    for (var index = 0; index < readings.length; index++) {
      final reading = readings[index];
      final timestamp = reading.recordedAt;
      if (timestamp == null) continue;
      final x = _xFor(timestamp, chartRect);
      final normalized =
          (reading.valueMgdl - paddedMin) / (paddedMax - paddedMin);
      final y =
          chartRect.bottom - normalized.clamp(0.0, 1.0) * chartRect.height;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colorScheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final dotPaint = Paint()..color = colorScheme.primary;
    for (final reading in readings) {
      final timestamp = reading.recordedAt;
      if (timestamp == null) continue;
      final x = _xFor(timestamp, chartRect);
      final normalized =
          (reading.valueMgdl - paddedMin) / (paddedMax - paddedMin);
      final y =
          chartRect.bottom - normalized.clamp(0.0, 1.0) * chartRect.height;
      canvas.drawCircle(Offset(x, y), 2.5, dotPaint);
    }
  }

  void _paintMarkers(Canvas canvas, Rect chartRect) {
    final markers = projection.items.where(
      (item) =>
          item.kind == ContextTimelineItemKind.meal ||
          item.kind == ContextTimelineItemKind.note,
    );
    for (final item in markers) {
      final x = _xFor(item.start, chartRect);
      final color = item.kind == ContextTimelineItemKind.meal
          ? colorScheme.error
          : colorScheme.tertiary;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(x, chartRect.top + 8),
        Offset(x, chartRect.bottom - 8),
        paint,
      );
      canvas.drawCircle(Offset(x, chartRect.top + 8), 4, paint);
    }
  }

  void _paintHeartRate(Canvas canvas, Rect rect) {
    final samples = projection.heartRateSamples;
    if (samples.isEmpty) return;
    final values = samples.map((sample) => sample.bpm).toList();
    final minValue = values.reduce(math.min);
    final maxValue = math.max(minValue + 1, values.reduce(math.max));
    final paint = Paint()..color = colorScheme.tertiary;
    for (final sample in samples) {
      final x = _xFor(sample.timestamp, rect);
      final normalized = (sample.bpm - minValue) / (maxValue - minValue);
      final y = rect.bottom - normalized.clamp(0.0, 1.0) * rect.height;
      canvas.drawCircle(Offset(x, y), 2, paint);
    }
  }

  double _xFor(DateTime timestamp, Rect rect) {
    final start = projection.window.start.millisecondsSinceEpoch;
    final end = projection.window.end.millisecondsSinceEpoch;
    if (end <= start) return rect.left;
    final fraction = (timestamp.millisecondsSinceEpoch - start) / (end - start);
    return rect.left + fraction.clamp(0.0, 1.0) * rect.width;
  }

  @override
  bool shouldRepaint(_ContextTimelinePainter oldDelegate) =>
      oldDelegate.projection != projection ||
      oldDelegate.colorScheme != colorScheme ||
      oldDelegate.showHeartRate != showHeartRate;
}

class _ContextLegend extends StatelessWidget {
  const _ContextLegend({required this.projection, required this.showHeartRate});

  final ContextTimelineProjection projection;
  final bool showHeartRate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: <Widget>[
        _LegendItem(color: theme.colorScheme.primary, label: 'Glucose'),
        _LegendItem(color: theme.colorScheme.tertiaryContainer, label: 'Sleep'),
        _LegendItem(color: theme.colorScheme.error, label: 'Meal'),
        _LegendItem(
          color: theme.colorScheme.secondaryContainer,
          label: 'Activity',
        ),
        if (showHeartRate && projection.heartRateSamples.isNotEmpty)
          _LegendItem(color: theme.colorScheme.tertiary, label: 'Heart rate'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const SizedBox(width: 10, height: 10),
      ),
      const SizedBox(width: 5),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
    ],
  );
}

class _AvailabilitySummary extends StatelessWidget {
  const _AvailabilitySummary({
    required this.projection,
    required this.showHeartRate,
  });

  final ContextTimelineProjection projection;
  final bool showHeartRate;

  @override
  Widget build(BuildContext context) {
    final unavailable = projection.laneStatuses
        .where(
          (status) =>
              status.availability != ContextDataAvailability.available &&
              (showHeartRate || status.lane != ContextTimelineLane.heartRate),
        )
        .toList(growable: false);
    if (unavailable.isEmpty) return const SizedBox.shrink();
    final semanticLabel = StringBuffer('Context availability.');
    for (final status in unavailable) {
      semanticLabel
        ..write(' ${status.lane.label}: ${status.availability.title}. ')
        ..write(status.availability.description);
      if (status.source case final source?) {
        semanticLabel.write(' Source: ${source.contextLabel}.');
      }
    }
    return Semantics(
      container: true,
      label: semanticLabel.toString(),
      child: Card(
        key: const ValueKey<String>('contextAvailabilitySummary'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Context availability',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (final status in unavailable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${status.lane.label}: ${status.availability.title}. '
                    '${status.availability.description}'
                    '${status.source == null ? '' : ' Source: ${status.source!.contextLabel}.'}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextAttachmentPromptCard extends StatelessWidget {
  const _ContextAttachmentPromptCard({
    required this.prompt,
    required this.onAttachmentRequested,
  });

  final ContextAttachmentPrompt prompt;
  final ValueChanged<ContextAttachmentDraft>? onAttachmentRequested;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label:
        'Optional context. This preview does not assess glucose patterns or identify a cause.',
    child: Card(
      key: const ValueKey<String>('contextAttachmentPrompt'),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Optional context',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            const Text(
              'You can prepare a context draft for reflection. This preview does not assess glucose patterns or identify a cause.',
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey<String>('requestContextAttachment'),
              onPressed: onAttachmentRequested == null
                  ? null
                  : () => _showAttachmentSheet(
                      context,
                      prompt,
                      onAttachmentRequested!,
                    ),
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('Add context'),
            ),
            if (onAttachmentRequested == null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Attachment capture is not configured in this preview.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    ),
  );

  static Future<void> _showAttachmentSheet(
    BuildContext context,
    ContextAttachmentPrompt prompt,
    ValueChanged<ContextAttachmentDraft> onAttachmentRequested,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                'Create an unsaved context draft',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose a draft type. Nothing is saved by this preview.',
            ),
            const SizedBox(height: 12),
            for (final kind in ContextAttachmentKind.values)
              ListTile(
                key: ValueKey<String>('attachmentDraft-${kind.name}'),
                leading: Icon(_attachmentIcon(kind)),
                title: Text(kind.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onAttachmentRequested(
                    ContextAttachmentDraft(prompt: prompt, kind: kind),
                  );
                },
              ),
          ],
        ),
      ),
    ),
  );

  static IconData _attachmentIcon(ContextAttachmentKind kind) => switch (kind) {
    ContextAttachmentKind.meal => Icons.restaurant_outlined,
    ContextAttachmentKind.activity => Icons.directions_run_outlined,
    ContextAttachmentKind.note => Icons.sticky_note_2_outlined,
  };
}

class _ContextItems extends StatelessWidget {
  const _ContextItems({required this.projection, required this.showHeartRate});

  final ContextTimelineProjection projection;
  final bool showHeartRate;

  @override
  Widget build(BuildContext context) {
    final visibleItems = projection.items
        .where((item) => item.kind != ContextTimelineItemKind.heartRate)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Context details',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        if (visibleItems.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final item in visibleItems)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: _ContextItemButton(item: item),
                  ),
              ],
            ),
          ),
        if (showHeartRate &&
            projection.heartRateSamples.isNotEmpty) ...<Widget>[
          if (visibleItems.isNotEmpty) const SizedBox(height: 8),
          _HeartRateSummaryButton(projection: projection),
        ],
      ],
    );
  }
}

class _ContextItemButton extends StatelessWidget {
  const _ContextItemButton({required this.item});

  final ContextTimelineItem item;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: ValueKey<String>('contextItem-${item.id}'),
    onPressed: () => _showItemDetails(context, item),
    icon: Icon(_iconFor(item.kind), size: 18),
    label: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
  );

  static IconData _iconFor(ContextTimelineItemKind kind) => switch (kind) {
    ContextTimelineItemKind.meal => Icons.restaurant_outlined,
    ContextTimelineItemKind.note => Icons.sticky_note_2_outlined,
    ContextTimelineItemKind.workout => Icons.fitness_center_outlined,
    ContextTimelineItemKind.movement => Icons.directions_walk_outlined,
    ContextTimelineItemKind.sleep => Icons.bedtime_outlined,
    ContextTimelineItemKind.heartRate => Icons.monitor_heart_outlined,
  };

  static Future<void> _showItemDetails(
    BuildContext context,
    ContextTimelineItem item,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                item.title,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 8),
            Text(item.detail),
            const SizedBox(height: 8),
            Text('Exact window: ${_formatWindow(item.start, item.end)}'),
            Text('Source: ${item.source.contextLabel}'),
            Text('Qualification: ${item.qualification.title}'),
            const SizedBox(height: 8),
            Text(item.qualification.description),
            const SizedBox(height: 8),
            const Text(
              'Context can support reflection. It does not prove a cause or medical meaning.',
            ),
          ],
        ),
      ),
    ),
  );
}

class _HeartRateSummaryButton extends StatelessWidget {
  const _HeartRateSummaryButton({required this.projection});

  final ContextTimelineProjection projection;

  @override
  Widget build(BuildContext context) {
    final samples = projection.heartRateSamples;
    final status = projection.statusFor(ContextTimelineLane.heartRate);
    return OutlinedButton.icon(
      key: const ValueKey<String>('heartRateSummary'),
      onPressed: () => _showDetails(context, samples, status),
      icon: const Icon(Icons.monitor_heart_outlined, size: 18),
      label: Text('Heart rate (${samples.length})'),
    );
  }

  static Future<void> _showDetails(
    BuildContext context,
    List<HeartRateSample> samples,
    ContextTimelineLaneStatus status,
  ) {
    final sources =
        <DataSource>{
          for (final sample in samples) sample.source,
        }.toList(growable: false)..sort(
          (left, right) => left.contextLabel.compareTo(right.contextLabel),
        );
    final sourceLabel = sources.map((source) => source.contextLabel).join(', ');
    final latest = samples.last;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Heart rate rail',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${samples.length} samples. Latest ${latest.bpm.round()} bpm.',
              ),
              const SizedBox(height: 8),
              Text(
                'Exact window: '
                '${_formatWindow(samples.first.timestamp, latest.timestamp)}',
              ),
              Text(
                sources.length == 1
                    ? 'Source: $sourceLabel'
                    : 'Sources: $sourceLabel',
              ),
              Text('Qualification: ${status.availability.title}'),
              const SizedBox(height: 8),
              Text(status.availability.description),
              const SizedBox(height: 8),
              const Text(
                'Context can support reflection. It does not prove a cause or medical meaning.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SampleDataNotice extends StatelessWidget {
  const _SampleDataNotice();

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Sample data, not from a sensor',
    child: ColoredBox(
      color: const Color(0xFFFFE8A3),
      child: const Padding(
        padding: EdgeInsets.all(10),
        child: Text(
          'SAMPLE DATA — NOT FROM A SENSOR',
          style: TextStyle(
            color: Color(0xFF6B4300),
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    ),
  );
}

String _formatWindow(DateTime start, DateTime end) {
  final format = DateFormat('d MMM, HH:mm');
  final startText = format.format(start.toLocal());
  final endText = format.format(end.toLocal());
  return start == end ? startText : '$startText – $endText';
}
