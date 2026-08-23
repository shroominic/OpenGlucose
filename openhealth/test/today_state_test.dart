import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/today_navigation.dart';
import 'package:openglucose/src/today_state.dart';

final _now = DateTime.utc(2026, 8, 24, 12);

void main() {
  group('classifyTodayDataState', () {
    final catalog = MockScenarioCatalog(clock: () => _now);

    test('separates no active sensor from retained history', () {
      expect(
        classifyTodayDataState(
          snapshot: null,
          displayReading: null,
          retainedHistoryCount: 0,
        ),
        TodayDataState.noActiveSensor,
      );
      expect(
        classifyTodayDataState(
          snapshot: null,
          displayReading: null,
          retainedHistoryCount: 1,
        ),
        TodayDataState.retainedHistory,
      );
    });

    test('does not classify warmup or unavailable snapshots as live', () {
      final warmup = catalog.buildSnapshot(MockScenario.warmup);
      final unavailable = catalog.buildSnapshot(MockScenario.error);

      expect(
        classifyTodayDataState(
          snapshot: warmup,
          displayReading: null,
          retainedHistoryCount: 0,
          now: _now,
        ),
        TodayDataState.warmup,
      );
      expect(
        classifyTodayDataState(
          snapshot: unavailable,
          displayReading: null,
          retainedHistoryCount: 0,
          now: _now,
        ),
        TodayDataState.unavailable,
      );
    });

    test('does not classify stale signal or reconnecting data as live', () {
      final signalLoss = catalog.buildSnapshot(MockScenario.signalLoss);
      final disconnected = catalog.buildSnapshot(MockScenario.disconnected);
      final expired = catalog.buildSnapshot(MockScenario.expired);

      expect(
        classifyTodayDataState(
          snapshot: signalLoss,
          displayReading: signalLoss.latestReading,
          retainedHistoryCount: 0,
          now: _now,
        ),
        TodayDataState.stale,
      );
      expect(
        classifyTodayDataState(
          snapshot: expired,
          displayReading: expired.latestReading,
          retainedHistoryCount: expired.history.length,
          now: _now,
        ),
        TodayDataState.inactiveSensor,
      );
      expect(
        classifyTodayDataState(
          snapshot: disconnected,
          displayReading: disconnected.latestReading,
          retainedHistoryCount: 0,
          now: _now,
        ),
        TodayDataState.stale,
      );
    });

    test('classifies a ready fresh snapshot as live', () {
      final active = catalog.buildSnapshot(MockScenario.activeNormal);

      expect(
        classifyTodayDataState(
          snapshot: active,
          displayReading: active.latestReading,
          retainedHistoryCount: 0,
          now: _now,
        ),
        TodayDataState.live,
      );
    });
  });

  test('unknown restored route indexes fall back to Today', () {
    expect(
      OpenGlucoseDestination.fromRestoredIndex(-1),
      OpenGlucoseDestination.today,
    );
    expect(
      OpenGlucoseDestination.fromRestoredIndex(99),
      OpenGlucoseDestination.today,
    );
  });
}
