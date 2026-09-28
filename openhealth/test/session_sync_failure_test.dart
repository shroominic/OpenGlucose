import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/sensor_connection_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desired product copy for a session that connected but never produced a
/// readable reading. Asserted as literals so any wording change is deliberate.
const _failureTitle = 'No reading from this sensor';
const _failureMessage =
    "This sensor didn't return a readable reading. Try again, or choose "
    'another sensor. Some sensor models are not supported yet.';

/// Longer than the bounded session deadline under test.
const _pastDeadline = Duration(seconds: 46);

void main() {
  const sensor = DiscoveredSensor(
    driverId: 'cbio',
    deviceId: 'synthetic-cbio',
    displayName: 'Synthetic sensor',
    storageKey: 'synthetic-cbio',
    rssi: -40,
    capabilities: CgmCapabilities(supportsDirectBle: true),
  );

  testWidgets('an undecodable frame followed by silence fails closed', (
    tester,
  ) async {
    final session = _StallingSession(sensor);
    final controller = await _pumpConnectionScreen(tester, sensor, session);
    await _connectFirstResult(tester);

    // The driver saw a five-byte reply that the offline parser rejected and
    // then emitted nothing else: exactly the field failure.
    session.reportUndecodableFrame();
    await tester.pump();
    expect(find.text('Syncing sensor history'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(controller.snapshot?.stage, CgmSyncStage.syncing);

    await tester.pump(_pastDeadline);
    await tester.pump();

    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(find.text('Syncing sensor history'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_failureTitle), findsOneWidget);
    expect(find.text(_failureMessage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('connectionRetryButton')),
      findsOneWidget,
    );
    expect(find.text('Choose another sensor'), findsOneWidget);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets(
    'a session that reports readable data before the deadline lives',
    (
      tester,
    ) async {
      final session = _StallingSession(sensor);
      final controller = await _pumpConnectionScreen(tester, sensor, session);
      await _connectFirstResult(tester);

      session.reportReading();
      await tester.pump();
      expect(controller.snapshot?.stage, CgmSyncStage.ready);

      await tester.pump(_pastDeadline);
      await tester.pump();
      expect(controller.snapshot?.stage, CgmSyncStage.ready);
      expect(find.text(_failureTitle), findsNothing);

      await _disposeConnectionScreen(tester, controller);
    },
  );

  testWidgets('retrying after the bounded failure starts a fresh window', (
    tester,
  ) async {
    final session = _StallingSession(sensor);
    final controller = await _pumpConnectionScreen(tester, sensor, session);
    await _connectFirstResult(tester);
    session.reportUndecodableFrame();
    await tester.pump();
    await tester.pump(_pastDeadline);
    await tester.pump();
    expect(controller.snapshot?.stage, CgmSyncStage.error);

    await tester.tap(
      find.byKey(const ValueKey<String>('connectionRetryButton')),
    );
    // Retrying tears the first session down before it reconnects. That
    // teardown awaits stream subscription cancellation, whose completion has
    // to come from the real event loop rather than the widget fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.snapshot?.stage, isNot(CgmSyncStage.error));
    expect(find.text(_failureTitle), findsNothing);
    expect(session.connectCalls, 2);

    await tester.pump(_pastDeadline);
    await tester.pump();
    expect(controller.snapshot?.stage, CgmSyncStage.error);
    expect(find.text(_failureTitle), findsOneWidget);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('a readable frame arriving later still recovers the session', (
    tester,
  ) async {
    final session = _StallingSession(sensor);
    final controller = await _pumpConnectionScreen(tester, sensor, session);
    await _connectFirstResult(tester);
    session.reportUndecodableFrame();
    await tester.pump(_pastDeadline);
    await tester.pump();
    expect(controller.snapshot?.stage, CgmSyncStage.error);

    session.reportReading();
    await tester.pump();
    expect(controller.snapshot?.stage, CgmSyncStage.ready);
    expect(find.text(_failureTitle), findsNothing);

    await _disposeConnectionScreen(tester, controller);
  });

  testWidgets('drivers with their own long waits are not bounded', (
    tester,
  ) async {
    for (final metadata in <Map<String, String>>[
      const <String, String>{'cgm.libre2.phase': 'awaitingPacket'},
    ]) {
      final session = _StallingSession(sensor, syncingMetadata: metadata);
      final controller = await _pumpConnectionScreen(tester, sensor, session);
      await _connectFirstResult(tester);
      session.reportUndecodableFrame();
      await tester.pump();

      await tester.pump(_pastDeadline);
      await tester.pump();
      expect(controller.snapshot?.stage, CgmSyncStage.syncing);
      expect(find.text(_failureTitle), findsNothing);

      await _disposeConnectionScreen(tester, controller);
      await tester.pump();
    }

    final historySession = _StallingSession(
      sensor,
      syncingHistoryInProgress: true,
    );
    final historyController = await _pumpConnectionScreen(
      tester,
      sensor,
      historySession,
    );
    await _connectFirstResult(tester);
    historySession.reportUndecodableFrame();
    await tester.pump();
    await tester.pump(_pastDeadline);
    await tester.pump();
    expect(historyController.snapshot?.stage, CgmSyncStage.syncing);

    await _disposeConnectionScreen(tester, historyController);
  });
}

Future<CgmAppController> _pumpConnectionScreen(
  WidgetTester tester,
  DiscoveredSensor sensor,
  _StallingSession session,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: _StallingDriver(sensor, session),
    healthStateStore: PreferencesHealthStateStore(preferences),
  );
  await controller.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SensorConnectionScreen(controller: controller, inline: true),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> _connectFirstResult(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('connectButton-1')));
  for (var attempt = 0; attempt < 12; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _disposeConnectionScreen(
  WidgetTester tester,
  CgmAppController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

final class _StallingDriver implements CgmDriver {
  _StallingDriver(this.sensor, this.session);

  final DiscoveredSensor sensor;
  final _StallingSession session;

  @override
  String get driverId => sensor.driverId;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    yield sensor;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    session.connectCalls += 1;
    return session;
  }
}

/// A connected session that stays in the syncing stage forever, mirroring a
/// sensor whose frames never decode into a reading.
final class _StallingSession implements CgmSession {
  _StallingSession(
    this.sensor, {
    Map<String, String> syncingMetadata = const <String, String>{},
    bool syncingHistoryInProgress = false,
  }) : _syncingMetadata = syncingMetadata,
       _syncingHistoryInProgress = syncingHistoryInProgress,
       currentSnapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting',
         sensor: sensor,
         capabilities: sensor.capabilities,
       );

  final Map<String, String> _syncingMetadata;
  final bool _syncingHistoryInProgress;
  final StreamController<CgmSessionSnapshot> _snapshots =
      StreamController<CgmSessionSnapshot>.broadcast(sync: true);

  int connectCalls = 0;

  @override
  final DiscoveredSensor sensor;

  @override
  CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  void reportUndecodableFrame() {
    _emit(
      currentSnapshot.copyWith(
        stage: CgmSyncStage.syncing,
        statusText: 'Listening for notifications',
        historySync: _syncingHistoryInProgress
            ? const CgmHistorySyncState(
                inProgress: true,
                totalAvailable: 100,
                storedCount: 3,
              )
            : const CgmHistorySyncState(),
      ),
    );
  }

  void reportReading() {
    final reading = CgmReading(
      valueMgdl: 112,
      sensorMinute: 1,
      source: CgmRecordSource.standard,
      recordedAt: DateTime.utc(2026, 9, 17, 12),
    );
    _emit(
      currentSnapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Receiving sensor readings',
        latestReading: reading,
        history: <CgmReading>[reading],
      ),
    );
  }

  void _emit(CgmSessionSnapshot snapshot) {
    currentSnapshot = CgmSessionSnapshot(
      stage: snapshot.stage,
      statusText: snapshot.statusText,
      sensor: snapshot.sensor,
      capabilities: snapshot.capabilities,
      latestReading: snapshot.latestReading,
      history: snapshot.history,
      historySync: snapshot.historySync,
      metadata: <String, String>{
        ...snapshot.metadata,
        if (snapshot.stage == CgmSyncStage.syncing) ..._syncingMetadata,
      },
      lastError: snapshot.lastError,
    );
    if (!_snapshots.isClosed) {
      _snapshots.add(currentSnapshot);
    }
  }

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
  Future<void> refreshLiveData() async {}

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
