import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/health_state_store.dart';
import 'package:openglucose/src/sensor_connection_screen.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const DiscoveredSensor _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'AA:BB:CC:DD:EE:FF',
  displayName: 'Cbio / SiSensing candidate',
  storageKey: 'AA:BB:CC:DD:EE:FF',
  rssi: -60,
  capabilities: CbioGlucoseSession.capabilities,
);

List<CgmReading> _readings(int count) => <CgmReading>[
  for (var index = 0; index < count; index++)
    CgmReading(
      valueMgdl: 100 + index.toDouble(),
      source: CgmRecordSource.raw,
      sensorMinute: 9970 + index,
      recordedAt: DateTime.now().subtract(Duration(minutes: count - index)),
      rawValue: 55 + index,
      isDisplayProvisional: true,
    ),
];

CgmSessionSnapshot _snapshot({
  required CgmSyncStage stage,
  required String statusText,
  required List<CgmReading> history,
  required CgmHistorySyncState historySync,
}) => CgmSessionSnapshot(
  stage: stage,
  statusText: statusText,
  sensor: _sensor,
  capabilities: _sensor.capabilities,
  latestReading: history.isEmpty ? null : history.last,
  history: history,
  historySync: historySync,
  metadata: const <String, String>{
    cgmAutomaticReconnectAllowedMetadataKey: 'false',
    cbioPhaseMetadataKey: CbioSessionPhase.live,
  },
);

Future<(CgmAppController, SharedPreferences)> _controllerFor(
  CgmSessionSnapshot Function() build,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: _CbioSurfaceDriver(build),
  );
  await controller.initialize();
  await controller.connect(_sensor);
  return (controller, preferences);
}

Future<void> _pumpApp(
  WidgetTester tester,
  CgmAppController controller,
  SharedPreferences preferences,
) async {
  await tester.pumpWidget(
    OpenGlucoseApp(
      controller: controller,
      healthExport: HealthExportController(
        preferences: preferences,
        writesAllowed: false,
      )..initialize(),
      preferences: preferences,
    ),
  );
  await tester.pump();
}

void main() {
  test('the CBio unit marker is the provisional-unit notice', () {
    final snapshot = _snapshot(
      stage: CgmSyncStage.ready,
      statusText: 'Live. Reading every minute.',
      history: _readings(2),
      historySync: const CgmHistorySyncState(
        storedCount: 2,
        totalAvailable: 2,
        latestStoredOffset: 9971,
      ),
    );
    expect(
      provisionalReadingNoticeForSnapshot(snapshot),
      cbioProvisionalUnitNotice,
    );
    expect(
      historyProvisionalNoticeForSnapshot(snapshot),
      cbioProvisionalUnitNotice,
    );
    expect(stageLabelForSnapshot(snapshot), 'Live');
  });

  test('history progress wording reports the fetched count', () {
    expect(
      historySyncProgressText(
        const CgmHistorySyncState(
          inProgress: true,
          storedCount: 1200,
          totalAvailable: 1520,
        ),
      ),
      'Fetching sensor history: 1200 of 1520 records',
    );
  });

  test('the progress card copy comes from the closed phase, never the driver', () {
    // A syncing snapshot with no closed phase must fall through to the generic
    // stage label. The driver's status text is an internal, unbounded string.
    expect(
      cbioProgressTextForSnapshot(
        CgmSessionSnapshot(
          stage: CgmSyncStage.syncing,
          statusText: 'Listening for notifications',
          sensor: _sensor,
          capabilities: _sensor.capabilities,
        ),
      ),
      isNull,
    );
    expect(
      cbioProgressTextForSnapshot(
        CgmSessionSnapshot(
          stage: CgmSyncStage.syncing,
          statusText: 'anything at all',
          sensor: _sensor,
          capabilities: _sensor.capabilities,
          metadata: const <String, String>{
            cbioPhaseMetadataKey: CbioSessionPhase.authenticating,
          },
        ),
      ),
      'Checking the sensor link',
    );
    expect(
      cbioProgressTextForSnapshot(
        _snapshot(
          stage: CgmSyncStage.syncing,
          statusText: 'whatever',
          history: const <CgmReading>[],
          historySync: const CgmHistorySyncState(),
        ),
      ),
      isNot(contains('whatever')),
    );
  });

  testWidgets(
    'a syncing cbio session shows the bounded-sync stage label, not the driver text',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      final preferences = await SharedPreferences.getInstance();
      final controller = CgmAppController(
        preferences: preferences,
        driver: _ScanningCbioDriver(
          CgmSessionSnapshot(
            stage: CgmSyncStage.syncing,
            statusText: 'Listening for notifications',
            sensor: _sensor,
            capabilities: _sensor.capabilities,
          ),
        ),
        healthStateStore: PreferencesHealthStateStore(preferences),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SensorConnectionScreen(
                controller: controller,
                inline: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('connectButton-1')));
      for (var attempt = 0; attempt < 12; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      // The bounded-failure contract asserts this stage label while a session
      // has connected but not yet decoded anything.
      expect(find.text('Syncing sensor history'), findsOneWidget);
      expect(find.text('Listening for notifications'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('the dashboard shows the live value with its provisional unit', (
    tester,
  ) async {
    final readings = _readings(3);
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: readings,
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
          lastSyncAt: null,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    expect(
      find.byKey(const ValueKey<String>('provisionalReadingNotice')),
      findsOneWidget,
    );
    expect(find.text(cbioProvisionalUnitNotice), findsNWidgets(2));
    expect(find.text('3 readings'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('the dashboard shows fetched-history progress while ingesting', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.syncing,
        statusText: 'Fetching sensor history',
        history: _readings(1200),
        historySync: const CgmHistorySyncState(
          inProgress: true,
          storedCount: 1200,
          totalAvailable: 1520,
          latestStoredOffset: 11169,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    expect(
      find.text('Fetching sensor history: 1200 of 1520 records'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('historySyncProgress')),
      findsOneWidget,
    );
    expect(find.text('Fetching history'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('the cbio value renders as sensor raw / 10, without a unit', (
    tester,
  ) async {
    // The GS1 field is a raw counter that independent clients read as tenths
    // of a millimole. Until a reference measurement verifies the scale, the
    // dashboard must not present the number as mg/dL or mmol/L.
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: _readings(3),
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    final hero = find.byKey(const ValueKey<String>('glucoseHeroCard'));
    expect(hero, findsOneWidget);
    expect(
      find.descendant(of: hero, matching: find.text('5.7')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hero, matching: find.textContaining('mg/dL')),
      findsNothing,
    );
    expect(
      find.descendant(of: hero, matching: find.textContaining('mmol')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('the cbio dashboard reports stored count and sensor range', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      () => _snapshot(
        stage: CgmSyncStage.ready,
        statusText: 'Live. Reading every minute.',
        history: _readings(3),
        historySync: const CgmHistorySyncState(
          storedCount: 3,
          totalAvailable: 3,
          latestStoredOffset: 9972,
        ),
      ),
    );
    await _pumpApp(tester, controller, preferences);

    expect(
      find.byKey(const ValueKey<String>('cbioStoredRange')),
      findsOneWidget,
    );
    expect(
      find.text('3 readings stored · sensor minutes 9970–9972'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });
}

final class _CbioSurfaceDriver implements CgmDriver {
  _CbioSurfaceDriver(this.build);

  final CgmSessionSnapshot Function() build;

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _CbioSurfaceSession(sensor: sensor, build: build);
}

final class _CbioSurfaceSession implements CgmSession {
  _CbioSurfaceSession({required this.sensor, required this.build})
    : currentSnapshot = build();

  final CgmSessionSnapshot Function() build;

  @override
  final DiscoveredSensor sensor;

  @override
  final CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      const Stream<CgmSessionSnapshot>.empty();

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

/// A driver that advertises one CBio sensor, so the connection screen can be
/// driven through its real connect button and reach the progress card.
final class _ScanningCbioDriver implements CgmDriver {
  _ScanningCbioDriver(this.snapshot);

  final CgmSessionSnapshot snapshot;

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    yield _sensor;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _FrozenCbioSession(sensor: sensor, snapshot: snapshot);
}

/// A session frozen on one snapshot; it never emits anything else.
final class _FrozenCbioSession implements CgmSession {
  _FrozenCbioSession({required this.sensor, required this.snapshot})
    : currentSnapshot = snapshot;

  final CgmSessionSnapshot snapshot;

  @override
  final DiscoveredSensor sensor;

  @override
  CgmSessionSnapshot currentSnapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  Stream<CgmSessionSnapshot> get snapshots => const Stream.empty();

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
