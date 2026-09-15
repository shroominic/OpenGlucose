import 'dart:async';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_live_update_bridge.dart';
import 'cgm_driver_registry.dart';
import 'demo_driver.dart';
import 'display_preferences.dart';
import 'health_state_store.dart';
import 'ios_live_activity_bridge.dart';
import 'live_activity_payload.dart';
import 'mock_scenarios.dart';
import 'sensor_archive.dart';
import 'sensor_archive_export_data.dart';
import 'sensor_connection_policy.dart';
import 'sensor_data_profiles.dart';
import 'sensor_history_repository.dart';
import 'session_presentation.dart';

typedef LiveActivityPrivacySetter =
    Future<void> Function({required bool enabled});

/// One exact-target app pause for an explicitly requested Libre history read.
/// This is not native NFC authority. The read owner must stop its NFC session
/// before release, including on route disposal, cancellation, and errors.
final class CgmPausedSensorConnection {
  CgmPausedSensorConnection._(this._controller, this._sensor);

  final CgmAppController _controller;
  final DiscoveredSensor _sensor;
  bool _ready = false;
  bool _released = false;

  bool get isCurrent =>
      _ready &&
      !_released &&
      !_controller._disposed &&
      identical(_controller._historyReadPause, this) &&
      _controller._sameSensor(_controller._selectedSensor, _sensor) &&
      _controller._sameStoredSensor(_controller._selectedSensor, _sensor);

  /// A failed or timed-out stop is not cleanup proof. Once released, later
  /// calls cannot upgrade an unconfirmed outcome or affect a newer owner.
  void release({required bool cleanupConfirmed}) {
    if (_released) return;
    _released = true;
    _controller._releaseHistoryRead(this, cleanupConfirmed: cleanupConfirmed);
  }

  @override
  String toString() => 'CgmPausedSensorConnection(target: <redacted>)';
}

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
    SensorHistoryRepository? historyRepository,
    Duration reconnectDelay = const Duration(seconds: 3),
    @visibleForTesting
    Duration pendingConnectionCleanupTimeout = const Duration(seconds: 15),
    @visibleForTesting LiveActivityPrivacySetter? liveActivityPrivacySetter,
    @visibleForTesting Future<void> Function()? liveActivityPrivacyRefresh,
    @visibleForTesting AndroidLiveUpdateClient? androidLiveUpdateClient,
    @visibleForTesting
    Future<void> Function(LiveActivityPayload?)? iosLiveActivityUpdater,
  }) : _preferences = preferences,
       _healthStateStore =
           healthStateStore ?? PreferencesHealthStateStore(preferences),
       _reconnectDelay = reconnectDelay,
       _pendingConnectionCleanupTimeout = pendingConnectionCleanupTimeout,
       _liveActivityPrivacySetter = liveActivityPrivacySetter,
       _liveActivityPrivacyRefresh = liveActivityPrivacyRefresh,
       _iosLiveActivityUpdater = iosLiveActivityUpdater,
       _androidLiveUpdates = AndroidLiveUpdateDispatcher(
         client:
             androidLiveUpdateClient ?? const PlatformAndroidLiveUpdateClient(),
       ),
       _driver = driver {
    _historyRepository =
        historyRepository ?? SensorHistoryRepository(_healthStateStore);
  }

  static const _displayPreferencesKey = 'openHealth.displayPreferences';
  static const _lastSensorKey = 'openHealth.lastSensor';
  static const _sensorArchiveKey = 'openHealth.sensorArchive';
  static const _bondTransferTombstonePrefix = 'openHealth.bondTransfer.';
  static const _qualifiedBondTransferTombstonePrefix =
      'openHealth.bondTransfer.v2.';
  static const _bondTransferOutcomeUnknown = 'outcome-unknown';
  static const _bondTransferSensorAccepted = 'sensor-accepted';
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
  late final SensorHistoryRepository _historyRepository;
  final Duration _reconnectDelay;
  final Duration _pendingConnectionCleanupTimeout;
  final CgmDriver _driver;
  final LiveActivityPrivacySetter? _liveActivityPrivacySetter;
  final Future<void> Function()? _liveActivityPrivacyRefresh;
  final AndroidLiveUpdateDispatcher _androidLiveUpdates;
  final Future<void> Function(LiveActivityPayload?)? _iosLiveActivityUpdater;
  final Map<String, DiscoveredSensor> _sensorsById =
      <String, DiscoveredSensor>{};
  final List<CgmLogEntry> _logs = <CgmLogEntry>[];

  CgmSession? _session;
  bool _sensorConnectionCleanupUnconfirmed = false;
  bool _sensorHistoryUnconfirmed = false;

  /// Native ownership was not released. A new connection in this process is
  /// unsafe; preserve receiver/history and require an actual app restart.
  bool get sensorConnectionCleanupUnconfirmed =>
      _sensorConnectionCleanupUnconfirmed ||
      (_snapshot?.sensor.driverId == 'libre2-gen1' &&
          (_snapshot?.lastError == 'libre2.cleanupUnconfirmed' ||
              _snapshot?.lastError == 'libre2.observationStorageUnavailable'));
  StreamSubscription<CgmSessionSnapshot>? _snapshotSubscription;
  StreamSubscription<CgmLogEntry>? _logSubscription;
  Timer? _historyPersistTimer;
  bool _historyFlushFailed = false;
  Timer? _reconnectTimer;
  CgmSessionSnapshot? _snapshot;
  DiscoveredSensor? _selectedSensor;
  List<CgmReading> _persistedHistory = const <CgmReading>[];
  List<ArchivedSensorSession> _archivedSensors =
      const <ArchivedSensorSession>[];
  bool _archiveManifestUnavailable = false;

  bool get archiveManifestUnavailable => _archiveManifestUnavailable;
  DisplayPreferences _displayPreferences = const DisplayPreferences();
  bool _sensitiveLiveActivityContentEnabled = false;
  bool _liveActivityPrivacyUpdateInFlight = false;
  bool _scanning = false;
  BleFailure? _scanFailure;
  int _scanGeneration = 0;
  StreamIterator<DiscoveredSensor>? _scanIterator;
  bool _disposed = false;
  bool _connectInProgress = false;
  int _connectionGeneration = 0;
  int? _activeConnectionAttemptGeneration;
  Future<CgmSession>? _pendingDriverConnection;
  Future<void>? _disconnectOperation;
  CgmPausedSensorConnection? _historyReadPause;
  bool _historyReadResumeRequired = false;
  bool _transportCleanupInProgress = false;
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

  bool get historyReadInProgress => _historyReadPause != null;

  /// Current, committed Libre reception can finish setup even when the
  /// decoder rejected the current glucose sample. Restored history alone,
  /// a pending selection write, or an uncertain transport cannot do so. This
  /// predicate never changes the snapshot or current-glucose eligibility.
  bool hasVerifiedLibreReceptionFor(DiscoveredSensor sensor) {
    final session = _session;
    final candidate = _snapshot;
    if (_disposed ||
        session == null ||
        candidate == null ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor) ||
        !_selectionPersisted ||
        _selectionPromotion != null ||
        _connectInProgress ||
        _pendingDriverConnection != null ||
        _disconnectOperation != null ||
        _transportCleanupInProgress ||
        _historyReadPause != null ||
        _historyReadResumeRequired ||
        _sensorHistoryUnconfirmed ||
        sensorConnectionCleanupUnconfirmed ||
        _historyFlushFailed ||
        _bondTransferInFlight ||
        _retiringExpiredSensor ||
        _clearingActivationRequiredSensor ||
        lastError != null) {
      return false;
    }
    return hasVerifiedLibreReception(candidate, expectedSensor: sensor) &&
        hasVerifiedLibreReception(
          session.currentSnapshot,
          expectedSensor: sensor,
        );
  }

  /// A settled exact-target setup failure must not remain a locked progress
  /// screen. Pending writes are not failures, and no native error text is
  /// returned through this presentation predicate.
  bool hasLibreReceptionSetupFailureFor(DiscoveredSensor sensor) {
    final candidate = _snapshot;
    if (_disposed ||
        sensor.driverId != 'libre2-gen1' ||
        candidate == null ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor) ||
        !_sameSensor(candidate.sensor, sensor) ||
        !_sameStoredSensor(candidate.sensor, sensor) ||
        _connectInProgress ||
        _pendingDriverConnection != null ||
        _selectionPromotion != null ||
        _disconnectOperation != null) {
      return false;
    }
    return lastError != null ||
        sensorConnectionCleanupUnconfirmed ||
        _sensorHistoryUnconfirmed ||
        _historyFlushFailed;
  }

  BleFailure? get scanFailure => _scanFailure;

  String? get scanFailureMessage => switch (_scanFailure) {
    final failure? => userMessageForBleFailure(failure),
    null => _lastError,
  };

  /// Whether the active build can route a connection to [candidateDriverId].
  bool supportsDriver(String candidateDriverId) =>
      _driverSupports(candidateDriverId);

  /// Resolve trusted driver behavior without connecting or reading storage.
  CgmSensorDataProfile sensorDataProfileFor(String driverId) {
    final driver = _driver;
    if (driver is CgmDriverRegistry) {
      return driver.sensorDataProfileFor(driverId) ??
          builtInSensorDataProfileFor(driverId);
    }
    if (driver.driverId == driverId && driver is CgmSensorDataProfileProvider) {
      return (driver as CgmSensorDataProfileProvider).sensorDataProfile;
    }
    return builtInSensorDataProfileFor(driverId);
  }

  SensorConnectionPolicy connectionPolicyFor(DiscoveredSensor sensor) {
    final driver = _driver;
    if (driver is CgmDriverRegistry) {
      return driver.connectionPolicyFor(sensor.driverId);
    }
    return driver.driverId == sensor.driverId
        ? builtInConnectionPolicyFor(sensor.driverId)
        : SensorConnectionPolicy.externalSetupOnly;
  }

  /// The sensor that needs an explicit, user-authorized activation attempt.
  ///
  /// The failed read-only probe clears the provisional selection, but this
  /// transient notice remains available to the connection UI. A later
  /// connection attempt or an explicit selection clear dismisses it.
  DiscoveredSensor? get activationRequiredSensor =>
      _clearingActivationRequiredSensor ? null : _activationRequiredSensor;

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
    return List<CgmReading>.unmodifiable(_loadHistoryAtKey(session.historyKey));
  }

  /// Explicit export must retain acquisition evidence and fail closed, even
  /// when permissive display history remains available for an older archive.
  ArchivedSensorExportData archivedSensorExportData(
    ArchivedSensorSession session,
  ) => _historyRepository.readArchivedSensorExportData(session);

  /// Refresh only committed history after a completed external history import.
  /// This neither selects a sensor nor creates connection/freshness evidence.
  void refreshImportedLibreHistory(DiscoveredSensor sensor) {
    if (_disposed ||
        sensor.driverId != 'libre2-gen1' ||
        _selectedSensor == null ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor)) {
      return;
    }
    _persistedHistory = _historyRepository.readCommittedHistory(
      _historyKey(sensor),
    );
    final current = _snapshot;
    if (current != null &&
        _sameSensor(current.sensor, sensor) &&
        _sameStoredSensor(current.sensor, sensor)) {
      _snapshot = _snapshotWithRetainedHistory(current, _persistedHistory);
    }
    notifyListeners();
  }

  /// Pause this exact saved selection without deleting it, its readings, or
  /// the receiver. No NFC command is sent here. All app reconnect/scan paths
  /// remain blocked until the caller confirms its own NFC cleanup.
  Future<CgmPausedSensorConnection> pauseForLibreHistoryRead(
    DiscoveredSensor sensor,
  ) async {
    if (_disposed ||
        isMockDriver ||
        sensor.driverId != 'libre2-gen1' ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor) ||
        sensorConnectionCleanupUnconfirmed ||
        _historyReadPause != null ||
        _connectInProgress ||
        _disconnectOperation != null ||
        _freshnessInFlight ||
        _bondTransferInFlight ||
        _retiringExpiredSensor ||
        _clearingActivationRequiredSensor) {
      throw StateError('The sensor is not ready for a history read.');
    }
    final pause = CgmPausedSensorConnection._(this, sensor);
    // Install before the first await. Foreground refresh, UI retries, and a
    // scan waiting for cancellation cannot start competing work in this gap.
    _historyReadPause = pause;
    _historyReadResumeRequired = true;
    _cancelReconnect();
    notifyListeners();
    try {
      await _disconnect(clearSelection: false);
      if (_disposed ||
          sensorConnectionCleanupUnconfirmed ||
          _historyFlushFailed ||
          _persistenceErrors.containsKey('Disconnecting sensor session') ||
          !_sameSensor(_selectedSensor, sensor) ||
          !_sameStoredSensor(_selectedSensor, sensor)) {
        throw StateError('Sensor cleanup could not be confirmed.');
      }
      // Drain queued native starts as well as clearing the retained native
      // target. A timeout or swallowed platform error cannot authorize NFC.
      if (!await _clearPlatformBackgroundState() || _disposed) {
        throw StateError('Sensor cleanup could not be confirmed.');
      }
      _backgroundSensorIdentity = null;
      pause._ready = true;
      return pause;
    } catch (_) {
      pause.release(cleanupConfirmed: false);
      throw StateError('Sensor cleanup could not be confirmed.');
    }
  }

  void _releaseHistoryRead(
    CgmPausedSensorConnection pause, {
    required bool cleanupConfirmed,
  }) {
    if (!identical(_historyReadPause, pause)) return;
    _historyReadPause = null;
    if (!cleanupConfirmed) {
      _sensorConnectionCleanupUnconfirmed = true;
      _lastError =
          'Sensor cleanup could not be confirmed. Close and reopen '
          'OpenGlucose before connecting again. Do not reset the sensor.';
    }
    // Do not select, reconnect, or publish imported history as a live value.
    // The explicit flow may request a new saved-receiver connection only
    // after its import and native stop both complete.
    if (!_disposed) notifyListeners();
  }

  /// Number of records retained in the archive, including warmup, provisional,
  /// and raw records. This is a storage count, not wellness/export eligibility.
  /// Count a shared ordinary history key only once. Libre archive segments can
  /// overlap after older cumulative writes, so count each observation once
  /// within its exact bootstrap, never across different sensors. Null reports
  /// unavailable archive data rather than a false partial or zero total.
  int? get archivedReadingCount {
    if (_archiveManifestUnavailable) return null;
    try {
      final libreGroups =
          _archivedSensors.any(
            (session) => session.driverId == 'libre2-gen1',
          )
          ? _historyRepository.readLibreArchivedHistoryGroups()
          : const <String, List<CgmReading>>{};
      final historyKeys = <String>{};
      final libreBootstraps = <String>{};
      var count = 0;
      for (final session in _archivedSensors) {
        if (session.driverId == 'libre2-gen1') {
          if (libreBootstraps.add(session.storageKey)) {
            final readings = libreGroups[session.storageKey];
            if (readings == null) return null;
            count += readings.length;
          }
        } else if (historyKeys.add(session.historyKey)) {
          count += _loadHistoryAtKey(session.historyKey).length;
        }
      }
      return count;
    } catch (_) {
      return null;
    }
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
      warmupMinutes:
          session.warmupMinutes ??
          sensorDataProfileFor(session.driverId).warmupMinutes,
    );
  }

  /// Wellness-eligible readings across previous sensors plus the active sensor.
  /// Duplicate records are collapsed so an archive hand-off cannot inflate
  /// long-range summaries. Provisional/raw records remain in local charts and
  /// explicit exports, but never enter this analytics/messaging input.
  List<CgmReading> get allHistoricalReadings {
    // Do not publish a partial aggregate when a related archive cannot be read.
    // The history card reports this state explicitly; current glucose is not
    // changed by the availability of an older archive.
    if (archivedReadingCount == null) return const <CgmReading>[];
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
          sessionStart: _inferredRetainedSessionStart(
            _selectedSensor,
            _persistedHistory,
          ),
          warmupMinutes: sensorDataProfileFor(
            _selectedSensor?.driverId ?? '',
          ).warmupMinutes,
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
        : _mergeHistory(_persistedHistory, raw.history, sensor: raw.sensor);
    return _snapshotWithRetainedHistory(raw, mergedHistory);
  }

  CgmReading? get latestReading {
    final current = snapshot;
    if (current == null) {
      return null;
    }
    if (sensorDataProfileFor(current.sensor.driverId).currentReadingPolicy ==
        CgmCurrentReadingPolicy.liveOnly) {
      return current.latestReading;
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
    if (sensorDataProfileFor(current.sensor.driverId).currentReadingPolicy ==
        CgmCurrentReadingPolicy.liveOnly) {
      return null;
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
    if (restoredSensor == null || !_driverSupports(restoredSensor.driverId)) {
      return;
    }

    _selectedSensor = restoredSensor;
    _selectionPersisted = true;
    _persistedHistory = _loadPersistedHistory(restoredSensor);
    final interruptedTransfer = _bondTransferTombstone(restoredSensor);
    if (interruptedTransfer != null) {
      final sensorAccepted = interruptedTransfer == _bondTransferSensorAccepted;
      _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.error,
        statusText: 'Sensor transfer needs attention',
        sensor: restoredSensor,
        capabilities: restoredSensor.capabilities,
        lastAdvertisement: restoredSensor.advertisement,
        history: _persistedHistory,
        sessionInfo: _retainedSessionInfo(restoredSensor, _persistedHistory),
        latestReading: _persistedHistory.isEmpty
            ? null
            : _persistedHistory.last,
        metadata: <String, String>{
          'deviceId': restoredSensor.deviceId,
          ...restoredSensor.metadata,
          cgmBondTransferStateMetadataKey: interruptedTransfer,
          cgmBondTransferDiagnosticMetadataKey: 'cgm.bond-transfer.interrupted',
        },
        lastError: sensorAccepted
            ? 'The sensor accepted a move, but app cleanup was interrupted. '
                  'Do not retry. '
                  'Check Android Bluetooth settings and forget the old bond '
                  'if it is still listed. Then review the move in Settings.'
            : 'The sensor response to a move is unknown. Do not reconnect, '
                  'forget the Android bond, disconnect, or retry. Contact '
                  'support for a reviewed recovery.',
      );
      _lastError = _snapshot!.lastError;
      notifyListeners();
      return;
    }
    final inferredStart = _inferredRetainedSessionStart(
      restoredSensor,
      _persistedHistory,
    );
    if (!_archiveManifestUnavailable &&
        _persistedSensorHasExpired(
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
      await _removeInactiveHistory(restoredSensor);
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
      sessionInfo: _retainedSessionInfo(restoredSensor, _persistedHistory),
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
      if (_disposed ||
          _historyReadResumeRequired ||
          _session != null ||
          !_sameSensor(_selectedSensor, restoredSensor)) {
        return;
      }
      unawaited(connect(restoredSensor, allowSessionActivation: false));
    });
  }

  Future<void> scan() async {
    if (_disposed ||
        _historyReadPause != null ||
        sensorConnectionCleanupUnconfirmed) {
      return;
    }
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
    if (_disposed ||
        _historyReadPause != null ||
        invalidationGeneration != _scanGeneration) {
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
    try {
      while (await iterator.moveNext()) {
        if (!_ownsScan(generation)) {
          break;
        }
        final sensor = iterator.current;
        _sensorsById[_sensorIdentity(sensor)] = sensor;
        notifyListeners();
      }
    } catch (error) {
      if (!_ownsScan(generation)) {
        return;
      }
      _recordScanFailure(error);
    } finally {
      if (identical(_scanIterator, iterator)) {
        _scanIterator = null;
      }
      if (_ownsScan(generation)) {
        _scanning = false;
        notifyListeners();
      }
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
    if (_disposed || _historyReadPause != null) return;
    if (_sensorConnectionCleanupUnconfirmed) {
      _lastError = _sensorHistoryUnconfirmed
          ? 'Saved sensor data could not be confirmed. Keep the app data and '
                'close and reopen OpenGlucose before connecting again.'
          : 'Connection cleanup could not be confirmed. Close and reopen '
                'OpenGlucose before connecting again. Do not reset the sensor.';
      notifyListeners();
      return;
    }
    if (_connectInProgress || _disconnectOperation != null || _disposed) {
      return;
    }
    // Explicit Connect/Retry, or the exact-target completion of a successful
    // history action, resumes here. Generic refresh/reconnect stays fenced.
    _historyReadResumeRequired = false;
    final generation = ++_connectionGeneration;
    _activeConnectionAttemptGeneration = generation;
    _connectInProgress = true;
    _activationRequiredSensor = null;
    _cancelReconnect();
    try {
      await _invalidateScan();
      if (generation != _connectionGeneration) return;
      if (!_driverSupports(sensor.driverId)) {
        _lastError =
            'This sensor protocol is not available in the current build.';
        notifyListeners();
        return;
      }
      if (!isMockDriver && _bondTransferTombstone(sensor) != null) {
        _lastError =
            'This sensor has an interrupted move. Do not reconnect or retry. '
            'Check Android Bluetooth settings first.';
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
      await _disconnect(
        clearSelection: false,
        invalidatePendingConnection: false,
      );
      if (generation != _connectionGeneration) return;
      if (_sensorConnectionCleanupUnconfirmed || _historyFlushFailed) return;
      _allowSessionActivation = allowSessionActivation;
      _selectedSensor = sensor;
      _selectionPersisted = resumeVerifiedSelection;
      if (!resumesPendingPromotion) {
        _selectionPromotionSource = null;
      }
      _persistedHistory = switch ((
        isMockDriver,
        resumeVerifiedSelection,
        resumesPendingPromotion,
      )) {
        (true, _, _) => const <CgmReading>[],
        (false, true, _) => _loadPersistedHistory(sensor),
        (false, false, true) => _mergeHistory(
          _loadPersistedHistory(promotionSource!),
          _mergeHistory(
            _loadPersistedHistory(sensor),
            inProcessHistory,
            sensor: sensor,
          ),
          sensor: sensor,
        ),
        (false, false, false) when sensor.driverId == 'libre2-gen1' =>
          _loadPersistedHistory(sensor),
        (false, false, false) => const <CgmReading>[],
      };
      _snapshot = CgmSessionSnapshot(
        stage: CgmSyncStage.connecting,
        statusText: 'Connecting',
        sensor: sensor,
        capabilities: sensor.capabilities,
        lastAdvertisement: sensor.advertisement,
        history: _persistedHistory,
        sessionInfo: _retainedSessionInfo(sensor, _persistedHistory),
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

      if (generation != _connectionGeneration) return;
      final pendingConnection = _driver.connect(
        _connectionSensorFor(
          sensor,
          _persistedHistory,
          allowSessionActivation: allowSessionActivation,
        ),
      );
      _pendingDriverConnection = pendingConnection;
      final session = await pendingConnection;
      // Disconnect owns a late driver result until physical cleanup finishes.
      // Cancellation alone must never release a receiver lease or publish a
      // new session after the user has removed its selection.
      if (generation != _connectionGeneration) return;
      _pendingDriverConnection = null;
      _session = session;
      _snapshotSubscription = session.snapshots.listen((nextSnapshot) {
        if (generation != _connectionGeneration) return;
        final isErrorSnapshot = nextSnapshot.stage == CgmSyncStage.error;
        if (isErrorSnapshot) {
          _debugAppSessionTrace('error-snapshot-received');
        }
        final nextHistory = isMockDriver
            ? nextSnapshot.history
            : _mergeHistory(
                _persistedHistory,
                nextSnapshot.history,
                sensor: nextSnapshot.sensor,
              );
        _snapshot = _snapshotWithRetainedHistory(nextSnapshot, nextHistory);
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
        if (_snapshotVerifiesSelection(nextSnapshot)) {
          // Once the sensor has proven that an active session exists, future
          // background reconnects must never be allowed to start a new one.
          _allowSessionActivation = false;
          _promoteVerifiedSelection(
            nextSnapshot.sensor,
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
      final initialHistory = isMockDriver
          ? currentSnapshot.history
          : _mergeHistory(
              _persistedHistory,
              currentSnapshot.history,
              sensor: currentSnapshot.sensor,
            );
      _snapshot = _snapshotWithRetainedHistory(currentSnapshot, initialHistory);
      if (!isMockDriver && initialHistory.isNotEmpty) {
        _persistedHistory = initialHistory;
      }
      final initialErrorSnapshot = _snapshot;
      if (initialErrorSnapshot != null &&
          (initialErrorSnapshot.stage == CgmSyncStage.error ||
              initialErrorSnapshot.stage == CgmSyncStage.disconnected)) {
        _lastError = primaryErrorTextForSnapshot(initialErrorSnapshot);
        if (initialErrorSnapshot.stage == CgmSyncStage.error) {
          _debugAppSessionTrace('error-snapshot-reconciled');
        }
      }
      if (_snapshotVerifiesSelection(_snapshot)) {
        // Fresh durable timing can verify Libre ownership without a glucose
        // reading. Apply the same evidence rule before and after subscription.
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
        if (generation != _connectionGeneration) return;
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
          await _clearActivationRequiredSelection();
        } else if (_snapshotHasExpired(initialSnapshot)) {
          unawaited(_retireExpiredSensor());
        }
      }
      final initialSelectionPromotion = _selectionPromotion;
      if (initialSelectionPromotion != null &&
          _snapshotVerifiesSelection(initialSnapshot)) {
        await initialSelectionPromotion;
      }
      if (generation == _connectionGeneration && !_disposed) {
        notifyListeners();
      }
    } catch (error) {
      if (generation != _connectionGeneration) return;
      _pendingDriverConnection = null;
      final libreFailure =
          sensor.driverId == 'libre2-gen1' && error is LibreGen1LiveException
          ? error.kind
          : null;
      if (libreFailure == LibreGen1LiveFailure.observationStorageUnavailable) {
        // Loading may migrate history. A failed dispatched load can therefore
        // be an uncertain write even though Bluetooth has not started.
        _sensorHistoryUnconfirmed = true;
        _sensorConnectionCleanupUnconfirmed = true;
      }
      final safeError = libreFailure == null
          ? _safeError('Connection', error)
          : 'libre2.${libreFailure.name}';
      _lastError = safeError;
      _snapshot = _snapshot?.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Connection failed',
        lastError: safeError,
        metadata: {
          ...?_snapshot?.metadata,
          if (error is BleFailure) ...error.toMetadata(),
          if (libreFailure != null) ...{
            'cgm.libre2.phase': 'failed',
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
          },
        },
      );
      _startPlatformTask(
        _pushLiveActivity(),
        'Updating private lock-screen state',
      );
      notifyListeners();
    } finally {
      _connectInProgress = false;
      _activeConnectionAttemptGeneration = null;
      if (!_disposed &&
          generation == _connectionGeneration &&
          sensor.driverId == 'libre2-gen1') {
        // The last setup notification can precede the end of the pending
        // connect barrier. Let the UI recheck current reception afterwards.
        notifyListeners();
      }
    }
  }

  Future<void> ensureFreshData({bool force = false}) async {
    if (_connectInProgress ||
        _historyReadPause != null ||
        _historyReadResumeRequired ||
        _disconnectOperation != null ||
        _freshnessInFlight ||
        _disposed) {
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
        currentSnapshot.capabilities.supportsHistoryBackfill &&
        (force || _needsHistoryCatchUp(currentSnapshot));
    if (!needsLiveRefresh && !needsHistoryCatchUp) {
      return;
    }

    _freshnessInFlight = true;
    final generation = _connectionGeneration;
    try {
      _lastError = null;
      if (needsLiveRefresh) {
        await session.refreshLiveData();
      }
      if (generation != _connectionGeneration ||
          _disconnectOperation != null ||
          !identical(session, _session)) {
        return;
      }
      final refreshedSnapshot = snapshot;
      if (refreshedSnapshot != null &&
          refreshedSnapshot.stage == CgmSyncStage.ready &&
          refreshedSnapshot.capabilities.supportsHistoryBackfill &&
          !refreshedSnapshot.historySync.inProgress &&
          (force || _needsHistoryCatchUp(refreshedSnapshot))) {
        await session.syncHistory(
          requestedStartOffset: _resumeHistoryStartOffset(refreshedSnapshot),
        );
      }
    } catch (error) {
      if (generation == _connectionGeneration &&
          _disconnectOperation == null &&
          identical(session, _session)) {
        _lastError = _safeError('Refresh', error);
      }
    } finally {
      _freshnessInFlight = false;
      notifyListeners();
    }
  }

  bool get connectionRequiresUserAction {
    final current = snapshot;
    if (current == null || sensorConnectionCleanupUnconfirmed) return false;
    if (isLibreGen1Snapshot(current)) {
      // Libre reports closed protocol errors, not AiDEX/adapter BleFailure
      // metadata. A completed attempt with manual recovery must still offer
      // the saved-sensor retry flow on the dashboard after app restoration.
      return (current.stage == CgmSyncStage.error ||
              current.stage == CgmSyncStage.disconnected) &&
          current.metadata[cgmAutomaticReconnectAllowedMetadataKey] ==
              'false' &&
          (current.lastError?.isNotEmpty ?? false);
    }
    return snapshotHasBleFailure(current) &&
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

  /// A radio-consent result must not start a replacement sensor or overlap NFC.
  Future<void> retryBluetoothConnectionFor(DiscoveredSensor sensor) async {
    final current = snapshot;
    if (_disposed ||
        current == null ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor) ||
        !snapshotNeedsBluetoothEnabled(current) ||
        _historyReadPause != null ||
        _historyReadResumeRequired ||
        sensorConnectionCleanupUnconfirmed ||
        _connectInProgress ||
        _disconnectOperation != null) {
      return;
    }
    await retryConnection();
  }

  /// Continue one user-initiated history action after its owner has disposed
  /// NFC. Never reconnect a replacement selection or replay sensor activation.
  Future<void> resumeLibreHistoryConnection(DiscoveredSensor sensor) async {
    if (_disposed ||
        sensor.driverId != 'libre2-gen1' ||
        !_sameSensor(_selectedSensor, sensor) ||
        !_sameStoredSensor(_selectedSensor, sensor) ||
        !_historyReadResumeRequired ||
        _historyReadPause != null ||
        sensorConnectionCleanupUnconfirmed ||
        _connectInProgress ||
        _disconnectOperation != null ||
        _session != null) {
      throw StateError('The saved sensor is not ready to resume.');
    }
    _cancelReconnect();
    await connect(sensor, allowSessionActivation: false);
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
    final generation = _connectionGeneration;
    if (session == null || !_ownsSessionOperation(session, generation)) {
      return;
    }
    try {
      _lastError = null;
      notifyListeners();
      await session.refreshLiveData();
      if (!_ownsSessionOperation(session, generation)) return;
      final refreshedSnapshot = snapshot;
      if (refreshedSnapshot == null ||
          !refreshedSnapshot.capabilities.supportsHistoryBackfill ||
          _isCurrentEnough(refreshedSnapshot)) {
        return;
      }
      await session.syncHistory(
        requestedStartOffset: _resumeHistoryStartOffset(refreshedSnapshot),
      );
    } catch (error) {
      if (!_ownsSessionOperation(session, generation)) return;
      _lastError = _safeError('Sync', error);
      notifyListeners();
    }
  }

  bool _ownsSessionOperation(CgmSession session, int generation) =>
      !_disposed &&
      generation == _connectionGeneration &&
      _disconnectOperation == null &&
      identical(session, _session);

  Future<void> refreshHistory() async {
    final session = _session;
    if (session == null ||
        snapshot?.capabilities.supportsHistoryBackfill != true) {
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
  }) {
    if (_historyReadPause != null) {
      return Future<void>.error(
        StateError('Stop the history read before disconnecting the sensor.'),
      );
    }
    return _disconnect(
      clearSelection: clearSelection,
      archiveReason: archiveReason,
      archiveWhenClearing: archiveWhenClearing,
      acknowledgeInterruptedTransfer: acknowledgeInterruptedTransfer,
    );
  }

  Future<void> _disconnect({
    bool clearSelection = true,
    SensorArchiveReason archiveReason = SensorArchiveReason.disconnected,
    bool archiveWhenClearing = true,
    bool acknowledgeInterruptedTransfer = false,
    bool invalidatePendingConnection = true,
    bool preserveActivationRequired = false,
  }) async {
    if (_bondTransferInFlight && !_finalizingBondTransfer) {
      return;
    }
    if (clearSelection && !preserveActivationRequired) {
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
      _lastError = interruptedTransfer == _bondTransferOutcomeUnknown
          ? 'The sensor response to the move is unknown. Do not reconnect, '
                'forget the Android bond, disconnect, or retry. Contact '
                'support for a reviewed recovery.'
          : 'Review the interrupted sensor move and check Android Bluetooth '
                'before clearing it from the app.';
      notifyListeners();
      return;
    }
    // Install the barrier before the first await. Foreground refresh, retries,
    // and timer callbacks must not see temporary session detachment as a reason
    // to reconnect while close/archive work still owns the selection.
    if (invalidatePendingConnection) _connectionGeneration++;
    final previous = _disconnectOperation;
    final completion = Completer<void>();
    _disconnectOperation = completion.future;
    try {
      if (previous != null) await previous;
      await _disconnectSession(
        clearSelection: clearSelection,
        archiveReason: archiveReason,
        archiveWhenClearing: archiveWhenClearing,
      );
    } finally {
      if (identical(_disconnectOperation, completion.future)) {
        _disconnectOperation = null;
      }
      completion.complete();
    }
  }

  Future<void> _disconnectSession({
    required bool clearSelection,
    required SensorArchiveReason archiveReason,
    required bool archiveWhenClearing,
  }) async {
    _clearInspectedBondTransfer();
    await _invalidateScan();
    _cancelReconnect();
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    final sensorToArchive = clearSelection ? _selectedSensor : null;
    final snapshotToArchive = clearSelection ? snapshot : null;
    var historyToArchive = clearSelection
        ? List<CgmReading>.of(
            snapshotToArchive?.history ?? _persistedHistory,
            growable: false,
          )
        : const <CgmReading>[];
    final snapshotSubscription = _snapshotSubscription;
    final logSubscription = _logSubscription;
    _snapshotSubscription = null;
    _logSubscription = null;
    var session = _session;
    _session = null;

    Object? teardownError;
    var libreCleanupUnconfirmed = false;
    final pendingConnection = _pendingDriverConnection;
    _transportCleanupInProgress = session != null || pendingConnection != null;
    if (pendingConnection != null) {
      try {
        session = await pendingConnection.timeout(
          _pendingConnectionCleanupTimeout,
        );
      } catch (error) {
        teardownError = error;
        // CgmDriver.connect does not promise physical cleanup when it throws.
        // Without a returned session handle, retain the exact selection and
        // ownership blocker. A deadline only stops waiting; it is not closure.
        libreCleanupUnconfirmed = true;
        unawaited(_closeAbandonedConnection(pendingConnection));
      } finally {
        if (identical(_pendingDriverConnection, pendingConnection)) {
          _pendingDriverConnection = null;
        }
      }
    }
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
        if (error is LibreGen1LiveException &&
            error.kind == LibreGen1LiveFailure.observationStorageUnavailable) {
          // RF may be closed while a dispatched write remains uncertain. Do
          // not clear selection or present that as a completed disconnection.
          _sensorHistoryUnconfirmed = true;
          libreCleanupUnconfirmed = true;
        }
      }
    }
    _transportCleanupInProgress = false;
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
      _session = session;
      final sensor = _selectedSensor;
      CgmSessionSnapshot? forSelectedSensor(CgmSessionSnapshot? candidate) =>
          sensor != null &&
              candidate != null &&
              _sameSensor(sensor, candidate.sensor) &&
              _sameStoredSensor(sensor, candidate.sensor)
          ? candidate
          : null;
      // Even failure snapshots must retain the exact selected target. A
      // mismatched driver snapshot cannot replace its identity or contribute
      // health records to the selected sensor's cache.
      final failed =
          forSelectedSensor(session?.currentSnapshot) ??
          forSelectedSensor(_snapshot) ??
          (sensor == null
              ? null
              : CgmSessionSnapshot(
                  stage: CgmSyncStage.error,
                  statusText: _sensorHistoryUnconfirmed
                      ? 'Saved sensor data needs an app restart'
                      : 'Connection cleanup needs an app restart',
                  sensor: sensor,
                  capabilities: sensor.capabilities,
                  history: _persistedHistory,
                  sessionInfo: _retainedSessionInfo(sensor, _persistedHistory),
                ));
      if (failed != null) {
        _persistedHistory = _mergeHistory(
          _persistedHistory,
          failed.history,
          sensor: failed.sensor,
        );
        _snapshot = failed.copyWith(
          stage: CgmSyncStage.error,
          statusText: _sensorHistoryUnconfirmed
              ? 'Saved sensor data needs an app restart'
              : 'Connection cleanup needs an app restart',
          lastError: failed.sensor.driverId == 'libre2-gen1'
              ? (_sensorHistoryUnconfirmed
                    ? 'libre2.observationStorageUnavailable'
                    : 'libre2.cleanupUnconfirmed')
              : 'cgm.connection.cleanupUnconfirmed',
          history: _persistedHistory,
          metadata: {
            ...failed.metadata,
            if (failed.sensor.driverId == 'libre2-gen1')
              'cgm.libre2.phase': 'failed',
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
          },
        );
      }
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

    // A driver may accept a final notification before its queued snapshot can
    // reach this controller. The close barrier above must settle before its
    // final immutable history is read. Never merge another target or storage
    // identity, and never treat uncertain teardown as a completed hand-off.
    final selectionPromotion = _selectionPromotion;
    if (selectionPromotion != null) await selectionPromotion;
    final retainedSensor = _selectedSensor;
    final closedSnapshot = teardownError == null
        ? session?.currentSnapshot
        : null;
    if (retainedSensor != null &&
        closedSnapshot != null &&
        _sameSensor(retainedSensor, closedSnapshot.sensor) &&
        _sameStoredSensor(retainedSensor, closedSnapshot.sensor)) {
      _persistedHistory = _mergeHistory(
        _persistedHistory,
        closedSnapshot.history,
        sensor: retainedSensor,
      );
      final current = _snapshot;
      if (current != null &&
          _sameSensor(retainedSensor, current.sensor) &&
          _sameStoredSensor(retainedSensor, current.sensor)) {
        _snapshot = _snapshotWithRetainedHistory(current, _persistedHistory);
      }
      if (sensorToArchive != null &&
          _sameSensor(sensorToArchive, retainedSensor) &&
          _sameStoredSensor(sensorToArchive, retainedSensor)) {
        historyToArchive = _mergeHistory(
          historyToArchive,
          _persistedHistory,
          sensor: retainedSensor,
        );
      }
    }

    if (clearSelection) {
      Object? selectionError;
      if (!isMockDriver) {
        try {
          if (sensorToArchive != null && archiveWhenClearing) {
            if (historyToArchive.isNotEmpty) {
              await _persistHistory(sensorToArchive, historyToArchive);
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
              await _removeInactiveHistory(sensorToArchive);
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
        _historyReadResumeRequired = false;
        _snapshot = null;
        _persistedHistory = const <CgmReading>[];
        _allowSessionActivation = false;
        _selectionPersisted = false;
        _selectionPromotionSource = null;
        _backgroundSensorIdentity = null;
        _historyFlushFailed = false;
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
        // The explicit Disconnect has already passed transport cleanup. A
        // failed archive save retains the app pointer and readings, but must
        // not let a previously queued native start revive background work.
        await _clearPlatformBackgroundState();
        _backgroundSensorIdentity = null;
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
      // Cancelling the debounce is not a durable flush. Reconnect reloads this
      // key, so it must wait for every received point to be saved first. On a
      // failed write keep the in-memory history and selection for a safe retry.
      if (!isMockDriver &&
          retainedSensor != null &&
          _persistedHistory.isNotEmpty) {
        try {
          await _persistHistory(retainedSensor, _persistedHistory);
          _historyFlushFailed = false;
          _clearPersistenceFailure('Saving history');
        } catch (error) {
          _historyFlushFailed = true;
          _recordPersistenceFailure('Saving history', error);
          _snapshot = _snapshot?.copyWith(
            stage: CgmSyncStage.disconnected,
            statusText: 'Disconnected — could not save sensor readings',
          );
          await _clearPlatformBackgroundState();
          _backgroundSensorIdentity = null;
          notifyListeners();
          return;
        }
      }
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

  Future<void> _closeAbandonedConnection(Future<CgmSession> pending) async {
    try {
      final session = await pending;
      await session.disconnect().timeout(_pendingConnectionCleanupTimeout);
    } catch (_) {
      // The controller already retained a cleanup-unconfirmed blocker. Late
      // success or failure cannot revive a session or authorize another try.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionGeneration++;
    _activationRequiredSensor = null;
    final pendingConnection = _pendingDriverConnection;
    if (pendingConnection != null && _disconnectOperation == null) {
      // Disposal invalidates callbacks, not physical ownership. If Disconnect
      // does not already own this future, close its eventual handle without
      // attaching a listener, promoting a selection, or clearing stored state.
      _pendingDriverConnection = null;
      _sensorConnectionCleanupUnconfirmed = true;
      unawaited(_closeAbandonedConnection(pendingConnection));
    }
    unawaited(
      _invalidateScan().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    _cancelReconnect();
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    super.dispose();
  }

  bool _ownsScan(int generation) => !_disposed && generation == _scanGeneration;

  void _recordScanFailure(Object error) {
    if (error is BleFailure) {
      _scanFailure = error;
      _lastError = userMessageForBleFailure(error);
      return;
    }
    _scanFailure = null;
    _lastError =
        'Sensor scan could not be completed. Check Bluetooth and try again.';
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
    _lastError = _snapshot?.lastError;
    unawaited(_pushLiveActivity());
    notifyListeners();
  }

  Future<bool> clearPersistedHistory() async {
    // A Disconnect may have already selected its immutable archive delta.
    // A later clear cannot report success while that delta is being saved.
    if (isMockDriver || _disconnectOperation != null) {
      return false;
    }
    final sensor = _selectedSensor;
    if (sensor == null) {
      return false;
    }
    _historyPersistTimer?.cancel();
    _historyPersistTimer = null;
    try {
      await _removeHistoryAtKey(_historyKey(sensor));
    } catch (error) {
      _recordPersistenceFailure('Clearing stored history', error);
      notifyListeners();
      return false;
    }
    _persistedHistory = const <CgmReading>[];
    // A successful readings clear resolves the failed flush. Libre retains its
    // observed-minute frontier and a tombstone against stale session snapshots.
    _historyFlushFailed = false;
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

  String _historyKey(DiscoveredSensor sensor) => sensorHistoryKey(sensor);

  Future<void> _removeInactiveHistory(DiscoveredSensor sensor) async {
    // Disconnect removes selection, not Libre replay state. Retain legacy
    // lists too, until the exact saved bootstrap can bind their migration.
    if (sensor.driverId == 'libre2-gen1') return;
    final key = _historyKey(sensor);
    if (!_historyRepository.retainOnDisconnect(key)) {
      await _removeHistoryAtKey(key);
    }
  }

  String _bondTransferTombstoneKey(DiscoveredSensor sensor) =>
      sensor.driverId == 'aidex'
      ? '$_bondTransferTombstonePrefix${sensor.storageKey}'
      : '$_qualifiedBondTransferTombstonePrefix'
            '${_encodedStorageIdentity(sensor)}';

  String _encodedStorageIdentity(DiscoveredSensor sensor) => base64Url
      .encode(
        utf8.encode(jsonEncode(<String>[sensor.driverId, sensor.storageKey])),
      )
      .replaceAll('=', '');

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
    try {
      final raw = _healthStateStore.getString(_sensorArchiveKey);
      if (raw == null) return const <ArchivedSensorSession>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        throw const FormatException('Invalid sensor archive manifest.');
      }
      if (decoded.any(
        (value) => value is Map && value['driverId'] == 'libre2-gen1',
      )) {
        // Validate references before the legacy presentation parser can fill
        // defaults or normalize malformed Libre metadata during a later save.
        _historyRepository.readLibreArchivedHistoryGroups();
      }
      const fields = {
        'id',
        'historyKey',
        'storageKey',
        'driverId',
        'deviceId',
        'displayName',
        'serial',
        'model',
        'firmware',
        'sensorVariant',
        'reason',
        'readingCount',
        'warmupMinutes',
        'startedAt',
        'endedAt',
        'lastReadingAt',
      };
      final sessions = <ArchivedSensorSession>[];
      for (final value in decoded) {
        if (value is! Map<String, dynamic> ||
            !value.keys.every(fields.contains)) {
          throw const FormatException('Invalid sensor archive entry.');
        }
        final session = ArchivedSensorSession.fromJson(value);
        if (session.storageKey.isEmpty) {
          throw const FormatException('Missing sensor archive identity.');
        }
        sessions.add(session);
      }
      return sessions;
    } catch (error) {
      _archiveManifestUnavailable = true;
      _recordPersistenceFailure('Reading saved sensor sessions', error);
      return const <ArchivedSensorSession>[];
    }
  }

  Future<void> _persistSensorArchive() {
    if (_archiveManifestUnavailable) {
      throw StateError('Saved sensor sessions are unavailable.');
    }
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
    if (_archiveManifestUnavailable) {
      throw StateError('Saved sensor sessions are unavailable.');
    }
    final deltaOnly = sensor.driverId == 'libre2-gen1';
    final archiveCandidates = deltaOnly
        ? await _historyRepository.unarchivedLibreReadings(
            sensor: sensor,
            incoming: history,
          )
        : history;
    if (deltaOnly) {
      // Local Disconnect is not a new physical sensor session. Keep existing
      // immutable segments and the active receiver envelope untouched when no
      // additional observation has been durably retained.
      if (archiveCandidates.isEmpty) return;
    }
    final sessionInfo = snapshot?.sessionInfo;
    final start =
        sessionInfo?.sessionStart ??
        startedAt ??
        _inferredRetainedSessionStart(sensor, archiveCandidates);
    final incomingLastReadingAt = latestReadingTime(archiveCandidates);
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
    String archiveIdFor(int discriminator) => base64Url
        .encode(
          utf8.encode(
            '${sensor.driverId}|${sensor.storageKey}|'
            '$discriminator',
          ),
        )
        .replaceAll('=', '');
    var discriminator = identityTime.toUtc().millisecondsSinceEpoch;
    var archiveId = archiveIdFor(discriminator);
    var archiveHistoryKey = 'openHealth.history.archive.$archiveId';
    if (deltaOnly) {
      final existingIds = _archivedSensors.map((entry) => entry.id).toSet();
      var collisions = 0;
      while (existingIds.contains(archiveId) ||
          _healthStateStore.getString(archiveHistoryKey) != null) {
        if (++collisions > 1024) {
          throw StateError('A new sensor archive identity is unavailable.');
        }
        // This number is an opaque collision discriminator, not a receipt or
        // activation timestamp. Same-clock/rollback segments never overwrite
        // an existing manifest entry or an orphaned archive blob.
        archiveId = archiveIdFor(++discriminator);
        archiveHistoryKey = 'openHealth.history.archive.$archiveId';
      }
    }
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
    final archivedHistory = _mergeHistory(
      existingHistory,
      archiveCandidates,
      sensor: sensor,
      filterCommittedLibreHistory: false,
    );
    final lastReadingAt =
        latestReadingTime(archivedHistory) ??
        existingEntry?.lastReadingAt ??
        incomingLastReadingAt;
    if (archivedHistory.isNotEmpty) {
      if (deltaOnly) {
        await _historyRepository.writeLibreArchive(
          sensor: sensor,
          archiveKey: archiveHistoryKey,
          incoming: archivedHistory,
        );
      } else {
        await _persistHistoryAtKey(archiveHistoryKey, archivedHistory);
      }
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
        sessionInfo?.sensorVariant?.model,
        sensor.metadata['model'],
        existingEntry?.model,
      ]),
      firmware: _firstNonEmpty(<String?>[
        sessionInfo?.firmware,
        sensor.metadata['firmware'],
        existingEntry?.firmware,
      ]),
      sensorVariant: sessionInfo?.sensorVariant ?? existingEntry?.sensorVariant,
      reason: existingEntry?.reason ?? reason,
      readingCount: archivedHistory.length,
      warmupMinutes:
          snapshot?.sessionInfo.warmupMinutes ??
          existingEntry?.warmupMinutes ??
          sensorDataProfileFor(sensor.driverId).warmupMinutes,
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
    // Receipt timestamps and counters with an unverified clock relationship
    // cannot establish activation or expiry. Wait for reported lifecycle.
    if (!sensorDataProfileFor(sensor.driverId).canInferRetainedLifecycle) {
      return false;
    }
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

  CgmSessionInfo _retainedSessionInfo(
    DiscoveredSensor sensor,
    List<CgmReading> history,
  ) {
    final profile = sensorDataProfileFor(sensor.driverId);
    return CgmSessionInfo(
      sessionStart: _inferredRetainedSessionStart(sensor, history),
      warmupMinutes: profile.warmupMinutes,
      expectedLifetimeMinutes: profile.expectedLifetimeMinutes,
    );
  }

  DateTime? _inferredRetainedSessionStart(
    DiscoveredSensor? sensor,
    List<CgmReading> history,
  ) {
    if (sensor == null ||
        !sensorDataProfileFor(sensor.driverId).canInferRetainedLifecycle) {
      return null;
    }
    return inferSensorStart(history);
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
      return Duration(
        minutes: sensorDataProfileFor(sensor.driverId).expectedLifetimeMinutes,
      );
    }
    return Duration(minutes: minutes);
  }

  bool _snapshotHasExpired(CgmSessionSnapshot value) {
    // Sensor-relative elapsed time can support a lifecycle display without a
    // known activation instant. Reaching its nominal duration is not authority
    // to archive the selection or retire a protected receiver automatically.
    if (value.sessionInfo.sessionStart == null &&
        !value.sessionInfo.sessionStopped &&
        !value.health.expired) {
      return false;
    }
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

  bool _snapshotVerifiesSelection(CgmSessionSnapshot? candidate) {
    if (candidate == null) return false;
    final selected = _selectedSensor;
    if (candidate.sensor.driverId == 'libre2-gen1') {
      return selected != null &&
          hasVerifiedLibreReception(candidate, expectedSensor: selected);
    }
    return candidate.stage == CgmSyncStage.ready;
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
          _mergeHistory(
            _loadPersistedHistory(sensor),
            currentHistory,
            sensor: sensor,
          ),
          sensor: sensor,
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
            await _removeInactiveHistory(promotionSource);
            _clearPersistenceFailure('Cleaning provisional sensor history');
          } catch (error) {
            _recordPersistenceFailure(
              'Cleaning provisional sensor history',
              error,
            );
          }
        }
        if (!_sensorConnectionCleanupUnconfirmed &&
            _historyReadPause == null &&
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
      await _disconnect(
        clearSelection: true,
        archiveWhenClearing: false,
        preserveActivationRequired: true,
      );
    } finally {
      _clearingActivationRequiredSensor = false;
      // A confirmation cannot authorize its next connection while cleanup of
      // the read-only probe still owns the transport/selection barrier.
      notifyListeners();
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

  List<CgmReading> _loadPersistedHistory(DiscoveredSensor sensor) {
    return _loadHistoryAtKey(_historyKey(sensor));
  }

  List<CgmReading> _loadHistoryAtKey(String key) {
    if (isMockDriver) {
      return const <CgmReading>[];
    }
    return _historyRepository.readCommittedHistory(key);
  }

  Future<void> _persistHistory(
    DiscoveredSensor sensor,
    List<CgmReading> history,
  ) async {
    return _persistHistoryAtKey(_historyKey(sensor), history);
  }

  Future<void> _persistHistoryAtKey(
    String key,
    List<CgmReading> history,
  ) {
    if (isMockDriver) {
      return Future<void>.value();
    }
    final trimmedHistory = _historyForPersistence(history);
    return _historyRepository.merge(key, trimmedHistory);
  }

  Future<void> _removeHistoryAtKey(String key) => _historyRepository.clear(key);

  Future<void> _pushLiveActivity() async {
    final snapshot = this.snapshot;
    final publishValue =
        !isMockDriver &&
        _historyReadPause == null &&
        snapshot != null &&
        _shouldPublishIosLiveActivity(snapshot);
    final payload = publishValue
        ? buildLiveActivityPayload(
            snapshot: snapshot,
            latestReading: displayLatestReading,
            preferences: _displayPreferences,
          )
        : null;
    final selected = _selectedSensor;
    final ownsSnapshot =
        !isMockDriver &&
        !_disposed &&
        _historyReadPause == null &&
        selected != null &&
        snapshot != null &&
        _sameSensor(selected, snapshot.sensor) &&
        _sameStoredSensor(selected, snapshot.sensor);
    // Enqueue before any await. A later final disconnect/end must supersede
    // this update even if the independent iOS bridge is still pending.
    final androidUpdate = _androidLiveUpdates.update(
      keepConnectionActive: shouldKeepAndroidConnectionActive(
        snapshot: ownsSnapshot ? snapshot : null,
        hasSession: _session != null,
        connectionAttemptActive:
            _connectInProgress &&
            _activeConnectionAttemptGeneration == _connectionGeneration &&
            (_session == null || _pendingDriverConnection != null),
        recoveryScheduled:
            _reconnectTimer != null &&
            snapshot != null &&
            snapshotAllowsAutomaticReconnect(snapshot),
        transportCleanupInProgress: _transportCleanupInProgress,
        cleanupUnconfirmed: sensorConnectionCleanupUnconfirmed,
      ),
      eligiblePayload: payload,
    );
    // Attach both error handlers immediately. One platform must not leave an
    // early error from the other unobserved while awaiting its own result.
    await Future.wait<void>(
      <Future<void>>[androidUpdate, _updateIosLiveActivity(payload)],
      eagerError: true,
    );
  }

  Future<void> _updateIosLiveActivity(LiveActivityPayload? payload) async {
    final override = _iosLiveActivityUpdater;
    if (override != null) {
      await override(payload);
    } else if (payload != null) {
      await IosLiveActivityBridge.upsert(payload);
    } else {
      await IosLiveActivityBridge.end();
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
    return (error is CgmBondTransferException ? error.userMessage : null) ??
        userMessageForBleError(error) ??
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

  Future<bool> _clearPlatformBackgroundState() async {
    // The native end is queued synchronously, and its completion is part of
    // this barrier. Cancellation of an earlier update is not stop proof.
    final androidEnd = _androidLiveUpdates.end();
    final operations = <Future<void> Function()>[
      () => androidEnd,
      IosLiveActivityBridge.clearBackgroundSensor,
      IosLiveActivityBridge.end,
      AndroidLiveUpdateBridge.clearBackgroundSensor,
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
    return firstError == null;
  }

  List<CgmReading> _historyForPersistence(List<CgmReading> history) {
    // Preserve source, receipt time, and provisional quality in restricted
    // local storage. Wellness/HealthKit consumers apply their own stricter
    // policy; persistence must not silently upgrade an experimental reading.
    return List<CgmReading>.from(history, growable: false);
  }

  CgmSessionSnapshot _snapshotWithRetainedHistory(
    CgmSessionSnapshot current,
    List<CgmReading> history,
  ) {
    final profile = sensorDataProfileFor(current.sensor.driverId);
    if (profile.currentReadingPolicy ==
        CgmCurrentReadingPolicy.latestOrHistory) {
      return current.copyWith(
        history: history,
        latestReading:
            current.latestReading ?? (history.isEmpty ? null : history.last),
      );
    }
    var latest = current.stage == CgmSyncStage.ready
        ? current.latestReading
        : null;
    final boundLibre =
        !isMockDriver &&
        current.sensor.driverId == 'libre2-gen1' &&
        _historyRepository.hasConfirmedLibreHistory(
          _historyKey(current.sensor),
        );
    if (latest != null) {
      if (!latest.valueMgdl.isFinite || latest.valueMgdl <= 0) {
        latest = null;
      } else if (boundLibre) {
        latest = _historyRepository.confirmedLibreLiveReading(
          _historyKey(current.sensor),
          latest,
        );
      } else if (latest.sensorMinute != null &&
          profile.duplicatePolicy == CgmHistoryDuplicatePolicy.keepFirst) {
        final minute = latest.sensorMinute;
        final source = latest.source;
        for (final retained in history) {
          if (retained.sensorMinute == minute && retained.source == source) {
            latest = retained;
            break;
          }
        }
      }
    }
    if (latest != null &&
        (!latest.valueMgdl.isFinite ||
            latest.valueMgdl <= 0 ||
            latest.source == CgmRecordSource.raw)) {
      latest = null;
    }
    if (latest != null &&
        !isMockDriver &&
        current.sensor.driverId == 'libre2-gen1' &&
        _historyRepository.filterRetainedHistory(_historyKey(current.sensor), [
          latest,
        ]).isEmpty) {
      latest = null;
    }
    // copyWith cannot clear a nullable latestReading. Rebuild so cached history
    // never becomes current glucose when a live sample is absent or invalid.
    // A repeated minute uses its first receipt for freshness as well as charts.
    return CgmSessionSnapshot(
      stage: current.stage,
      statusText: current.statusText,
      sensor: current.sensor,
      capabilities: current.capabilities,
      latestReading: latest,
      lastAdvertisement: current.lastAdvertisement,
      history: history,
      rawHistory: current.rawHistory,
      calibrations: current.calibrations,
      diagnostics: current.diagnostics,
      sessionInfo: current.sessionInfo,
      health: current.health,
      historySync: current.historySync,
      metadata: current.metadata,
      lastError: current.lastError,
    );
  }

  List<CgmReading> _mergeHistory(
    Iterable<CgmReading> persisted,
    Iterable<CgmReading> incoming, {
    required DiscoveredSensor sensor,
    bool filterCommittedLibreHistory = true,
  }) {
    final readingsByKey = <String, CgmReading>{};
    final duplicatePolicy = sensorDataProfileFor(
      sensor.driverId,
    ).duplicatePolicy;
    void add(Iterable<CgmReading> readings) {
      for (final reading in readings) {
        final timestamp = reading.recordedAt?.toUtc().toIso8601String() ?? '';
        final minute = reading.sensorMinute;
        final key = minute == null
            ? 'time|$timestamp|${reading.source.name}'
            : 'minute|$minute|${reading.source.name}';
        if (duplicatePolicy == CgmHistoryDuplicatePolicy.keepFirst) {
          // A fresh BLE session can repeat a previously received minute. Keep
          // its first accepted value and receipt time rather than moving a
          // retained point to the time of the reconnect.
          readingsByKey.putIfAbsent(key, () => reading);
        } else {
          readingsByKey[key] = reading;
        }
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
    return !isMockDriver &&
            filterCommittedLibreHistory &&
            sensor.driverId == 'libre2-gen1'
        ? _historyRepository.filterRetainedHistory(_historyKey(sensor), merged)
        : merged;
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
    if (!snapshot.capabilities.supportsHistoryBackfill) {
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
        _historyReadPause != null ||
        _historyReadResumeRequired ||
        _connectInProgress ||
        _disconnectOperation != null ||
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
      if (_disconnectOperation != null ||
          _historyReadPause != null ||
          _historyReadResumeRequired) {
        return;
      }
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
