import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_live_update_bridge.dart';
import 'demo_driver.dart';
import 'display_preferences.dart';
import 'health_state_store.dart';
import 'ios_live_activity_bridge.dart';
import 'live_activity_payload.dart';
import 'mock_scenarios.dart';
import 'sensor_archive.dart';
import 'session_presentation.dart';

typedef LiveActivityPrivacySetter =
    Future<void> Function({required bool enabled});

class CgmAppController extends ChangeNotifier {
  CgmAppController({
    required SharedPreferences preferences,
    required CgmDriver driver,
    HealthStateStore? healthStateStore,
    Duration reconnectDelay = const Duration(seconds: 3),
    @visibleForTesting LiveActivityPrivacySetter? liveActivityPrivacySetter,
    @visibleForTesting Future<void> Function()? liveActivityPrivacyRefresh,
  }) : _preferences = preferences,
       _healthStateStore =
           healthStateStore ?? PreferencesHealthStateStore(preferences),
       _reconnectDelay = reconnectDelay,
       _liveActivityPrivacySetter = liveActivityPrivacySetter,
       _liveActivityPrivacyRefresh = liveActivityPrivacyRefresh,
       _driver = driver;

  static const _displayPreferencesKey = 'openHealth.displayPreferences';
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _sensorArchiveKey = 'openHealth.sensorArchive';
  static const _scanTimeout = Duration(seconds: 6);
  static const _historyPersistDebounce = Duration(milliseconds: 900);
  static const _restoredConnectDelay = Duration(milliseconds: 700);
  static const _liveRefreshThreshold = Duration(minutes: 2);
  static const _historyCatchUpThreshold = Duration(minutes: 5);
  static const _resumeOffsetMetadataKey = 'resumeOffset';
  static const _resumeCountMetadataKey = 'resumeCount';
  static const _resumeHistoryMetadataKey = 'resumeHistory';

  final SharedPreferences _preferences;
  final HealthStateStore _healthStateStore;
  final Duration _reconnectDelay;
  final CgmDriver _driver;
  final LiveActivityPrivacySetter? _liveActivityPrivacySetter;
  final Future<void> Function()? _liveActivityPrivacyRefresh;
  final Map<String, DiscoveredSensor> _sensorsById =
      <String, DiscoveredSensor>{};
  final List<CgmLogEntry> _logs = <CgmLogEntry>[];

  CgmSession? _session;
  StreamSubscription<CgmSessionSnapshot>? _snapshotSubscription;
  StreamSubscription<CgmLogEntry>? _logSubscription;
  Timer? _historyPersistTimer;
  Timer? _reconnectTimer;
  CgmSessionSnapshot? _snapshot;
  DiscoveredSensor? _selectedSensor;
  List<CgmReading> _persistedHistory = const <CgmReading>[];
  List<ArchivedSensorSession> _archivedSensors =
      const <ArchivedSensorSession>[];
  DisplayPreferences _displayPreferences = const DisplayPreferences();
  bool _sensitiveLiveActivityContentEnabled = false;
  bool _liveActivityPrivacyUpdateInFlight = false;
  bool _scanning = false;
  BleFailure? _scanFailure;
  int _scanGeneration = 0;
  bool _disposed = false;
  bool _connectInProgress = false;
  bool _freshnessInFlight = false;
  bool _retiringExpiredSensor = false;
  bool _clearingActivationRequiredSensor = false;
  bool _allowSessionActivation = false;
  bool _selectionPersisted = false;
  Future<void>? _selectionPromotion;
  String? _backgroundSensorStorageKey;
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
    final failure? => userMessageForBleFailure(failure),
    null => null,
  };

  String? get lastError {
    final persistenceError = _persistenceErrors.values.join('. ');
    if (_lastError != null && persistenceError.isNotEmpty) {
      return '$_lastError. $persistenceError';
    }
    return _lastError ?? (persistenceError.isEmpty ? null : persistenceError);
  }

  DisplayPreferences get displayPreferences => _displayPreferences;

  bool get sensitiveLiveActivityContentEnabled =>
      _sensitiveLiveActivityContentEnabled;

  bool get liveActivityPrivacyUpdateInFlight =>
      _liveActivityPrivacyUpdateInFlight;

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
    return List<CgmReading>.unmodifiable(_loadHistoryAtKey(session.historyKey));
  }

  /// Archived readings suitable for charts and wellness analytics.
  ///
  /// The raw retained history remains available through
  /// [readingsForArchivedSensor] so data export stays complete.
  List<CgmReading> displayReadingsForArchivedSensor(
    ArchivedSensorSession session,
  ) {
    return readingsAfterWarmup(
      _loadHistoryAtKey(session.historyKey),
      sessionStart: session.startedAt,
      warmupMinutes: const CgmSessionInfo().warmupMinutes,
    );
  }

  /// All retained readings across previous sensors plus the active sensor.
  /// Duplicate records are collapsed so an archive hand-off cannot inflate
  /// long-range summaries.
  List<CgmReading> get allHistoricalReadings {
    final byIdentity = <String, CgmReading>{};
    void addAll(Iterable<CgmReading> readings) {
      for (final reading in readings) {
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
    if (restoredSensor == null || restoredSensor.driverId != _driver.driverId) {
      return;
    }

    _selectedSensor = restoredSensor;
    _selectionPersisted = true;
    _persistedHistory = _loadPersistedHistory(restoredSensor.storageKey);
    final inferredStart = inferSensorStart(_persistedHistory);
    if (_persistedSensorHasExpired(
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
      await _healthStateStore.remove(_historyKey(restoredSensor.storageKey));
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
      sensor: restoredSensor,
      capabilities: restoredSensor.capabilities,
      lastAdvertisement: restoredSensor.advertisement,
      history: _persistedHistory,
      latestReading: _persistedHistory.isEmpty ? null : _persistedHistory.last,
      sessionInfo: CgmSessionInfo(sessionStart: inferredStart),
      metadata: <String, String>{
        'deviceId': restoredSensor.deviceId,
        ...restoredSensor.metadata,
      },
    );
    _startPlatformTask(
      _pushLiveActivity(),
      'Updating private lock-screen state',
    );
    notifyListeners();
    Timer(_restoredConnectDelay, () {
      if (_session != null ||
          _selectedSensor?.deviceId != restoredSensor.deviceId) {
        return;
      }
      unawaited(connect(restoredSensor, allowSessionActivation: false));
    });
  }

  Future<void> scan() async {
    if (_disposed) {
      return;
    }
    final generation = ++_scanGeneration;
    _scanning = true;
    _scanFailure = null;
    _lastError = null;
    _sensorsById.clear();
    notifyListeners();

    try {
      await for (final sensor in _driver.scan(timeout: _scanTimeout)) {
        if (!_ownsScan(generation)) {
          break;
        }
        _sensorsById[sensor.deviceId] = sensor;
        notifyListeners();
      }
    } catch (error) {
      if (!_ownsScan(generation)) {
        return;
      }
      if (error is BleFailure) {
        _scanFailure = error;
        _lastError = userMessageForBleFailure(error);
      } else {
        _scanFailure = null;
        _lastError =
            'Sensor scan could not be completed. Check Bluetooth and try '
            'again.';
      }
    } finally {
      if (_ownsScan(generation)) {
        _scanning = false;
        notifyListeners();
      }
    }
  }

  Future<void> connect(
    DiscoveredSensor sensor, {
    bool allowSessionActivation = true,
  }) async {
    _invalidateScan();
    if (_connectInProgress) {
      return;
    }
    _connectInProgress = true;
    _cancelReconnect();
    try {
      if (sensor.driverId != _driver.driverId) {
        _lastError =
            'Sensor driver ${sensor.driverId} does not match '
            '${_driver.driverId}.';
        notifyListeners();
        return;
      }
      final resumeVerifiedSelection =
          _selectionPersisted &&
          _selectedSensor?.storageKey == sensor.storageKey;
      await disconnect(clearSelection: false);
      _allowSessionActivation = allowSessionActivation;
      _selectedSensor = sensor;
      _selectionPersisted = resumeVerifiedSelection;
      _persistedHistory = isMockDriver || !resumeVerifiedSelection
          ? const <CgmReading>[]
          : _loadPersistedHistory(sensor.storageKey);
      _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.connecting,
        statusText: 'Connecting',
        sensor: sensor,
        capabilities: sensor.capabilities,
        lastAdvertisement: sensor.advertisement,
        history: _persistedHistory,
        latestReading: _persistedHistory.isEmpty
            ? null
            : _persistedHistory.last,
        metadata: <String, String>{
          'deviceId': sensor.deviceId,
          ...sensor.metadata,
        },
      );
      _logs.clear();
      _lastError = null;
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
      _session = session;
      _snapshot = session.currentSnapshot;
      final initialErrorSnapshot = _snapshot;
      if (initialErrorSnapshot != null &&
          (initialErrorSnapshot.stage == CgmSyncStage.error ||
              initialErrorSnapshot.stage == CgmSyncStage.disconnected)) {
        _lastError = primaryErrorTextForSnapshot(initialErrorSnapshot);
      }
      if (_snapshot?.stage == CgmSyncStage.ready) {
        _promoteVerifiedSelection(sensor);
      }
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      _snapshotSubscription = session.snapshots.listen((nextSnapshot) {
        final nextHistory = isMockDriver
            ? nextSnapshot.history
            : _mergeHistory(_persistedHistory, nextSnapshot.history);
        _snapshot = nextSnapshot.copyWith(
          history: nextHistory,
          latestReading:
              nextSnapshot.latestReading ??
              (nextHistory.isEmpty ? null : nextHistory.last),
        );
        final reconnectingStage =
            nextSnapshot.stage == CgmSyncStage.disconnected ||
            nextSnapshot.stage == CgmSyncStage.error;
        if (nextSnapshot.lastError != null && reconnectingStage) {
          _lastError =
              primaryErrorTextForSnapshot(_snapshot!) ??
              'Sensor connection reported an error';
        } else if (!reconnectingStage) {
          _lastError = null;
        }
        if (!isMockDriver &&
            _selectedSensor != null &&
            nextHistory.isNotEmpty) {
          _persistedHistory = nextHistory;
          if (!nextSnapshot.historySync.inProgress) {
            _schedulePersistHistory(_selectedSensor!.storageKey, nextHistory);
          }
        }
        if (!isMockDriver && _snapshotHasExpired(nextSnapshot)) {
          unawaited(_retireExpiredSensor());
          return;
        }
        if (!isMockDriver &&
            nextSnapshot.metadata['activationRequired'] == 'true') {
          unawaited(_clearActivationRequiredSelection());
          return;
        }
        if (nextSnapshot.stage == CgmSyncStage.activating) {
          // Starting a sensor is irreversible. Once the driver begins that
          // exchange, any automatic retry must fail closed and require a new
          // explicit scan selection rather than attempting activation again.
          _allowSessionActivation = false;
        }
        if (nextSnapshot.stage == CgmSyncStage.ready) {
          // Once the sensor has proven that an active session exists, future
          // background reconnects must never be allowed to start a new one.
          _allowSessionActivation = false;
          _promoteVerifiedSelection(sensor);
        }
        if (reconnectingStage &&
            !isMockDriver &&
            snapshotAllowsAutomaticReconnect(_snapshot!)) {
          _scheduleReconnect();
        } else {
          _cancelReconnect();
        }
        _startPlatformTask(
          _pushLiveActivity(),
          'Updating private lock-screen state',
        );
        notifyListeners();
      });
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
          unawaited(_clearActivationRequiredSelection());
        } else if (_snapshotHasExpired(initialSnapshot)) {
          unawaited(_retireExpiredSensor());
        }
      }
      notifyListeners();
    } catch (error) {
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
    if (_isBusyStage(currentSnapshot.stage) ||
        currentSnapshot.historySync.inProgress) {
      return;
    }

    final needsLiveRefresh = force || _needsLiveRefresh(currentSnapshot);
    final needsHistoryCatchUp = force || _needsHistoryCatchUp(currentSnapshot);
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
          !_isBusyStage(refreshedSnapshot.stage) &&
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
      if (refreshedSnapshot == null || _isCurrentEnough(refreshedSnapshot)) {
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
    if (session == null) {
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
    if (session == null) {
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
    if (session == null) {
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
  }) async {
    _invalidateScan();
    _cancelReconnect();
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
    for (final operation in <Future<void> Function()>[
      if (snapshotSubscription != null) snapshotSubscription.cancel,
      if (logSubscription != null) logSubscription.cancel,
      if (session != null) session.disconnect,
    ]) {
      try {
        await operation();
      } catch (error) {
        teardownError ??= error;
      }
    }
    if (teardownError != null) {
      _recordPersistenceFailure('Disconnecting sensor session', teardownError);
    } else {
      _clearPersistenceFailure('Disconnecting sensor session');
    }

    if (clearSelection) {
      final selectionPromotion = _selectionPromotion;
      if (selectionPromotion != null) {
        await selectionPromotion;
      }
      Object? selectionError;
      if (!isMockDriver) {
        try {
          if (sensorToArchive != null && archiveWhenClearing) {
            if (historyToArchive.isNotEmpty) {
              await _persistHistory(
                sensorToArchive.storageKey,
                historyToArchive,
              );
            }
            await _archiveSensor(
              sensor: sensorToArchive,
              history: historyToArchive,
              reason: archiveReason,
              snapshot: snapshotToArchive,
            );
          }
          await _healthStateStore.remove(_lastSensorKey);
          if (sensorToArchive != null) {
            try {
              await _healthStateStore.remove(
                _historyKey(sensorToArchive.storageKey),
              );
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
      if (selectionError == null || isMockDriver) {
        _selectedSensor = null;
        _snapshot = null;
        _persistedHistory = const <CgmReading>[];
        _allowSessionActivation = false;
        _selectionPersisted = false;
        _backgroundSensorStorageKey = null;
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
    _invalidateScan();
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _cancelReconnect();
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    super.dispose();
  }

  bool _ownsScan(int generation) => !_disposed && generation == _scanGeneration;

  void _invalidateScan() {
    _scanGeneration += 1;
    _scanning = false;
    _scanFailure = null;
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
    _lastError = _snapshot?.lastError;
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
      await _healthStateStore.remove(_historyKey(sensor.storageKey));
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

  String _historyKey(String storageKey) => 'openHealth.history.$storageKey';

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
    final naturalEnd = start?.add(kSensorLifeDuration);
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
    final archiveHistoryKey = 'openHealth.history.archive.$archiveId';
    ArchivedSensorSession? existingEntry;
    for (final entry in _archivedSensors) {
      if (entry.id == archiveId) {
        existingEntry = entry;
        break;
      }
    }
    final existingHistory = existingEntry == null
        ? const <CgmReading>[]
        : _loadHistoryAtKey(existingEntry.historyKey);
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
    required List<CgmReading> history,
    required DateTime? inferredStart,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    if (inferredStart != null &&
        !inferredStart.add(kSensorLifeDuration).isAfter(reference)) {
      return true;
    }
    final lastReadingAt = latestReadingTime(history);
    return lastReadingAt != null &&
        !lastReadingAt.add(kSensorLifeDuration).isAfter(reference);
  }

  bool _snapshotHasExpired(CgmSessionSnapshot value) {
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

  void _promoteVerifiedSelection(DiscoveredSensor sensor) {
    if (isMockDriver ||
        _selectionPromotion != null ||
        _selectedSensor?.deviceId != sensor.deviceId ||
        (_selectionPersisted &&
            _backgroundSensorStorageKey == sensor.storageKey)) {
      return;
    }
    _selectionPromotion = () async {
      try {
        if (!_selectionPersisted) {
          await _persistSelectedSensor(sensor);
          _selectionPersisted = true;
        }
        if (_backgroundSensorStorageKey != sensor.storageKey) {
          await _setBackgroundSensorBridges(sensor);
          _backgroundSensorStorageKey = sensor.storageKey;
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

  List<CgmReading> _loadPersistedHistory(String storageKey) {
    return _loadHistoryAtKey(_historyKey(storageKey));
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
    String storageKey,
    List<CgmReading> history,
  ) async {
    return _persistHistoryAtKey(_historyKey(storageKey), history);
  }

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

  void _schedulePersistHistory(String storageKey, List<CgmReading> history) {
    if (isMockDriver) {
      return;
    }
    final snapshot = _historyForPersistence(history);
    _historyPersistTimer?.cancel();
    _historyPersistTimer = Timer(_historyPersistDebounce, () {
      unawaited(
        _persistHistory(storageKey, snapshot)
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
    return userMessageForBleError(error) ??
        '$context failed (${error.runtimeType})';
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

  Future<void> _persistSelectedSensor(DiscoveredSensor sensor) async {
    await _healthStateStore.setString(
      _lastSensorKey,
      jsonEncode(sensor.toJson()),
    );
  }

  bool _isBusyStage(CgmSyncStage stage) {
    return stage == CgmSyncStage.connecting ||
        stage == CgmSyncStage.bonding ||
        stage == CgmSyncStage.pairing ||
        stage == CgmSyncStage.activating ||
        stage == CgmSyncStage.syncing;
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
    _reconnectTimer = Timer(_reconnectDelay, () {
      _reconnectTimer = null;
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

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
        ...sensor.metadata,
        cgmAllowSessionActivationMetadataKey: allowSessionActivation.toString(),
        if (hasFullEnoughPrefix) ...<String, String>{
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
