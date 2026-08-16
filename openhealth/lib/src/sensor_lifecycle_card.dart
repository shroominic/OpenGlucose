import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'session_presentation.dart';

/// Self-contained sensor lifecycle details card for Current sensor settings.
///
/// Renders, from the session timing alone (no extra wiring):
///  - sensor age + % of the 15-day life used + time remaining (progress arc),
///  - the warmup countdown while the sensor is warming up,
///  - a heads-up banner when the sensor is expiring soon,
///  - a full offboarding state (replace prompt) when the sensor has expired,
///  - the last-sync time.
///
/// Stateless: it recomputes the lifecycle on every parent rebuild. The
/// parent rebuilds on each controller notification, so the countdown/age stay
/// fresh without this widget owning a perpetual timer (which would break
/// `pumpAndSettle` in widget tests). [clock] is injectable for deterministic
/// tests.
class SensorLifecycleCard extends StatelessWidget {
  const SensorLifecycleCard({
    super.key,
    required this.snapshot,
    this.latestReading,
    this.onReplaceSensor,
    this.clock,
    this.outerPadding = const EdgeInsets.fromLTRB(20, 16, 20, 0),
  });

  final CgmSessionSnapshot snapshot;
  final CgmReading? latestReading;

  /// Invoked when the user taps "Replace sensor" in the expired state. Wire to
  /// the disconnect/rescan flow. When null the button is hidden.
  final VoidCallback? onReplaceSensor;

  /// Injectable clock for tests; defaults to [DateTime.now].
  final DateTime Function()? clock;

  /// Space around the lifecycle card. Settings can place it flush inside an
  /// already padded page.
  final EdgeInsetsGeometry outerPadding;

  @override
  Widget build(BuildContext context) {
    final now = (clock ?? DateTime.now)();
    final lifecycle = computeSensorLifecycle(
      snapshot,
      latestReading: latestReading,
      now: now,
    );

    if (lifecycle.phase == SensorLifecyclePhase.unknown) {
      return Padding(
        padding: outerPadding,
        child: const Card(
          key: ValueKey<String>('sensorLifecycleCard'),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Icon(Icons.schedule_rounded, color: Color(0xFF0B6E69)),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Sensor lifecycle',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Life remaining unavailable while the sensor session '
                        'is being verified.',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: outerPadding,
      child: Card(
        key: const ValueKey<String>('sensorLifecycleCard'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: lifecycle.isExpired
              ? _ExpiredOffboarding(
                  lifecycle: lifecycle,
                  lastReadingAt: latestReading?.recordedAt,
                  now: now,
                  onReplaceSensor: onReplaceSensor,
                )
              : _ActiveLifecycle(
                  lifecycle: lifecycle,
                  lastSyncAt: snapshot.historySync.lastSyncAt,
                  now: now,
                ),
        ),
      ),
    );
  }
}

class _ActiveLifecycle extends StatelessWidget {
  const _ActiveLifecycle({
    required this.lifecycle,
    required this.lastSyncAt,
    required this.now,
  });

  final SensorLifecycle lifecycle;
  final DateTime? lastSyncAt;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warmup = lifecycle.warmup;
    final isWarming = lifecycle.isWarmingUp && warmup != null;

    final accent = lifecycle.isExpiringSoon
        ? const Color(0xFFF2A65A)
        : isWarming
        ? const Color(0xFFF2A65A)
        : const Color(0xFF0B6E69);

    final remainingText = compactDurationText(lifecycle.remaining);
    final ageText = compactDurationText(lifecycle.age);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Sensor lifecycle',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const Spacer(),
            _LifecyclePill(
              label: isWarming
                  ? 'Warming up'
                  : lifecycle.isExpiringSoon
                  ? 'Expiring soon'
                  : 'Active',
              color: accent,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _LifeRing(
              fraction: lifecycle.lifeUsedFraction,
              accent: accent,
              centerTop: isWarming
                  ? '${warmup.remainingMinutes}'
                  : '${lifecycle.lifeUsedPercent}%',
              centerBottom: isWarming ? 'min' : 'used',
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (isWarming) ...<Widget>[
                    _LifeStatRow(
                      label: 'Warmup',
                      value: '${warmup.remainingMinutes} min left',
                    ),
                    _LifeStatRow(
                      label: 'Sensor age',
                      value: ageText,
                    ),
                  ] else ...<Widget>[
                    _LifeStatRow(
                      label: 'Time remaining',
                      value: remainingText,
                      emphasize: lifecycle.isExpiringSoon,
                    ),
                    _LifeStatRow(label: 'Sensor age', value: ageText),
                  ],
                  _LifeStatRow(
                    label: 'Total life',
                    value: '${lifecycle.totalLife.inDays} days',
                  ),
                  _LifeStatRow(
                    label: 'Last sync',
                    value: lastSyncText(lastSyncAt, now: now)
                        .replaceFirst('Synced ', '')
                        .replaceFirst('Not synced yet', 'Not yet'),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (isWarming) ...<Widget>[
          const SizedBox(height: 14),
          _InfoBanner(
            color: const Color(0xFFF2A65A),
            icon: Icons.hourglass_top_rounded,
            text:
                'Warming up — readings stabilise after the first hour. Keep '
                'the sensor on and this device nearby.',
          ),
        ] else if (lifecycle.isExpiringSoon) ...<Widget>[
          const SizedBox(height: 14),
          _InfoBanner(
            color: const Color(0xFFF2A65A),
            icon: Icons.notifications_active_rounded,
            text:
                'This sensor expires in ${compactDurationText(lifecycle.remaining)}. '
                "Have a replacement ready so you don't miss readings.",
          ),
        ],
      ],
    );
  }
}

class _ExpiredOffboarding extends StatelessWidget {
  const _ExpiredOffboarding({
    required this.lifecycle,
    required this.lastReadingAt,
    required this.now,
    required this.onReplaceSensor,
  });

  final SensorLifecycle lifecycle;
  final DateTime? lastReadingAt;
  final DateTime now;
  final VoidCallback? onReplaceSensor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const expiredColor = Color(0xFFC25A3B);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.event_busy_rounded,
              color: expiredColor,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Sensor expired',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: expiredColor,
                ),
              ),
            ),
            const _LifecyclePill(label: 'Expired', color: expiredColor),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'This sensor reached the end of its 15-day life. The readings below '
          'are frozen at the last known values — they are kept for your '
          'records but are no longer live.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF5B6E6A),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        _InfoBanner(
          color: expiredColor,
          icon: Icons.history_toggle_off_rounded,
          text: lastReadingAt == null
              ? 'Last reading is preserved below.'
              : 'Last reading ${lastSyncText(lastReadingAt, now: now).replaceFirst('Synced ', '')}. Your history is preserved.',
        ),
        const SizedBox(height: 16),
        Text(
          'Next steps',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        const _OffboardingStep(
          index: 1,
          text: 'Peel off and dispose of the expired sensor.',
        ),
        const _OffboardingStep(
          index: 2,
          text: 'Apply a fresh Aidex X sensor and wait for the ~1h warmup.',
        ),
        const _OffboardingStep(
          index: 3,
          text: 'Tap below to start a new sensor session.',
        ),
        if (onReplaceSensor != null) ...<Widget>[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey<String>('replaceSensorButton'),
              onPressed: onReplaceSensor,
              style: FilledButton.styleFrom(backgroundColor: expiredColor),
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: const Text('Replace sensor'),
            ),
          ),
        ],
      ],
    );
  }
}

class _OffboardingStep extends StatelessWidget {
  const _OffboardingStep({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFEDE2DA),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: Color(0xFFC25A3B),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _LifeRing extends StatelessWidget {
  const _LifeRing({
    required this.fraction,
    required this.accent,
    required this.centerTop,
    required this.centerBottom,
  });

  final double fraction;
  final Color accent;
  final String centerTop;
  final String centerBottom;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox(
            width: 84,
            height: 84,
            child: CircularProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              strokeWidth: 8,
              backgroundColor: const Color(0xFFE6EFEA),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                centerTop,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  color: accent,
                ),
              ),
              Text(
                centerBottom,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF5B6E6A),
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

class _LifeStatRow extends StatelessWidget {
  const _LifeStatRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF5B6E6A)),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: emphasize ? const Color(0xFFC25A3B) : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _LifecyclePill extends StatelessWidget {
  const _LifecyclePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: const Color(0xFF3A4744),
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Exposed for completeness so callers can format the sensor start timestamp
/// identically to the rest of the dashboard if needed.
String sensorStartLabel(DateTime? sessionStart) {
  if (sessionStart == null) {
    return '--';
  }
  return DateFormat('MMM d, HH:mm').format(sessionStart.toLocal());
}
