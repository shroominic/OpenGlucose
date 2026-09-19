import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_live_update_bridge.dart';
import 'app_language_controller.dart';
import 'cgm_driver_registry.dart';
import 'demo_driver.dart';
import 'display_awake_gate.dart';
import 'display_preferences.dart';
import 'health_state_store.dart';
import 'ios_live_activity_bridge.dart';
import 'live_activity_payload.dart';
import 'mock_scenarios.dart';
import 'sensor_archive.dart';
import 'persistence/sensor_state_identity.dart';
import 'session_presentation.dart';

typedef LiveActivityPrivacySetter =
    Future<void> Function({required bool enabled});

/// Closed diagnostic for a retry run the controller stopped on its own.
const String automaticReconnectExhaustedCode = 'cgm.session.reconnectExhausted';

void _debugAppSessionTrace(String milestone) {
  assert(() {
    // Debug-only closed milestones. No device identifiers, sensor values,
    // or native descriptions are written to process output.
    debugPrint('OGBLE ui=$milestone');
    return true;
  }(), 'debug session trace');
}

class CgmAppController extends ChangeNotifier {
  CgmAppController({
    required SharedPreferences preferences,
    required CgmDriver driver,
    HealthStateStore? healthStateStore,
    Future<void> Function(DiscoveredSensor)? prepareTarget,
    Future<void> Function()? flushPrivateState,
    String? Function(DiscoveredSensor)? historyNamespace,
    DisplayAwakeGate? displayAwake,
    Duration reconnectDelay = const Duration(seconds: 3),
    @visibleForTesting AppLanguage initialAppLanguage = AppLanguage.english,
    @visibleForTesting LiveActivityPrivacySetter? liveActivityPrivacySetter,
    @visibleForTesting Future<void> Function()? liveActivityPrivacyRefresh,
  }) : _prepareTarget = prepareTarget,
       _flushPrivateState = flushPrivateState,
       _historyNamespace = historyNamespace,
       _preferences = preferences,
       _healthStateStore =
           healthStateStore ?? PreferencesHealthStateStore(preferences),
       _displayAwake = displayAwake ?? const NoopDisplayAwakeGate(),
       _reconnectDelay = reconnectDelay,
       _appLanguage = initialAppLanguage,
       _liveActivityPrivacySetter = liveActivityPrivacySetter,
       _liveActivityPrivacyRefresh = liveActivityPrivacyRefresh,
       _driver = driver;

  static const _displayPreferencesKey = 'openHealth.displayPreferences';
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _sensorArchiveKey = 'openHealth.sensorArchive';
  static const _bondTransferTombstonePrefix = 'openHealth.bondTransfer.';
  static const _qualifiedHistoryPrefix = 'openHealth.history.v2.';
  static const _qualifiedBondTransferTombstonePrefix =
      'openHealth.bondTransfer.v2.';
  static const _bondTransferOutcomeUnknown = 'outcome-unknown';
  static const _bondTransferSensorAccepted = 'sensor-accepted';
  static const _scanTimeout = Duration(seconds: 6);
  static const _historyPersistDebounce = Duration(milliseconds: 900);
  static const _restoredConnectDelay = Duration(milliseconds: 700);
  // A live session that reaches the syncing stage can stop making progress
  // when the sensor's frames never decode into a reading. Bound that wait so
  // setup fails closed with a next action instead of spinning forever.
  static const _syncStageDeadline = Duration(seconds: 45);
  static const _syncStalledStatusText = 'Sensor sent no readable reading';
  static const _liveRefreshThreshold = Duration(minutes: 2);
  static const _historyCatchUpThreshold = Duration(minutes: 5);
  static const _resumeOffsetMetadataKey = 'resumeOffset';
  static const _resumeCountMetadataKey = 'resumeCount';
  static const _resumeHistoryMetadataKey = 'resumeHistory';

  /// How many automatic reconnect attempts one run may spend without the user.
  ///
  /// With the default delay this backoff reaches 3, 6, 12, 24, 48 seconds and
  /// then stops - about 93 seconds of trying - after which the host asks for a
  /// decision instead of retrying a dead link every three seconds forever.
  static const int _maxAutomaticReconnectAttempts = 5;

  final SharedPreferences _preferences;
  final Future<void> Function(DiscoveredSensor)? _prepareTarget;
  final Future<void> Function()? _flushPrivateState;
  final String? Function(DiscoveredSensor)? _historyNamespace;
  final HealthStateStore _healthStateStore;
  final Duration _reconnectDelay;
  int _reconnectAttempts = 0;
  final CgmDriver _driver;
  final DisplayAwakeGate _displayAwake;
  final LiveActivityPrivacySetter? _liveActivityPrivacySetter;
  final Future<void> Function()? _liveActivityPrivacyRefresh;
  final Map<String, DiscoveredSensor> _sensorsById =
      <String, DiscoveredSensor>{};
  final List<CgmLogEntry> _logs = <CgmLogEntry>[];

  CgmSession? _session;
  bool _sensorConnectionCleanupUnconfirmed = false;

  /// Native ownership was not released. A new connection in this process is
  /// unsafe; preserve receiver/history and require an actual app restart.
  bool get sensorConnectionCleanupUnconfirmed =>
      _sensorConnectionCleanupUnconfirmed;
  StreamSubscription<CgmSessionSnapshot>? _snapshotSubscription;
  StreamSubscription<CgmLogEntry>? _logSubscription;
  Timer? _historyPersistTimer;
  Timer? _reconnectTimer;
  Timer? _syncStageTimer;
  bool _syncStageStalled = false;
  CgmSessionSnapshot? _snapshot;
  DiscoveredSensor? _selectedSensor;
  List<CgmReading> _persistedHistory = const <CgmReading>[];
  List<ArchivedSensorSession> _archivedSensors =
      const <ArchivedSensorSession>[];
  DisplayPreferences _displayPreferences = const DisplayPreferences();
  bool _sensitiveLiveActivityContentEnabled = false;
  AppLanguage _appLanguage;
  bool _liveActivityPrivacyUpdateInFlight = false;
  bool _scanning = false;
  BleFailure? _scanFailure;
  int _scanGeneration = 0;
  StreamIterator<DiscoveredSensor>? _scanIterator;
  bool _disposed = false;
  bool _connectInProgress = false;
  int _connectionGeneration = 0;
  Completer<void>? _connectCompletion;
  Completer<void>? _disconnectCompletion;
  bool _freshnessInFlight = false;
  bool _bondTransferInFlight = false;
  bool _finalizingBondTransfer = false;
  CgmBondTransferSession? _inspectedBondTransferSession;
  String? _inspectedBondTransferIdentity;
  CgmBondTransferPlan? _inspectedBondTransferPlan;
  bool _retiringExpiredSensor = false;
  bool _clearingActivationRequiredSensor = false;
  DiscoveredSensor? _activationRequiredSensor;
  bool _allowSessionActivation = false;
  bool _selectionPersisted = false;
  Future<void>? _selectionPromotion;
  DiscoveredSensor? _selectionPromotionSource;
  String? _backgroundSensorIdentity;
  String? _lastError;
  final Map<String, String> _persistenceErrors = <String, String>{};

  List<DiscoveredSensor> get sensors {
    final values = _sensorsById.values.toList(growable: false);
    values.sort((left, right) => right.rssi.compareTo(left.rssi));
    return values;
  }

  bool get scanning => _scanning;

  BleFailure? get scanFailure => _scanFailure;

  String? get scanFailureMessage => switch (_scanFailure) {
    final failure? => userMessageForBleFailure(
      failure,
      language: _appLanguage,
    ),
    null => _lastError,
  };

  /// Whether the active build can route a connection to [candidateDriverId].
  bool supportsDriver(String candidateDriverId) =>
      _driverSupports(candidateDriverId);

  /// The sensor that needs an explicit, user-authorized activation attempt.
  ///
  /// The failed read-only probe clears the provisional selection, but this
  /// transient notice remains available to the connection UI. A later
  /// connection attempt or an explicit selection clear dismisses it.
  DiscoveredSensor? get activationRequiredSensor => _activationRequiredSensor;

  String? get lastError {
    final persistenceError = _persistenceErrors.values.join('. ');
    if (_lastError != null && persistenceError.isNotEmpty) {
      // Both halves are complete sentences. Keep the joined notice readable
      // when the first one already carries its own terminal punctuation.
      final terminal = _appLanguage == AppLanguage.simplifiedChinese
          ? '。'
          : '.';
      final head = _lastError!.endsWith(terminal)
          ? _lastError!
          : '$_lastError$terminal';
      return '$head $persistenceError';
    }
    return _lastError ?? (persistenceError.isEmpty ? null : persistenceError);
  }

  DisplayPreferences get displayPreferences => _displayPreferences;

  bool get sensitiveLiveActivityContentEnabled =>
      _sensitiveLiveActivityContentEnabled;

  /// Updates the language used by native live surfaces and refreshes an
  /// already-visible notification/Live Activity. It never changes sensor,
  /// health, or display-unit preferences.
  Future<void> updateAppLanguage(AppLanguage language) async {
    if (_appLanguage == language) {
      return;
    }
    _appLanguage = language;
    if (_disposed) {
      return;
    }
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
  }

  bool get liveActivityPrivacyUpdateInFlight =>
      _liveActivityPrivacyUpdateInFlight;

  bool get bondTransferInFlight => _bondTransferInFlight;

  bool get canMoveSensorToAnotherPhone =>
      !_bondTransferInFlight &&
      _snapshot?.stage == CgmSyncStage.ready &&
      _session is CgmBondTransferSession &&
      (_selectedSensor == null ||
          _bondTransferTombstone(_selectedSensor!) == null);

  bool sensorHasInterruptedTransfer(DiscoveredSensor sensor) =>
      !isMockDriver && _bondTransferTombstone(sensor) != null;

  bool canAcknowledgeInterruptedSensorTransfer(DiscoveredSensor sensor) =>
      !isMockDriver &&
      _bondTransferTombstone(sensor) == _bondTransferSensorAccepted;

  List<ArchivedSensorSession> get archivedSensors {
    final sessions = List<ArchivedSensorSession>.of(_archivedSensors);
    sessions.sort((left, right) {
      final leftAt = left.endedAt ?? left.lastReadingAt ?? left.startedAt;
      final rightAt = right.endedAt ?? right.lastReadingAt ?? right.startedAt;
      if (leftAt == null && rightAt == null) return 0;
      if (leftAt == null) return 1;
      if (rightAt == null) return -1;
      return rightAt.compareTo(leftAt);
    });
    return List<ArchivedSensorSession>.unmodifiable(sessions);
  }

  List<CgmReading> readingsForArchivedSensor(ArchivedSensorSession session) {
    final identity = DiscoveredSensor(
      driverId: session.driverId,
      deviceId: session.deviceId,
      displayName: session.displayName,
      storageKey: session.storageKey,
      rssi: 0,
      capabilities: const CgmCapabilities(),
    );
    if (_historyNamespace?.call(identity) != null) {
      final key = _historyKey(identity);
      if (session.historyKey != key &&
          !session.historyKey.startsWith('$key.archive.')) {
        return const <CgmReading>[];
      }
      return readingsForWellness(_loadHistoryAtKey(session.historyKey));
    }
    if (session.isUnreconciled) {
      try {
        final raw = _healthStateStore.getString(session.historyKey);
        final decoded = raw == null ? null : jsonDecode(raw);
        if (decoded is! List || !decoded.every((row) => row is Map)) {
          return const <CgmReading>[];
        }
        return List<CgmReading>.unmodifiable(
          _loadHistoryAtKey(session.historyKey),
        );
      } on Object {
        // The explicit unreconciled marker is retained; these bytes cannot be
        // exported as parsed rows or represented as a successful empty session.
        return const <CgmReading>[];
      }
    }
    return List<CgmReading>.unmodifiable(
      _loadHistoryAtKey(session.historyKey),
    );
  }

  /// Archived readings suitable for charts and wellness analytics.
  ///
  /// The raw retained history remains available through
  /// [readingsForArchivedSensor] so data export stays complete.
  List<CgmReading> displayReadingsForArchivedSensor(
    ArchivedSensorSession session,
  ) {
    if (session.isUnreconciled) return const <CgmReading>[];
    return readingsAfterWarmup(
      readingsForArchivedSensor(session),
      sessionStart: session.startedAt,
      warmupMinutes: const CgmSessionInfo().warmupMinutes,
    );
  }

  /// Wellness-eligible readings across previous sensors plus the active sensor.
  /// Duplicate records are collapsed so an archive hand-off cannot inflate
  /// long-range summaries. Provisional/raw records remain in local charts and
  /// explicit exports, but never enter this analytics/messaging input.
  List<CgmReading> get allHistoricalReadings {
    final byIdentity = <String, CgmReading>{};
    void addAll(Iterable<CgmReading> readings) {
      for (final reading in readingsForWellness(readings)) {
        final recordedAt = reading.recordedAt?.toUtc().toIso8601String() ?? '';
        final key =
            '$recordedAt|${reading.sensorMinute ?? ''}|'
            '${reading.valueMgdl}|${reading.source.name}';
        byIdentity[key] = reading;
      }
    }

    for (final session in _archivedSensors) {
      addAll(displayReadingsForArchivedSensor(session));
    }
    final current = snapshot;
    if (current != null) {
      addAll(
        readingsAfterWarmup(
          current.history,
          sessionStart: current.sessionInfo.sessionStart,
          warmupMinutes: current.sessionInfo.warmupMinutes,
        ),
      );
    } else {
      addAll(
        readingsAfterWarmup(
          _persistedHistory,
          sessionStart: inferSensorStart(_persistedHistory),
          warmupMinutes: const CgmSessionInfo().warmupMinutes,
        ),
      );
    }
    final readings = byIdentity.values.toList(growable: false)
      ..sort(
        (left, right) =>
            left.timelineTimestamp.compareTo(right.timelineTimestamp),
      );
    return List<CgmReading>.unmodifiable(readings);
  }

  CgmSessionSnapshot? get snapshot {
    final raw = _snapshot;
    if (raw == null) {
      return null;
    }
    final mergedHistory = isMockDriver
        ? raw.history
        : _mergeHistory(_persistedHistory, raw.history);
    return raw.copyWith(
      history: mergedHistory,
      latestReading:
          raw.latestReading ??
          (mergedHistory.isEmpty ? null : mergedHistory.last),
    );
  }

  CgmReading? get latestReading {
    final current = snapshot;
    if (current == null) {
      return null;
    }
    return current.latestReading ??
        (current.history.isEmpty ? null : current.history.last);
  }

  /// Latest reading suitable for user-facing values and messaging.
  ///
  /// Operational freshness and reconnect logic continue to use
  /// [latestReading], which intentionally retains the sensor's raw state.
  CgmReading? get displayLatestReading {
    final current = snapshot;
    if (current == null) {
      return null;
    }
    final latest = current.latestReading;
    if (latest != null &&
        readingsAfterWarmup(
          <CgmReading>[latest],
          sessionStart: current.sessionInfo.sessionStart,
          warmupMinutes: current.sessionInfo.warmupMinutes,
        ).isNotEmpty) {
      return latest;
    }
    final history = readingsAfterWarmup(
      current.history,
      sessionStart: current.sessionInfo.sessionStart,
      warmupMinutes: current.sessionInfo.warmupMinutes,
    );
    return history.isEmpty ? null : history.last;
  }

  List<CgmReading> get visibleHistory {
    final current = snapshot;
    if (current == null) {
      return const <CgmReading>[];
    }
    final history = readingsAfterWarmup(
      current.history,
      sessionStart: current.sessionInfo.sessionStart,
      warmupMinutes: current.sessionInfo.warmupMinutes,
    );
    final crop = _displayPreferences.cropFirstSamples;
    if (crop <= 0 || crop >= history.length) {
      return history;
    }
    return history.skip(crop).toList(growable: false);
  }

  /// Only normalized, non-provisional records enter wellness analytics.
  List<CgmReading> get visibleWellnessHistory =>
      readingsForWellness(visibleHistory);

  List<CgmLogEntry> get logs => List<CgmLogEntry>.unmodifiable(_logs.reversed);

  Future<void> initialize() async {
    if (!isMockDriver) {
      await _healthStateStore.initialize();
    }
    final rawPreferences = _preferences.getString(_displayPreferencesKey);
    if (rawPreferences != null && rawPreferences.isNotEmpty) {
      final decoded = jsonDecode(rawPreferences);
      if (decoded is Map<String, Object?>) {
        _displayPreferences = DisplayPreferences.fromJson(decoded);
      }
    }

    if (!isMockDriver) {
      await _restoreLiveActivityPrivacyPreference();
    }

    if (isMockDriver) {
      return;
    }

    _archivedSensors = _loadSensorArchive();

    final restoredSensor = _loadPersistedSensor();
    if (restoredSensor == null || !_driverSupports(restoredSensor.driverId)) {
      return;
    }

    _selectedSensor = restoredSensor;
    _selectionPersisted = true;
    try {
      await _prepareTarget?.call(restoredSensor);
      _persistedHistory = _loadPersistedHistory(restoredSensor);
    } on Object catch (error) {
      _showRestoreFailure(restoredSensor, error);
      return;
    }
    final interruptedTransfer = _bondTransferTombstone(restoredSensor);
    if (interruptedTransfer != null) {
      _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Sensor transfer needs attention',
        sensor: _publicSensor(restoredSensor),
        capabilities: restoredSensor.capabilities,
        lastAdvertisement:
            restoredSensor.capabilities.supportsAdvertisementGlucose
            ? restoredSensor.advertisement
            : null,
        history: _persistedHistory,
        latestReading: _persistedHistory.isEmpty
            ? null
            : _persistedHistory.last,
        metadata: <String, String>{
          'deviceId': restoredSensor.deviceId,
          ..._publicSensor(restoredSensor).metadata,
          cgmBondTransferStateMetadataKey: interruptedTransfer,
          cgmBondTransferDiagnosticMetadataKey: 'cgm.bond-transfer.interrupted',
        },
        lastError: interruptedBondTransferText(
          interruptedTransfer,
          language: _appLanguage,
        ),
      );
      _lastError = interruptedBondTransferText(
        interruptedTransfer,
        language: _appLanguage,
      );
      notifyListeners();
      return;
    }
    final inferredStart = restoredSensor.driverId == 'cbio'
        ? null
        : inferSensorStart(_persistedHistory);
    if (_persistedSensorHasExpired(
      sensor: restoredSensor,
      history: _persistedHistory,
      inferredStart: inferredStart,
    )) {
      await _archiveSensor(
        sensor: restoredSensor,
        history: _persistedHistory,
        reason: SensorArchiveReason.expired,
        startedAt: inferredStart,
      );
      await _healthStateStore.remove(_lastSensorKey);
      await _healthStateStore.remove(_historyKey(restoredSensor));
      _selectionPersisted = false;
      _selectedSensor = null;
      _persistedHistory = const <CgmReading>[];
      await _clearPlatformBackgroundState();
      notifyListeners();
      return;
    }
    _snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.connecting,
      statusText: 'Reconnecting',
      sensor: _publicSensor(restoredSensor),
      capabilities: restoredSensor.capabilities,
      lastAdvertisement:
          restoredSensor.capabilities.supportsAdvertisementGlucose
          ? restoredSensor.advertisement
          : null,
      history: _persistedHistory,
      latestReading: _persistedHistory.isEmpty ? null : _persistedHistory.last,
      sessionInfo: CgmSessionInfo(sessionStart: inferredStart),
      metadata: <String, String>{
        'deviceId': restoredSensor.deviceId,
        ..._publicSensor(restoredSensor).metadata,
      },
    );
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
    notifyListeners();
    Timer(_restoredConnectDelay, () {
      if (_disposed ||
          _session != null ||
          !_sameSensor(_selectedSensor, restoredSensor)) {
        return;
      }
      unawaited(connect(restoredSensor, allowSessionActivation: false));
    });
  }

  Future<void> scan() async {
    late final int invalidationGeneration;
    try {
      invalidationGeneration = await _invalidateScan();
    } catch (error) {
      if (_disposed) {
        return;
      }
      _recordScanFailure(error);
      _scanning = false;
      notifyListeners();
      return;
    }
    if (_disposed || invalidationGeneration != _scanGeneration) {
      return;
    }
    final generation = ++_scanGeneration;
    _scanning = true;
    _scanFailure = null;
    _lastError = null;
    _sensorsById.clear();
    notifyListeners();

    final iterator = StreamIterator<DiscoveredSensor>(
      _driver.scan(timeout: _scanTimeout),
    );
    _scanIterator = iterator;
    // Android will not run the unfiltered pass this sensor needs while the
    // display is off, and it reports that by returning nothing at all. Hold the
    // display for the window so the pass is allowed to run, and release it when
    // the window ends however it ends.
    await _holdDisplayForScan();
    try {
      while (await iterator.moveNext()) {
        if (!_ownsScan(generation)) {
          break;
        }
        final sensor = iterator.current;
        _sensorsById[_sensorIdentity(sensor)] = sensor;
        notifyListeners();
      }
      if (_ownsScan(generation) &&
          _sensorsById.isEmpty &&
          !await _displayIsInteractive()) {
        _recordScanFailure(
          BleFailure(
            kind: BleFailureKind.scanUnavailable,
            operation: BleOperation.scan,
            diagnosticCode: 'cgm.ble.scan.display-off',
          ),
        );
      }
    } catch (error) {
      if (!_ownsScan(generation)) {
        return;
      }
      _recordScanFailure(error);
    } finally {
      await _releaseDisplayAfterScan();
      if (identical(_scanIterator, iterator)) {
        _scanIterator = null;
      }
      if (_ownsScan(generation)) {
        _scanning = false;
        notifyListeners();
      }
    }
  }

  /// Holds the display for one scan window. A gate failure never breaks a scan.
  Future<void> _holdDisplayForScan() async {
    try {
      await _displayAwake.hold();
    } on Object {
      // The platform bridge is not a scan dependency.
    }
  }

  /// Releases the hold taken for a scan window, however the window ended.
  Future<void> _releaseDisplayAfterScan() async {
    try {
      await _displayAwake.release();
    } on Object {
      // The platform bridge is not a scan dependency.
    }
  }

  /// Whether the platform would run an unfiltered scan right now.
  ///
  /// A platform that cannot answer reads as interactive, so a scan is only
  /// ever called declined when the platform said so.
  Future<bool> _displayIsInteractive() async {
    try {
      return await _displayAwake.isInteractive();
    } on Object {
      return true;
    }
  }

  /// Stops the current physical scan without changing sensor selection.
  ///
  /// Cleanup errors are retained as privacy-safe scan failures and never
  /// escape route disposal. A newer scan owns its generation and cannot be
  /// overwritten when an older cancellation finishes late.
  Future<void> cancelScan() async {
    final cancellationGeneration = _scanGeneration + 1;
    try {
      await _invalidateScan();
    } catch (error) {
      if (_disposed || cancellationGeneration != _scanGeneration) {
        return;
      }
      _recordScanFailure(error);
      notifyListeners();
      return;
    }
    if (_disposed || cancellationGeneration != _scanGeneration) {
      return;
    }
    notifyListeners();
  }

  Future<void> connect(
    DiscoveredSensor sensor, {
    bool allowSessionActivation = true,
  }) async {
    if (_sensorConnectionCleanupUnconfirmed) {
      _lastError =
          'Connection cleanup could not be confirmed. Close and reopen '
          'OpenGlucose before connecting again. Do not reset the sensor.';
      notifyListeners();
      return;
    }
    final generation = ++_connectionGeneration;
    while (_connectInProgress) {
      await _connectCompletion!.future;
      if (_disposed || generation != _connectionGeneration) return;
    }
    _connectInProgress = true;
    _connectCompletion = Completer<void>();
    _activationRequiredSensor = null;
    _cancelReconnect();
    try {
      await _disconnectCompletion?.future;
      if (_disposed || generation != _connectionGeneration) return;
      await _invalidateScan();
      if (_disposed || generation != _connectionGeneration) return;
      if (!_driverSupports(sensor.driverId)) {
        _lastError =
            'This sensor protocol is not available in the current build.';
        notifyListeners();
        return;
      }
      if (!isMockDriver && _bondTransferTombstone(sensor) != null) {
        _lastError = interruptedBondTransferText(
          _bondTransferTombstone(sensor),
          language: _appLanguage,
        );
        notifyListeners();
        return;
      }
      _clearInspectedBondTransfer();
      final resumeVerifiedSelection =
          _selectionPersisted && _sameStoredSensor(_selectedSensor, sensor);
      final promotionSource = _selectionPromotionSource;
      final resumesPendingPromotion =
          promotionSource != null && _sameSensor(promotionSource, sensor);
      final inProcessHistory = resumesPendingPromotion
          ? List<CgmReading>.of(_persistedHistory, growable: false)
          : const <CgmReading>[];
      // Prepare the target without rebinding any active state. A corrupt
      // target must not strand the current sensor's unsaved history.
      try {
        await _prepareTarget?.call(sensor);
      } on Object catch (error) {
        if (_disposed || generation != _connectionGeneration) return;
        _recordPersistenceFailure('Restoring sensor history', error);
        notifyListeners();
        return;
      }
      if (_disposed || generation != _connectionGeneration) return;
      await disconnect(clearSelection: false, requireDurableHandoff: true);
      if (_disposed ||
          generation != _connectionGeneration ||
          _sensorConnectionCleanupUnconfirmed) {
        return;
      }
      final preparedHistory = switch ((
        isMockDriver,
        resumeVerifiedSelection,
        resumesPendingPromotion,
      )) {
        (true, _, _) => const <CgmReading>[],
        (false, true, _) => _loadPersistedHistory(sensor),
        (false, false, true) => _mergeHistory(
          _loadPersistedHistory(promotionSource!),
          _mergeHistory(_loadPersistedHistory(sensor), inProcessHistory),
        ),
        (false, false, false) => const <CgmReading>[],
      };
      _allowSessionActivation = allowSessionActivation;
      _selectedSensor = sensor;
      _selectionPersisted = resumeVerifiedSelection;
      if (!resumesPendingPromotion) {
        _selectionPromotionSource = null;
      }
      _persistedHistory = preparedHistory;
      _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.connecting,
        statusText: 'Connecting',
        sensor: _publicSensor(sensor),
        capabilities: sensor.capabilities,
        lastAdvertisement: sensor.capabilities.supportsAdvertisementGlucose
            ? sensor.advertisement
            : null,
        history: _persistedHistory,
        latestReading: _persistedHistory.isEmpty
            ? null
            : _persistedHistory.last,
        metadata: <String, String>{
          'deviceId': sensor.deviceId,
          ..._publicSensor(sensor).metadata,
        },
      );
      _logs.clear();
      _lastError = null;
      _cancelSyncStageDeadline();
      _syncStageStalled = false;
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      notifyListeners();

      final session = await _driver.connect(
        _connectionSensorFor(
          sensor,
          _persistedHistory,
          allowSessionActivation: allowSessionActivation,
        ),
      );
      if (_disposed || generation != _connectionGeneration) {
        await session.disconnect();
        await _flushPrivateState?.call();
        return;
      }
      _session = session;
      _snapshotSubscription = session.snapshots.listen((incomingSnapshot) {
        if (_disposed || !identical(_session, session)) return;
        if (_syncStageStalled) {
          if (incomingSnapshot.stage == CgmSyncStage.syncing) {
            // The bounded failure already replaced this stage. Keep the
            // terminal state until the driver reports data, an error, or a
            // disconnect.
            return;
          }
          _syncStageStalled = false;
        }
        final isErrorSnapshot = incomingSnapshot.stage == CgmSyncStage.error;
        if (isErrorSnapshot) {
          _debugAppSessionTrace('error-snapshot-received');
        }
        _snapshot = _acceptSessionSnapshot(incomingSnapshot);
        final nextSnapshot = _snapshot!;
        final nextHistory = _snapshot!.history;
        final reconnectingStage =
            nextSnapshot.stage == CgmSyncStage.disconnected ||
            nextSnapshot.stage == CgmSyncStage.error;
        if (nextSnapshot.lastError != null && reconnectingStage) {
          _lastError =
              primaryErrorTextForSnapshot(
                _snapshot!,
                language: _appLanguage,
              ) ??
              safeOperationFailureText('Connection', language: _appLanguage);
        } else if (!reconnectingStage) {
          _lastError = null;
        }
        if (!isMockDriver &&
            _selectedSensor != null &&
            nextHistory.isNotEmpty) {
          _persistedHistory = nextHistory;
        }
        if (!isMockDriver && _snapshotHasExpired(nextSnapshot)) {
          if (nextHistory.isNotEmpty && !nextSnapshot.historySync.inProgress) {
            _schedulePersistHistory(_selectedSensor!, nextHistory);
          }
          unawaited(_retireExpiredSensor());
          return;
        }
        if (!isMockDriver &&
            nextSnapshot.metadata['activationRequired'] == 'true') {
          _activationRequiredSensor = _selectedSensor ?? nextSnapshot.sensor;
          if (nextHistory.isNotEmpty && !nextSnapshot.historySync.inProgress) {
            _schedulePersistHistory(_selectedSensor!, nextHistory);
          }
          unawaited(_clearActivationRequiredSelection());
          return;
        }
        if (nextSnapshot.stage == CgmSyncStage.activating) {
          // Starting a sensor is irreversible. Once the driver begins that
          // exchange, any automatic retry must fail closed and require a new
          // explicit scan selection rather than attempting activation again.
          _allowSessionActivation = false;
        }
        if (_snapshot!.stage == CgmSyncStage.ready) {
          // Once the sensor has proven that an active session exists, future
          // background reconnects must never be allowed to start a new one.
          _allowSessionActivation = false;
          _promoteVerifiedSelection(
            _snapshot!.sensor,
            history: nextHistory,
          );
        }
        if (!isMockDriver &&
            _selectedSensor != null &&
            nextHistory.isNotEmpty &&
            !nextSnapshot.historySync.inProgress) {
          _schedulePersistHistory(_selectedSensor!, nextHistory);
        }
        if (reconnectingStage &&
            !isMockDriver &&
            snapshotAllowsAutomaticReconnect(_snapshot!)) {
          _scheduleReconnect();
        } else {
          _cancelReconnect();
        }
        _trackSyncStageDeadline();
        if (_snapshot!.stage == CgmSyncStage.ready) {
          // The link proved itself, so the next run starts with a full budget.
          _reconnectAttempts = 0;
        }
        _startPlatformTask(
          _pushLiveActivity(),
          'Updating private lock-screen state',
        );
        notifyListeners();
        if (isErrorSnapshot) {
          _debugAppSessionTrace('error-snapshot-notified');
        }
      });
      // Attach to the non-replaying stream before reading currentSnapshot.
      // This closes the gap in which setup can publish a terminal state after
      // the first read but before the listener exists.
      final currentSnapshot = session.currentSnapshot;
      _snapshot = _acceptSessionSnapshot(currentSnapshot);
      final initialHistory = _snapshot!.history;
      if (!isMockDriver && initialHistory.isNotEmpty) {
        _persistedHistory = initialHistory;
      }
      final initialErrorSnapshot = _snapshot;
      if (initialErrorSnapshot != null &&
          (initialErrorSnapshot.stage == CgmSyncStage.error ||
              initialErrorSnapshot.stage == CgmSyncStage.disconnected)) {
        _lastError = primaryErrorTextForSnapshot(
          initialErrorSnapshot,
          language: _appLanguage,
        );
        if (initialErrorSnapshot.stage == CgmSyncStage.error) {
          _debugAppSessionTrace('error-snapshot-reconciled');
        }
      }
      if (_snapshot?.stage == CgmSyncStage.ready) {
        // The initial snapshot can already be ready before the non-replaying
        // stream listener is attached. Treat it like a later ready event so a
        // reconnect can never repeat sensor activation.
        _allowSessionActivation = false;
        _promoteVerifiedSelection(
          _snapshot!.sensor,
          history: initialHistory,
        );
        if (!isMockDriver &&
            initialHistory.isNotEmpty &&
            !_snapshot!.historySync.inProgress) {
          _schedulePersistHistory(_selectedSensor!, initialHistory);
        }
      }
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      _logSubscription = session.logs.listen((entry) {
        _logs.add(entry);
        if (_logs.length > 250) {
          _logs.removeRange(0, _logs.length - 250);
        }
        notifyListeners();
      });
      final initialSnapshot = _snapshot;
      if (!isMockDriver && initialSnapshot != null) {
        if (initialSnapshot.stage == CgmSyncStage.activating) {
          _allowSessionActivation = false;
        }
        if (initialSnapshot.metadata['activationRequired'] == 'true') {
          _activationRequiredSensor = _selectedSensor ?? initialSnapshot.sensor;
          unawaited(_clearActivationRequiredSelection());
        } else if (_snapshotHasExpired(initialSnapshot)) {
          unawaited(_retireExpiredSensor());
        }
      }
      final initialSelectionPromotion = _selectionPromotion;
      if (initialSelectionPromotion != null &&
          initialSnapshot?.stage == CgmSyncStage.ready) {
        await initialSelectionPromotion;
      }
      _trackSyncStageDeadline();
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _connectionGeneration) return;
      final safeError = _safeError('Connection', error);
      _lastError = safeError;
      _snapshot = _snapshot?.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Connection failed',
        lastError: safeError,
      );
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      notifyListeners();
    } finally {
      _connectInProgress = false;
      _connectCompletion?.complete();
      _connectCompletion = null;
    }
  }

  Future<void> ensureFreshData({bool force = false}) async {
    if (_connectInProgress || _freshnessInFlight) {
      return;
    }
    final sensor = _selectedSensor;
    if (sensor == null) {
      return;
    }
    final session = _session;
    final currentSnapshot = snapshot;
    if (session == null || currentSnapshot == null) {
      await connect(sensor, allowSessionActivation: _allowSessionActivation);
      return;
    }
    if (currentSnapshot.stage == CgmSyncStage.disconnected) {
      _scheduleReconnect();
      return;
    }
    // Refresh only a session that completed setup. A forced foreground
    // refresh must not run against a torn-down or user-action BLE failure and
    // overwrite its terminal phase/support metadata with a syncing snapshot.
    if (currentSnapshot.stage != CgmSyncStage.ready ||
        currentSnapshot.historySync.inProgress) {
      return;
    }

    final needsLiveRefresh = force || _needsLiveRefresh(currentSnapshot);
    final needsHistoryCatchUp =
        currentSnapshot.capabilities.supportsHistory &&
        (force || _needsHistoryCatchUp(currentSnapshot));
    if (!needsLiveRefresh && !needsHistoryCatchUp) {
      return;
    }

    _freshnessInFlight = true;
    try {
      _lastError = null;
      if (needsLiveRefresh) {
        await session.refreshLiveData();
      }
      final refreshedSnapshot = snapshot;
      if (refreshedSnapshot != null &&
          refreshedSnapshot.stage == CgmSyncStage.ready &&
          refreshedSnapshot.capabilities.supportsHistory &&
          !refreshedSnapshot.historySync.inProgress &&
          (force || _needsHistoryCatchUp(refreshedSnapshot))) {
        await session.syncHistory(
          requestedStartOffset: _resumeHistoryStartOffset(refreshedSnapshot),
        );
      }
    } catch (error) {
      _lastError = _safeError('Refresh', error);
    } finally {
      _freshnessInFlight = false;
      notifyListeners();
    }
  }

  bool get connectionRequiresUserAction {
    final current = snapshot;
    return current != null &&
        snapshotHasBleFailure(current) &&
        !_canAutomaticallyReconnect(current);
  }

  Future<void> retryConnection() async {
    final sensor = _selectedSensor;
    if (sensor == null) {
      return;
    }
    _cancelReconnect();
    await connect(sensor, allowSessionActivation: _allowSessionActivation);
  }

  Future<void> chooseAnotherSensor() {
    final current = snapshot;
    final shouldArchive =
        _selectionPersisted || (current?.history.isNotEmpty ?? false);
    return disconnect(clearSelection: true, archiveWhenClearing: shouldArchive);
  }

  Future<CgmBondTransferPlan> inspectSensorTransfer() async {
    final session = _session;
    final sensor = _selectedSensor;
    if (session == null ||
        sensor == null ||
        _snapshot?.stage != CgmSyncStage.ready ||
        _bondTransferInFlight ||
        _bondTransferTombstone(sensor) != null) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    if (session is! CgmBondTransferSession) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    final transferSession = session as CgmBondTransferSession;
    _bondTransferInFlight = true;
    _lastError = null;
    notifyListeners();
    try {
      final plan = await transferSession.inspectBondTransfer();
      if (!identical(_session, session) ||
          !_sameStoredSensor(_selectedSensor, sensor)) {
        throw const CgmBondTransferException(
          CgmBondTransferFailureKind.sessionNotReady,
          outcome: CgmBondTransferOutcome.notStarted,
        );
      }
      _inspectedBondTransferSession = transferSession;
      _inspectedBondTransferIdentity = _storedSensorIdentity(sensor);
      _inspectedBondTransferPlan = plan;
      return plan;
    } catch (error) {
      _lastError = _safeError('Sensor transfer check', error);
      rethrow;
    } finally {
      _bondTransferInFlight = false;
      notifyListeners();
    }
  }

  Future<void> moveSensorToAnotherPhone(CgmBondTransferPlan plan) async {
    final session = _session;
    final sensor = _selectedSensor;
    if (session == null ||
        sensor == null ||
        _snapshot?.stage != CgmSyncStage.ready ||
        _bondTransferInFlight ||
        !identical(_inspectedBondTransferSession, session) ||
        _inspectedBondTransferIdentity != _storedSensorIdentity(sensor) ||
        _inspectedBondTransferPlan != plan ||
        _bondTransferTombstone(sensor) != null) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    if (session is! CgmBondTransferSession) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    final transferSession = session as CgmBondTransferSession;
    _clearInspectedBondTransfer();
    _bondTransferInFlight = true;
    _cancelReconnect();
    _lastError = null;
    notifyListeners();
    var tombstoneWritten = false;
    try {
      try {
        await _healthStateStore.setString(
          _bondTransferTombstoneKey(sensor),
          _bondTransferOutcomeUnknown,
        );
        tombstoneWritten = true;
      } catch (error, stackTrace) {
        const failure = CgmBondTransferException(
          CgmBondTransferFailureKind.statePersistenceFailed,
          outcome: CgmBondTransferOutcome.notStarted,
        );
        Error.throwWithStackTrace(failure, stackTrace);
      }
      await transferSession.executeBondTransfer(
        plan,
        onSensorAccepted: () => _healthStateStore.setString(
          _bondTransferTombstoneKey(sensor),
          _bondTransferSensorAccepted,
        ),
      );
      // The driver has confirmed the sensor-side response, disconnected the
      // transport, and removed the local Android bond. This final teardown
      // archives app data and closes session streams; it does not unpair.
      _finalizingBondTransfer = true;
      try {
        await disconnect(
          archiveReason: SensorArchiveReason.disconnected,
          archiveWhenClearing: true,
        );
      } finally {
        _finalizingBondTransfer = false;
      }
      if (_selectedSensor != null || _bondTransferTombstone(sensor) != null) {
        throw const CgmBondTransferException(
          CgmBondTransferFailureKind.statePersistenceFailed,
          outcome: CgmBondTransferOutcome.sensorAccepted,
        );
      }
    } catch (error) {
      _cancelReconnect();
      if (tombstoneWritten &&
          error is CgmBondTransferException &&
          error.outcome == CgmBondTransferOutcome.notStarted) {
        try {
          await _healthStateStore.remove(
            _bondTransferTombstoneKey(sensor),
          );
        } catch (_) {
          // Retaining the fail-closed tombstone is safer than allowing a
          // second control-point attempt after uncertain durable cleanup.
        }
      }
      _lastError = _safeError('Sensor transfer', error);
      rethrow;
    } finally {
      _bondTransferInFlight = false;
      notifyListeners();
    }
  }

  Future<void> acknowledgeInterruptedSensorTransfer(
    DiscoveredSensor sensor,
  ) async {
    final transferState = _bondTransferTombstone(sensor);
    if (transferState == _bondTransferOutcomeUnknown) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sensorResponseUnknown,
        outcome: CgmBondTransferOutcome.unknown,
      );
    }
    if (isMockDriver ||
        _bondTransferInFlight ||
        transferState != _bondTransferSensorAccepted) {
      return;
    }
    if (_session != null || _sameStoredSensor(_selectedSensor, sensor)) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    try {
      await _healthStateStore.remove(
        _bondTransferTombstoneKey(sensor),
      );
      _clearPersistenceFailure('Clearing sensor transfer state');
      _lastError = null;
    } catch (error) {
      _recordPersistenceFailure('Clearing sensor transfer state', error);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> acknowledgeInterruptedSelectedSensorTransfer() async {
    final sensor = _selectedSensor;
    if (sensor == null || _bondTransferInFlight) {
      return;
    }
    final transferState = _bondTransferTombstone(sensor);
    if (transferState == _bondTransferOutcomeUnknown) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sensorResponseUnknown,
        outcome: CgmBondTransferOutcome.unknown,
      );
    }
    if (transferState != _bondTransferSensorAccepted) {
      return;
    }
    await disconnect(acknowledgeInterruptedTransfer: true);
  }

  Future<void> refresh() async {
    final session = _session;
    if (session == null) {
      return;
    }
    try {
      await session.refresh();
    } catch (error) {
      _lastError = _safeError('Refresh', error);
      notifyListeners();
    }
  }

  Future<void> sync() async {
    final session = _session;
    if (session == null) {
      return;
    }
    try {
      _lastError = null;
      notifyListeners();
      await session.refreshLiveData();
      final refreshedSnapshot = snapshot;
      if (refreshedSnapshot == null ||
          !refreshedSnapshot.capabilities.supportsHistory ||
          _isCurrentEnough(refreshedSnapshot)) {
        return;
      }
      await session.syncHistory(
        requestedStartOffset: _resumeHistoryStartOffset(refreshedSnapshot),
      );
    } catch (error) {
      _lastError = _safeError('Sync', error);
      notifyListeners();
    }
  }

  Future<void> refreshHistory() async {
    final session = _session;
    if (session == null || snapshot?.capabilities.supportsHistory != true) {
      return;
    }
    try {
      await session.syncHistory();
    } catch (error) {
      _lastError = _safeError('History refresh', error);
      notifyListeners();
    }
  }

  Future<void> refreshDiagnostics() async {
    final session = _session;
    if (session == null || snapshot?.capabilities.supportsDiagnostics != true) {
      return;
    }
    try {
      await session.refreshDiagnostics();
    } catch (error) {
      _lastError = _safeError('Diagnostics refresh', error);
      notifyListeners();
    }
  }

  Future<void> loadCalibrations() async {
    final session = _session;
    if (session == null || snapshot?.capabilities.supportsCalibration != true) {
      return;
    }
    try {
      await session.fetchCalibrations();
    } catch (error) {
      _lastError = _safeError('Calibration load', error);
      notifyListeners();
    }
  }

  Future<void> disconnect({
    bool clearSelection = true,
    SensorArchiveReason archiveReason = SensorArchiveReason.disconnected,
    bool archiveWhenClearing = true,
    bool acknowledgeInterruptedTransfer = false,
    bool requireDurableHandoff = false,
  }) async {
    if (_bondTransferInFlight && !_finalizingBondTransfer) return;
    final generation = requireDurableHandoff
        ? _connectionGeneration
        : ++_connectionGeneration;
    await _disconnectCompletion?.future;
    if (_disposed || generation != _connectionGeneration) return;
    final completion = Completer<void>();
    _disconnectCompletion = completion;
    try {
      await _disconnectInternal(
        clearSelection: clearSelection,
        archiveReason: archiveReason,
        archiveWhenClearing: archiveWhenClearing,
        acknowledgeInterruptedTransfer: acknowledgeInterruptedTransfer,
        requireDurableHandoff: requireDurableHandoff,
        generation: generation,
      );
    } finally {
      _disconnectCompletion = null;
      completion.complete();
    }
  }

  Future<void> _disconnectInternal({
    required int generation,
    bool clearSelection = true,
    SensorArchiveReason archiveReason = SensorArchiveReason.disconnected,
    bool archiveWhenClearing = true,
    bool acknowledgeInterruptedTransfer = false,
    bool requireDurableHandoff = false,
  }) async {
    if (_bondTransferInFlight && !_finalizingBondTransfer) {
      return;
    }
    if (clearSelection && !_clearingActivationRequiredSensor) {
      _activationRequiredSensor = null;
    }
    final selectedSensor = _selectedSensor;
    final interruptedTransfer = selectedSensor == null
        ? null
        : _bondTransferTombstone(selectedSensor);
    if (clearSelection &&
        !_finalizingBondTransfer &&
        interruptedTransfer != null &&
        (!acknowledgeInterruptedTransfer ||
            interruptedTransfer != _bondTransferSensorAccepted)) {
      _lastError = interruptedBondTransferText(
        interruptedTransfer,
        language: _appLanguage,
      );
      notifyListeners();
      return;
    }
    _clearInspectedBondTransfer();
    await _invalidateScan();
    if (_disposed || generation != _connectionGeneration) return;
    _cancelReconnect();
    _cancelSyncStageDeadline();
    _syncStageStalled = false;
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    final sensorToArchive = clearSelection ? _selectedSensor : null;
    final snapshotToArchive = clearSelection ? snapshot : null;
    final historyToArchive = clearSelection
        ? List<CgmReading>.of(
            snapshotToArchive?.history ?? _persistedHistory,
            growable: false,
          )
        : const <CgmReading>[];
    final snapshotSubscription = _snapshotSubscription;
    final logSubscription = _logSubscription;
    _snapshotSubscription = null;
    _logSubscription = null;
    final session = _session;
    _session = null;

    Object? teardownError;
    var libreCleanupUnconfirmed = false;
    for (final operation in <Future<void> Function()>[
      if (snapshotSubscription != null) snapshotSubscription.cancel,
      if (logSubscription != null) logSubscription.cancel,
      if (session != null) session.disconnect,
    ]) {
      try {
        await operation();
      } catch (error) {
        teardownError ??= error;
        if (error is LibreGen1LiveException &&
            error.kind == LibreGen1LiveFailure.cleanupUnconfirmed) {
          libreCleanupUnconfirmed = true;
        }
      }
    }
    if (_disposed || generation != _connectionGeneration) return;
    if (teardownError != null) {
      _recordPersistenceFailure('Disconnecting sensor session', teardownError);
    } else {
      _clearPersistenceFailure('Disconnecting sensor session');
    }

    if (libreCleanupUnconfirmed || _sensorConnectionCleanupUnconfirmed) {
      _sensorConnectionCleanupUnconfirmed = true;
      // A ready-state promotion can still be awaiting storage or a platform
      // call. Finish it before the final privacy clear so it cannot republish
      // background sensor state after the uncertain disconnect.
      final promotion = _selectionPromotion;
      if (promotion != null) await promotion;
      if (_disposed || generation != _connectionGeneration) return;
      _session = session;
      final failed = session?.currentSnapshot ?? _snapshot;
      if (failed != null) {
        _persistedHistory = _mergeHistory(_persistedHistory, failed.history);
        _snapshot = failed.copyWith(
          stage: CgmSyncStage.error,
          statusText: 'Connection cleanup needs an app restart',
          lastError: 'libre2.cleanupUnconfirmed',
          history: _persistedHistory,
          metadata: {
            ...failed.metadata,
            'cgm.libre2.phase': 'failed',
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
          },
        );
      }
      final sensor = _selectedSensor;
      if (sensor != null && !isMockDriver) {
        try {
          await _persistHistory(sensor, _persistedHistory);
        } catch (error) {
          _recordPersistenceFailure('Saving history', error);
        }
      }
      await _clearPlatformBackgroundState();
      _backgroundSensorIdentity = null;
      notifyListeners();
      return;
    }

    final pendingPromotion = _selectionPromotion;
    if (pendingPromotion != null) await pendingPromotion;
    if (_disposed || generation != _connectionGeneration) return;
    try {
      await _flushPrivateState?.call();
      _clearPersistenceFailure('Saving private sensor state');
    } on Object catch (error) {
      _recordPersistenceFailure('Saving private sensor state', error);
      if (!_disposed && generation == _connectionGeneration) {
        _snapshot = _snapshot?.copyWith(
          stage: CgmSyncStage.disconnected,
          statusText: 'Disconnected — could not save sensor history',
        );
        notifyListeners();
      }
      if (requireDurableHandoff) rethrow;
      return;
    }
    if (_disposed || generation != _connectionGeneration) return;

    if (clearSelection) {
      final selectionPromotion = _selectionPromotion;
      if (selectionPromotion != null) {
        await selectionPromotion;
      }
      if (_disposed || generation != _connectionGeneration) return;
      Object? selectionError;
      if (!isMockDriver) {
        try {
          if (sensorToArchive != null && archiveWhenClearing) {
            if (historyToArchive.isNotEmpty) {
              await _persistHistory(
                sensorToArchive,
                historyToArchive,
              );
              if (_disposed || generation != _connectionGeneration) return;
            }
            await _archiveSensor(
              sensor: sensorToArchive,
              history: historyToArchive,
              reason: archiveReason,
              snapshot: snapshotToArchive,
            );
            if (_disposed || generation != _connectionGeneration) return;
          }
          await _healthStateStore.remove(_lastSensorKey);
          if (_disposed || generation != _connectionGeneration) return;
          if (sensorToArchive != null) {
            try {
              await _healthStateStore.remove(_historyKey(sensorToArchive));
              if (_disposed || generation != _connectionGeneration) return;
            } catch (error) {
              // The durable active pointer is already gone, so retaining an
              // orphaned mutable cache is safer than making the completed
              // archive hand-off appear to fail.
              _recordPersistenceFailure('Cleaning active history', error);
            }
          }
        } catch (error) {
          selectionError = error;
        }
      }
      if (_disposed || generation != _connectionGeneration) return;
      if (selectionError == null || isMockDriver) {
        _selectedSensor = null;
        _snapshot = null;
        _persistedHistory = const <CgmReading>[];
        _allowSessionActivation = false;
        _selectionPersisted = false;
        _selectionPromotionSource = null;
        _backgroundSensorIdentity = null;
      } else {
        _snapshot = _snapshot?.copyWith(
          stage: CgmSyncStage.disconnected,
          statusText: 'Disconnected — could not archive sensor',
        );
      }
      if (!isMockDriver) {
        if (selectionError != null) {
          _recordPersistenceFailure(
            'Clearing the selected sensor',
            selectionError,
          );
        } else {
          _clearPersistenceFailure('Clearing the selected sensor');
        }
        if (selectionError == null) {
          await _clearPlatformBackgroundState();
        }
        if (_selectedSensor == null &&
            sensorToArchive != null &&
            _bondTransferTombstone(sensorToArchive) != null) {
          try {
            await _healthStateStore.remove(
              _bondTransferTombstoneKey(sensorToArchive),
            );
            _clearPersistenceFailure('Clearing sensor transfer state');
          } catch (error) {
            _recordPersistenceFailure('Clearing sensor transfer state', error);
          }
        }
      }
    } else {
      _snapshot = _snapshot?.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Disconnected',
      );
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionGeneration++;
    unawaited(
      _invalidateScan().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _cancelReconnect();
    _cancelSyncStageDeadline();
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    // Nothing else tears a live session down: [disconnect] is reached only from
    // an explicit user path. Without this the GATT client outlives the last
    // owner that could ever service it, holding a radio and a connection slot
    // for an app state that no longer exists.
    final session = _session;
    _session = null;
    unawaited(() async {
      try {
        await session?.disconnect();
      } on Object catch (error) {
        _recordPersistenceFailure('Disconnecting sensor session', error);
      }
      try {
        await _flushPrivateState?.call();
      } on Object catch (error) {
        _recordPersistenceFailure('Saving private sensor state', error);
      }
    }());
    super.dispose();
  }

  bool _ownsScan(int generation) => !_disposed && generation == _scanGeneration;

  void _recordScanFailure(Object error) {
    if (error is BleFailure) {
      _scanFailure = error;
      _lastError = userMessageForBleFailure(error, language: _appLanguage);
      return;
    }
    _scanFailure = null;
    _lastError = safeOperationFailureText(
      'Sensor scan',
      language: _appLanguage,
    );
  }

  Future<int> _invalidateScan() async {
    final invalidationGeneration = ++_scanGeneration;
    _scanning = false;
    _scanFailure = null;
    final iterator = _scanIterator;
    _scanIterator = null;
    await iterator?.cancel();
    return invalidationGeneration;
  }

  void updateDisplayPreferences(DisplayPreferences preferences) {
    _displayPreferences = preferences;
    unawaited(
      _preferences.setString(
        _displayPreferencesKey,
        jsonEncode(preferences.toJson()),
      ),
    );
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
    notifyListeners();
  }

  Future<bool> updateSensitiveLiveActivityContent({
    required bool enabled,
  }) async {
    if (_liveActivityPrivacyUpdateInFlight) {
      return false;
    }
    if (_sensitiveLiveActivityContentEnabled == enabled) {
      return true;
    }
    _liveActivityPrivacyUpdateInFlight = true;
    notifyListeners();
    var nativePreferenceChanged = false;
    try {
      await _setSensitiveLiveActivityContentOnPlatform(enabled);
      nativePreferenceChanged = true;
      await (_liveActivityPrivacyRefresh?.call() ?? _pushLiveActivity());
      _sensitiveLiveActivityContentEnabled = enabled;
      _clearPersistenceFailure('Updating lock-screen privacy');
      return true;
    } catch (error) {
      if (!enabled) {
        // Native implementations remove sensitive surfaces even when
        // persisting withdrawal fails. Mirror that fail-closed state in the
        // UI so a failed write can never make consent appear to remain on.
        _sensitiveLiveActivityContentEnabled = false;
      }
      if (nativePreferenceChanged) {
        if (enabled) {
          // Enabling is transactional: publishing failure rolls native
          // consent back before Flutter reports failure to the user.
          try {
            await _setSensitiveLiveActivityContentOnPlatform(false);
          } catch (_) {
            // Both native setters independently fail closed. Preserve the
            // original publish error for the user-facing diagnostic.
          }
        }
        // Withdrawal remains effective even if recreating a redacted surface
        // fails. For enable failures, this mirrors the rollback above.
        _sensitiveLiveActivityContentEnabled = false;
      }
      _recordPersistenceFailure('Updating lock-screen privacy', error);
      return false;
    } finally {
      _liveActivityPrivacyUpdateInFlight = false;
      notifyListeners();
    }
  }

  Future<void> _setSensitiveLiveActivityContentOnPlatform(bool enabled) async {
    final override = _liveActivityPrivacySetter;
    if (override != null) {
      await override(enabled: enabled);
      return;
    }
    await AndroidLiveUpdateBridge.setSensitiveContentEnabled(enabled: enabled);
    await IosLiveActivityBridge.setSensitiveContentEnabled(enabled: enabled);
  }

  Future<void> _restoreLiveActivityPrivacyPreference() async {
    try {
      final androidEnabled =
          await AndroidLiveUpdateBridge.sensitiveContentEnabled();
      final iosEnabled = await IosLiveActivityBridge.sensitiveContentEnabled();
      _sensitiveLiveActivityContentEnabled = androidEnabled || iosEnabled;
      _clearPersistenceFailure('Reading lock-screen privacy');
    } catch (error) {
      // Consent is fail-closed. A bridge/read failure must never opt the user
      // into exposing glucose on a lock-screen surface.
      _sensitiveLiveActivityContentEnabled = false;
      _recordPersistenceFailure('Reading lock-screen privacy', error);
    }
  }

  /// Whether the active driver is the OG_DEMO mock driver, i.e. the Developer
  /// scenario switcher should be shown.
  bool get isMockDriver => _driver is DemoCgmDriver;

  /// The mock scenario currently driving the demo session, or null when not in
  /// demo mode.
  MockScenario? get mockScenario {
    final driver = _driver;
    return driver is DemoCgmDriver ? driver.scenario : null;
  }

  /// Switches the live mock scenario without a rebuild. No-op outside OG_DEMO.
  /// The demo session emits a fresh snapshot through the existing stream, so
  /// the dashboard updates automatically.
  void applyMockScenario(MockScenario scenario) {
    final driver = _driver;
    if (driver is! DemoCgmDriver) {
      return;
    }
    final session = driver.applyScenario(scenario);
    if (session == null) {
      // Not connected yet; the new scenario becomes the default for the next
      // connect. Trigger a (re)connect to surface it immediately.
      unawaited(connect(_selectedSensor ?? driver.scenarioSensor));
      return;
    }
    _snapshot = session.currentSnapshot;
    final snapshot = _snapshot;
    _lastError = snapshot == null
        ? null
        : primaryErrorTextForSnapshot(snapshot, language: _appLanguage);
    unawaited(_pushLiveActivity());
    notifyListeners();
  }

  Future<bool> clearPersistedHistory() async {
    if (isMockDriver) {
      return false;
    }
    final sensor = _selectedSensor;
    if (sensor == null) {
      return false;
    }
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    try {
      await _healthStateStore.remove(_historyKey(sensor));
    } catch (error) {
      _recordPersistenceFailure('Clearing stored history', error);
      notifyListeners();
      return false;
    }
    _persistedHistory = const <CgmReading>[];
    _clearPersistenceFailure('Clearing stored history');
    _clearPersistenceFailure('Saving history');
    notifyListeners();
    return true;
  }

  /// Ends the current session while retaining its sensor metadata and readings
  /// in the archive. Expired sessions are labelled truthfully; an in-life
  /// sensor explicitly replaced by the user is labelled as replaced.
  Future<void> replaceCurrentSensor() {
    final current = snapshot;
    final reason = current != null && _snapshotHasExpired(current)
        ? SensorArchiveReason.expired
        : SensorArchiveReason.replaced;
    return disconnect(archiveReason: reason);
  }

  String _historyKey(DiscoveredSensor sensor) {
    final namespace = _historyNamespace?.call(sensor);
    return namespace == null
        ? _legacyHistoryKey(sensor)
        : '$namespace${encodedSensorStateIdentity(sensor)}';
  }

  String _legacyHistoryKey(DiscoveredSensor sensor) =>
      sensor.driverId == 'aidex'
      ? 'openHealth.history.${sensor.storageKey}'
      : '$_qualifiedHistoryPrefix${encodedSensorStateIdentity(sensor)}';

  String _bondTransferTombstoneKey(DiscoveredSensor sensor) =>
      sensor.driverId == 'aidex'
      ? '$_bondTransferTombstonePrefix${sensor.storageKey}'
      : '$_qualifiedBondTransferTombstonePrefix'
            '${encodedSensorStateIdentity(sensor)}';

  String? _bondTransferTombstone(DiscoveredSensor sensor) {
    if (isMockDriver) {
      return null;
    }
    final value = _healthStateStore.getString(
      _bondTransferTombstoneKey(sensor),
    );
    if (value == null || value.isEmpty) {
      return null;
    }
    return value == _bondTransferSensorAccepted
        ? _bondTransferSensorAccepted
        : _bondTransferOutcomeUnknown;
  }

  void _clearInspectedBondTransfer() {
    _inspectedBondTransferSession = null;
    _inspectedBondTransferIdentity = null;
    _inspectedBondTransferPlan = null;
  }

  List<ArchivedSensorSession> _loadSensorArchive() {
    final raw = _healthStateStore.getString(_sensorArchiveKey);
    if (raw == null || raw.isEmpty) {
      return const <ArchivedSensorSession>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <ArchivedSensorSession>[];
      }
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (value) => ArchivedSensorSession.fromJson(
              Map<String, Object?>.from(value),
            ),
          )
          .where((session) => session.storageKey.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const <ArchivedSensorSession>[];
    }
  }

  Future<void> _persistSensorArchive() {
    return _healthStateStore.setString(
      _sensorArchiveKey,
      jsonEncode(
        _archivedSensors
            .map((session) => session.toJson())
            .toList(growable: false),
      ),
    );
  }

  Future<void> _archiveSensor({
    required DiscoveredSensor sensor,
    required List<CgmReading> history,
    required SensorArchiveReason reason,
    CgmSessionSnapshot? snapshot,
    DateTime? startedAt,
  }) async {
    final sessionInfo = snapshot?.sessionInfo;
    final start =
        sessionInfo?.sessionStart ?? startedAt ?? inferSensorStart(history);
    final incomingLastReadingAt = latestReadingTime(history);
    final now = DateTime.now();
    final naturalEnd = start?.add(
      _expectedSensorLifetime(sensor, sessionInfo: sessionInfo),
    );
    final endedAt =
        reason == SensorArchiveReason.expired &&
            naturalEnd != null &&
            naturalEnd.isBefore(now)
        ? naturalEnd
        : now;
    final identityTime = start ?? incomingLastReadingAt ?? endedAt;
    final archiveId = base64Url
        .encode(
          utf8.encode(
            '${sensor.driverId}|${sensor.storageKey}|'
            '${identityTime.toUtc().millisecondsSinceEpoch}',
          ),
        )
        .replaceAll('=', '');
    final archiveHistoryKey = _historyNamespace?.call(sensor) == null
        ? 'openHealth.history.archive.$archiveId'
        : '${_historyKey(sensor)}.archive.$archiveId';
    ArchivedSensorSession? existingEntry;
    for (final entry in _archivedSensors) {
      if (entry.id == archiveId) {
        existingEntry = entry;
        break;
      }
    }
    final existingHistory = existingEntry == null
        ? const <CgmReading>[]
        : readingsForArchivedSensor(existingEntry);
    final archivedHistory = _mergeHistory(existingHistory, history);
    final lastReadingAt =
        latestReadingTime(archivedHistory) ??
        existingEntry?.lastReadingAt ??
        incomingLastReadingAt;
    if (archivedHistory.isNotEmpty) {
      await _persistHistoryAtKey(archiveHistoryKey, archivedHistory);
    }
    final entry = ArchivedSensorSession(
      id: archiveId,
      historyKey: archiveHistoryKey,
      storageKey: sensor.storageKey,
      driverId: sensor.driverId,
      deviceId: sensor.deviceId,
      displayName: sensor.displayName,
      serial: _firstNonEmpty(<String?>[
        sessionInfo?.serial,
        sensor.metadata['serial'],
        existingEntry?.serial,
      ]),
      model: _firstNonEmpty(<String?>[
        sessionInfo?.model,
        sensor.metadata['model'],
        existingEntry?.model,
      ]),
      firmware: _firstNonEmpty(<String?>[
        sessionInfo?.firmware,
        sensor.metadata['firmware'],
        existingEntry?.firmware,
      ]),
      reason: existingEntry?.reason ?? reason,
      readingCount: archivedHistory.length,
      startedAt: start ?? existingEntry?.startedAt,
      endedAt: existingEntry?.endedAt ?? endedAt,
      lastReadingAt: lastReadingAt,
    );
    final previousArchive = _archivedSensors;
    _archivedSensors = <ArchivedSensorSession>[
      for (final existing in _archivedSensors)
        if (existing.id != archiveId) existing,
      entry,
    ];
    try {
      await _persistSensorArchive();
    } catch (_) {
      _archivedSensors = previousArchive;
      rethrow;
    }
  }

  bool _persistedSensorHasExpired({
    required DiscoveredSensor sensor,
    required List<CgmReading> history,
    required DateTime? inferredStart,
    DateTime? now,
  }) {
    if (sensor.driverId == 'cbio') return false;
    final reference = now ?? DateTime.now();
    final expectedLife = _expectedSensorLifetime(sensor);
    if (inferredStart != null &&
        !inferredStart.add(expectedLife).isAfter(reference)) {
      return true;
    }
    final lastReadingAt = latestReadingTime(history);
    return lastReadingAt != null &&
        !lastReadingAt.add(expectedLife).isAfter(reference);
  }

  Duration _expectedSensorLifetime(
    DiscoveredSensor sensor, {
    CgmSessionInfo? sessionInfo,
  }) {
    final reportedMinutes = sessionInfo?.expectedLifetimeMinutes;
    final discoveredMinutes = int.tryParse(
      sensor.metadata[cgmExpectedLifetimeMinutesMetadataKey] ?? '',
    );
    final minutes = reportedMinutes ?? discoveredMinutes;
    if (minutes == null || minutes <= 0) {
      return kSensorLifeDuration;
    }
    return Duration(minutes: minutes);
  }

  bool _snapshotHasExpired(CgmSessionSnapshot value) {
    if (value.sensor.driverId == 'cbio') return false;
    return computeSensorLifecycle(
      value,
      latestReading:
          value.latestReading ??
          (value.history.isEmpty ? null : value.history.last),
    ).isExpired;
  }

  Future<void> _retireExpiredSensor() async {
    if (_retiringExpiredSensor || _selectedSensor == null) {
      return;
    }
    _retiringExpiredSensor = true;
    try {
      await disconnect(archiveReason: SensorArchiveReason.expired);
    } finally {
      _retiringExpiredSensor = false;
    }
  }

  void _promoteVerifiedSelection(
    DiscoveredSensor sensor, {
    required List<CgmReading> history,
  }) {
    final selectedSensor = _selectedSensor;
    final sensorIdentity = _storedSensorIdentity(sensor);
    if (isMockDriver ||
        _selectionPromotion != null ||
        selectedSensor == null ||
        !_sameSensor(selectedSensor, sensor)) {
      return;
    }
    final pendingPromotionSource = _selectionPromotionSource;
    final promotionSource =
        pendingPromotionSource != null &&
            _sameSensor(pendingPromotionSource, sensor)
        ? pendingPromotionSource
        : selectedSensor;
    final storageIdentityChanged = !_sameStoredSensor(selectedSensor, sensor);
    final promotionStorageIdentityChanged = !_sameStoredSensor(
      promotionSource,
      sensor,
    );
    if (_selectionPersisted &&
        !storageIdentityChanged &&
        !promotionStorageIdentityChanged &&
        _backgroundSensorIdentity == sensorIdentity) {
      return;
    }
    final selectionWasPersisted = _selectionPersisted;
    final needsSelectionWrite =
        !selectionWasPersisted || storageIdentityChanged;
    final provisionalHistoryKey = _historyKey(promotionSource);
    final verifiedHistoryKey = _historyKey(sensor);
    final currentHistory = List<CgmReading>.of(history, growable: false);
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _selectedSensor = sensor;
    if (storageIdentityChanged) {
      _selectionPersisted = false;
      _selectionPromotionSource = promotionSource;
    }
    _selectionPromotion = () async {
      try {
        final mergedHistory = _mergeHistory(
          _loadPersistedHistory(promotionSource),
          _mergeHistory(_loadPersistedHistory(sensor), currentHistory),
        );
        _persistedHistory = mergedHistory;
        if (mergedHistory.isNotEmpty) {
          // Write verified history before the durable pointer can name the
          // verified identity. A crash can retain an orphaned new cache, but
          // it cannot restore a stable identity with missing history.
          await _persistHistory(sensor, mergedHistory);
        }
        if (needsSelectionWrite) {
          await _persistSelectedSensor(sensor);
          _selectionPersisted = true;
        }
        if (_selectionPersisted &&
            provisionalHistoryKey != verifiedHistoryKey) {
          _selectionPromotionSource = null;
        }
        if (promotionStorageIdentityChanged &&
            provisionalHistoryKey != verifiedHistoryKey) {
          try {
            await _healthStateStore.remove(provisionalHistoryKey);
            _clearPersistenceFailure('Cleaning provisional sensor history');
          } catch (error) {
            _recordPersistenceFailure(
              'Cleaning provisional sensor history',
              error,
            );
          }
        }
        if (!_sensorConnectionCleanupUnconfirmed &&
            _backgroundSensorIdentity != sensorIdentity) {
          await _setBackgroundSensorBridges(sensor);
          _backgroundSensorIdentity = sensorIdentity;
        }
        _clearPersistenceFailure('Saving verified sensor selection');
      } catch (error) {
        _recordPersistenceFailure('Saving verified sensor selection', error);
      } finally {
        _selectionPromotion = null;
        notifyListeners();
      }
    }();
  }

  Future<void> _clearActivationRequiredSelection() async {
    if (_clearingActivationRequiredSensor || _selectedSensor == null) {
      return;
    }
    _clearingActivationRequiredSensor = true;
    try {
      await disconnect(clearSelection: true, archiveWhenClearing: false);
    } finally {
      _clearingActivationRequiredSensor = false;
    }
  }

  String _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return '';
  }

  bool _driverSupports(String candidateDriverId) {
    final driver = _driver;
    if (driver is CgmDriverRegistry) {
      return driver.containsDriver(candidateDriverId);
    }
    return driver.driverId == candidateDriverId;
  }

  String _sensorIdentity(DiscoveredSensor sensor) =>
      '${sensor.driverId}\u0000${sensor.deviceId}';

  bool _sameSensor(DiscoveredSensor? left, DiscoveredSensor right) =>
      left != null &&
      left.driverId == right.driverId &&
      left.deviceId == right.deviceId;

  bool _sameStoredSensor(DiscoveredSensor? left, DiscoveredSensor right) =>
      left != null &&
      left.driverId == right.driverId &&
      left.storageKey == right.storageKey;

  String _storedSensorIdentity(DiscoveredSensor sensor) =>
      '${sensor.driverId}\u0000${sensor.storageKey}';

  void _showRestoreFailure(DiscoveredSensor sensor, Object error) {
    _recordPersistenceFailure('Restoring sensor history', error);
    _snapshot = CgmSessionSnapshot(
      sensor: _publicSensor(sensor),
      capabilities: sensor.capabilities,
      stage: CgmSyncStage.error,
      statusText: 'Saved sensor history needs recovery',
      lastError: 'cgm.history.restore-invalid',
      metadata: {
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
      },
    );
    notifyListeners();
  }

  CgmSessionSnapshot _acceptSessionSnapshot(CgmSessionSnapshot incoming) {
    if (!isMockDriver &&
        (!_sameSensor(_selectedSensor, incoming.sensor) ||
            (_historyNamespace?.call(incoming.sensor) != null &&
                !_sameStoredSensor(_selectedSensor, incoming.sensor)))) {
      return CgmSessionSnapshot(
        sensor: _publicSensor(_selectedSensor ?? incoming.sensor),
        capabilities: _selectedSensor?.capabilities ?? incoming.capabilities,
        history: _persistedHistory,
        latestReading: _persistedHistory.lastOrNull,
        stage: CgmSyncStage.error,
        statusText: 'Sensor identity could not be confirmed',
        lastError: 'cgm.session.foreign',
        metadata: const {cgmAutomaticReconnectAllowedMetadataKey: 'false'},
      );
    }
    final history = isMockDriver
        ? incoming.history
        : _mergeHistory(_persistedHistory, incoming.history);
    if (_historyNamespace?.call(incoming.sensor) != null) {
      final normalized = readingsForWellness(history);
      final latest = readingsForWellness([
        ?incoming.latestReading,
      ]).lastOrNull;
      return CgmSessionSnapshot(
        stage: incoming.stage,
        statusText: incoming.statusText,
        sensor: incoming.sensor,
        capabilities: incoming.capabilities,
        latestReading: latest ?? normalized.lastOrNull,
        history: normalized,
        rawHistory: readingsForWellness(incoming.rawHistory),
        lastAdvertisement: incoming.capabilities.supportsAdvertisementGlucose
            ? incoming.lastAdvertisement
            : null,
        calibrations: incoming.calibrations,
        diagnostics: incoming.diagnostics,
        sessionInfo: incoming.sessionInfo,
        health: incoming.health,
        historySync: incoming.historySync,
        metadata: incoming.metadata,
        lastError: incoming.lastError,
      );
    }
    return incoming.copyWith(
      history: history,
      latestReading: incoming.latestReading ?? history.lastOrNull,
    );
  }

  List<CgmReading> _loadPersistedHistory(DiscoveredSensor sensor) {
    final history = _loadHistoryAtKey(_historyKey(sensor));
    return _historyNamespace?.call(sensor) == null
        ? history
        : readingsForWellness(history);
  }

  List<CgmReading> _loadHistoryAtKey(String key) {
    if (isMockDriver) {
      return const <CgmReading>[];
    }
    final raw = _healthStateStore.getString(key);
    if (raw == null || raw.isEmpty) {
      return const <CgmReading>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) {
      return const <CgmReading>[];
    }
    return decoded
        .whereType<Map<dynamic, dynamic>>()
        .map((value) => CgmReading.fromJson(Map<String, Object?>.from(value)))
        .toList(growable: false);
  }

  Future<void> _persistHistory(
    DiscoveredSensor sensor,
    List<CgmReading> history,
  ) => _persistHistoryAtKey(_historyKey(sensor), history);

  Future<void> _persistHistoryAtKey(
    String key,
    List<CgmReading> history,
  ) async {
    if (isMockDriver) {
      return;
    }
    final trimmedHistory = _historyForPersistence(history);
    await _healthStateStore.setString(
      key,
      jsonEncode(
        trimmedHistory
            .map((reading) => reading.toJson())
            .toList(growable: false),
      ),
    );
  }

  Future<void> _pushLiveActivity() async {
    if (isMockDriver) {
      await IosLiveActivityBridge.end();
      await AndroidLiveUpdateBridge.end();
      return;
    }
    final snapshot = this.snapshot;
    if (snapshot == null) {
      await IosLiveActivityBridge.end();
      await AndroidLiveUpdateBridge.end();
      return;
    }
    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: displayLatestReading,
      preferences: _displayPreferences,
      language: _appLanguage,
    );
    if (_shouldPublishIosLiveActivity(snapshot)) {
      await IosLiveActivityBridge.upsert(payload);
      await AndroidLiveUpdateBridge.upsert(payload);
    } else {
      await IosLiveActivityBridge.end();
      await AndroidLiveUpdateBridge.end();
    }
  }

  Future<void> _setBackgroundSensorBridges(DiscoveredSensor sensor) async {
    if (isMockDriver) {
      return;
    }
    await IosLiveActivityBridge.setBackgroundSensor(
      sensorName: sensor.displayName,
      serial: sensor.metadata['serial'],
    );
    await AndroidLiveUpdateBridge.setBackgroundSensor(
      sensorName: sensor.displayName,
      serial: sensor.metadata['serial'],
    );
  }

  bool _shouldPublishIosLiveActivity(CgmSessionSnapshot snapshot) {
    return shouldPublishLiveActivity(
      snapshot: snapshot,
      latestReading: displayLatestReading,
    );
  }

  void _schedulePersistHistory(
    DiscoveredSensor sensor,
    List<CgmReading> history,
  ) {
    if (isMockDriver) {
      return;
    }
    final snapshot = _historyForPersistence(history);
    _historyPersistTimer?.cancel();
    _historyPersistTimer = Timer(_historyPersistDebounce, () {
      unawaited(
        _persistHistory(sensor, snapshot)
            .then((_) {
              if (_persistenceErrors.containsKey('Saving history')) {
                _clearPersistenceFailure('Saving history');
                notifyListeners();
              }
            })
            .catchError((Object error, StackTrace _) {
              _recordPersistenceFailure('Saving history', error);
              notifyListeners();
            }),
      );
    });
  }

  void _recordPersistenceFailure(String context, Object error) {
    final message = _safeError(context, error);
    _persistenceErrors[context] = message;
    _logs.add(
      CgmLogEntry(
        timestamp: DateTime.now(),
        level: CgmLogLevel.error,
        message: message,
      ),
    );
    if (_logs.length > 250) {
      _logs.removeRange(0, _logs.length - 250);
    }
  }

  void _clearPersistenceFailure(String context) {
    _persistenceErrors.remove(context);
  }

  String _safeError(String context, Object error) {
    if (error is CgmBondTransferException) {
      return userMessageForBondTransferFailure(
        error,
        language: _appLanguage,
      );
    }
    return userMessageForBleError(error, language: _appLanguage) ??
        safeOperationFailureText(context, language: _appLanguage);
  }

  void _startPlatformTask(Future<void> task, String context) {
    unawaited(() async {
      try {
        await task;
        if (_persistenceErrors.containsKey(context)) {
          _clearPersistenceFailure(context);
          notifyListeners();
        }
      } catch (error) {
        _recordPersistenceFailure(context, error);
        notifyListeners();
      }
    }());
  }

  Future<void> _clearPlatformBackgroundState() async {
    final operations = <Future<void> Function()>[
      IosLiveActivityBridge.clearBackgroundSensor,
      IosLiveActivityBridge.end,
      AndroidLiveUpdateBridge.clearBackgroundSensor,
      AndroidLiveUpdateBridge.end,
    ];
    Object? firstError;
    for (final operation in operations) {
      try {
        await operation();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      _recordPersistenceFailure(
        'Clearing private background state',
        firstError,
      );
    } else {
      _clearPersistenceFailure('Clearing private background state');
    }
  }

  List<CgmReading> _historyForPersistence(List<CgmReading> history) {
    // Preserve source, receipt time, and provisional quality in restricted
    // local storage. Wellness/HealthKit consumers apply their own stricter
    // policy; persistence must not silently upgrade an experimental reading.
    return List<CgmReading>.from(history, growable: false);
  }

  List<CgmReading> _mergeHistory(
    Iterable<CgmReading> persisted,
    Iterable<CgmReading> incoming,
  ) {
    final readingsByKey = <String, CgmReading>{};
    void add(Iterable<CgmReading> readings) {
      for (final reading in readings) {
        final timestamp = reading.recordedAt?.toUtc().toIso8601String() ?? '';
        final minute = reading.sensorMinute;
        final key = minute == null
            ? 'time|$timestamp|${reading.source.name}'
            : 'minute|$minute|${reading.source.name}';
        readingsByKey[key] = reading;
      }
    }

    add(persisted);
    add(incoming);
    final merged = readingsByKey.values.toList(growable: false)
      ..sort((left, right) {
        final leftAt = left.recordedAt;
        final rightAt = right.recordedAt;
        if (leftAt != null && rightAt != null) {
          return leftAt.compareTo(rightAt);
        }
        if (leftAt != null) return 1;
        if (rightAt != null) return -1;
        return (left.sensorMinute ?? -1).compareTo(right.sensorMinute ?? -1);
      });
    return merged;
  }

  DiscoveredSensor? _loadPersistedSensor() {
    final raw = _healthStateStore.getString(_lastSensorKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return DiscoveredSensor.fromJson(decoded);
  }

  DiscoveredSensor _publicSensor(DiscoveredSensor sensor) {
    if (_historyNamespace?.call(sensor) == null) return sensor;
    return DiscoveredSensor.fromJson({
      ...sensor.toJson(),
      'advertisement': sensor.capabilities.supportsAdvertisementGlucose
          ? sensor.advertisement?.toJson()
          : null,
      'metadata': {
        for (final entry in sensor.metadata.entries)
          if (const {
            'serial',
            'model',
            cgmExpectedLifetimeMinutesMetadataKey,
          }.contains(entry.key))
            entry.key: entry.value,
      },
    });
  }

  Future<void> _persistSelectedSensor(DiscoveredSensor sensor) async {
    await _healthStateStore.setString(
      _lastSensorKey,
      jsonEncode(_publicSensor(sensor).toJson()),
    );
  }

  bool _needsLiveRefresh(CgmSessionSnapshot snapshot) {
    final latest = latestReading;
    if (latest == null) {
      return true;
    }
    final recordedAt = latest.recordedAt;
    if (recordedAt != null &&
        DateTime.now().difference(recordedAt) >= _liveRefreshThreshold) {
      return true;
    }
    final latestMinute = latest.sensorMinute;
    final elapsedMinutes = snapshot.sessionInfo.elapsedMinutes;
    if (latestMinute != null &&
        elapsedMinutes != null &&
        elapsedMinutes - latestMinute >= 2) {
      return true;
    }
    return recordedAt == null && latestMinute == null;
  }

  bool _needsHistoryCatchUp(CgmSessionSnapshot snapshot) {
    if (!snapshot.capabilities.supportsHistory) {
      return false;
    }
    final latest = latestReading;
    if (latest == null) {
      return snapshot.history.isEmpty;
    }
    final latestMinute = latest.sensorMinute;
    final latestStoredOffset = snapshot.historySync.latestStoredOffset;
    if (latestMinute != null) {
      if (latestStoredOffset == null) {
        return snapshot.history.isEmpty;
      }
      if (latestMinute > latestStoredOffset + 1) {
        return true;
      }
    }
    final recordedAt = latest.recordedAt;
    if (recordedAt != null &&
        DateTime.now().difference(recordedAt) >= _historyCatchUpThreshold) {
      return true;
    }
    return false;
  }

  bool _isCurrentEnough(CgmSessionSnapshot snapshot) {
    final now = DateTime.now();
    final latest = latestReading;
    final recordedAt = latest?.recordedAt;
    if (recordedAt != null &&
        now.difference(recordedAt).abs() <= const Duration(minutes: 1)) {
      return true;
    }
    final lastSyncAt = snapshot.historySync.lastSyncAt;
    if (lastSyncAt != null &&
        now.difference(lastSyncAt).abs() <= const Duration(minutes: 1)) {
      return true;
    }
    return false;
  }

  int? _resumeHistoryStartOffset(CgmSessionSnapshot snapshot) {
    final latestStoredOffset = snapshot.historySync.latestStoredOffset;
    return latestStoredOffset == null ? null : latestStoredOffset + 1;
  }

  void _scheduleReconnect() {
    if (isMockDriver) {
      return;
    }
    if (_selectedSensor == null ||
        _connectInProgress ||
        _reconnectTimer != null) {
      return;
    }
    final currentSnapshot = snapshot;
    if (currentSnapshot != null &&
        !_canAutomaticallyReconnect(currentSnapshot)) {
      return;
    }
    if (_reconnectAttempts >= _maxAutomaticReconnectAttempts) {
      _stopAutomaticReconnect(currentSnapshot);
      return;
    }
    if (currentSnapshot != null &&
        (currentSnapshot.latestReading != null ||
            currentSnapshot.history.isNotEmpty) &&
        (currentSnapshot.stage == CgmSyncStage.disconnected ||
            currentSnapshot.stage == CgmSyncStage.error)) {
      _snapshot = currentSnapshot.copyWith(
        stage: CgmSyncStage.connecting,
        statusText: 'Reconnecting',
        clearLastError: true,
      );
      notifyListeners();
    }
    _reconnectTimer = Timer(_reconnectBackoff, () {
      _reconnectTimer = null;
      _reconnectAttempts += 1;
      final sensor = _selectedSensor;
      if (sensor == null) {
        return;
      }
      final nextSnapshot = snapshot;
      if (nextSnapshot != null && !_canAutomaticallyReconnect(nextSnapshot)) {
        return;
      }
      if (nextSnapshot != null &&
          nextSnapshot.stage != CgmSyncStage.disconnected &&
          nextSnapshot.stage != CgmSyncStage.error &&
          nextSnapshot.stage != CgmSyncStage.connecting) {
        return;
      }
      unawaited(
        connect(sensor, allowSessionActivation: _allowSessionActivation),
      );
    });
  }

  /// Doubling backoff, so a sensor that stays away costs the radio less each
  /// round instead of a flat delay repeated without limit.
  Duration get _reconnectBackoff =>
      _reconnectDelay * (1 << _reconnectAttempts.clamp(0, 8));

  /// Ends the retry run with the state a user can act on.
  ///
  /// The failure carries a closed diagnostic and blocks further automatic
  /// reconnect, so the connect screen offers Try again / Choose another sensor
  /// instead of the app retrying in the background forever.
  void _stopAutomaticReconnect(CgmSessionSnapshot? currentSnapshot) {
    _cancelReconnect();
    if (currentSnapshot == null) {
      return;
    }
    final failure = BleFailure(
      kind: BleFailureKind.deviceDisconnected,
      operation: BleOperation.connect,
      diagnosticCode: automaticReconnectExhaustedCode,
    );
    _snapshot = currentSnapshot.copyWith(
      stage: CgmSyncStage.error,
      statusText: 'Reconnect stopped',
      lastError: automaticReconnectExhaustedCode,
      metadata: <String, String>{
        ...currentSnapshot.metadata,
        ...failure.toMetadata(),
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
      },
    );
    _lastError = 'Reconnect stopped. Try again when the sensor is close.';
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
    notifyListeners();
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Arms the bounded wait for the first readable result of a live session.
  ///
  /// The wait is skipped when the driver owns its own terminal outcome or the
  /// stage is expected to run long, so a healthy session is never failed for
  /// merely taking its time.
  void _trackSyncStageDeadline() {
    final snapshot = _snapshot;
    if (_disposed ||
        isMockDriver ||
        snapshot == null ||
        snapshot.stage != CgmSyncStage.syncing ||
        _syncStageWaitsAreDriverOwned(snapshot)) {
      _cancelSyncStageDeadline();
      return;
    }
    _syncStageTimer ??= Timer(_syncStageDeadline, _failSyncStage);
  }

  bool _syncStageWaitsAreDriverOwned(CgmSessionSnapshot snapshot) {
    // Libre 2 publishes its own phase and terminal failure, and an in-progress
    // history sync is a bounded, driver-owned exchange with its own progress.
    return snapshot.metadata['cgm.libre2.phase'] != null ||
        snapshot.historySync.inProgress ||
        snapshot.metadata.containsKey(cgmBondTransferStateMetadataKey);
  }

  /// Fails the stalled session closed so setup shows a next action instead of
  /// an endless "Syncing sensor history" card.
  void _failSyncStage() {
    _syncStageTimer = null;
    final snapshot = _snapshot;
    if (_disposed ||
        snapshot == null ||
        snapshot.stage != CgmSyncStage.syncing) {
      return;
    }
    _syncStageStalled = true;
    _lastError = sensorSyncStalledMessage;
    _cancelReconnect();
    _snapshot = snapshot.copyWith(
      stage: CgmSyncStage.error,
      statusText: _syncStalledStatusText,
      lastError: sensorSyncStalledMessage,
      metadata: <String, String>{
        ...snapshot.metadata,
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
        cgmSessionSyncStalledMetadataKey: 'true',
      },
    );
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
    notifyListeners();
  }

  void _cancelSyncStageDeadline() {
    _syncStageTimer?.cancel();
    _syncStageTimer = null;
  }

  bool _canAutomaticallyReconnect(CgmSessionSnapshot currentSnapshot) {
    if (!snapshotAllowsAutomaticReconnect(currentSnapshot)) {
      return false;
    }
    final verifiedOrPreviouslyUseful =
        _selectionPersisted ||
        _selectionPromotion != null ||
        currentSnapshot.latestReading != null ||
        currentSnapshot.history.isNotEmpty;
    return verifiedOrPreviouslyUseful;
  }

  DiscoveredSensor _connectionSensorFor(
    DiscoveredSensor sensor,
    List<CgmReading> history, {
    required bool allowSessionActivation,
  }) {
    final resumableHistory = history
        .where((reading) => reading.sensorMinute != null)
        .toList(growable: false);
    final latestOffset = resumableHistory.isEmpty
        ? null
        : resumableHistory.last.sensorMinute;
    final oldestOffset = resumableHistory.isEmpty
        ? null
        : resumableHistory.first.sensorMinute;
    final hasFullEnoughPrefix =
        latestOffset != null &&
        oldestOffset != null &&
        (oldestOffset <= 10 || resumableHistory.length >= 2000);

    return DiscoveredSensor(
      driverId: sensor.driverId,
      deviceId: sensor.deviceId,
      displayName: sensor.displayName,
      storageKey: sensor.storageKey,
      rssi: sensor.rssi,
      capabilities: sensor.capabilities,
      advertisement: sensor.advertisement,
      notes: sensor.notes,
      metadata: <String, String>{
        for (final entry in sensor.metadata.entries)
          if (sensor.driverId != 'cbio' ||
              (entry.key != cbioCheckpointMetadataKey &&
                  !entry.key.startsWith('cgm.cbio.clock.') &&
                  !entry.key.startsWith('cgm.cbio.resume.')))
            entry.key: entry.value,
        cgmAllowSessionActivationMetadataKey: allowSessionActivation.toString(),
        if (hasFullEnoughPrefix &&
            sensor.driverId != 'cbio') ...<String, String>{
          _resumeOffsetMetadataKey: latestOffset.toString(),
          _resumeCountMetadataKey: resumableHistory.length.toString(),
          _resumeHistoryMetadataKey: jsonEncode(
            resumableHistory
                .map((reading) => reading.toJson())
                .toList(growable: false),
          ),
        },
      },
    );
  }
}
