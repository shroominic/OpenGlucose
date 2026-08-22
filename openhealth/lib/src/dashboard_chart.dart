import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'display_preferences.dart';

class CgmDashboardChart extends StatefulWidget {
  const CgmDashboardChart({
    super.key,
    required this.readings,
    required this.preferences,
    required this.historySync,
  });

  final List<CgmReading> readings;
  final DisplayPreferences preferences;
  final CgmHistorySyncState historySync;

  @override
  State<CgmDashboardChart> createState() => _CgmDashboardChartState();
}

class _CgmDashboardChartState extends State<CgmDashboardChart> {
  static const List<_ChartTimeframe> _timeframeOptions = <_ChartTimeframe>[
    _ChartTimeframe(label: '3h', minutes: 180),
    _ChartTimeframe(label: '12h', minutes: 720),
    _ChartTimeframe(label: '1d', minutes: 1440),
    _ChartTimeframe(label: '3d', minutes: 4320),
    _ChartTimeframe(label: '7d', minutes: 10080),
    _ChartTimeframe(label: 'ALL', minutes: 0),
  ];

  int _selectedTimeframeMinutes = 720;
  int? _selectedPointId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final samples = _buildSamples(widget.readings);
    final timeframes = _visibleTimeframes(samples);
    final effectiveTimeframe = _effectiveTimeframeMinutes(timeframes);
    final loading = samples.isEmpty && widget.historySync.inProgress;

    return LayoutBuilder(
      builder: (context, constraints) {
        final plotted = _buildPlottedPoints(
          samples,
          timeframeMinutes: effectiveTimeframe,
          maxWidth: constraints.maxWidth,
        );
        final hasTimeframeControls = timeframes.length > 1;
        final overlayInsetTop = hasTimeframeControls ? 42.0 : 0.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: loading
                        ? const _LoadingChart()
                        : _InteractiveHistoryChart(
                            points: plotted,
                            preferences: widget.preferences,
                            timeframeMinutes: effectiveTimeframe,
                            chartStyle: widget.preferences.chartStyle,
                            selectedPointId: _selectedPointId,
                            overlayInsetTop: overlayInsetTop,
                            onSelectPoint: _handleSelection,
                            onClearSelection: _clearSelection,
                          ),
                  ),
                  if (hasTimeframeControls)
                    Positioned(
                      top: 10,
                      left: 10,
                      right: 10,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: timeframes
                              .map((timeframe) {
                                final selected =
                                    timeframe.minutes == effectiveTimeframe;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      setState(() {
                                        _selectedTimeframeMinutes =
                                            timeframe.minutes;
                                        _selectedPointId = null;
                                      });
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 160,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? const Color(0xFF113437)
                                            : Colors.white.withValues(
                                                alpha: 0.78,
                                              ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        timeframe.label,
                                        style: theme.textTheme.labelLarge
                                            ?.copyWith(
                                              color: selected
                                                  ? Colors.white
                                                  : const Color(0xFF5C6E69),
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                  ),
                                );
                              })
                              .toList(growable: false),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleSelection(_PlottedPoint? point) async {
    final nextId = point?.id;
    if (_selectedPointId == nextId) {
      return;
    }
    setState(() {
      _selectedPointId = nextId;
    });
    if (nextId != null) {
      await HapticFeedback.selectionClick();
    }
  }

  void _clearSelection() {
    if (_selectedPointId == null) {
      return;
    }
    setState(() {
      _selectedPointId = null;
    });
  }

  List<_ReadingSample> _buildSamples(List<CgmReading> readings) {
    final samples = <_ReadingSample>[];
    var fallbackMinute = 0;
    for (final reading in readings) {
      final minute = reading.sensorMinute ?? fallbackMinute;
      fallbackMinute = minute + 1;
      samples.add(
        _ReadingSample(
          reading: reading,
          minute: minute,
          recordedAt: reading.recordedAt,
          value: reading.displayValue(widget.preferences),
        ),
      );
    }
    return samples;
  }

  List<_ChartTimeframe> _visibleTimeframes(List<_ReadingSample> samples) {
    if (samples.length < 2) {
      return const <_ChartTimeframe>[];
    }
    final span = samples.last.minute - samples.first.minute;
    if (span < 180) {
      return const <_ChartTimeframe>[];
    }
    return _timeframeOptions
        .where(
          (timeframe) => timeframe.minutes == 0 || timeframe.minutes <= span,
        )
        .toList(growable: false);
  }

  int _effectiveTimeframeMinutes(List<_ChartTimeframe> timeframes) {
    if (timeframes.isEmpty) {
      return 0;
    }
    if (timeframes.any(
      (timeframe) => timeframe.minutes == _selectedTimeframeMinutes,
    )) {
      return _selectedTimeframeMinutes;
    }
    if (timeframes.last.minutes == 0 && timeframes.length > 1) {
      return timeframes[timeframes.length - 2].minutes;
    }
    return timeframes.last.minutes;
  }

  List<_PlottedPoint> _buildPlottedPoints(
    List<_ReadingSample> samples, {
    required int timeframeMinutes,
    required double maxWidth,
  }) {
    if (samples.isEmpty) {
      return const <_PlottedPoint>[];
    }
    final latestMinute = samples.last.minute;
    final visibleSamples = timeframeMinutes == 0
        ? samples
        : samples
              .where(
                (sample) => sample.minute >= latestMinute - timeframeMinutes,
              )
              .toList(growable: false);
    if (visibleSamples.isEmpty) {
      return const <_PlottedPoint>[];
    }
    final targetPoints = _targetPointCount(
      timeframeMinutes: timeframeMinutes,
      width: maxWidth,
    );
    if (visibleSamples.length <= targetPoints) {
      return visibleSamples
          .map(
            (sample) => _PlottedPoint(
              id: sample.minute,
              minute: sample.minute,
              recordedAt: sample.recordedAt,
              value: sample.value,
              low: sample.value,
              high: sample.value,
              sampleCount: 1,
            ),
          )
          .toList(growable: false);
    }

    final bucketSize = (visibleSamples.length / targetPoints).ceil();
    final points = <_PlottedPoint>[];
    for (var start = 0; start < visibleSamples.length; start += bucketSize) {
      final end = math.min(start + bucketSize, visibleSamples.length);
      final bucket = visibleSamples.sublist(start, end);
      final anchor = bucket[bucket.length ~/ 2];
      final values = bucket
          .map((sample) => sample.value)
          .toList(growable: false);
      final total = values.fold<double>(0, (sum, value) => sum + value);
      points.add(
        _PlottedPoint(
          id: anchor.minute,
          minute: anchor.minute,
          recordedAt: anchor.recordedAt,
          value: total / values.length,
          low: values.reduce(math.min),
          high: values.reduce(math.max),
          sampleCount: bucket.length,
        ),
      );
    }
    return points;
  }

  int _targetPointCount({
    required int timeframeMinutes,
    required double width,
  }) {
    final widthDriven = math.max(48, (width / 3.2).round());
    return switch (timeframeMinutes) {
      0 => math.min(widthDriven, 96),
      <= 180 => math.min(widthDriven, 180),
      <= 720 => math.min(widthDriven, 160),
      <= 1440 => math.min(widthDriven, 140),
      _ => math.min(widthDriven, 96),
    };
  }
}

class _InteractiveHistoryChart extends StatelessWidget {
  const _InteractiveHistoryChart({
    required this.points,
    required this.preferences,
    required this.timeframeMinutes,
    required this.chartStyle,
    required this.selectedPointId,
    required this.overlayInsetTop,
    required this.onSelectPoint,
    required this.onClearSelection,
  });

  final List<_PlottedPoint> points;
  final DisplayPreferences preferences;
  final int timeframeMinutes;
  final ChartStyle chartStyle;
  final int? selectedPointId;
  final double overlayInsetTop;
  final ValueChanged<_PlottedPoint?> onSelectPoint;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final plotRect = _plotRect(size, overlayInsetTop: overlayInsetTop);
        final selectedPoint = _selectedPoint();
        final selectedOffset = selectedPoint == null
            ? null
            : Offset(
                _xForMinute(
                  selectedPoint.minute,
                  plotRect,
                  points.firstOrNull?.minute ?? 0,
                  points.lastOrNull?.minute ?? 0,
                ),
                _yForValue(
                  selectedPoint.value,
                  plotRect,
                  _chartMin(),
                  _chartMax(),
                ),
              );

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) =>
              onSelectPoint(_nearestPoint(event.localPosition, size)),
          onPointerMove: (event) =>
              onSelectPoint(_nearestPoint(event.localPosition, size)),
          onPointerUp: (_) => onClearSelection(),
          onPointerCancel: (_) => onClearSelection(),
          child: Stack(
            children: <Widget>[
              CustomPaint(
                painter: _DashboardChartPainter(
                  points: points,
                  preferences: preferences,
                  theme: Theme.of(context),
                  timeframeMinutes: timeframeMinutes,
                  selectedPointId: selectedPointId,
                  chartStyle: chartStyle,
                  overlayInsetTop: overlayInsetTop,
                ),
                child: const SizedBox.expand(),
              ),
              if (selectedPoint != null && selectedOffset != null)
                Positioned(
                  top: overlayInsetTop + 6,
                  left: math.max(
                    8,
                    math.min(size.width - 164, selectedOffset.dx - 72),
                  ),
                  child: _SelectionTooltip(
                    point: selectedPoint,
                    preferences: preferences,
                    timeframeMinutes: timeframeMinutes,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  _PlottedPoint? _selectedPoint() {
    for (final point in points) {
      if (point.id == selectedPointId) {
        return point;
      }
    }
    return null;
  }

  double _chartMin() {
    if (points.isEmpty) {
      return preferences.unit == GlucoseUnit.mgdl ? 60 : (60 / 18);
    }
    final bandLow = preferences.unit.convertFromMgdl(preferences.targetLowMgdl);
    final minValue = points.map((point) => point.low).reduce(math.min);
    final padding = preferences.unit == GlucoseUnit.mgdl ? 10.0 : 0.8;
    return math.min(minValue, bandLow) - padding;
  }

  double _chartMax() {
    if (points.isEmpty) {
      return preferences.unit == GlucoseUnit.mgdl ? 140 : (140 / 18);
    }
    final bandHigh = preferences.unit.convertFromMgdl(
      preferences.targetHighMgdl,
    );
    final maxValue = points.map((point) => point.high).reduce(math.max);
    final padding = preferences.unit == GlucoseUnit.mgdl ? 10.0 : 0.8;
    return math.max(maxValue, bandHigh) + padding;
  }

  _PlottedPoint? _nearestPoint(Offset location, Size size) {
    if (points.isEmpty) {
      return null;
    }
    if (location.dy < 0 || location.dy > size.height) {
      return null;
    }
    final plotRect = _plotRect(size, overlayInsetTop: overlayInsetTop);
    final clampedX = location.dx
        .clamp(plotRect.left, plotRect.right)
        .toDouble();
    final minMinute = points.first.minute;
    final maxMinute = points.last.minute;
    _PlottedPoint? nearest;
    var bestDistance = double.infinity;
    for (final point in points) {
      final x = _xForMinute(point.minute, plotRect, minMinute, maxMinute);
      final distance = (x - clampedX).abs();
      if (distance < bestDistance) {
        nearest = point;
        bestDistance = distance;
      }
    }
    return nearest;
  }
}

class _SelectionTooltip extends StatelessWidget {
  const _SelectionTooltip({
    required this.point,
    required this.preferences,
    required this.timeframeMinutes,
  });

  final _PlottedPoint point;
  final DisplayPreferences preferences;
  final int timeframeMinutes;

  @override
  Widget build(BuildContext context) {
    final valueText =
        '${point.value.toStringAsFixed(preferences.unit == GlucoseUnit.mgdl ? 0 : 1)} ${preferences.unit.label}';
    final timeText = switch ((
      point.recordedAt,
      timeframeMinutes > 1440 || timeframeMinutes == 0,
    )) {
      (final DateTime recordedAt?, true) => DateFormat(
        'MMM d, HH:mm',
      ).format(recordedAt.toLocal()),
      (final DateTime recordedAt?, false) => DateFormat(
        'HH:mm',
      ).format(recordedAt.toLocal()),
      _ => 'Minute ${point.minute}',
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 156),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF121A1A).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                valueText,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                timeText,
                style: const TextStyle(color: Color(0xFFD4E4DE), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingChart extends StatelessWidget {
  const _LoadingChart();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFFF4FBF8), Color(0xFFE8F2EF)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0E7E2)),
      ),
      child: const Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }
}

class _DashboardChartPainter extends CustomPainter {
  _DashboardChartPainter({
    required this.points,
    required this.preferences,
    required this.theme,
    required this.timeframeMinutes,
    required this.selectedPointId,
    required this.chartStyle,
    required this.overlayInsetTop,
  });

  final List<_PlottedPoint> points;
  final DisplayPreferences preferences;
  final ThemeData theme;
  final int timeframeMinutes;
  final int? selectedPointId;
  final ChartStyle chartStyle;
  final double overlayInsetTop;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFFF4FBF8), Color(0xFFE8F2EF)],
      ).createShader(Offset.zero & size);
    final outline = Paint()
      ..color = const Color(0xFFE0E7E2)
      ..style = PaintingStyle.stroke;
    final chartRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(20),
    );
    canvas.drawRRect(chartRect, backgroundPaint);
    canvas.drawRRect(chartRect, outline);

    if (points.isEmpty) {
      return;
    }

    final plotRect = _plotRect(size, overlayInsetTop: overlayInsetTop);
    final minMinute = points.first.minute;
    final maxMinute = points.last.minute;
    final bandLow = preferences.unit.convertFromMgdl(preferences.targetLowMgdl);
    final bandHigh = preferences.unit.convertFromMgdl(
      preferences.targetHighMgdl,
    );
    final minValue = points.map((point) => point.low).reduce(math.min);
    final maxValue = points.map((point) => point.high).reduce(math.max);
    final padding = preferences.unit == GlucoseUnit.mgdl ? 10.0 : 0.8;
    final chartMin = math.min(minValue, bandLow) - padding;
    final chartMax = math.max(maxValue, bandHigh) + padding;

    final bandTop = _yForValue(bandHigh, plotRect, chartMin, chartMax);
    final bandBottom = _yForValue(bandLow, plotRect, chartMin, chartMax);
    final bandPaint = Paint()..color = const Color(0x1725A66C);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(plotRect.left, bandTop, plotRect.right, bandBottom),
        const Radius.circular(16),
      ),
      bandPaint,
    );

    final gridPaint = Paint()
      ..color = const Color(0xFFD8E3DE)
      ..strokeWidth = 1;
    final labelStyle =
        theme.textTheme.labelSmall?.copyWith(color: const Color(0xFF63746F)) ??
        const TextStyle(color: Color(0xFF63746F));

    for (var step = 0; step < 4; step++) {
      final value = chartMin + ((chartMax - chartMin) * (step / 3));
      final y = _yForValue(value, plotRect, chartMin, chartMax);
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
      _paintText(
        canvas,
        Offset(4, y - 8),
        preferences.unit == GlucoseUnit.mgdl
            ? value.toStringAsFixed(0)
            : value.toStringAsFixed(1),
        labelStyle,
      );
    }

    final chartPoints = points
        .map(
          (point) => Offset(
            _xForMinute(point.minute, plotRect, minMinute, maxMinute),
            _yForValue(point.value, plotRect, chartMin, chartMax),
          ),
        )
        .toList(growable: false);
    final effectiveStyle = chartStyle == ChartStyle.dots && points.length > 120
        ? ChartStyle.line
        : chartStyle;

    if (effectiveStyle != ChartStyle.candles) {
      final linePath = Path();
      for (var index = 0; index < chartPoints.length; index++) {
        final point = chartPoints[index];
        if (index == 0) {
          linePath.moveTo(point.dx, point.dy);
        } else {
          linePath.lineTo(point.dx, point.dy);
        }
      }
      final fillPath = Path.from(linePath)
        ..lineTo(plotRect.right, plotRect.bottom)
        ..lineTo(plotRect.left, plotRect.bottom)
        ..close();
      final fillPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x443BAE97), Color(0x00FFFFFF)],
        ).createShader(plotRect);
      canvas.drawPath(fillPath, fillPaint);

      final linePaint = Paint()
        ..color = const Color(0xFF177E73)
        ..strokeWidth = effectiveStyle == ChartStyle.dots ? 2.0 : 3.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(linePath, linePaint);
    }

    final pointPaint = Paint()..isAntiAlias = true;
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final offset = chartPoints[index];
      pointPaint.color = point.value < bandLow
          ? const Color(0xFFF48C6A)
          : point.value > bandHigh
          ? const Color(0xFFE9A23B)
          : const Color(0xFF177E73);

      if (point.sampleCount > 1) {
        final lowY = _yForValue(point.low, plotRect, chartMin, chartMax);
        final highY = _yForValue(point.high, plotRect, chartMin, chartMax);
        canvas.drawLine(
          Offset(offset.dx, lowY),
          Offset(offset.dx, highY),
          Paint()
            ..color = pointPaint.color.withValues(alpha: 0.24)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }

      if (effectiveStyle == ChartStyle.candles) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: offset,
              width: 6,
              height: math.max(10, plotRect.bottom - offset.dy),
            ),
            const Radius.circular(4),
          ),
          pointPaint..color = pointPaint.color.withValues(alpha: 0.5),
        );
      } else if (points.length <= 120) {
        canvas.drawCircle(
          offset,
          effectiveStyle == ChartStyle.dots ? 3.4 : 2.6,
          pointPaint,
        );
      }
    }

    if (selectedPointId != null) {
      final selectedIndex = points.indexWhere(
        (point) => point.id == selectedPointId,
      );
      if (selectedIndex >= 0) {
        final selected = chartPoints[selectedIndex];
        final selectedPoint = points[selectedIndex];
        canvas.drawLine(
          Offset(selected.dx, plotRect.top),
          Offset(selected.dx, plotRect.bottom),
          Paint()
            ..color = const Color(0xFF516864).withValues(alpha: 0.5)
            ..strokeWidth = 1
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawCircle(selected, 7, Paint()..color = Colors.white);
        canvas.drawCircle(
          selected,
          4.2,
          Paint()
            ..color = selectedPoint.value < bandLow
                ? const Color(0xFFF48C6A)
                : selectedPoint.value > bandHigh
                ? const Color(0xFFE9A23B)
                : const Color(0xFF177E73),
        );
      }
    }

    final labelCount = math.min(4, math.max(2, points.length));
    for (var index = 0; index < labelCount; index++) {
      final fraction = labelCount == 1 ? 0.0 : index / (labelCount - 1);
      final sourceIndex = ((points.length - 1) * fraction).round();
      final point = points[sourceIndex];
      final x = _xForMinute(point.minute, plotRect, minMinute, maxMinute);
      final label = _axisLabel(point, timeframeMinutes);
      final textPainter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(x - (textPainter.width / 2), plotRect.bottom + 8),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.preferences != preferences ||
        oldDelegate.selectedPointId != selectedPointId ||
        oldDelegate.timeframeMinutes != timeframeMinutes ||
        oldDelegate.chartStyle != chartStyle ||
        oldDelegate.overlayInsetTop != overlayInsetTop;
  }
}

String _axisLabel(_PlottedPoint point, int timeframeMinutes) {
  if (point.recordedAt == null) {
    return 'm${point.minute}';
  }
  final recordedAt = point.recordedAt!.toLocal();
  if (timeframeMinutes == 0 || timeframeMinutes > 1440) {
    return DateFormat('MMM d').format(recordedAt);
  }
  return DateFormat('HH:mm').format(recordedAt);
}

Rect _plotRect(Size size, {double overlayInsetTop = 0}) {
  const left = 42.0;
  const right = 14.0;
  const top = 14.0;
  const bottom = 30.0;
  return Rect.fromLTWH(
    left,
    top + overlayInsetTop,
    math.max(0, size.width - left - right),
    math.max(0, size.height - top - bottom - overlayInsetTop),
  );
}

double _xForMinute(int minute, Rect plotRect, int minMinute, int maxMinute) {
  if (maxMinute <= minMinute) {
    return plotRect.center.dx;
  }
  final fraction = (minute - minMinute) / (maxMinute - minMinute);
  return plotRect.left + (plotRect.width * fraction);
}

double _yForValue(
  double value,
  Rect plotRect,
  double minValue,
  double maxValue,
) {
  final range = maxValue - minValue;
  if (range <= 0) {
    return plotRect.center.dy;
  }
  final fraction = (value - minValue) / range;
  return plotRect.bottom - (plotRect.height * fraction);
}

void _paintText(Canvas canvas, Offset offset, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
}

class _ChartTimeframe {
  const _ChartTimeframe({required this.label, required this.minutes});

  final String label;
  final int minutes;
}

class _ReadingSample {
  const _ReadingSample({
    required this.reading,
    required this.minute,
    required this.recordedAt,
    required this.value,
  });

  final CgmReading reading;
  final int minute;
  final DateTime? recordedAt;
  final double value;
}

class _PlottedPoint {
  const _PlottedPoint({
    required this.id,
    required this.minute,
    required this.recordedAt,
    required this.value,
    required this.low,
    required this.high,
    required this.sampleCount,
  });

  final int id;
  final int minute;
  final DateTime? recordedAt;
  final double value;
  final double low;
  final double high;
  final int sampleCount;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
