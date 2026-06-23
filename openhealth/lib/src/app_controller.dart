import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_live_update_bridge.dart';
import 'demo_driver.dart';
import 'display_preferences.dart';
import 'ios_live_activity_bridge.dart';
import 'live_activity_payload.dart';
import 'mock_scenarios.dart';

class CgmAppController extends ChangeNotifier {
  CgmAppController({
    required SharedPreferences preferences,
    required CgmDriver driver,
  }) : _preferences = preferences,
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

  List<DiscoveredSensor> get sensors {
    final values = _sensorsById.values.toList(growable: false);
    values.sort((left, right) => right.rssi.compareTo(left.rssi));
    return values;
  }

  bool get scanning => _scanning;

  String? get lastError => _lastError;

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
    unawaited(_pushLiveActivity());
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
      _lastError = error.toString();
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
      unawaited(_pushLiveActivity());
      notifyListeners();

      final session = await _driver.connect(
        _connectionSensorFor(sensor, _persistedHistory),
      );
      _session = session;
      _snapshot = session.currentSnapshot;
      unawaited(_setBackgroundSensorBridges(sensor));
      unawaited(_pushLiveActivity());
      _snapshotSubscription = session.snapshots.listen((nextSnapshot) {
        _snapshot = nextSnapshot;
        final reconnectingStage =
            nextSnapshot.stage == CgmSyncStage.disconnected ||
            nextSnapshot.stage == CgmSyncStage.error;
        if (nextSnapshot.lastError != null && reconnectingStage) {
          _lastError = nextSnapshot.lastError;
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
        unawaited(_pushLiveActivity());
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
      _lastError = error.toString();
      _snapshot = _snapshot?.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Connection failed',
        lastError: error.toString(),
      );
      unawaited(_pushLiveActivity());
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
      _lastError = error.toString();
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
      _lastError = error.toString();
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
      _lastError = error.toString();
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
      _lastError = error.toString();
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
      _lastError = error.toString();
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
      _lastError = error.toString();
      notifyListeners();
    }
  }

  Future<void> disconnect({bool clearSelection = true}) async {
    _cancelReconnect();
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    await _snapshotSubscription?.cancel();
    await _logSubscription?.cancel();
    _snapshotSubscription = null;
    _logSubscription = null;

    final session = _session;
    _session = null;
    if (session != null) {
      await session.disconnect();
    }

    if (clearSelection) {
      _selectedSensor = null;
      _snapshot = null;
      _persistedHistory = const <CgmReading>[];
      await _preferences.remove(_lastSensorKey);
      await IosLiveActivityBridge.clearBackgroundSensor();
      await IosLiveActivityBridge.end();
      await AndroidLiveUpdateBridge.clearBackgroundSensor();
      await AndroidLiveUpdateBridge.end();
    } else {
      _snapshot = _snapshot?.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Disconnected',
      );
      unawaited(_pushLiveActivity());
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
    unawaited(_pushLiveActivity());
    notifyListeners();
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

  void clearPersistedHistory() {
    final sensor = _selectedSensor;
    if (sensor == null) {
      return;
    }
    _persistedHistory = const <CgmReading>[];
    unawaited(_preferences.remove(_historyKey(sensor.storageKey)));
    notifyListeners();
  }

  String _historyKey(String storageKey) => 'openHealth.history.$storageKey';

  List<CgmReading> _loadPersistedHistory(String storageKey) {
    final raw = _preferences.getString(_historyKey(storageKey));
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
    await _preferences.setString(
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
      unawaited(_persistHistory(storageKey, snapshot));
    });
  }

  List<CgmReading> _historyForPersistence(List<CgmReading> history) {
    return List<CgmReading>.from(history, growable: false);
  }

  DiscoveredSensor? _loadPersistedSensor() {
    final raw = _preferences.getString(_lastSensorKey);
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
    await _preferences.setString(_lastSensorKey, jsonEncode(sensor.toJson()));
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
