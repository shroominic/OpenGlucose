import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'onboarding_store.dart';

const Color _kAccent = Color(0xFF0B6E69);
const Color _kInk = Color(0xFF103B3C);
const Color _kMuted = Color(0xFF5B6E6A);

/// Light, skippable first-run onboarding.
///
/// A short sequence of intro screens: welcome, how it works, a target-range
/// picker, and a "connect your sensor" handoff. On completion (or skip) it
/// persists state via [OnboardingStore] and invokes [onFinished], which the
/// launch gate uses to hand off to the existing scan/connect flow.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.store,
    required this.onFinished,
    this.unit = GlucoseUnit.mgdl,
  });

  final OnboardingStore store;

  /// Called once onboarding is completed or skipped (after persistence).
  final VoidCallback onFinished;

  /// Display unit for the target-range step. Defaults to mg/dL.
  final GlucoseUnit unit;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  final PageController _pageController = PageController();

  // Target range, held in mg/dL (canonical). Picker edits in the chosen unit.
  RangeValues _rangeMgdl = const RangeValues(
    OnboardingStore.defaultTargetLowMgdl,
    OnboardingStore.defaultTargetHighMgdl,
  );

  int _page = 0;
  bool _finishing = false;

  static const int _lastPage = 3;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= _lastPage) {
      unawaited(_finish(targetRange: true));
      return;
    }
    unawaited(
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      ),
    );
  }

  Future<void> _finish({required bool targetRange}) async {
    if (_finishing) {
      return;
    }
    setState(() => _finishing = true);
    await widget.store.complete(
      targetLowMgdl: targetRange ? _rangeMgdl.start : null,
      targetHighMgdl: targetRange ? _rangeMgdl.end : null,
    );
    if (!mounted) {
      return;
    }
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color(0xFFF7F0E4),
              Color(0xFFE9F3EF),
              Color(0xFFF7F5EE),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: <Widget>[
              _TopBar(
                onSkip: _page < _lastPage && !_finishing
                    ? () => _finish(targetRange: false)
                    : null,
              ),
              Expanded(
                child: PageView(
                  key: const ValueKey<String>('onboardingPageView'),
                  controller: _pageController,
                  onPageChanged: (value) => setState(() => _page = value),
                  children: <Widget>[
                    const _WelcomeStep(),
                    const _HowItWorksStep(),
                    _TargetRangeStep(
                      unit: widget.unit,
                      rangeMgdl: _rangeMgdl,
                      onChanged: (value) => setState(() => _rangeMgdl = value),
                    ),
                    const _ConnectStep(),
                  ],
                ),
              ),
              _Footer(
                page: _page,
                pageCount: _lastPage + 1,
                finishing: _finishing,
                accent: _kAccent,
                onNext: _finishing ? null : _next,
                isLast: _page == _lastPage,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({this.onSkip});

  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: <Widget>[
          const Spacer(),
          SizedBox(
            height: 40,
            child: onSkip == null
                ? null
                : TextButton(
                    key: const ValueKey<String>('onboardingSkipButton'),
                    onPressed: onSkip,
                    style: TextButton.styleFrom(
                      foregroundColor: _kMuted,
                    ),
                    child: const Text('Skip'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.page,
    required this.pageCount,
    required this.finishing,
    required this.accent,
    required this.onNext,
    required this.isLast,
  });

  final int page;
  final int pageCount;
  final bool finishing;
  final Color accent;
  final VoidCallback? onNext;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: <Widget>[
          _Dots(count: pageCount, active: page, accent: accent),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              key: const ValueKey<String>('onboardingPrimaryButton'),
              onPressed: onNext,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: finishing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(isLast ? 'Connect my sensor' : 'Continue'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({
    required this.count,
    required this.active,
    required this.accent,
  });

  final int count;
  final int active;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            height: 8,
            width: i == active ? 24 : 8,
            decoration: BoxDecoration(
              color: i == active ? accent : accent.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}

/// Shared scaffold for an intro step: icon medallion, title, body, optional
/// bullet rows. Keeps every screen visually consistent and light on text.
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.icon,
    required this.title,
    required this.body,
    this.bullets = const <_Bullet>[],
    this.footnote,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<_Bullet> bullets;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 12),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 36, color: _kAccent),
          ),
          const SizedBox(height: 28),
          Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: _kInk,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: _kMuted,
              height: 1.45,
            ),
          ),
          if (bullets.isNotEmpty) ...<Widget>[
            const SizedBox(height: 24),
            for (final bullet in bullets) ...<Widget>[
              _BulletRow(bullet: bullet),
              const SizedBox(height: 16),
            ],
          ],
          if (footnote != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              footnote!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _kMuted,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bullet {
  const _Bullet({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;
}

class _BulletRow extends StatelessWidget {
  const _BulletRow({required this.bullet});

  final _Bullet bullet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDCE7E2)),
          ),
          child: Icon(
            bullet.icon,
            size: 20,
            color: _kAccent,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                bullet.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _kInk,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                bullet.body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _kMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    return const _StepScaffold(
      icon: Icons.favorite_rounded,
      title: 'Welcome to OpenGlucose',
      body:
          'An open-source, local-first way to watch your glucose. Built for '
          'wellness, sport and self-experimentation — not as a medical '
          'device.',
      bullets: <_Bullet>[
        _Bullet(
          icon: Icons.lock_outline_rounded,
          title: 'Stored locally by default',
          body:
              'History stays on this device. Optional HealthKit or AI features '
              'share data only when you enable them.',
        ),
        _Bullet(
          icon: Icons.code_rounded,
          title: 'Open source & hackable',
          body: 'MIT-licensed. Inspect it, extend it, make it yours.',
        ),
      ],
      footnote:
          'OpenGlucose is for wellness and self-experimentation. It is not a '
          'medical device and not a substitute for medical advice.',
    );
  }
}

class _HowItWorksStep extends StatelessWidget {
  const _HowItWorksStep();

  @override
  Widget build(BuildContext context) {
    return const _StepScaffold(
      icon: Icons.sensors_rounded,
      title: 'How it works',
      body:
          'Apply your Aidex X sensor, pair it over Bluetooth, and let it warm '
          'up. After that, readings stream straight to your phone.',
      bullets: <_Bullet>[
        _Bullet(
          icon: Icons.touch_app_rounded,
          title: 'Apply the sensor',
          body: 'A small all-in-one sensor you wear for up to 15 days.',
        ),
        _Bullet(
          icon: Icons.hourglass_bottom_rounded,
          title: '~1 hour warm-up',
          body: 'The sensor calibrates itself before the first reading.',
        ),
        _Bullet(
          icon: Icons.timelapse_rounded,
          title: 'A reading every minute',
          body: 'Live values and trends, refreshed continuously.',
        ),
      ],
    );
  }
}

class _TargetRangeStep extends StatelessWidget {
  const _TargetRangeStep({
    required this.unit,
    required this.rangeMgdl,
    required this.onChanged,
  });

  final GlucoseUnit unit;
  final RangeValues rangeMgdl;
  final ValueChanged<RangeValues> onChanged;

  // Slider bounds in mg/dL; the picker snaps low/high to sensible steps.
  static const double _minMgdl = 50;
  static const double _maxMgdl = 250;
  static const double _stepMgdl = 5;

  String _format(double mgdl) {
    final value = unit.convertFromMgdl(mgdl);
    return unit == GlucoseUnit.mgdl
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divisions = ((_maxMgdl - _minMgdl) / _stepMgdl).round();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 12),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.tune_rounded,
              size: 36,
              color: _kAccent,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Set your target range',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: _kInk,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Choose the range you want to stay within. You can change this any '
            'time in settings.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: _kMuted,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFDCE7E2)),
            ),
            child: Column(
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Text(
                      _format(rangeMgdl.start),
                      key: const ValueKey<String>('onboardingRangeLow'),
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: _kInk,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        '–',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: _kMuted,
                        ),
                      ),
                    ),
                    Text(
                      _format(rangeMgdl.end),
                      key: const ValueKey<String>('onboardingRangeHigh'),
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: _kInk,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        unit.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: _kMuted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                RangeSlider(
                  key: const ValueKey<String>('onboardingRangeSlider'),
                  values: rangeMgdl,
                  min: _minMgdl,
                  max: _maxMgdl,
                  divisions: divisions,
                  activeColor: _kAccent,
                  inactiveColor: _kAccent.withValues(
                    alpha: 0.18,
                  ),
                  labels: RangeLabels(
                    _format(rangeMgdl.start),
                    _format(rangeMgdl.end),
                  ),
                  onChanged: (values) {
                    // Keep a minimum gap between handles.
                    if (values.end - values.start < _stepMgdl) {
                      return;
                    }
                    onChanged(values);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Most people start with 70–180 mg/dL (about 3.9–10 '
            'mmol/L).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _kMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectStep extends StatelessWidget {
  const _ConnectStep();

  @override
  Widget build(BuildContext context) {
    return const _StepScaffold(
      icon: Icons.bluetooth_searching_rounded,
      title: "You're all set",
      body:
          'Have your Aidex X sensor on and nearby. We’ll scan for it over '
          'Bluetooth and connect — then your live dashboard takes over.',
      bullets: <_Bullet>[
        _Bullet(
          icon: Icons.bluetooth_rounded,
          title: 'Turn on Bluetooth',
          body: 'Keep your phone close to the sensor while it pairs.',
        ),
        _Bullet(
          icon: Icons.show_chart_rounded,
          title: 'Watch it come alive',
          body: 'Trends and readings appear as soon as warm-up finishes.',
        ),
      ],
    );
  }
}
