// Guards the GS1 live surface against the counter-as-clock skew of #146.
//
// The `08` record counter is epoch-less: it advances 60 s per stored record, so
// anything that turns it into a wall clock reports the ingest position and calls
// it a clock. The session stopped inventing a timestamp for these records
// (`recordedAt: null`); these tests pin that decision at the two surfaces that
// showed the skew - the hero and the 12 h chart - so it cannot come back.
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/dashboard_chart.dart';
import 'package:openglucose/src/healthkit_export.dart';
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

/// The oldest stored position the examined GS1 reported.
const int _firstStoredIndex = 10067;

/// Readings shaped exactly as `CbioGlucoseSession` publishes them: the counter
/// is the position, and there is no wall-clock timestamp for it.
List<CgmReading> _gs1Readings(int count) => <CgmReading>[
  for (var index = 0; index < count; index++)
    CgmReading(
      valueMgdl: 100 + index.toDouble(),
      source: CgmRecordSource.raw,
      sensorMinute: _firstStoredIndex + index,
      recordedAt: null,
      rawValue: 55 + index,
      isDisplayProvisional: true,
    ),
];

CgmSessionSnapshot _snapshot(List<CgmReading> history) => CgmSessionSnapshot(
  stage: CgmSyncStage.ready,
  statusText: 'Live. Reading every minute.',
  sensor: _sensor,
  capabilities: _sensor.capabilities,
  latestReading: history.isEmpty ? null : history.last,
  history: history,
  historySync: CgmHistorySyncState(
    storedCount: history.length,
    totalAvailable: history.length,
    latestStoredOffset: history.last.sensorMinute,
  ),
  metadata: const <String, String>{
    cgmAutomaticReconnectAllowedMetadataKey: 'false',
    cbioPhaseMetadataKey: CbioSessionPhase.live,
  },
);

void main() {
  test('the counter-to-clock formula #146 removed is the on-screen skew', () {
    // From #146: the two captures are 448 stored records apart, and the
    // rendered "latest" moved 01:36 -> 09:04 while the phone clock did not
    // move at all.
    const counterA = 1780000000;
    const counterB = counterA + 448 * 60;
    DateTime asClock(int counter) =>
        DateTime.fromMillisecondsSinceEpoch(counter * 1000, isUtc: true);

    expect(448 * 60, 7 * 3600 + 28 * 60);
    expect(
      asClock(counterB).difference(asClock(counterA)),
      const Duration(hours: 7, minutes: 28),
      reason: 'this is the +7h28m the dashboard showed for a 448-record fetch',
    );
  });

  test('a GS1 reading has no wall clock for any surface to render', () {
    final latest = _gs1Readings(3).last;

    expect(latest.sensorMinute, _firstStoredIndex + 2);
    expect(latest.recordedAt, isNull);
    // The hero's time formatter must not fall back to one either.
    expect(readingTimeText(latest), '--');
    expect(readingTimeText(latest, now: DateTime.now()), '--');
    expect(clampedDisplayRecordedAt(latest.recordedAt), isNull);
  });

  testWidgets('the hero and the chart carry no counter-derived clock', (
    tester,
  ) async {
    final readings = _gs1Readings(4);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = CgmAppController(
      preferences: preferences,
      driver: _GuardDriver(() => _snapshot(readings)),
    );
    await controller.initialize();
    await controller.connect(_sensor);

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

    final hero = find.byKey(const ValueKey<String>('glucoseHeroCard'));
    expect(hero, findsOneWidget);
    expect(
      find.descendant(
        of: hero,
        matching: find.text('Raw sensor value'),
      ),
      findsOneWidget,
      reason: 'the raw value must not claim a glucose unit or sensor clock',
    );

    final heroText = tester
        .widgetList<Text>(
          find.descendant(of: hero, matching: find.byType(Text)),
        )
        .map((widget) => widget.data ?? '')
        .join(' | ');
    expect(
      RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(heroText),
      isFalse,
      reason:
          'a clock beside the live value can only come from the counter; '
          'hero rendered: $heroText',
    );
    expect(heroText, isNot(contains('Latest reading at')));

    // Raw data must not acquire glucose axes or a fabricated clock.
    expect(find.byType(CgmDashboardChart), findsNothing);
    expect(controller.visibleHistory, isNotEmpty);
    expect(
      controller.visibleHistory.every((reading) => reading.recordedAt == null),
      isTrue,
      reason: 'no timestamped reading may reach the chart on the GS1 lane',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });
}

final class _GuardDriver implements CgmDriver {
  _GuardDriver(this.build);

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
      _GuardSession(sensor: sensor, build: build);
}

final class _GuardSession implements CgmSession {
  _GuardSession({required this.sensor, required this.build})
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
