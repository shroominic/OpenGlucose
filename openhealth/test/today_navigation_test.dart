import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('navigation exposes truthful no-sensor supporting states', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('primaryNavigationBar')),
      findsOne,
    );
    expect(find.text('Today'), findsOneWidget);

    await tester.tap(
      _navigationDestination(
        Icons.view_timeline_outlined,
        Icons.view_timeline_rounded,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('timelineDestinationContent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todayState-noActiveSensor')),
      findsOneWidget,
    );

    await tester.tap(
      _navigationDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('trendsDestinationContent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('todayState-noActiveSensor')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('warmup and stale sensor states never become live tabs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final warmup = await _fixture(initialScenario: MockScenario.warmup);
    await warmup.controller.connect(warmup.driver.scenarioSensor);
    await tester.pumpWidget(warmup.app);
    await tester.pump();

    await tester.tap(
      _navigationDestination(
        Icons.view_timeline_outlined,
        Icons.view_timeline_rounded,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('todayState-warmup')),
      findsOneWidget,
    );
    expect(find.text('Recent glucose'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    warmup.controller.dispose();

    final stale = await _fixture(initialScenario: MockScenario.signalLoss);
    await stale.controller.connect(stale.driver.scenarioSensor);
    await tester.pumpWidget(stale.app);
    await tester.pump();

    await tester.tap(
      _navigationDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('todayState-stale')),
      findsOneWidget,
    );
    expect(find.text('Patterns'), findsNothing);
    expect(
      find.text(
        'The last glucose value is not live. Reconnect or wait for a '
        'fresh sensor update.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    stale.controller.dispose();
  });

  testWidgets('live demo tabs keep their sample-data disclosure', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);
    await fixture.controller.connect(fixture.driver.scenarioSensor);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.tap(
      _navigationDestination(
        Icons.view_timeline_outlined,
        Icons.view_timeline_rounded,
      ),
    );
    await tester.pump();

    expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);
    expect(find.text('Recent glucose'), findsOneWidget);

    await tester.tap(
      _navigationDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();
    expect(find.text('SAMPLE DATA — NOT FROM A SENSOR'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selected destination restores after a restart', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.tap(
      _navigationDestination(
        Icons.view_timeline_outlined,
        Icons.view_timeline_rounded,
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('timelineDestinationContent')),
      findsOneWidget,
    );

    await tester.restartAndRestore();
    expect(
      find.byKey(const ValueKey<String>('timelineDestinationContent')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact navigation handles 200 percent text at phone widths', (
    tester,
  ) async {
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final width in <double>[375, 390, 430]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: fixture.app,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width');
      await tester.tap(
        _navigationDestination(
          Icons.view_timeline_outlined,
          Icons.view_timeline_rounded,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'timeline width $width');
      await tester.tap(
        _navigationDestination(
          Icons.insights_outlined,
          Icons.insights_rounded,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'trends width $width');
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Trends stays usable on a live 375 pixel phone layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);
    await fixture.controller.connect(fixture.driver.scenarioSensor);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.tap(
      _navigationDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('trendsDestinationContent')),
      findsOneWidget,
    );
    expect(find.text('Trends'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wide navigation uses a rail and switches to Trends', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('primaryNavigationRail')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('primaryNavigationBar')),
      findsNothing,
    );
    await tester.tap(
      _railDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('trendsDestinationContent')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('navigation exposes named destinations through semantics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    final fixture = await _fixture();
    addTearDown(fixture.controller.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();

    expect(find.bySemanticsLabel('Primary navigation'), findsOneWidget);
    final navigation = find.byKey(
      const ValueKey<String>('primaryNavigationBar'),
    );
    expect(
      find.descendant(
        of: navigation,
        matching: find.bySemanticsLabel(RegExp('^Today')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: navigation,
        matching: find.bySemanticsLabel(RegExp('^Timeline')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: navigation,
        matching: find.bySemanticsLabel(RegExp('^Trends')),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Today content'), findsOneWidget);

    await tester.tap(
      _navigationDestination(Icons.insights_outlined, Icons.insights_rounded),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Trends content'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets(
    'stale timestamp hides Timeline and Trends during a stalled refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      var now = DateTime.now().toUtc();
      final fixture = await _deadlineFixture(
        now: now,
        sessionStart: now.subtract(const Duration(hours: 3)),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.app(
          clock: () => now,
          foregroundFreshnessInterval: const Duration(days: 1),
        ),
      );
      await tester.pump();
      await tester.tap(
        _navigationDestination(
          Icons.insights_outlined,
          Icons.insights_rounded,
        ),
      );
      await tester.pump();
      expect(find.text('Patterns'), findsOneWidget);

      final stalledRefresh = fixture.controller.ensureFreshData(force: true);
      await fixture.session.refreshStarted.future;
      expect(fixture.session.snapshotEvents, 0);

      now = now.add(kLiveReadingRefreshThreshold);
      await tester.pump(kLiveReadingRefreshThreshold);
      await tester.pump();

      expect(fixture.session.snapshotEvents, 0);
      expect(
        find.byKey(const ValueKey<String>('todayState-stale')),
        findsOneWidget,
      );
      final staleSemantics = tester.getSemantics(
        find.byKey(const ValueKey<String>('todayStateSemantics-stale')),
      );
      expect(staleSemantics.label, 'Live glucose is unavailable');
      expect(staleSemantics.flagsCollection.isLiveRegion, isTrue);
      expect(find.text('Patterns'), findsNothing);

      await tester.tap(
        _navigationDestination(
          Icons.view_timeline_outlined,
          Icons.view_timeline_rounded,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('todayState-stale')),
        findsOneWidget,
      );
      expect(find.text('Recent glucose'), findsNothing);

      fixture.session.completeRefresh();
      await stalledRefresh;
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sensor-life expiry hides Timeline and Trends without a snapshot event',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      var now = DateTime.now().toUtc();
      final fixture = await _deadlineFixture(
        now: now,
        sessionStart: now.subtract(
          kSensorLifeDuration - const Duration(minutes: 1),
        ),
        elapsedMinutes: kSensorLifeDuration.inMinutes - 1,
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.app(
          clock: () => now,
          foregroundFreshnessInterval: const Duration(days: 1),
        ),
      );
      await tester.pump();
      await tester.tap(
        _railDestination(Icons.insights_outlined, Icons.insights_rounded),
      );
      await tester.pump();
      expect(find.text('Patterns'), findsOneWidget);
      expect(fixture.session.snapshotEvents, 0);

      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(fixture.session.snapshotEvents, 0);
      expect(
        find.byKey(const ValueKey<String>('todayState-inactiveSensor')),
        findsOneWidget,
      );
      final inactiveSemantics = tester.getSemantics(
        find.byKey(
          const ValueKey<String>('todayStateSemantics-inactiveSensor'),
        ),
      );
      expect(inactiveSemantics.label, 'This sensor is no longer active');
      expect(inactiveSemantics.flagsCollection.isLiveRegion, isTrue);
      expect(find.text('Patterns'), findsNothing);

      await tester.tap(
        _railDestination(
          Icons.view_timeline_outlined,
          Icons.view_timeline_rounded,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('todayState-inactiveSensor')),
        findsOneWidget,
      );
      expect(find.text('Recent glucose'), findsNothing);

      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<_Fixture> _fixture({MockScenario? initialScenario}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
  });
  final preferences = await SharedPreferences.getInstance();
  final driver = DemoCgmDriver(
    initialScenario: initialScenario ?? MockScenario.activeNormal,
  );
  final controller = CgmAppController(preferences: preferences, driver: driver);
  await controller.initialize();
  final healthExport = HealthExportController(
    preferences: preferences,
    writesAllowed: false,
  )..initialize();
  return _Fixture(
    app: OpenGlucoseApp(
      controller: controller,
      healthExport: healthExport,
      preferences: preferences,
    ),
    controller: controller,
    driver: driver,
  );
}

class _Fixture {
  const _Fixture({
    required this.app,
    required this.controller,
    required this.driver,
  });

  final OpenGlucoseApp app;
  final CgmAppController controller;
  final DemoCgmDriver driver;
}

Future<_DeadlineFixture> _deadlineFixture({
  required DateTime now,
  required DateTime sessionStart,
  int? elapsedMinutes,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
  });
  final preferences = await SharedPreferences.getInstance();
  const sensor = DiscoveredSensor(
    driverId: 'controlled',
    deviceId: 'controlled-sensor',
    displayName: 'Controlled sensor',
    storageKey: 'controlled-sensor',
    rssi: -45,
    capabilities: CgmCapabilities(supportsHistory: true),
  );
  final reading = CgmReading(
    valueMgdl: 112,
    source: CgmRecordSource.vendor,
    sensorMinute: elapsedMinutes ?? 180,
    recordedAt: now,
  );
  final session = _StalledSession(
    CgmSessionSnapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Connected',
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: reading,
      history: <CgmReading>[reading],
      sessionInfo: CgmSessionInfo(
        sessionStart: sessionStart,
        elapsedMinutes: elapsedMinutes ?? 180,
      ),
    ),
  );
  final controller = CgmAppController(
    preferences: preferences,
    driver: _ControlledDriver(session),
  );
  await controller.initialize();
  await controller.connect(sensor);
  return _DeadlineFixture(controller: controller, session: session);
}

class _DeadlineFixture {
  _DeadlineFixture({required this.controller, required this.session});

  final CgmAppController controller;
  final _StalledSession session;

  Widget app({
    required DateTime Function() clock,
    required Duration foregroundFreshnessInterval,
  }) => MaterialApp(
    home: CgmHomePage(
      controller: controller,
      clock: clock,
      foregroundFreshnessInterval: foregroundFreshnessInterval,
    ),
  );

  Future<void> dispose() async {
    session.completeRefresh();
    controller.dispose();
    await session.close();
  }
}

class _ControlledDriver implements CgmDriver {
  _ControlledDriver(this.session);

  final _StalledSession session;

  @override
  String get driverId => 'controlled';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {}

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async => session;
}

class _StalledSession implements CgmSession {
  _StalledSession(this._snapshot);

  final CgmSessionSnapshot _snapshot;
  final Completer<void> _refreshCompleter = Completer<void>();
  final Completer<void> refreshStarted = Completer<void>();
  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);
  int snapshotEvents = 0;

  void completeRefresh() {
    if (!_refreshCompleter.isCompleted) {
      _refreshCompleter.complete();
    }
  }

  Future<void> close() => _snapshots.close();

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  DiscoveredSensor get sensor => _snapshot.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream.map((value) {
    snapshotEvents += 1;
    return value;
  });

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

  @override
  Future<void> refreshLiveData() {
    if (!refreshStarted.isCompleted) {
      refreshStarted.complete();
    }
    return _refreshCompleter.future;
  }

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}

Finder _navigationDestination(IconData unselected, IconData selected) {
  final navigation = find.byKey(const ValueKey<String>('primaryNavigationBar'));
  return _destinationIn(navigation, unselected, selected);
}

Finder _railDestination(IconData unselected, IconData selected) {
  final navigation = find.byKey(
    const ValueKey<String>('primaryNavigationRail'),
  );
  return _destinationIn(navigation, unselected, selected);
}

Finder _destinationIn(
  Finder navigation,
  IconData unselected,
  IconData selected,
) {
  final unselectedFinder = find.descendant(
    of: navigation,
    matching: find.byIcon(unselected),
  );
  return unselectedFinder.evaluate().isNotEmpty
      ? unselectedFinder
      : find.descendant(of: navigation, matching: find.byIcon(selected));
}
