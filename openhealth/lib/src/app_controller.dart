import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_live_update_bridge.dart';
import 'display_preferences.dart';
import 'health_state_store.dart';
import 'ios_live_activity_bridge.dart';
import 'live_activity_payload.dart';

class CgmAppController extends ChangeNotifier {
  CgmAppController({
    required SharedPreferences preferences,
    required CgmDriver driver,
    HealthStateStore? healthStateStore,
  }) : _preferences = preferences,
       _healthStateStore =
           healthStateStore ?? PreferencesHealthStateStore(preferences),
       _driver = driver;

  static const _displayPreferencesKey = 'openHealth.displayPreferences';
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _scanTimeout = Duration(seconds: 6);
  static const _historyPersistDebounce = Duration(milliseconds: 900);
  static const _restoredConnectDelay = Duration(milliseconds: 700);
  static const _reconnectDelay = Duration(seconds: 3);
  static const _liveRefreshThreshold = Duration(minutes: 2);
  static const _historyCatchUpThreshold = Duration(minutes: 5);
  static const _resumeOffsetMetadataKey = 'resumeOffset';
  static const _resumeCountMetadataKey = 'resumeCount';
  static const _resumeHistoryMetadataKey = 'resumeHistory';

  final SharedPreferences _preferences;
  final HealthStateStore _healthStateStore;
  final CgmDriver _driver;
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
  DisplayPreferences _displayPreferences = const DisplayPreferences();
  bool _scanning = false;
  bool _connectInProgress = false;
  bool _freshnessInFlight = false;
  String? _lastError;
  final Map<String, String> _persistenceErrors = <String, String>{};

  List<DiscoveredSensor> get sensors {
    final values = _sensorsById.values.toList(growable: false);
    values.sort((left, right) => right.rssi.compareTo(left.rssi));
    return values;
  }

  bool get scanning => _scanning;

  String? get lastError {
    final persistenceError = _persistenceErrors.values.join('. ');
    if (_lastError != null && persistenceError.isNotEmpty) {
      return '$_lastError. $persistenceError';
    }
    return _lastError ?? (persistenceError.isEmpty ? null : persistenceError);
  }

  DisplayPreferences get displayPreferences => _displayPreferences;

  CgmSessionSnapshot? get snapshot {
    final raw = _snapshot;
    if (raw == null) {
      return null;
    }
    final mergedHistory = raw.history.isNotEmpty
        ? raw.history
        : _persistedHistory;
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

  List<CgmReading> get visibleHistory {
    final history = snapshot?.history ?? const <CgmReading>[];
    final crop = _displayPreferences.cropFirstSamples;
    if (crop <= 0 || crop >= history.length) {
      return history;
    }
    return history.skip(crop).toList(growable: false);
  }

  List<CgmLogEntry> get logs => List<CgmLogEntry>.unmodifiable(_logs.reversed);

  Future<void> initialize() async {
    await _healthStateStore.initialize();
    final rawPreferences = _preferences.getString(_displayPreferencesKey);
    if (rawPreferences != null && rawPreferences.isNotEmpty) {
      final decoded = jsonDecode(rawPreferences);
      if (decoded is Map<String, Object?>) {
        _displayPreferences = DisplayPreferences.fromJson(decoded);
      }
    }

    final restoredSensor = _loadPersistedSensor();
    if (restoredSensor == null) {
      return;
    }

    _selectedSensor = restoredSensor;
    _persistedHistory = _loadPersistedHistory(restoredSensor.storageKey);
    _snapshot = CgmSessionSnapshot(
      stage: CgmSyncStage.connecting,
      statusText: 'Reconnecting',
      sensor: restoredSensor,
      capabilities: restoredSensor.capabilities,
      lastAdvertisement: restoredSensor.advertisement,
      history: _persistedHistory,
      latestReading: _persistedHistory.isEmpty ? null : _persistedHistory.last,
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
      unawaited(connect(restoredSensor));
    });
  }

  Future<void> scan() async {
    _scanning = true;
    _lastError = null;
    _sensorsById.clear();
    notifyListeners();

    try {
      await for (final sensor in _driver.scan(timeout: _scanTimeout)) {
        _sensorsById[sensor.deviceId] = sensor;
        notifyListeners();
      }
    } catch (error) {
      _lastError = _safeError('Sensor scan', error);
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  Future<void> connect(DiscoveredSensor sensor) async {
    if (_connectInProgress) {
      return;
    }
    _connectInProgress = true;
    _cancelReconnect();
    try {
      await disconnect(clearSelection: false);
      _selectedSensor = sensor;
      _persistedHistory = _loadPersistedHistory(sensor.storageKey);
      await _persistSelectedSensor(sensor);
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
        _connectionSensorFor(sensor, _persistedHistory),
      );
      _session = session;
      _snapshot = session.currentSnapshot;
      _startPlatformTask(
        _setBackgroundSensorBridges(sensor),
        'Saving private background sensor state',
      );
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      _snapshotSubscription = session.snapshots.listen((nextSnapshot) {
        _snapshot = nextSnapshot;
        final reconnectingStage =
            nextSnapshot.stage == CgmSyncStage.disconnected ||
            nextSnapshot.stage == CgmSyncStage.error;
        if (nextSnapshot.lastError != null && reconnectingStage) {
          _lastError = 'Sensor connection reported an error';
        } else if (!reconnectingStage) {
          _lastError = null;
        }
        if (_selectedSensor != null && nextSnapshot.history.isNotEmpty) {
          _persistedHistory = nextSnapshot.history;
          if (!nextSnapshot.historySync.inProgress) {
            _schedulePersistHistory(
              _selectedSensor!.storageKey,
              nextSnapshot.history,
            );
          }
        }
        if (reconnectingStage) {
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
      await connect(sensor);
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

  Future<void> disconnect({bool clearSelection = true}) async {
    _cancelReconnect();
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
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
      Object? selectionError;
      try {
        await _healthStateStore.remove(_lastSensorKey);
      } catch (error) {
        selectionError = error;
      }
      _selectedSensor = null;
      _snapshot = null;
      _persistedHistory = const <CgmReading>[];
      if (selectionError != null) {
        _recordPersistenceFailure(
          'Clearing the selected sensor',
          selectionError,
        );
      } else {
        _clearPersistenceFailure('Clearing the selected sensor');
      }
      await _clearPlatformBackgroundState();
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
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _cancelReconnect();
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    super.dispose();
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

  Future<bool> clearPersistedHistory() async {
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

  String _historyKey(String storageKey) => 'openHealth.history.$storageKey';

  List<CgmReading> _loadPersistedHistory(String storageKey) {
    final raw = _healthStateStore.getString(_historyKey(storageKey));
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
    final trimmedHistory = _historyForPersistence(history);
    await _healthStateStore.setString(
      _historyKey(storageKey),
      jsonEncode(
        trimmedHistory
            .map((reading) => reading.toJson())
            .toList(growable: false),
      ),
    );
  }

  Future<void> _pushLiveActivity() async {
    final snapshot = this.snapshot;
    if (snapshot == null) {
      await IosLiveActivityBridge.end();
      await AndroidLiveUpdateBridge.end();
      return;
    }
    final payload = buildLiveActivityPayload(
      snapshot: snapshot,
      latestReading: latestReading,
      preferences: _displayPreferences,
    );
    if (_shouldPublishIosLiveActivity(snapshot)) {
      await IosLiveActivityBridge.upsert(payload);
    } else {
      await IosLiveActivityBridge.end();
    }
    await AndroidLiveUpdateBridge.upsert(payload);
  }

  Future<void> _setBackgroundSensorBridges(DiscoveredSensor sensor) async {
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
    if (snapshot.history.isNotEmpty) {
      return true;
    }
    final reading = latestReading;
    if (reading != null) {
      return true;
    }
    return snapshot.stage == CgmSyncStage.ready;
  }

  void _schedulePersistHistory(String storageKey, List<CgmReading> history) {
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
    return '$context failed (${error.runtimeType})';
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
    if (_selectedSensor == null ||
        _connectInProgress ||
        _reconnectTimer != null) {
      return;
    }
    final currentSnapshot = snapshot;
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
      if (nextSnapshot != null &&
          nextSnapshot.stage != CgmSyncStage.disconnected &&
          nextSnapshot.stage != CgmSyncStage.error &&
          nextSnapshot.stage != CgmSyncStage.connecting) {
        return;
      }
      unawaited(connect(sensor));
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  DiscoveredSensor _connectionSensorFor(
    DiscoveredSensor sensor,
    List<CgmReading> history,
  ) {
    final resumableHistory = history
        .where((reading) => reading.sensorMinute != null)
        .toList(growable: false);
    if (resumableHistory.isEmpty) {
      return sensor;
    }

    final latestOffset = resumableHistory.last.sensorMinute;
    if (latestOffset == null) {
      return sensor;
    }

    final oldestOffset = resumableHistory.first.sensorMinute;
    final hasFullEnoughPrefix =
        oldestOffset != null &&
        (oldestOffset <= 10 || resumableHistory.length >= 2000);
    if (!hasFullEnoughPrefix) {
      return sensor;
    }

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
        _resumeOffsetMetadataKey: latestOffset.toString(),
        _resumeCountMetadataKey: resumableHistory.length.toString(),
        _resumeHistoryMetadataKey: jsonEncode(
          resumableHistory
              .map((reading) => reading.toJson())
              .toList(growable: false),
        ),
      },
    );
  }
}
