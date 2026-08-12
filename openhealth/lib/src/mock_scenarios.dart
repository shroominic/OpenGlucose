import 'dart:math' as math;

import 'package:cgm_core/cgm_core.dart';

import 'session_presentation.dart';

/// Selectable mock sensor scenarios for the OG_DEMO harness.
///
/// Each scenario maps to a fully-formed [CgmSessionSnapshot] (via
/// [MockScenarioCatalog.buildSnapshot]) so the dashboard renders that exact
/// lifecycle / alert state in the iOS simulator without any real BLE. The
/// mapping is pure and clock-injectable so it can be unit tested.
enum MockScenario {
  /// Sensor inside its ~1h warmup window: no readings yet, countdown showing.
  warmup,

  /// Healthy in-range glucose, gently oscillating. This is the default and
  /// preserves the original demo behaviour.
  activeNormal,

  /// Sustained high glucose that should trip a high alert.
  activeHigh,

  /// Sustained low glucose that should trip a low alert.
  activeLow,

  /// Glucose climbing quickly (rapid-rise trend arrow).
  rapidRise,

  /// Glucose dropping quickly (rapid-fall trend arrow).
  rapidFall,

  /// Near the end of the 15-day sensor life (hours left).
  expiringSoon,

  /// Sensor expired / session stopped — offboarding state.
  expired,

  /// Connected but the sensor signal is currently lost (stale readings).
  signalLoss,

  /// Disconnected with previously-known data (reconnecting state).
  disconnected,

  /// Current sensor plus history carried over from a previous sensor.
  multiSensorHistory,

  /// Hard error state with no usable data.
  error
  ;

  /// Stable identifier used for `--dart-define=OG_SCENARIO=<id>` and as the
  /// persisted runtime selection.
  String get id => name;

  /// Human-friendly label for the Developer-tab picker.
  String get label => switch (this) {
    MockScenario.warmup => 'Warmup',
    MockScenario.activeNormal => 'Active — normal',
    MockScenario.activeHigh => 'Active — high (alert)',
    MockScenario.activeLow => 'Active — low (alert)',
    MockScenario.rapidRise => 'Rapid rise',
    MockScenario.rapidFall => 'Rapid fall',
    MockScenario.expiringSoon => 'Expiring soon',
    MockScenario.expired => 'Expired',
    MockScenario.signalLoss => 'Signal loss',
    MockScenario.disconnected => 'Disconnected',
    MockScenario.multiSensorHistory => 'Multi-sensor history',
    MockScenario.error => 'Error',
  };

  /// One-line description shown under the picker.
  String get description => switch (this) {
    MockScenario.warmup => 'Inside the ~1h warmup window — no readings yet.',
    MockScenario.activeNormal => 'Healthy in-range glucose, gently waving.',
    MockScenario.activeHigh => 'Sustained high glucose — trips a high alert.',
    MockScenario.activeLow => 'Sustained low glucose — trips a low alert.',
    MockScenario.rapidRise => 'Glucose climbing fast (rising trend).',
    MockScenario.rapidFall => 'Glucose dropping fast (falling trend).',
    MockScenario.expiringSoon => 'A few hours left on the 15-day sensor.',
    MockScenario.expired => 'Sensor expired — offboarding state.',
    MockScenario.signalLoss => 'Connected but signal lost — readings stale.',
    MockScenario.disconnected => 'Disconnected with last-known data.',
    MockScenario.multiSensorHistory =>
      'Current sensor + carried-over previous-sensor history.',
    MockScenario.error => 'Hard error with no usable data.',
  };

  /// Resolves a scenario id (e.g. from a dart-define) to a [MockScenario],
  /// falling back to [activeNormal] for empty/unknown values.
  static MockScenario fromId(String? id) {
    if (id == null || id.isEmpty) {
      return MockScenario.activeNormal;
    }
    for (final scenario in MockScenario.values) {
      if (scenario.id == id) {
        return scenario;
      }
    }
    return MockScenario.activeNormal;
  }
}

/// Glucose alert thresholds (mg/dL) the active scenarios are designed to cross.
/// These mirror typical CGM defaults; the high/low scenarios sit clearly
/// outside this band so any alert layer built on the snapshot trips.
const double kMockHighThresholdMgdl = 180;
const double kMockLowThresholdMgdl = 70;

/// Builds [CgmSessionSnapshot]s for each [MockScenario].
///
/// Pure and clock-injectable: pass a fixed `clock` in tests to get
/// deterministic snapshots.
class MockScenarioCatalog {
  MockScenarioCatalog({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const _warmupMinutes = 60;
  // Single source of truth lives in session_presentation.dart (kSensorLife
  // Duration) so the mock harness and the lifecycle UI never drift.
  static const _sensorLife = kSensorLifeDuration;

  /// The simulated sensor advertised by the demo driver.
  static const DiscoveredSensor sensor = DiscoveredSensor(
    driverId: 'demo-aidex',
    deviceId: 'demo-aidex-07A12',
    displayName: 'AiDEX Demo 07A12',
    storageKey: 'demo:07A12',
    rssi: -46,
    capabilities: CgmCapabilities(
      supportsDirectBle: true,
      supportsVendorPairing: true,
      supportsAdvertisementGlucose: true,
      supportsHistory: true,
      supportsRawHistory: true,
      supportsCalibration: true,
      supportsDiagnostics: true,
      supportsCommunicationInterval: true,
    ),
    advertisement: CgmAdvertisement(
      payloadHex: '5900DEMO0712',
      counter: 12,
      phaseHex: '21',
      glucoseTriplet: <int>[122, 124, 127],
      qualifiers: <int>[1, 0, 0],
      displayValueMgdl: 124,
    ),
    notes: 'Demo transport for simulator, screenshots, and widget tests.',
    metadata: <String, String>{'serial': '07A12', 'mode': 'demo'},
  );

  /// Builds the full snapshot for [scenario] as of "now".
  CgmSessionSnapshot buildSnapshot(MockScenario scenario) {
    return switch (scenario) {
      MockScenario.warmup => _warmup(),
      MockScenario.activeNormal => _active(scenario, _normalShape),
      MockScenario.activeHigh => _active(scenario, _highShape),
      MockScenario.activeLow => _active(scenario, _lowShape),
      // Fewer samples so the per-5-minute slope is steep enough that the
      // dashboard's trend arrow reads as a genuine rapid rise/fall.
      MockScenario.rapidRise => _active(
        scenario,
        _rapidRiseShape,
        sampleCount: 18,
      ),
      MockScenario.rapidFall => _active(
        scenario,
        _rapidFallShape,
        sampleCount: 18,
      ),
      MockScenario.expiringSoon => _expiringSoon(),
      MockScenario.expired => _expired(),
      MockScenario.signalLoss => _signalLoss(),
      MockScenario.disconnected => _disconnected(),
      MockScenario.multiSensorHistory => _multiSensorHistory(),
      MockScenario.error => _error(),
    };
  }

  // --- Glucose shape functions: index -> mg/dL ------------------------------

  double _normalShape(int index, int count) =>
      118 + (math.sin(index / 4) * 16) + ((index % 5) - 2);

  double _highShape(int index, int count) =>
      232 + (math.sin(index / 5) * 14) + ((index % 4) - 1.5);

  double _lowShape(int index, int count) =>
      58 + (math.sin(index / 6) * 6) + ((index % 3) - 1);

  double _rapidRiseShape(int index, int count) =>
      // Climb steadily from ~80 to ~230 across the window (monotonic so the
      // last-step delta clearly reads as rising).
      80 + (index / (count - 1)) * 150 + (math.sin(index / 5) * 2);

  double _rapidFallShape(int index, int count) =>
      // Drop steadily from ~240 to ~70 across the window.
      240 - (index / (count - 1)) * 170 + (math.sin(index / 5) * 2);

  // --- Scenario builders ----------------------------------------------------

  /// Active session: a populated, in-progress 15-day sensor whose readings
  /// follow [shape]. Used for the normal/high/low/rapid scenarios.
  CgmSessionSnapshot _active(
    MockScenario scenario,
    double Function(int index, int count) shape, {
    int sampleCount = 48,
    Duration sessionAge = const Duration(hours: 16),
  }) {
    final now = _clock();
    final sessionStart = now.subtract(sessionAge);
    final history = _buildHistory(
      now: now,
      sessionStart: sessionStart,
      count: sampleCount,
      shape: shape,
    );
    return _readySnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      statusText: 'Demo session ready (${scenario.label})',
      scenario: scenario,
    );
  }

  CgmSessionSnapshot _warmup() {
    final now = _clock();
    // Started 20 minutes ago, still ~40 minutes of warmup left, no readings.
    final sessionStart = now.subtract(const Duration(minutes: 20));
    return _baseSnapshot(
      now: now,
      sessionStart: sessionStart,
      history: const <CgmReading>[],
      stage: CgmSyncStage.ready,
      statusText: 'Warming up',
      health: const CgmHealthSnapshot(
        statusText: 'Sensor warming up',
        warningFlagsHex: '0x00',
        sensorCheckHex: '0100',
      ),
      scenario: MockScenario.warmup,
      latestReading: null,
    );
  }

  CgmSessionSnapshot _expiringSoon() {
    final now = _clock();
    // ~3 hours of life left out of 15 days.
    final sessionStart = now.subtract(
      _sensorLife - const Duration(hours: 3),
    );
    final history = _buildHistory(
      now: now,
      sessionStart: sessionStart,
      count: 48,
      shape: _normalShape,
    );
    return _readySnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      statusText: 'Sensor nearing end of life',
      scenario: MockScenario.expiringSoon,
      health: const CgmHealthSnapshot(
        statusText: 'Sensor expiring soon',
        warningFlagsHex: '0x02',
        sensorCheckHex: '0100',
      ),
    );
  }

  CgmSessionSnapshot _expired() {
    final now = _clock();
    // Started just over 15 days ago: expired / session stopped.
    final sessionStart = now.subtract(
      _sensorLife + const Duration(hours: 2),
    );
    // Last readings stop ~2h ago, when the sensor expired.
    final lastReadingAt = now.subtract(const Duration(hours: 2));
    final history = _buildHistory(
      now: lastReadingAt,
      sessionStart: sessionStart,
      count: 48,
      shape: _normalShape,
    );
    final base = _baseSnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      stage: CgmSyncStage.ready,
      statusText: 'Sensor expired — replace sensor',
      scenario: MockScenario.expired,
      health: const CgmHealthSnapshot(
        statusText: 'Sensor expired',
        expired: true,
        warningFlagsHex: '0x04',
        sensorCheckHex: '0101',
      ),
    );
    return base.copyWith(
      sessionInfo: base.sessionInfo.copyWith(sessionStopped: true),
    );
  }

  CgmSessionSnapshot _signalLoss() {
    final now = _clock();
    final sessionStart = now.subtract(const Duration(hours: 16));
    // Readings froze ~12 minutes ago (signal lost), session still "connected".
    final lastReadingAt = now.subtract(const Duration(minutes: 12));
    final history = _buildHistory(
      now: lastReadingAt,
      sessionStart: sessionStart,
      count: 48,
      shape: _normalShape,
    );
    return _baseSnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      stage: CgmSyncStage.ready,
      statusText: 'Signal lost — waiting for sensor',
      scenario: MockScenario.signalLoss,
      health: const CgmHealthSnapshot(
        statusText: 'Signal lost',
        signalLost: true,
        warningFlagsHex: '0x08',
        sensorCheckHex: '0100',
      ),
    );
  }

  CgmSessionSnapshot _disconnected() {
    final now = _clock();
    final sessionStart = now.subtract(const Duration(hours: 16));
    final lastReadingAt = now.subtract(const Duration(minutes: 4));
    final history = _buildHistory(
      now: lastReadingAt,
      sessionStart: sessionStart,
      count: 48,
      shape: _normalShape,
    );
    return _baseSnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      stage: CgmSyncStage.disconnected,
      statusText: 'Disconnected',
      scenario: MockScenario.disconnected,
      health: const CgmHealthSnapshot(
        statusText: 'Disconnected',
        warningFlagsHex: '0x00',
        sensorCheckHex: '0100',
      ),
    );
  }

  CgmSessionSnapshot _multiSensorHistory() {
    final now = _clock();
    final sessionStart = now.subtract(const Duration(hours: 30));
    // Current-sensor readings for the last 30h.
    final current = _buildHistory(
      now: now,
      sessionStart: sessionStart,
      count: 60,
      shape: _normalShape,
    );
    // Previous sensor: a separate older block, ~5-7 days ago, sourced as
    // vendor history carried over. Negative sensorMinute marks it as belonging
    // to the prior session so the UI can still render a continuous trend.
    final previousStart = now.subtract(const Duration(days: 7));
    final previous = List<CgmReading>.generate(48, (index) {
      final recordedAt = previousStart.add(Duration(minutes: index * 10));
      final value = 110 + (math.sin(index / 5) * 20) + ((index % 4) - 1.5);
      return CgmReading(
        valueMgdl: value,
        source: CgmRecordSource.vendor,
        sensorMinute: -(48 - index) * 10,
        recordedAt: recordedAt,
        rawValue: value.round(),
        qualifier: 1,
      );
    });
    final history = <CgmReading>[...previous, ...current];
    final base = _readySnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      statusText: 'Demo session ready (multi-sensor history)',
      scenario: MockScenario.multiSensorHistory,
    );
    return base.copyWith(
      metadata: <String, String>{
        ...base.metadata,
        'previousSensorSerial': '06F90',
        'previousSensorReadings': previous.length.toString(),
      },
    );
  }

  CgmSessionSnapshot _error() {
    return CgmSessionSnapshot(
      stage: CgmSyncStage.error,
      statusText: 'Sensor error',
      sensor: sensor,
      capabilities: sensor.capabilities,
      lastAdvertisement: sensor.advertisement,
      diagnostics: _buildDiagnostics(),
      sessionInfo: const CgmSessionInfo(
        manufacturer: 'MicroTech Medical',
        model: 'AiDEX X',
        serial: '07A12',
        firmware: '1.9.7-demo',
        warmupMinutes: _warmupMinutes,
      ),
      health: const CgmHealthSnapshot(
        statusText: 'Sensor malfunction',
        error: true,
        malfunction: true,
        warningFlagsHex: '0x80',
        sensorCheckHex: '0111',
      ),
      metadata: <String, String>{
        'deviceId': sensor.deviceId,
        'serial': '07A12',
        'mode': 'demo',
        'driverId': sensor.driverId,
        'scenario': MockScenario.error.id,
        'historyCount': '0',
      },
      lastError: 'Demo: simulated sensor error (E-204 communication failure)',
    );
  }

  // --- Shared builders ------------------------------------------------------

  List<CgmReading> _buildHistory({
    required DateTime now,
    required DateTime sessionStart,
    required int count,
    required double Function(int index, int count) shape,
  }) {
    return List<CgmReading>.generate(count, (index) {
      final recordedAt = now.subtract(
        Duration(minutes: (count - 1 - index) * 5),
      );
      final sensorMinute = recordedAt.difference(sessionStart).inMinutes;
      final value = shape(index, count);
      return CgmReading(
        valueMgdl: value,
        source: index == count - 1
            ? CgmRecordSource.broadcast
            : CgmRecordSource.vendor,
        sensorMinute: sensorMinute,
        recordedAt: recordedAt,
        rawValue: value.round(),
        qualifier: 1,
      );
    });
  }

  /// A "ready" active snapshot with history, calibrations, and full session
  /// info. Used by the active/expiring/multi-sensor scenarios.
  CgmSessionSnapshot _readySnapshot({
    required DateTime now,
    required DateTime sessionStart,
    required List<CgmReading> history,
    required String statusText,
    required MockScenario scenario,
    CgmHealthSnapshot health = const CgmHealthSnapshot(
      statusText: 'Sensor active',
      warningFlagsHex: '0x00',
      sensorCheckHex: '0100',
    ),
  }) {
    return _baseSnapshot(
      now: now,
      sessionStart: sessionStart,
      history: history,
      stage: CgmSyncStage.ready,
      statusText: statusText,
      scenario: scenario,
      health: health,
    );
  }

  CgmSessionSnapshot _baseSnapshot({
    required DateTime now,
    required DateTime sessionStart,
    required List<CgmReading> history,
    required CgmSyncStage stage,
    required String statusText,
    required MockScenario scenario,
    required CgmHealthSnapshot health,
    CgmReading? latestReading = _unsetReading,
  }) {
    final resolvedLatest = identical(latestReading, _unsetReading)
        ? (history.isEmpty ? null : history.last)
        : latestReading;
    final calibrations = history.length > 20
        ? <CgmCalibrationEntry>[
            CgmCalibrationEntry(
              index: 1,
              glucoseMgdl: history[20].valueMgdl.round(),
              sensorMinute: history[20].sensorMinute,
              recordedAt: history[20].recordedAt,
              payloadHex: '7600150c',
            ),
          ]
        : const <CgmCalibrationEntry>[];
    return CgmSessionSnapshot(
      stage: stage,
      statusText: statusText,
      sensor: sensor,
      capabilities: sensor.capabilities,
      latestReading: resolvedLatest,
      lastAdvertisement: sensor.advertisement,
      history: history,
      rawHistory: history
          .map((reading) => reading.copyWith(source: CgmRecordSource.raw))
          .toList(growable: false),
      calibrations: calibrations,
      diagnostics: _buildDiagnostics(),
      sessionInfo: CgmSessionInfo(
        manufacturer: 'MicroTech Medical',
        model: 'AiDEX X',
        serial: '07A12',
        firmware: '1.9.7-demo',
        sessionStart: sessionStart,
        sessionStartPayloadHex: 'E907040D01080C0000',
        elapsedMinutes: history.isEmpty
            ? now.difference(sessionStart).inMinutes
            : history.last.sensorMinute,
        warmupMinutes: _warmupMinutes,
      ),
      health: health,
      historySync: CgmHistorySyncState(
        storedCount: history.length,
        totalAvailable: history.length,
        latestStoredOffset: history.isEmpty ? null : history.last.sensorMinute,
        startIndex: history.isEmpty ? null : history.first.sensorMinute,
        targetIndex: history.isEmpty ? null : history.last.sensorMinute,
        lastSyncAt: now,
      ),
      metadata: <String, String>{
        'deviceId': sensor.deviceId,
        'serial': '07A12',
        'mode': 'demo',
        'driverId': sensor.driverId,
        'scenario': scenario.id,
        'historyCount': history.length.toString(),
      },
    );
  }

  List<CgmDiagnosticItem> _buildDiagnostics() {
    return <CgmDiagnosticItem>[
      const CgmDiagnosticItem(
        key: 'pair',
        title: 'Vendor Pair State',
        summary: 'Demo transport always reports the vendor session as ready.',
        rawHex: '1122334455667788',
      ),
      const CgmDiagnosticItem(
        key: 'device',
        title: 'Device Information',
        fields: <String, String>{
          'manufacturer': 'MicroTech Medical',
          'model': 'AiDEX X',
          'firmware': '1.9.7-demo',
        },
      ),
      const CgmDiagnosticItem(
        key: 'status',
        title: 'Standard CGM State',
        fields: <String, String>{
          'featureHex': '8B3F',
          'statusHex': '0000010000000000',
          'sessionRunTimeHex': '00480000',
        },
      ),
    ];
  }

  /// Sentinel so [_baseSnapshot] can distinguish "use history.last" from an
  /// explicit `null` latest reading (warmup needs the latter).
  static const CgmReading _unsetReading = CgmReading(
    valueMgdl: double.nan,
    source: CgmRecordSource.vendor,
  );
}
