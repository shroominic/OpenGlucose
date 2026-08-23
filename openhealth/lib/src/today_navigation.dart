import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_theme.dart';
import 'display_preferences.dart';
import 'metrics_section.dart';
import 'today_state.dart';
import 'weekly_recap/weekly_recap_screen.dart';

/// Stable, top-level product destinations.
///
/// The numeric index is persisted by the home page. Invalid restored values
/// safely return users to Today instead of selecting an unknown destination.
enum OpenGlucoseDestination {
  today('/today', 'Today', Icons.today_outlined, Icons.today_rounded),
  timeline(
    '/timeline',
    'Timeline',
    Icons.view_timeline_outlined,
    Icons.view_timeline_rounded,
  ),
  trends('/trends', 'Trends', Icons.insights_outlined, Icons.insights_rounded)
  ;

  const OpenGlucoseDestination(
    this.routeName,
    this.label,
    this.icon,
    this.selectedIcon,
  );

  final String routeName;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  static OpenGlucoseDestination fromRestoredIndex(int index) {
    if (index < 0 || index >= values.length) {
      return OpenGlucoseDestination.today;
    }
    return values[index];
  }
}

/// Responsive, state-preserving navigation around the current Today content.
///
/// The caller owns route/restoration state. [IndexedStack] keeps every tab's
/// local scroll and selection state alive when a user switches destinations.
class OpenGlucoseNavigationShell extends StatelessWidget {
  const OpenGlucoseNavigationShell({
    super.key,
    required this.destination,
    required this.onDestinationSelected,
    required this.today,
    required this.timeline,
    required this.trends,
  });

  final OpenGlucoseDestination destination;
  final ValueChanged<OpenGlucoseDestination> onDestinationSelected;
  final Widget today;
  final Widget timeline;
  final Widget trends;

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationDestination>[
      for (final destination in OpenGlucoseDestination.values)
        NavigationDestination(
          icon: Icon(destination.icon),
          selectedIcon: Icon(destination.selectedIcon),
          label: destination.label,
        ),
    ];
    final body = Semantics(
      label: '${destination.label} content',
      child: IndexedStack(
        index: destination.index,
        children: <Widget>[
          KeyedSubtree(
            key: const PageStorageKey<String>('todayDestination'),
            child: today,
          ),
          KeyedSubtree(
            key: const PageStorageKey<String>('timelineDestination'),
            child: timeline,
          ),
          KeyedSubtree(
            key: const PageStorageKey<String>('trendsDestination'),
            child: trends,
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 700) {
          return Row(
            children: <Widget>[
              Semantics(
                container: true,
                label: 'Primary navigation',
                child: NavigationRail(
                  key: const ValueKey<String>('primaryNavigationRail'),
                  selectedIndex: destination.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (index) => onDestinationSelected(
                    OpenGlucoseDestination.fromRestoredIndex(index),
                  ),
                  destinations: <NavigationRailDestination>[
                    for (final item in OpenGlucoseDestination.values)
                      NavigationRailDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: Text(item.label),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          );
        }

        return Column(
          children: <Widget>[
            Expanded(child: body),
            Semantics(
              container: true,
              label: 'Primary navigation',
              child: NavigationBar(
                key: const ValueKey<String>('primaryNavigationBar'),
                selectedIndex: destination.index,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: (index) => onDestinationSelected(
                  OpenGlucoseDestination.fromRestoredIndex(index),
                ),
                destinations: destinations,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Compact glucose-only list while the unified body timeline is delivered by
/// its own issue. It does not invent meals, workouts, notes, or source data.
class GlucoseTimelinePane extends StatelessWidget {
  const GlucoseTimelinePane({
    super.key,
    required this.snapshot,
    required this.displayReading,
    required this.visibleHistory,
    required this.retainedHistoryCount,
    required this.preferences,
    required this.isSampleData,
  });

  final CgmSessionSnapshot? snapshot;
  final CgmReading? displayReading;
  final List<CgmReading> visibleHistory;
  final int retainedHistoryCount;
  final DisplayPreferences preferences;
  final bool isSampleData;

  @override
  Widget build(BuildContext context) {
    final state = classifyTodayDataState(
      snapshot: snapshot,
      displayReading: displayReading,
      retainedHistoryCount: retainedHistoryCount,
    );
    return CustomScrollView(
      key: const ValueKey<String>('timelineDestinationContent'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              OpenGlucoseTokens.pageGutter,
              OpenGlucoseTokens.sectionGap,
              OpenGlucoseTokens.pageGutter,
              OpenGlucoseTokens.sectionGap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (isSampleData && state == TodayDataState.live) ...<Widget>[
                  const _SampleDataBanner(),
                  const SizedBox(height: OpenGlucoseTokens.sectionGap),
                ],
                const _DestinationHeading(
                  title: 'Timeline',
                  description: 'Your chronological glucose context.',
                ),
                const SizedBox(height: OpenGlucoseTokens.sectionGap),
                if (state == TodayDataState.live)
                  _RecentGlucoseCard(
                    readings: visibleHistory,
                    preferences: preferences,
                  )
                else
                  TodayDataStateCard(state: state),
                const SizedBox(height: OpenGlucoseTokens.sectionGap),
                const _ScopeNotice(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Existing, explainable pattern surfaces in their own destination.
///
/// Trends deliberately hides derived metrics until a current usable reading is
/// available. Retained, warming-up, stale, and unavailable data cannot be
/// mistaken for live patterns from this tab.
class GlucoseTrendsPane extends StatelessWidget {
  const GlucoseTrendsPane({
    super.key,
    required this.snapshot,
    required this.displayReading,
    required this.visibleHistory,
    required this.retainedHistoryCount,
    required this.preferences,
    required this.isSampleData,
  });

  final CgmSessionSnapshot? snapshot;
  final CgmReading? displayReading;
  final List<CgmReading> visibleHistory;
  final int retainedHistoryCount;
  final DisplayPreferences preferences;
  final bool isSampleData;

  @override
  Widget build(BuildContext context) {
    final state = classifyTodayDataState(
      snapshot: snapshot,
      displayReading: displayReading,
      retainedHistoryCount: retainedHistoryCount,
    );
    return CustomScrollView(
      key: const ValueKey<String>('trendsDestinationContent'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              OpenGlucoseTokens.pageGutter,
              OpenGlucoseTokens.sectionGap,
              OpenGlucoseTokens.pageGutter,
              OpenGlucoseTokens.sectionGap,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (isSampleData && state == TodayDataState.live) ...<Widget>[
                  const _SampleDataBanner(),
                  const SizedBox(height: OpenGlucoseTokens.sectionGap),
                ],
                const _DestinationHeading(
                  title: 'Trends',
                  description:
                      'Explainable observations for self-experimentation, not medical advice.',
                ),
                const SizedBox(height: OpenGlucoseTokens.sectionGap),
                if (state == TodayDataState.live) ...<Widget>[
                  MetricsSection(
                    readings: visibleHistory,
                    preferences: preferences,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: OpenGlucoseTokens.sectionGap,
                    ),
                    child: FilledButton.tonalIcon(
                      key: const ValueKey<String>('trendsWeeklyRecapButton'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WeeklyRecapScreen(
                            readings: visibleHistory,
                            preferences: preferences,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.insights_rounded),
                      label: const Text('Weekly recap'),
                    ),
                  ),
                ] else
                  TodayDataStateCard(state: state),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TodayDataStateCard extends StatelessWidget {
  const TodayDataStateCard({super.key, required this.state});

  final TodayDataState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (state) {
      TodayDataState.noActiveSensor => Icons.sensors_off_outlined,
      TodayDataState.retainedHistory => Icons.history_outlined,
      TodayDataState.inactiveSensor => Icons.history_toggle_off_rounded,
      TodayDataState.warmup => Icons.hourglass_top_rounded,
      TodayDataState.unavailable => Icons.cloud_off_outlined,
      TodayDataState.stale => Icons.sync_problem_rounded,
      TodayDataState.live => Icons.check_circle_outline,
    };
    return Semantics(
      liveRegion: true,
      child: Card(
        key: ValueKey<String>('todayState-${state.name}'),
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(OpenGlucoseTokens.sectionGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      state.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: OpenGlucoseTokens.compactGap),
                    Text(state.description),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DestinationHeading extends StatelessWidget {
  const _DestinationHeading({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: OpenGlucoseTokens.compactGap),
        Text(
          description,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _RecentGlucoseCard extends StatelessWidget {
  const _RecentGlucoseCard({required this.readings, required this.preferences});

  final List<CgmReading> readings;
  final DisplayPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = readings.reversed.take(6).toList(growable: false);
    if (recent.isEmpty) {
      return const TodayDataStateCard(state: TodayDataState.unavailable);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(OpenGlucoseTokens.sectionGap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Recent glucose',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: OpenGlucoseTokens.compactGap),
            Text(
              'Current sensor readings only.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: OpenGlucoseTokens.compactGap),
            for (final reading in recent)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.water_drop_outlined),
                title: Text(_formatReading(reading, preferences)),
                subtitle: Text(_formatTimestamp(reading)),
              ),
          ],
        ),
      ),
    );
  }

  String _formatReading(CgmReading reading, DisplayPreferences preferences) {
    final value = preferences.unit.convertFromMgdl(reading.valueMgdl);
    final digits = preferences.unit == GlucoseUnit.mgdl ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${preferences.unit.label}';
  }

  String _formatTimestamp(CgmReading reading) {
    final recordedAt = reading.recordedAt;
    if (recordedAt == null) {
      return 'Time unavailable';
    }
    return DateFormat('HH:mm').format(recordedAt.toLocal());
  }
}

class _ScopeNotice extends StatelessWidget {
  const _ScopeNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(OpenGlucoseTokens.sectionGap),
        child: Text(
          'Meals, workouts, sleep, notes, and source-aware imports are not '
          'shown in this first navigation slice. They require their own '
          'reviewed data contracts.',
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _SampleDataBanner extends StatelessWidget {
  const _SampleDataBanner();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Sample data, not from a sensor',
      child: Card(
        color: const Color(0xFFFFE8A3),
        child: const Padding(
          padding: EdgeInsets.all(OpenGlucoseTokens.compactGap),
          child: Row(
            children: <Widget>[
              Icon(Icons.visibility_outlined, color: Color(0xFF6B4300)),
              SizedBox(width: OpenGlucoseTokens.compactGap),
              Expanded(
                child: Text(
                  'SAMPLE DATA — NOT FROM A SENSOR',
                  style: TextStyle(
                    color: Color(0xFF6B4300),
                    fontWeight: FontWeight.w900,
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
