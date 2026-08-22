import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'dashboard_chart.dart';
import 'display_preferences.dart';
import 'metrics_section.dart';
import 'weekly_recap/weekly_recap_screen.dart';

/// Read-only product preview for people who do not have a sensor connected.
///
/// Sample readings exist only in memory. This route never touches BLE,
/// persistence, HealthKit, notifications, or lock-screen activities.
class SampleDashboardScreen extends StatelessWidget {
  SampleDashboardScreen({super.key, required this.preferences, DateTime? now})
    : _now = now ?? DateTime.now(),
      _readings = _sampleReadings(now ?? DateTime.now());

  final DisplayPreferences preferences;
  final DateTime _now;
  final List<CgmReading> _readings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sample dashboard')),
      body: Column(
        children: <Widget>[
          const Material(
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
                        'SAMPLE DATA — NOT FROM A SENSOR',
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
          ),
          Expanded(
            child: CustomScrollView(
              key: const ValueKey<String>('sampleDashboard'),
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: Card(
                      color: const Color(0xFF103B3C),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'See how OpenGlucose works',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              'This private preview is generated in memory. '
                              'It cannot connect, export, notify, or be mixed '
                              'with your real glucose history.',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: const Color(0xFFD8EEE8),
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    'Glucose history',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Color(0xFFFFE8A3),
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(999),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    child: Text(
                                      'SAMPLE',
                                      style: TextStyle(
                                        color: Color(0xFF6B4300),
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 336,
                              child: CgmDashboardChart(
                                readings: _readings,
                                preferences: preferences,
                                historySync: const CgmHistorySyncState(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: MetricsSection(
                      readings: _readings,
                      preferences: preferences,
                      now: _now,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    child: FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WeeklyRecapScreen(
                            readings: _readings,
                            preferences: preferences,
                            now: _now,
                            isSampleData: true,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.insights_rounded),
                      label: const Text('Open sample weekly recap'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static List<CgmReading> _sampleReadings(DateTime now) {
    final end = DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch - now.millisecondsSinceEpoch % 60000,
    );
    const interval = Duration(minutes: 15);
    const count = 14 * 24 * 4;
    return List<CgmReading>.generate(count, (index) {
      final minutesAgo = (count - index - 1) * interval.inMinutes;
      final timestamp = end.subtract(Duration(minutes: minutesAgo));
      final minuteOfDay = timestamp.hour * 60 + timestamp.minute;
      final dailyWave = math.sin((minuteOfDay / 1440) * math.pi * 2) * 8;
      final slowWave = math.sin((index / 90) * math.pi * 2) * 5;
      final breakfast = _mealRise(minuteOfDay, 8 * 60 + 15, 33);
      final lunch = _mealRise(minuteOfDay, 13 * 60, 24);
      final dinner = _mealRise(minuteOfDay, 19 * 60 + 15, 38);
      final value = 94 + dailyWave + slowWave + breakfast + lunch + dinner;
      return CgmReading(
        valueMgdl: value.clamp(68, 185).toDouble(),
        source: CgmRecordSource.vendor,
        sensorMinute: index * interval.inMinutes,
        recordedAt: timestamp,
      );
    }, growable: false);
  }

  static double _mealRise(int minuteOfDay, int center, double amplitude) {
    final distance = (minuteOfDay - center).abs();
    final circularDistance = math.min(distance, 1440 - distance);
    return amplitude * math.exp(-math.pow(circularDistance / 75, 2));
  }
}
