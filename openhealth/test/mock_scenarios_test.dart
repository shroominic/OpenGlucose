import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/display_preferences.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/session_presentation.dart';

/// Fixed clock so scenario snapshots are deterministic.
final _now = DateTime.utc(2026, 6, 23, 12);
DateTime _clock() => _now;

void main() {
  group('MockScenario.fromId', () {
    test('resolves every known id back to its scenario', () {
      for (final scenario in MockScenario.values) {
        expect(MockScenario.fromId(scenario.id), scenario);
      }
    });

    test('falls back to activeNormal for empty/unknown ids', () {
      expect(MockScenario.fromId(null), MockScenario.activeNormal);
      expect(MockScenario.fromId(''), MockScenario.activeNormal);
      expect(MockScenario.fromId('nope'), MockScenario.activeNormal);
    });
  });

  group('MockScenarioCatalog.buildSnapshot', () {
    final catalog = MockScenarioCatalog(clock: _clock);

    test('builds a snapshot for every scenario and tags metadata', () {
      for (final scenario in MockScenario.values) {
        final snapshot = catalog.buildSnapshot(scenario);
        expect(
          snapshot.metadata['scenario'],
          scenario.id,
          reason: '${scenario.id} should tag its metadata',
        );
        expect(snapshot.metadata['mode'], 'demo');
      }
    });

    test('warmup has no readings and is inside the warmup window', () {
      final snapshot = catalog.buildSnapshot(MockScenario.warmup);
      expect(snapshot.history, isEmpty);
      expect(snapshot.latestReading, isNull);
      final warmup = computeWarmupStatus(snapshot, now: _now);
      expect(warmup, isNotNull);
      expect(warmup!.phase, WarmupPhase.warming);
      expect(warmup.remainingMinutes, greaterThan(0));
    });

    test('activeNormal stays in range (70-180 mg/dL)', () {
      final snapshot = catalog.buildSnapshot(MockScenario.activeNormal);
      expect(snapshot.history, isNotEmpty);
      for (final reading in snapshot.history) {
        expect(reading.valueMgdl, greaterThanOrEqualTo(70));
        expect(reading.valueMgdl, lessThanOrEqualTo(180));
      }
    });

    test('activeHigh sustains above the high threshold', () {
      final snapshot = catalog.buildSnapshot(MockScenario.activeHigh);
      expect(snapshot.latestReading, isNotNull);
      expect(
        snapshot.latestReading!.valueMgdl,
        greaterThan(kMockHighThresholdMgdl),
      );
      // The bulk of the window should be high, not just the last point.
      final highCount = snapshot.history
          .where((r) => r.valueMgdl > kMockHighThresholdMgdl)
          .length;
      expect(highCount, greaterThan(snapshot.history.length ~/ 2));
    });

    test('activeLow sustains below the low threshold', () {
      final snapshot = catalog.buildSnapshot(MockScenario.activeLow);
      expect(snapshot.latestReading, isNotNull);
      expect(
        snapshot.latestReading!.valueMgdl,
        lessThan(kMockLowThresholdMgdl),
      );
      final lowCount = snapshot.history
          .where((r) => r.valueMgdl < kMockLowThresholdMgdl)
          .length;
      expect(lowCount, greaterThan(snapshot.history.length ~/ 2));
    });

    test('rapidRise trends strongly upward', () {
      final snapshot = catalog.buildSnapshot(MockScenario.rapidRise);
      final first = snapshot.history.first.valueMgdl;
      final last = snapshot.history.last.valueMgdl;
      expect(last - first, greaterThan(100));
      final trend = glucoseTrendSummary(
        snapshot.history,
        const DisplayPreferences(),
      );
      expect(trend.symbol, anyOf('↑', '↑↑', '↗'));
    });

    test('rapidFall trends strongly downward', () {
      final snapshot = catalog.buildSnapshot(MockScenario.rapidFall);
      final first = snapshot.history.first.valueMgdl;
      final last = snapshot.history.last.valueMgdl;
      expect(first - last, greaterThan(100));
      final trend = glucoseTrendSummary(
        snapshot.history,
        const DisplayPreferences(),
      );
      expect(trend.symbol, anyOf('↓', '↓↓', '↘'));
    });

    test('expiringSoon reports hours, not days, of life left', () {
      final snapshot = catalog.buildSnapshot(MockScenario.expiringSoon);
      final lifeText = sensorLifeText(
        snapshot.sessionInfo.sessionStart,
        now: _now,
      );
      expect(lifeText, contains('hour'));
      expect(snapshot.history, isNotEmpty);
    });

    test('expired is past 15-day life, stopped, and flagged expired', () {
      final snapshot = catalog.buildSnapshot(MockScenario.expired);
      expect(snapshot.sessionInfo.sessionStopped, isTrue);
      expect(snapshot.health.expired, isTrue);
      final lifeText = sensorLifeText(
        snapshot.sessionInfo.sessionStart,
        now: _now,
      );
      expect(lifeText, 'Sensor expired');
    });

    test('signalLoss is connected with a stale last reading', () {
      final snapshot = catalog.buildSnapshot(MockScenario.signalLoss);
      expect(snapshot.stage, CgmSyncStage.ready);
      expect(snapshot.health.signalLost, isTrue);
      final recordedAt = snapshot.latestReading!.recordedAt!;
      expect(_now.difference(recordedAt).inMinutes, greaterThanOrEqualTo(10));
    });

    test('disconnected uses the disconnected stage but keeps data', () {
      final snapshot = catalog.buildSnapshot(MockScenario.disconnected);
      expect(snapshot.stage, CgmSyncStage.disconnected);
      expect(snapshot.history, isNotEmpty);
      expect(stageLabelForSnapshot(snapshot), 'Reconnecting');
    });

    test('multiSensorHistory carries previous-sensor readings', () {
      final snapshot = catalog.buildSnapshot(MockScenario.multiSensorHistory);
      expect(snapshot.metadata['previousSensorReadings'], isNotNull);
      // Readings with negative sensorMinute belong to the previous sensor.
      final previous = snapshot.history.where(
        (r) => (r.sensorMinute ?? 0) < 0,
      );
      expect(previous, isNotEmpty);
      final current = snapshot.history.where((r) => (r.sensorMinute ?? 0) >= 0);
      expect(current, isNotEmpty);
    });

    test('error has no data, error stage, and a lastError message', () {
      final snapshot = catalog.buildSnapshot(MockScenario.error);
      expect(snapshot.stage, CgmSyncStage.error);
      expect(snapshot.history, isEmpty);
      expect(snapshot.latestReading, isNull);
      expect(snapshot.health.error, isTrue);
      expect(snapshot.lastError, isNotNull);
      expect(shouldShowPrimaryError(snapshot), isTrue);
    });
  });

  group('DemoCgmSession scenario switching', () {
    test('applyScenario emits a fresh snapshot for the new scenario', () async {
      final driver = DemoCgmDriver(
        initialScenario: MockScenario.activeNormal,
        clock: _clock,
      );
      final session = await driver.connect(driver.scenarioSensor)
          as DemoCgmSession;
      addTearDown(session.disconnect);

      expect(session.scenario, MockScenario.activeNormal);
      expect(session.currentSnapshot.stage, CgmSyncStage.ready);

      final emitted = session.snapshots.first;
      session.applyScenario(MockScenario.activeHigh);

      final snapshot = await emitted;
      expect(session.scenario, MockScenario.activeHigh);
      expect(snapshot.metadata['scenario'], MockScenario.activeHigh.id);
      expect(
        snapshot.latestReading!.valueMgdl,
        greaterThan(kMockHighThresholdMgdl),
      );
    });

    test('driver.applyScenario updates the live session', () async {
      final driver = DemoCgmDriver(clock: _clock);
      final session = await driver.connect(driver.scenarioSensor)
          as DemoCgmSession;
      addTearDown(session.disconnect);

      final result = driver.applyScenario(MockScenario.error);
      expect(result, same(session));
      expect(driver.scenario, MockScenario.error);
      expect(session.currentSnapshot.stage, CgmSyncStage.error);
    });

    test('refresh keeps a high scenario in its glucose band', () async {
      final driver = DemoCgmDriver(
        initialScenario: MockScenario.activeHigh,
        clock: _clock,
      );
      final session = await driver.connect(driver.scenarioSensor)
          as DemoCgmSession;
      addTearDown(session.disconnect);

      await session.refresh();
      expect(
        session.currentSnapshot.latestReading!.valueMgdl,
        greaterThan(kMockHighThresholdMgdl),
      );
    });
  });
}
