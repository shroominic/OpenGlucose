import 'dart:async';
import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';

import 'mock_scenarios.dart';

/// In-memory CGM driver used by the OG_DEMO harness so the app can be exercised
/// in the iOS simulator (no Bluetooth) and in widget tests.
///
/// The driver is **scenario-driven**: it builds snapshots from
/// [MockScenarioCatalog] for a selectable [MockScenario]. The default scenario
/// is [MockScenario.activeNormal], which preserves the original demo behaviour.
/// The live scenario can be swapped at runtime via
/// [DemoCgmSession.applyScenario] (wired to the Developer-tab picker).
class DemoCgmDriver implements CgmDriver {
  DemoCgmDriver({
    MockScenario initialScenario = MockScenario.activeNormal,
    DateTime Function()? clock,
  }) : _scenario = initialScenario,
       _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  MockScenario _scenario;

  /// The active session, if connected. Exposed so the app controller can swap
  /// the live scenario without reconnecting.
  DemoCgmSession? _session;

  /// The currently selected scenario (initial define or last runtime switch).
  MockScenario get scenario => _session?.scenario ?? _scenario;

  /// The sensor this driver advertises, for callers that need to (re)connect
  /// without first running a scan.
  DiscoveredSensor get scenarioSensor => MockScenarioCatalog.sensor;

  @override
  String get driverId => 'demo-aidex';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    yield MockScenarioCatalog.sensor;
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    final session = DemoCgmSession(
      sensor: sensor,
      scenario: _scenario,
      clock: _clock,
    );
    _session = session;
    return session;
  }

  /// Swaps the live scenario on the active session (if any) and remembers it
  /// as the default for future connections. Returns the connected session, or
  /// null if not connected.
  DemoCgmSession? applyScenario(MockScenario scenario) {
    _scenario = scenario;
    final session = _session;
    if (session != null && !session.isClosed) {
      session.applyScenario(scenario);
      return session;
    }
    return null;
  }
}

class DemoCgmSession implements CgmSession {
  DemoCgmSession({
    required this.sensor,
    required MockScenario scenario,
    required DateTime Function() clock,
  }) : _scenario = scenario,
       _clock = clock,
       _catalog = MockScenarioCatalog(clock: clock) {
    _applyScenarioInternal(scenario, announce: false);
    _log(CgmLogLevel.info, 'Demo session initialized (${scenario.label})');
  }

  @override
  final DiscoveredSensor sensor;

  final DateTime Function() _clock;
  final MockScenarioCatalog _catalog;
  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();

  MockScenario _scenario;
  late CgmSessionSnapshot _snapshot;
  late List<CgmReading> _history;
  late List<CgmCalibrationEntry> _calibrations;
  late List<CgmDiagnosticItem> _diagnostics;
  bool _closed = false;

  /// The scenario currently driving this session.
  MockScenario get scenario => _scenario;

  bool get isClosed => _closed;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  /// Rebuilds the session from [scenario] and emits the new snapshot so the UI
  /// switches live without a reconnect. Gated behind OG_DEMO by the caller.
  void applyScenario(MockScenario scenario) {
    _ensureOpen();
    _applyScenarioInternal(scenario, announce: true);
    _log(CgmLogLevel.info, 'Demo scenario switched to ${scenario.label}');
  }

  void _applyScenarioInternal(MockScenario scenario, {required bool announce}) {
    _scenario = scenario;
    final snapshot = _catalog.buildSnapshot(scenario);
    _history = snapshot.history;
    _calibrations = snapshot.calibrations;
    _diagnostics = snapshot.diagnostics;
    if (announce) {
      _emitSnapshot(snapshot);
    } else {
      _snapshot = snapshot;
    }
  }

  @override
  Future<void> refresh() async {
    _ensureOpen();
    // Frozen/error lifecycle scenarios must stay authoritative. In particular,
    // freshness polling must not turn stale, expired, or disconnected demo
    // readings into new glucose values.
    if (!_scenario.supportsLiveRefresh) {
      _emitSnapshot(_snapshot);
      return;
    }
    final latestTime = _clock();
    final sessionStart = _snapshot.sessionInfo.sessionStart ?? latestTime;
    final sensorMinute = latestTime.difference(sessionStart).inMinutes;
    // Continue around the last known value so the live tick matches the
    // scenario's glucose band (high stays high, low stays low, etc.).
    final base = _history.last.valueMgdl;
    final latest = CgmReading(
      valueMgdl: base + (math.sin(sensorMinute / 11) * 6),
      source: CgmRecordSource.broadcast,
      sensorMinute: sensorMinute,
      recordedAt: latestTime,
      qualifier: 1,
    );
    _history =
        <CgmReading>[
          ..._history.where((reading) => reading.sensorMinute != sensorMinute),
          latest,
        ]..sort(
          (left, right) =>
              (left.sensorMinute ?? 0).compareTo(right.sensorMinute ?? 0),
        );
    _emitSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Demo reading refreshed',
        latestReading: latest,
        history: _history,
        historySync: _snapshot.historySync.copyWith(lastSyncAt: latestTime),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _history.length.toString(),
        },
      ),
    );
    _log(CgmLogLevel.info, 'Demo refresh completed');
  }

  @override
  Future<void> refreshLiveData() => refresh();

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    _ensureOpen();
    final rawHistory = includeRawHistory
        ? _history
              .map((reading) => reading.copyWith(source: CgmRecordSource.raw))
              .toList(growable: false)
        : _snapshot.rawHistory;
    _emitSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Demo history synced',
        history: _history,
        rawHistory: rawHistory,
        latestReading: _history.isEmpty ? null : _history.last,
        historySync: _snapshot.historySync.copyWith(
          inProgress: false,
          totalAvailable: _history.length,
          storedCount: _history.length,
          latestStoredOffset: _history.isEmpty
              ? null
              : _history.last.sensorMinute,
          lastSyncAt: _clock(),
        ),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _history.length.toString(),
        },
      ),
    );
    _log(CgmLogLevel.info, 'Demo history sync complete');
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async {
    _ensureOpen();
    _emitSnapshot(_snapshot.copyWith(calibrations: _calibrations));
    _log(CgmLogLevel.debug, 'Loaded ${_calibrations.length} demo calibrations');
    return _calibrations;
  }

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {
    _ensureOpen();
    _calibrations = <CgmCalibrationEntry>[
      ..._calibrations,
      CgmCalibrationEntry(
        index: _calibrations.length + 1,
        glucoseMgdl: glucoseMgdl,
        sensorMinute: sensorMinute,
        recordedAt: recordedAt ?? _clock(),
        payloadHex:
            '${glucoseMgdl.toRadixString(16).padLeft(4, '0')}${(sensorMinute ?? 0).toRadixString(16).padLeft(4, '0')}',
      ),
    ];
    _emitSnapshot(_snapshot.copyWith(calibrations: _calibrations));
    _log(CgmLogLevel.info, 'Demo calibration submitted');
  }

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async {
    _ensureOpen();
    _emitSnapshot(_snapshot.copyWith(diagnostics: _diagnostics));
    _log(CgmLogLevel.debug, 'Demo diagnostics refreshed');
    return _diagnostics;
  }

  @override
  Future<void> disconnect() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _snapshotController.close();
    await _logController.close();
  }

  void _emitSnapshot(CgmSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _log(CgmLogLevel level, String message) {
    if (_logController.isClosed) {
      return;
    }
    _logController.add(
      CgmLogEntry(timestamp: _clock(), level: level, message: message),
    );
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Demo session is disconnected.');
    }
  }
}

extension on MockScenario {
  bool get supportsLiveRefresh => switch (this) {
    MockScenario.activeNormal ||
    MockScenario.activeHigh ||
    MockScenario.activeLow ||
    MockScenario.rapidRise ||
    MockScenario.rapidFall ||
    MockScenario.expiringSoon ||
    MockScenario.multiSensorHistory => true,
    MockScenario.warmup ||
    MockScenario.expired ||
    MockScenario.signalLoss ||
    MockScenario.disconnected ||
    MockScenario.error => false,
  };
}
