// The GS1 surface reads the record index as a clock only when the session
// holds an anchor for it: the clock this app set on the sensor, confirmed
// against the sensor's own newest record stamp. Without one the surface says
// the clock is unsynced and names the ordering it can stand behind, instead of
// showing a placeholder time or a counter-derived one (#146).
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/app_language_controller.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/session_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cbio_snapshot_fixture.dart';

const DiscoveredSensor _sensor = DiscoveredSensor(
  driverId: 'cbio',
  deviceId: 'AA:BB:CC:DD:EE:FF',
  displayName: 'Cbio / SiSensing candidate',
  storageKey: 'AA:BB:CC:DD:EE:FF',
  rssi: -60,
  capabilities: CbioGlucoseSession.capabilities,
);

/// The newest stored position of the examined GS1 and the instant its own
/// stamp resolved to for the anchored cases.
const int _newestIndex = 10067;
final DateTime _anchorInstant = DateTime.utc(2026, 9, 18, 3, 5);

List<CgmReading> _readings({required bool anchored}) => <CgmReading>[
  for (var offset = 2; offset >= 0; offset -= 1)
    CgmReading(
      valueMgdl: (55 + offset) / 10,
      source: CgmRecordSource.raw,
      sensorMinute: _newestIndex - offset,
      recordedAt: anchored
          ? _anchorInstant.subtract(Duration(minutes: offset))
          : null,
      rawValue: 55 + offset,
      isDisplayProvisional: true,
    ),
];

CgmSessionSnapshot _snapshot({
  required bool anchored,
  bool covered = true,
  List<CgmReading>? history,
}) {
  final readings = history ?? _readings(anchored: anchored);
  final anchor = anchored
      ? CbioIndexTimeAnchor(
          anchorIndex: _newestIndex,
          coveredFromIndex: covered ? _newestIndex - 400 : _newestIndex - 1,
          anchorEpochSeconds: _anchorInstant.millisecondsSinceEpoch ~/ 1000,
          observedAt: _anchorInstant.add(const Duration(seconds: 4)),
          clockReferenceEpochSeconds:
              _anchorInstant.millisecondsSinceEpoch ~/ 1000 - 900,
        )
      : null;
  return CgmSessionSnapshot(
    stage: CgmSyncStage.ready,
    statusText: 'Live. Reading every minute.',
    sensor: _sensor,
    capabilities: _sensor.capabilities,
    latestReading: readings.last,
    history: readings,
    historySync: CgmHistorySyncState(
      storedCount: readings.length,
      totalAvailable: readings.length,
      latestStoredOffset: readings.last.sensorMinute,
    ),
    metadata: <String, String>{
      ...syntheticCbioFreshMetadata(_sensor, readings, anchor: anchor),
      cgmAutomaticReconnectAllowedMetadataKey: 'false',
      cbioPhaseMetadataKey: CbioSessionPhase.live,
      if (anchor != null) ...anchor.toMetadata(),
    },
  );
}

Future<(CgmAppController, SharedPreferences)> _controllerFor(
  CgmSessionSnapshot snapshot,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'openHealth.onboarding.completed': true,
  });
  final preferences = await SharedPreferences.getInstance();
  final controller = CgmAppController(
    preferences: preferences,
    driver: _AnchorDriver(snapshot),
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

String _heroText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('glucoseHeroCard')),
        matching: find.byType(Text),
      ),
    )
    .map((widget) => widget.data ?? '')
    .join(' | ');

void main() {
  test('Chinese clock details localize the uncertainty unit', () {
    expect(
      cbioClockStateText(
        _snapshot(anchored: true),
        language: AppLanguage.simplifiedChinese,
      ),
      contains('±1 分钟'),
    );
  });
  test('an anchored snapshot hands the surface a usable clock', () {
    final snapshot = _snapshot(anchored: true);
    final anchor = cbioAnchorForSnapshot(snapshot);

    expect(anchor, isNotNull);
    expect(anchor!.anchorIndex, _newestIndex);
    expect(
      anchor.timeForIndex(_newestIndex),
      _anchorInstant,
      reason: 'the newest position carries the stamp the sensor reported',
    );
    expect(
      cbioClockStateText(snapshot),
      'Sensor clock set by this app · latest '
      '${DateFormat('HH:mm').format(_anchorInstant.toLocal())} (±1 min)',
    );
  });

  test('an unanchored snapshot says the clock is unsynced', () {
    final snapshot = _snapshot(anchored: false);

    expect(cbioAnchorForSnapshot(snapshot), isNull);
    expect(
      cbioClockStateText(snapshot),
      'Sensor clock unsynced · ordered by sensor index, not by clock',
    );
    expect(
      RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(cbioClockStateText(snapshot)),
      isFalse,
    );
  });

  test('a position outside the anchored range claims no time', () {
    final snapshot = _snapshot(
      anchored: true,
      covered: false,
      history: _readings(anchored: true)
          .map(
            (reading) => CgmReading(
              valueMgdl: reading.valueMgdl,
              source: reading.source,
              sensorMinute: reading.sensorMinute,
              recordedAt: null,
              rawValue: reading.rawValue,
              isDisplayProvisional: true,
            ),
          )
          .toList(growable: false),
    );
    final anchor = cbioAnchorForSnapshot(snapshot)!;

    expect(anchor.coversIndex(_newestIndex), isTrue);
    expect(
      anchor.coversIndex(_newestIndex - 50),
      isFalse,
      reason: 'a hole ends the range the anchor may speak for',
    );
    expect(
      cbioClockStateText(snapshot),
      contains('no anchored time'),
      reason: 'the anchor exists but does not speak for the newest position',
    );
  });

  testWidgets('sensor details retain the anchored time in the device zone', (
    tester,
  ) async {
    final (controller, preferences) = await _controllerFor(
      _snapshot(anchored: true),
    );
    await _pumpApp(tester, controller, preferences);

    expect(find.byKey(const ValueKey('cbioClockState')), findsNothing);
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current sensor'));
    await tester.pumpAndSettle();
    final local = DateFormat('HH:mm').format(_anchorInstant.toLocal());
    expect(
      find.text(
        'Sensor clock set by this app · latest $local '
        '(±1 min)',
      ),
      findsOneWidget,
    );
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      expect(
        local,
        isNot(DateFormat('HH:mm').format(_anchorInstant)),
        reason: 'the device zone, not UTC, is what sensor details show',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets(
    'the hero never shows a placeholder clock for an unanchored GS1',
    (
      tester,
    ) async {
      final (controller, preferences) = await _controllerFor(
        _snapshot(anchored: false),
      );
      await _pumpApp(tester, controller, preferences);

      final heroText = _heroText(tester);
      expect(find.byKey(const ValueKey('cbioClockState')), findsNothing);
      expect(heroText, isNot(contains('--')));
      expect(RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(heroText), isFalse);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current sensor'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sensor clock unsynced · ordered by sensor index, not by clock',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.pump();
    },
  );
}

final class _AnchorDriver implements CgmDriver {
  _AnchorDriver(this.snapshot);

  final CgmSessionSnapshot snapshot;

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async =>
      _AnchorSession(sensor: sensor, currentSnapshot: snapshot);
}

final class _AnchorSession implements CgmSession {
  _AnchorSession({required this.sensor, required this.currentSnapshot});

  @override
  final DiscoveredSensor sensor;

  @override
  final CgmSessionSnapshot currentSnapshot;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      Stream<CgmSessionSnapshot>.value(currentSnapshot);

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  Future<void> initialize() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

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

  @override
  Future<void> disconnect() async {}
}
