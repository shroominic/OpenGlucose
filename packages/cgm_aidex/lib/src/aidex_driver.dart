import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'aidex_protocol.dart';

/// Metadata key for the current, privacy-safe AiDEX setup phase.
///
/// Values are deliberately closed and opaque. They describe only which setup
/// operation was in progress; they never contain device or sensor data.
const String aidexSetupPhaseMetadataKey = 'cgm.aidex.setup.phase';

/// Metadata keys for the current privacy-safe notification setup position.
///
/// Values are from the closed sets below. They never contain UUIDs, device
/// identifiers, sensor data, or native error descriptions.
const String aidexSubscribeStepMetadataKey = 'cgm.aidex.setup.subscribe.step';
const String aidexSubscribeAttemptMetadataKey =
    'cgm.aidex.setup.subscribe.attempt';
void _debugAidexSetupTrace(String milestone) {
  assert(() {
    // Debug-only closed milestones for USB setup diagnosis. No identifier,
    // payload, native description, or sensor reading is included.
    // ignore: avoid_print
    print('OGBLE setup=$milestone');
    return true;
  }());
}

abstract final class AidexSetupPhase {
  static const String connect = 'P01';
  static const String bond = 'P02';
  static const String reconnect = 'P03';
  static const String discovery = 'P04';
  static const String subscribe = 'P05';
  static const String identity = 'P06';
  static const String vendorPair = 'P07';
  static const String baseline = 'P08';
  static const String activation = 'P09';
  static const String finalization = 'P10';

  static const Set<String> values = <String>{
    connect,
    bond,
    reconnect,
    discovery,
    subscribe,
    identity,
    vendorPair,
    baseline,
    activation,
    finalization,
  };
}

abstract final class AidexSubscribeStep {
  static const String f001 = 'N01';
  static const String f002 = 'N02';
  static const String f003 = 'N03';
  static const String specificOps = 'N04';
  static const String racp = 'N05';
  static const String measurement = 'N06';

  static const Set<String> values = <String>{
    f001,
    f002,
    f003,
    specificOps,
    racp,
    measurement,
  };
}

abstract final class AidexSubscribeAttempt {
  static const String initial = 'A01';
  static const String recovery = 'A02';

  static const Set<String> values = <String>{initial, recovery};
}

class AidexSensorDriver implements CgmDriver {
  AidexSensorDriver(
    this._transport, {
    DateTime Function()? clock,
    AidexTimingProfile timingProfile = AidexTimingProfile.production,
  }) : _clock = clock ?? DateTime.now,
       _timingProfile = timingProfile;

  final BleTransport _transport;
  final DateTime Function() _clock;
  final AidexTimingProfile _timingProfile;

  static const CgmCapabilities _capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsVendorPairing: true,
    supportsAdvertisementGlucose: true,
    supportsHistory: true,
    supportsRawHistory: true,
    supportsCalibration: true,
    supportsDiagnostics: true,
    supportsUnsafeAdmin: true,
    supportsCommunicationInterval: true,
    supportsAutoUpdateControl: true,
  );

  @override
  String get driverId => 'aidex';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    final seen = <String, DiscoveredSensor>{};
    await for (final result in _transport.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
      withServices: const <String>[AidexUuids.cgmService],
    )) {
      final candidate = _mapScanResult(result);
      if (candidate == null) {
        continue;
      }
      final existing = seen[candidate.deviceId];
      if (allowDuplicates ||
          existing == null ||
          existing.rssi != candidate.rssi ||
          existing.advertisement?.payloadHex !=
              candidate.advertisement?.payloadHex) {
        seen[candidate.deviceId] = candidate;
        yield candidate;
      }
    }
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    final session = AidexSession._(
      sensor: sensor,
      transport: _transport,
      clock: _clock,
      timingProfile: _timingProfile,
    );
    unawaited(session.initialize());
    return session;
  }

  DiscoveredSensor? _mapScanResult(BleScanResult result) {
    final name = result.deviceName.trim();
    final serviceMatch = result.serviceUuids
        .map((uuid) => uuid.toUpperCase())
        .contains(AidexUuids.cgmService);
    final manufacturer = result.manufacturerData
        .cast<BleManufacturerData?>()
        .firstWhere((entry) => entry?.companyId == 0x0059, orElse: () => null);
    final nameMatch =
        name.contains('AiDEX') ||
        name.contains('LinX') ||
        name.contains('AIDEX');
    if (!nameMatch && !(serviceMatch && manufacturer != null)) {
      return null;
    }

    final advertisement = manufacturer == null
        ? null
        : parseAidexManufacturerData(
            Uint8List.fromList(<int>[0x59, 0x00, ...manufacturer.bytes]),
          );
    final serial = extractAidexSerial(name);
    return DiscoveredSensor(
      driverId: driverId,
      deviceId: result.deviceId,
      displayName: name.isEmpty ? result.deviceId : name,
      storageKey: serial.isEmpty ? result.deviceId : 'serial:$serial',
      rssi: result.rssi,
      capabilities: _capabilities,
      advertisement: advertisement,
      notes: nameMatch
          ? 'Matched by AiDEX/LinX device name.'
          : 'Matched by CGM service and manufacturer prefix 0x0059.',
      metadata: <String, String>{if (serial.isNotEmpty) 'serial': serial},
    );
  }
}

class AidexSession implements CgmSession, CgmBondTransferSession {
  // AiDEX-X sensors require a 60-minute warmup before reporting glucose. The
  // protocol does not expose this duration via any characteristic; elapsed-
  // since-start IS sensor-reported (2AA9 byte 0-1 -> sessionInfo.elapsedMinutes
  // + _reconcileSessionStartToElapsedClock), but the warmup length itself is a
  // sensor-model constant the driver owns.
  static const int _aidexWarmupMinutes = 60;
  static const Duration _liveRefreshInterval = Duration(minutes: 1);
  static const Duration _liveStaleThreshold = Duration(minutes: 3);
  static const Duration _sessionStartTolerance = Duration(minutes: 45);
  static const Duration _sessionStartDriftCorrectionThreshold = Duration(
    minutes: 15,
  );
  static const Duration _sessionStartDriftCorrectionLimit = Duration(hours: 2);
  static const int _historyCommandMaxAttempts = 4;
  static const Duration _historyRetryDelay = Duration(seconds: 2);
  static const Duration _historyResumeDelay = Duration(seconds: 6);

  AidexSession._({
    required this.sensor,
    required BleTransport transport,
    required DateTime Function() clock,
    required AidexTimingProfile timingProfile,
  }) : _transport = transport,
       _clock = clock,
       _timings = timingProfile,
       _snapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting to ${sensor.displayName}',
         sensor: sensor,
         capabilities: sensor.capabilities,
         lastAdvertisement: sensor.advertisement,
         sessionInfo: const CgmSessionInfo(warmupMinutes: _aidexWarmupMinutes),
         metadata: <String, String>{
           'deviceId': sensor.deviceId,
           aidexSetupPhaseMetadataKey: AidexSetupPhase.connect,
         },
       ),
       _unsafeAdmin = AidexUnsafeAdmin._() {
    _unsafeAdmin.attach(this);
    _hydrateRestoredHistory();
  }

  @override
  final DiscoveredSensor sensor;

  final BleTransport _transport;
  final DateTime Function() _clock;
  final AidexTimingProfile _timings;
  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();
  final StreamController<List<int>> _f001Notifications =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _f002Notifications =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _f003Notifications =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _specificOpsNotifications =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _racpNotifications =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _measurementNotifications =
      StreamController<List<int>>.broadcast();
  final Map<int, CgmReading> _historyByMinute = <int, CgmReading>{};
  final Map<int, CgmReading> _rawHistoryByMinute = <int, CgmReading>{};
  final Map<String, BleCharacteristicRef> _characteristics =
      <String, BleCharacteristicRef>{};
  final Map<String, StreamSubscription<List<int>>> _notificationSubscriptions =
      <String, StreamSubscription<List<int>>>{};
  final Map<String, String> _rawHex = <String, String>{};
  final AidexUnsafeAdmin _unsafeAdmin;

  CgmSessionSnapshot _snapshot;
  BleConnection? _connection;
  StreamSubscription<BleConnectionState>? _connectionStateSubscription;
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  Uint8List? _sessionKey;
  Uint8List? _sessionIv;
  Uint8List? _rawVendorSeed;
  Future<void> _operationChain = Future<void>.value();
  Future<void>? _initializationFuture;
  Timer? _liveRefreshTimer;
  Timer? _historyResumeTimer;
  bool _liveCatchUpQueued = false;
  bool _disconnecting = false;
  bool _discoveryRecoveryUsed = false;
  bool? _sensorPairedBeforeBond;
  String _lastF003Hex = '';

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  AidexUnsafeAdmin get unsafeAdmin => _unsafeAdmin;

  @override
  Future<CgmBondTransferPlan> inspectBondTransfer() {
    return _runQueued<CgmBondTransferPlan>(
      _inspectBondTransferInternal,
      allowWhileDisconnecting: true,
    );
  }

  @override
  Future<void> executeBondTransfer(
    CgmBondTransferPlan plan, {
    required Future<void> Function() onSensorAccepted,
  }) {
    return _runQueued<void>(
      () => _executeBondTransferInternal(
        plan,
        onSensorAccepted: onSensorAccepted,
      ),
      allowWhileDisconnecting: true,
    );
  }

  Future<void> initialize() {
    return _initializationFuture ??= _runQueued<void>(_initializeInternal);
  }

  @override
  Future<void> refresh() => _runQueued<void>(_refreshInternal);

  @override
  Future<void> refreshLiveData() => _runQueued<void>(_refreshLiveDataInternal);

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) {
    return _runQueued<void>(
      () => _syncHistoryInternal(
        includeRawHistory: includeRawHistory,
        requestedStartOffset: requestedStartOffset,
      ),
    );
  }

  Future<List<CgmReading>> fetchRawHistory({int? requestedStartOffset}) {
    return _runQueued<List<CgmReading>>(
      () =>
          _fetchRawHistoryInternal(requestedStartOffset: requestedStartOffset),
    );
  }

  Future<AidexCommunicationIntervalState> getCommunicationInterval() {
    return _runQueued<AidexCommunicationIntervalState>(
      _getCommunicationIntervalInternal,
    );
  }

  Future<AidexCommunicationIntervalState> setCommunicationInterval(
    int interval,
  ) {
    return _runQueued<AidexCommunicationIntervalState>(
      () => _setCommunicationIntervalInternal(interval),
    );
  }

  Future<bool?> getAutoUpdateStatus() {
    return _runQueued<bool?>(_getAutoUpdateStatusInternal);
  }

  Future<void> setAutoUpdateStatus(bool enabled) {
    return _runQueued<void>(() => _setAutoUpdateStatusInternal(enabled));
  }

  Future<void> setDynamicAdvertisementMode(int mode) {
    return _runQueued<void>(() => _setDynamicAdvertisementModeInternal(mode));
  }

  Future<List<CgmDiagnosticItem>> fetchDeviceLogs() {
    return _runQueued<List<CgmDiagnosticItem>>(_fetchDeviceLogsInternal);
  }

  Future<String> fetchErrorLogsHex() {
    return _runQueued<String>(_fetchErrorLogsHexInternal);
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() {
    return _runQueued<List<CgmCalibrationEntry>>(_fetchCalibrationsInternal);
  }

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) {
    return _runQueued<void>(
      () => _submitCalibrationInternal(
        glucoseMgdl: glucoseMgdl,
        sensorMinute: sensorMinute,
        recordedAt: recordedAt,
      ),
    );
  }

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() {
    return _runQueued<List<CgmDiagnosticItem>>(_refreshDiagnosticsInternal);
  }

  @override
  Future<void> disconnect() async {
    _disconnecting = true;
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _operationChain.catchError((Object _) {});
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Disconnected',
      ),
    );
    await _clearNotificationSubscriptions();
    try {
      await _connection?.disconnect();
    } catch (error) {
      _emitLog(
        CgmLogLevel.warning,
        'BLE disconnect failed (${error.runtimeType})',
      );
    }
    _connection = null;
    _connectionState = BleConnectionState.disconnected;
    await _f001Notifications.close();
    await _f002Notifications.close();
    await _f003Notifications.close();
    await _specificOpsNotifications.close();
    await _racpNotifications.close();
    await _measurementNotifications.close();
    await _snapshotController.close();
    await _logController.close();
  }

  Future<void> _initializeInternal() async {
    try {
      _setSetupPhase(AidexSetupPhase.connect);
      _emitLog(CgmLogLevel.info, 'Connecting to AiDEX sensor');
      _connection = await _transport.connect(sensor.deviceId);
      _connectionState = BleConnectionState.connected;
      _throwIfDisconnectingDuringSetup();
      _emitLog(CgmLogLevel.debug, 'BLE link connected');

      // AiDEX establishes BLE security after the client has enumerated the
      // GATT table. This discovery does not subscribe to Service Changed, so
      // it is safe before bonding and lets Android learn the protected
      // services before createBond starts.
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.bonding,
          statusText: 'Discovering services',
        ),
      );
      _setSetupPhase(AidexSetupPhase.discovery);
      _emitLog(CgmLogLevel.debug, 'Discovering services');
      await _discoverServicesWithRecovery(verifyPersistedBondOnRecovery: false);
      _throwIfDisconnectingDuringSetup();

      _setSetupPhase(AidexSetupPhase.bond);
      var conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      // F005 only informs Android's explicit bond-lifecycle recovery. Reading
      // it on iOS is unnecessary and can trigger protected-link behavior.
      if (conn.supportsBondLifecycle) {
        await _capturePreBondSensorPairState();
        _throwIfDisconnectingDuringSetup();
      } else {
        _sensorPairedBeforeBond = null;
      }
      final bondStateBeforeSetup = conn.supportsBondLifecycle
          ? await conn.currentBondState()
          : BleBondState.bonded;
      _throwIfDisconnectingDuringSetup();
      var debugBmsProbeEnabled = false;
      assert(() {
        debugBmsProbeEnabled = true;
        return true;
      }(), 'debug BMS feature probe');
      if (debugBmsProbeEnabled &&
          conn.supportsBondLifecycle &&
          bondStateBeforeSetup == BleBondState.unbonded &&
          _sensorPairedBeforeBond == true) {
        await _probeDebugBmsFeature();
        _throwIfDisconnectingDuringSetup();
      }
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.bonding,
          statusText: 'Bonding BLE link',
        ),
      );
      conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      _throwIfDisconnectingDuringSetup();
      _emitLog(CgmLogLevel.debug, 'Ensuring BLE bond');
      try {
        await conn.ensureBonded();
      } on BleFailure catch (error, stackTrace) {
        if (bondStateBeforeSetup == BleBondState.unbonded &&
            _sensorPairedBeforeBond == true &&
            (error.kind == BleFailureKind.sensorPossiblyInUse ||
                error.kind == BleFailureKind.bondRejected)) {
          Error.throwWithStackTrace(
            BleFailure(
              kind: BleFailureKind.bondRejected,
              operation: BleOperation.bond,
              diagnosticCode: 'aidex.bond.sensor-paired-os-unbonded',
            ),
            stackTrace,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      _throwIfDisconnectingDuringSetup();
      conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      final bondStateAfterSetup = conn.supportsBondLifecycle
          ? await conn.currentBondState()
          : BleBondState.bonded;
      _throwIfDisconnectingDuringSetup();
      if (conn.supportsBondLifecycle &&
          bondStateAfterSetup != BleBondState.bonded) {
        throw BleFailure(
          kind: BleFailureKind.bondRejected,
          operation: BleOperation.bond,
          diagnosticCode: 'aidex.bond.not-completed',
        );
      }
      final establishedBondDuringSetup =
          conn.supportsBondLifecycle &&
          bondStateBeforeSetup != BleBondState.bonded &&
          bondStateAfterSetup == BleBondState.bonded;
      if (establishedBondDuringSetup) {
        _setSetupPhase(AidexSetupPhase.reconnect);
        await _refreshGattConnection(
          conn,
          closeGap: _timings.gattGap,
          postConnectSettle: Duration.zero,
          statusText: 'Refreshing Bluetooth link',
          logReason: 'after bond',
          verifyPersistedBond: true,
        );
        _setSnapshot(
          _snapshot.copyWith(
            stage: CgmSyncStage.bonding,
            statusText: 'Discovering services',
          ),
        );
        _setSetupPhase(AidexSetupPhase.discovery);
        _emitLog(CgmLogLevel.debug, 'Rediscovering services after bond');
        await _discoverServicesWithRecovery(
          verifyPersistedBondOnRecovery: true,
        );
        _throwIfDisconnectingDuringSetup();
      } else {
        _monitorConnectionState();
      }
      // A newly created bond gets a fresh GATT connection and fresh handles.
      // A bond retained from an earlier run keeps the first discovery and
      // avoids unnecessary disconnect/reconnect churn.
      final identityRequiredBeforeVendorPair =
          _requiresGattIdentityForVendorPair();
      await _initializeVendorNotificationsWithRecovery(
        identityRequiredBeforeVendorPair: identityRequiredBeforeVendorPair,
      );
      _throwIfDisconnectingDuringSetup();
      if (!identityRequiredBeforeVendorPair) {
        _setSetupPhase(AidexSetupPhase.identity);
        _emitLog(CgmLogLevel.debug, 'Prefetching identity');
        await _prefetchIdentity();
      }
      _setSetupPhase(AidexSetupPhase.baseline);
      _emitLog(CgmLogLevel.debug, 'Refreshing baseline');
      await _refreshBaseline();
      _setSetupPhase(AidexSetupPhase.activation);
      final sessionStart = parseSessionStart(
        bytesFromHex(_rawHex[AidexUuids.sessionStart] ?? ''),
      );
      final status = parseCgmStatus(
        bytesFromHex(_rawHex[AidexUuids.status] ?? ''),
      );
      final explicitActivationAllowed =
          sensor.metadata[cgmAllowSessionActivationMetadataKey] == 'true';
      final activationReady =
          explicitActivationAllowed &&
          sessionStart != null &&
          sessionStart.isAllZero &&
          status?.sessionStopped == true;
      if (activationReady) {
        _throwIfDisconnectingDuringSetup();
        _emitLog(CgmLogLevel.debug, 'Starting CGM session');
        await _startSession();
      } else if (sessionStart == null ||
          sessionStart.isAllZero ||
          status?.sessionStopped == true) {
        final stoppedExistingSession =
            status?.sessionStopped == true &&
            sessionStart != null &&
            !sessionStart.isAllZero;
        final activationRequired =
            sessionStart != null &&
            sessionStart.isAllZero &&
            status?.sessionStopped == true;
        _setSnapshot(
          _snapshot.copyWith(
            stage: CgmSyncStage.error,
            statusText: stoppedExistingSession
                ? 'Sensor session ended'
                : activationRequired
                ? 'Sensor activation required'
                : 'Could not verify sensor session',
            sessionInfo: _snapshot.sessionInfo.copyWith(
              sessionStopped: stoppedExistingSession,
            ),
            health: _snapshot.health.copyWith(
              statusText: stoppedExistingSession
                  ? 'Session stopped'
                  : activationRequired
                  ? 'Session not started'
                  : 'Session state unavailable',
              expired: stoppedExistingSession,
            ),
            metadata: <String, String>{
              ..._snapshot.metadata,
              if (activationRequired) 'activationRequired': 'true',
            },
            lastError: stoppedExistingSession
                ? 'This sensor session has ended. Connect a new sensor.'
                : activationRequired
                ? 'Choose this sensor from the scan screen to start it.'
                : 'The sensor session state could not be verified safely.',
          ),
        );
        throw StateError(
          stoppedExistingSession
              ? 'Refusing to restart a stopped sensor session'
              : activationRequired
              ? 'Sensor activation requires an explicit user connection'
              : 'Refusing activation because sensor state is malformed',
        );
      }
      _setSetupPhase(AidexSetupPhase.finalization);
      await _refreshVendorStartTimeInternal();
      await _ensureLiveUpdateConfiguration();
      final readyMetadata = <String, String>{..._snapshot.metadata}
        ..remove(aidexSetupPhaseMetadataKey)
        ..remove(aidexSubscribeStepMetadataKey)
        ..remove(aidexSubscribeAttemptMetadataKey)
        ..remove(bleFailureKindMetadataKey)
        ..remove(bleFailureOperationMetadataKey)
        ..remove(bleFailureDiagnosticCodeMetadataKey);
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.ready,
          statusText: 'Connected',
          metadata: readyMetadata,
        ),
      );
      _emitLog(CgmLogLevel.info, 'Aidex session connected');
      unawaited(_runInitialBackgroundSync());
      _scheduleLiveRefresh(const Duration(seconds: 1));
    } catch (error, stackTrace) {
      if (!_disconnecting) {
        await _teardownFailedSetupLink();
      }
      _debugAidexSetupTrace('handle-error-start');
      _handleError(error, stackTrace, context: 'initializing session');
      _debugAidexSetupTrace('handle-error-complete');
    }
  }

  Future<void> _teardownFailedSetupLink() async {
    _debugAidexSetupTrace('teardown-start');
    try {
      await _connectionStateSubscription?.cancel();
    } catch (error) {
      _emitLog(
        CgmLogLevel.warning,
        'BLE monitor cleanup failed (${error.runtimeType})',
      );
    }
    _connectionStateSubscription = null;
    _debugAidexSetupTrace('teardown-monitor-cleared');
    try {
      await _clearNotificationSubscriptions();
    } catch (error) {
      _emitLog(
        CgmLogLevel.warning,
        'BLE notification cleanup failed (${error.runtimeType})',
      );
    }
    _debugAidexSetupTrace('teardown-listeners-cleared');
    final failedConnection = _connection;
    _connection = null;
    _connectionState = BleConnectionState.disconnected;
    _debugAidexSetupTrace('teardown-link-released');
    if (failedConnection == null) {
      _debugAidexSetupTrace('teardown-no-link');
      return;
    }
    try {
      _debugAidexSetupTrace('teardown-disconnect-start');
      await failedConnection.disconnect();
      _debugAidexSetupTrace('teardown-disconnect-complete');
    } catch (error) {
      _debugAidexSetupTrace('teardown-disconnect-failed');
      _emitLog(
        CgmLogLevel.warning,
        'BLE setup disconnect failed (${error.runtimeType})',
      );
    }
  }

  Future<void> _capturePreBondSensorPairState() async {
    _sensorPairedBeforeBond = null;
    try {
      final state = await _read(_characteristic(AidexUuids.f005));
      if (state.isNotEmpty && (state.first == 0x00 || state.first == 0x01)) {
        _sensorPairedBeforeBond = state.first == 0x01;
        _debugAidexSetupTrace(
          _sensorPairedBeforeBond! ? 'f005-paired' : 'f005-unpaired',
        );
        _emitLog(CgmLogLevel.debug, 'Read sensor pairing state');
      }
    } catch (error) {
      // This read is diagnostic only. Bonding remains authoritative, and
      // setup must never reset either side when the value is unavailable.
      _emitLog(
        CgmLogLevel.debug,
        'Sensor pairing state unavailable (${error.runtimeType})',
      );
    }
  }

  Future<void> _probeDebugBmsFeature() async {
    final featureRef =
        _characteristics[_normalizeUuid(AidexUuids.bondManagementFeature)];
    if (featureRef == null) {
      _debugAidexSetupTrace('bms-feature-unavailable');
      return;
    }
    try {
      final feature = await _read(featureRef);
      if (feature.isEmpty) {
        _debugAidexSetupTrace('bms-feature-unavailable');
        return;
      }
      // Bluetooth SIG BMS Feature octet 1 bits 2 and 3 respectively
      // advertise delete-all LE bonds and its authorization-code requirement.
      final supportsDeleteAllLe =
          feature.length >= 2 && (feature[1] & 0x04) != 0;
      final requiresAuthorizationCode =
          feature.length >= 2 && (feature[1] & 0x08) != 0;
      _debugAidexSetupTrace(
        supportsDeleteAllLe && !requiresAuthorizationCode
            ? 'bms-delete-all-le-without-authorization-code-operand-supported'
            : 'bms-delete-all-le-without-authorization-code-operand-unsupported',
      );
    } catch (_) {
      _debugAidexSetupTrace('bms-feature-read-failed');
    }
  }

  Future<void> _discoverServicesWithRecovery({
    required bool verifyPersistedBondOnRecovery,
  }) async {
    final discoveryConnection = _connection;
    if (discoveryConnection == null) {
      throw StateError('Disconnected before service discovery');
    }

    try {
      await _discoverServices();
      return;
    } on BleFailure catch (error, stackTrace) {
      if (!_isRecoverableDiscoveryFailure(error)) {
        rethrow;
      }
      if (_discoveryRecoveryUsed) {
        _throwDiscoveryRecoveryExhausted(error, stackTrace);
      }
      _discoveryRecoveryUsed = true;
    }

    // The first discovery future is terminal before recovery starts. This is
    // important for transports that serialize BLE plugin operations.
    _throwIfDisconnectingDuringSetup();
    _setSetupPhase(AidexSetupPhase.reconnect);
    await _refreshGattConnection(
      discoveryConnection,
      closeGap: _timings.discoveryRecoveryCloseGap,
      postConnectSettle: _timings.discoveryRecoveryPostConnectSettle,
      statusText: 'Recovering Bluetooth setup',
      logReason: 'for service discovery recovery',
      verifyPersistedBond: verifyPersistedBondOnRecovery,
    );
    _throwIfDisconnectingDuringSetup();

    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.bonding,
        statusText: 'Discovering services',
      ),
    );
    _setSetupPhase(AidexSetupPhase.discovery);
    _emitLog(CgmLogLevel.debug, 'Retrying service discovery');
    _throwIfDisconnectingDuringSetup();
    // One retry only. Any second failure is final and remains in phase P04.
    try {
      await _discoverServices();
    } on BleFailure catch (error, stackTrace) {
      if (!_isRecoverableDiscoveryFailure(error)) {
        rethrow;
      }
      _throwDiscoveryRecoveryExhausted(error, stackTrace);
    }
  }

  Never _throwDiscoveryRecoveryExhausted(
    BleFailure error,
    StackTrace stackTrace,
  ) {
    Error.throwWithStackTrace(
      BleFailure(
        kind: BleFailureKind.unexpected,
        operation: BleOperation.discoverServices,
        diagnosticCode: 'aidex.discovery.${error.kind.name}.recovery-exhausted',
      ),
      stackTrace,
    );
  }

  bool _isRecoverableDiscoveryFailure(BleFailure failure) {
    return failure.operation == BleOperation.discoverServices &&
        (failure.kind == BleFailureKind.operationTimedOut ||
            failure.kind == BleFailureKind.deviceDisconnected);
  }

  Future<void> _initializeVendorNotificationsWithRecovery({
    required bool identityRequiredBeforeVendorPair,
  }) async {
    var attempt = AidexSubscribeAttempt.initial;
    var recoveryUsed = false;

    while (true) {
      final attemptConnection = _connection;
      if (attemptConnection == null) {
        throw StateError('Disconnected before notification setup');
      }

      try {
        await _subscribeBeforeVendorPair(attempt);
        _throwIfDisconnectingDuringSetup();
        if (identityRequiredBeforeVendorPair &&
            _snapshot.sessionInfo.serial.trim().isEmpty) {
          _setSetupPhase(AidexSetupPhase.identity);
          _emitLog(CgmLogLevel.debug, 'Prefetching identity for vendor pair');
          await _prefetchIdentity();
        }
        _setSetupPhase(AidexSetupPhase.vendorPair);
        _emitLog(CgmLogLevel.debug, 'Running vendor pair handshake');
        await _pairVendor();
        _throwIfDisconnectingDuringSetup();
        await _subscribeAfterVendorPair(attempt);
        return;
      } on BleFailure catch (error, stackTrace) {
        await _clearNotificationSubscriptions();
        if (!_isRecoverableSubscriptionFailure(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (recoveryUsed) {
          Error.throwWithStackTrace(
            BleFailure(
              kind: BleFailureKind.unexpected,
              operation: BleOperation.subscribe,
              diagnosticCode:
                  'aidex.subscribe.${error.kind.name}.recovery-exhausted',
            ),
            stackTrace,
          );
        }

        // A fresh GATT link has a fresh F002 token. Discard the old
        // connection-scoped vendor session and authenticate the replacement
        // link before replaying post-authentication subscriptions.
        recoveryUsed = true;
        _clearVendorSessionState();
        _throwIfDisconnectingDuringSetup();
        _setSetupPhase(AidexSetupPhase.reconnect);
        await _refreshGattConnection(
          attemptConnection,
          closeGap: _timings.subscriptionRecoveryCloseGap,
          postConnectSettle: _timings.subscriptionRecoveryPostConnectSettle,
          statusText: 'Recovering Bluetooth setup',
          logReason: 'for notification recovery',
          verifyPersistedBond: true,
        );
        _throwIfDisconnectingDuringSetup();

        _setSnapshot(
          _snapshot.copyWith(
            stage: CgmSyncStage.bonding,
            statusText: 'Discovering services',
          ),
        );
        _setSetupPhase(AidexSetupPhase.discovery);
        _emitLog(CgmLogLevel.debug, 'Rediscovering services after recovery');
        await _discoverServices();
        _throwIfDisconnectingDuringSetup();
        attempt = AidexSubscribeAttempt.recovery;
      } catch (error, stackTrace) {
        await _clearNotificationSubscriptions();
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  bool _isRecoverableSubscriptionFailure(BleFailure failure) {
    return failure.operation == BleOperation.subscribe &&
        (failure.kind == BleFailureKind.operationTimedOut ||
            failure.kind == BleFailureKind.deviceDisconnected);
  }

  void _clearVendorSessionState() {
    _sessionKey = null;
    _sessionIv = null;
    _rawVendorSeed = null;
    _lastF003Hex = '';
    _rawHex
      ..remove(AidexUuids.f001)
      ..remove(AidexUuids.f002)
      ..remove(AidexUuids.f003);
    final metadata = <String, String>{..._snapshot.metadata}
      ..remove('vendorPaired');
    _setSnapshot(_snapshot.copyWith(metadata: metadata));
  }

  Future<void> _refreshGattConnection(
    BleConnection priorConnection, {
    required Duration closeGap,
    required Duration postConnectSettle,
    required String statusText,
    required String logReason,
    required bool verifyPersistedBond,
  }) async {
    _throwIfDisconnectingDuringSetup();
    final activeConnection = _connection;
    if (activeConnection != null &&
        !identical(activeConnection, priorConnection)) {
      throw StateError('BLE connection changed during GATT refresh');
    }
    _setSnapshot(
      _snapshot.copyWith(stage: CgmSyncStage.bonding, statusText: statusText),
    );
    _emitLog(CgmLogLevel.debug, 'Refreshing GATT link $logReason');

    // Android vendors can retain a stale GATT client after a bond transition
    // or failed discovery. Cancel monitoring before this intentional
    // disconnect so it cannot be reported as a user-visible link loss.
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _throwIfDisconnectingDuringSetup();
    await priorConnection.disconnect();
    _connection = null;
    _connectionState = BleConnectionState.disconnected;

    _throwIfDisconnectingDuringSetup();
    await Future<void>.delayed(closeGap);
    _throwIfDisconnectingDuringSetup();
    final refreshedConnection = await _transport.connect(sensor.deviceId);
    _connection = refreshedConnection;
    _connectionState = BleConnectionState.connected;
    _throwIfDisconnectingDuringSetup();

    if (verifyPersistedBond && refreshedConnection.supportsBondLifecycle) {
      final refreshedBondState = await refreshedConnection.currentBondState();
      _throwIfDisconnectingDuringSetup();
      if (refreshedBondState != BleBondState.bonded) {
        throw BleFailure(
          kind: BleFailureKind.bondRejected,
          operation: BleOperation.bond,
          diagnosticCode: 'aidex.bond.not-persisted',
        );
      }
    }

    await Future<void>.delayed(postConnectSettle);
    _throwIfDisconnectingDuringSetup();
    if (verifyPersistedBond) {
      _monitorConnectionState();
    }
    _emitLog(CgmLogLevel.debug, 'GATT link refreshed $logReason');
  }

  void _throwIfDisconnectingDuringSetup() {
    if (_disconnecting) {
      throw const _SessionSetupCancelled();
    }
  }

  Future<void> _runInitialBackgroundSync() async {
    try {
      _emitLog(CgmLogLevel.debug, 'Syncing history');
      await _runQueued<void>(
        () => _syncHistoryInternal(includeRawHistory: false),
      );
    } catch (error, stackTrace) {
      _handleError(error, stackTrace, context: 'syncing history');
    }
  }

  Future<void> _refreshInternal() async {
    await _refreshBaseline();
    await _refreshDiagnosticsInternal();
  }

  void _scheduleLiveRefresh([Duration delay = _liveRefreshInterval]) {
    _liveRefreshTimer?.cancel();
    if (_disconnecting) {
      return;
    }
    _liveRefreshTimer = Timer(delay, () {
      _liveRefreshTimer = null;
      if (_disconnecting) {
        return;
      }
      unawaited(
        _runQueued<void>(() async {
          try {
            await _refreshLiveDataInternal();
          } catch (error) {
            _emitLog(
              CgmLogLevel.warning,
              'Live refresh failed (${error.runtimeType})',
            );
            _queueCatchUpSyncIfStale(reason: 'Live refresh failed');
          } finally {
            if (!_disconnecting) {
              _scheduleLiveRefresh();
            }
          }
        }),
      );
    });
  }

  Future<void> _refreshLiveDataInternal() async {
    if (_disconnecting ||
        _connection == null ||
        _connectionState != BleConnectionState.connected ||
        _sessionKey == null ||
        _sessionIv == null) {
      return;
    }

    final response = await _sendVendorCommand(
      AidexVendorOpcode.getBroadcastData,
    );
    final broadcast = parseVendorBroadcastData(response.payload);
    final liveMinute = broadcast.timeOffsetMinutes;
    final latestStoredOffset = _latestStoredOffset();
    if (liveMinute != null) {
      _setSnapshot(
        _snapshot.copyWith(
          sessionInfo: _snapshot.sessionInfo.copyWith(
            elapsedMinutes: liveMinute,
          ),
        ),
      );
    }
    if (!broadcast.isUsableGlucose ||
        liveMinute == null ||
        broadcast.currentGlucoseMgdl == null) {
      if (liveMinute != null &&
          latestStoredOffset != null &&
          liveMinute > latestStoredOffset + 1) {
        _queueCatchUpSync(
          requestedStartOffset: latestStoredOffset + 1,
          reason: 'Vendor broadcast gap detected',
        );
      }
      _queueCatchUpSyncIfStale(reason: 'Vendor broadcast not usable');
      return;
    }

    _applyLiveReading(
      CgmReading(
        valueMgdl: broadcast.currentGlucoseMgdl!,
        source: CgmRecordSource.broadcast,
        sensorMinute: liveMinute,
        rawValue: broadcast.currentGlucoseRawByte,
        qualifier: broadcast.currentQualifier,
      ),
      scheduleCatchUp: true,
    );
    _queueCatchUpSyncIfStale(
      reason: 'Latest reading is stale after live refresh',
    );
  }

  void _monitorConnectionState() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    _connectionState = BleConnectionState.connected;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = connection.connectionStates.listen(
      (state) {
        _connectionState = state;
        if (_disconnecting) {
          return;
        }
        if (state == BleConnectionState.disconnected) {
          _handleUnexpectedDisconnect();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _handleError(error, stackTrace, context: 'monitoring BLE connection');
      },
    );
  }

  void _handleUnexpectedDisconnect() {
    if (_disconnecting || _snapshot.stage == CgmSyncStage.disconnected) {
      return;
    }
    final existingFailure = _snapshot.stage == CgmSyncStage.error
        ? BleFailure.fromMetadata(_snapshot.metadata)
        : null;
    final failure =
        existingFailure ??
        BleFailure(
          kind: BleFailureKind.deviceDisconnected,
          operation: BleOperation.connect,
          diagnosticCode: 'aidex.connection.disconnected',
        );
    _connection = null;
    _connectionState = BleConnectionState.disconnected;
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    _liveCatchUpQueued = false;
    _emitLog(CgmLogLevel.warning, 'BLE link disconnected unexpectedly');
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Connection lost',
        metadata: <String, String>{
          ..._snapshot.metadata,
          ...failure.toMetadata(),
        },
        lastError: existingFailure == null
            ? 'BLE connection lost'
            : _snapshot.lastError,
      ),
    );
  }

  void _handleMeasurementNotification(List<int> bytes) {
    final records = parseStandardMeasurementNotification(bytes);
    final liveMinute = records
        .map((record) => record.sensorMinute)
        .whereType<int>()
        .fold<int?>(null, (latest, minute) {
          if (latest == null || minute > latest) {
            return minute;
          }
          return latest;
        });
    if (liveMinute != null) {
      _setSnapshot(
        _snapshot.copyWith(
          sessionInfo: _snapshot.sessionInfo.copyWith(
            elapsedMinutes: liveMinute,
          ),
        ),
      );
    }
    for (final record in records) {
      _applyLiveReading(record, scheduleCatchUp: true);
    }
    _queueCatchUpSyncIfStale(
      reason: 'Latest reading is stale after measurement update',
    );
  }

  void _applyLiveReading(CgmReading reading, {required bool scheduleCatchUp}) {
    final resolved = _applyAbsoluteRecordedAt(reading);
    final minute = resolved.sensorMinute;
    final latestStoredOffset = _latestStoredOffset();
    final canMergeIntoHistory =
        minute != null &&
        (latestStoredOffset == null || minute <= latestStoredOffset + 1);

    if (canMergeIntoHistory) {
      _historyByMinute[minute] = resolved;
      final history = _sortedHistory(_historyByMinute);
      _setSnapshot(
        _snapshot.copyWith(
          latestReading: history.isEmpty ? resolved : history.last,
          history: history,
          historySync: _snapshot.historySync.copyWith(
            storedCount: _historyByMinute.length,
            latestStoredOffset: _latestStoredOffset(),
          ),
          metadata: <String, String>{
            ..._snapshot.metadata,
            'historyCount': _historyByMinute.length.toString(),
          },
        ),
      );
      _reconcileSessionStartToElapsedClock(source: 'live');
      return;
    }

    _setSnapshot(_snapshot.copyWith(latestReading: resolved));
    _reconcileSessionStartToElapsedClock(source: 'live');

    if (scheduleCatchUp &&
        minute != null &&
        latestStoredOffset != null &&
        minute > latestStoredOffset + 1 &&
        !_snapshot.historySync.inProgress) {
      _queueCatchUpSync(
        requestedStartOffset: latestStoredOffset + 1,
        reason: 'Live reading jumped ahead',
      );
    }
  }

  Future<void> _discoverServices() async {
    final services = await _requireConnection.discoverServices();
    // A post-bond discovery must fully replace pre-bond references. Android
    // may return different characteristic handles after encryption starts.
    final refreshedCharacteristics = <String, BleCharacteristicRef>{};
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        refreshedCharacteristics[_normalizeUuid(
          characteristic.characteristicUuid,
        )] = characteristic.copyWith(
          serviceUuid: _normalizeUuid(service.uuid),
        );
      }
    }
    for (final uuid in <String>[
      AidexUuids.f001,
      AidexUuids.f002,
      AidexUuids.f005,
      AidexUuids.status,
      AidexUuids.sessionStart,
      AidexUuids.sessionRunTime,
      AidexUuids.specificOps,
      AidexUuids.racp,
      AidexUuids.measurement,
    ]) {
      if (!refreshedCharacteristics.containsKey(uuid)) {
        throw StateError('Missing required Aidex characteristic $uuid.');
      }
    }
    _characteristics
      ..clear()
      ..addAll(refreshedCharacteristics);
  }

  Future<void> _subscribeBeforeVendorPair(String attempt) async {
    await _attachNotification(
      AidexUuids.f001,
      _f001Notifications,
      step: AidexSubscribeStep.f001,
      attempt: attempt,
    );
    await _attachNotification(
      AidexUuids.f002,
      _f002Notifications,
      step: AidexSubscribeStep.f002,
      attempt: attempt,
    );
  }

  Future<void> _subscribeAfterVendorPair(String attempt) async {
    if (_characteristics.containsKey(AidexUuids.f003)) {
      await _attachNotification(
        AidexUuids.f003,
        _f003Notifications,
        step: AidexSubscribeStep.f003,
        attempt: attempt,
      );
    }
    await _attachNotification(
      AidexUuids.specificOps,
      _specificOpsNotifications,
      step: AidexSubscribeStep.specificOps,
      attempt: attempt,
    );
    await _attachNotification(
      AidexUuids.racp,
      _racpNotifications,
      step: AidexSubscribeStep.racp,
      attempt: attempt,
    );
    await _attachNotification(
      AidexUuids.measurement,
      _measurementNotifications,
      step: AidexSubscribeStep.measurement,
      attempt: attempt,
    );
  }

  Future<void> _attachNotification(
    String uuid,
    StreamController<List<int>> sink, {
    required String step,
    required String attempt,
  }) async {
    _setSubscriptionProgress(step: step, attempt: attempt);
    _emitLog(CgmLogLevel.debug, 'Subscribing to notification $step');
    _throwIfNotificationLinkDisconnected();
    final ref = _characteristic(uuid);
    final conn = _requireConnection;
    final stream = conn.notifications(ref);
    _notificationSubscriptions[uuid] = stream.listen(
      (bytes) {
        _rawHex[uuid] = hexOf(bytes);
        if (!sink.isClosed) {
          sink.add(bytes);
        }
        if (uuid == AidexUuids.f003) {
          _lastF003Hex = hexOf(bytes);
        } else if (uuid == AidexUuids.measurement) {
          _handleMeasurementNotification(bytes);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _handleError(error, stackTrace, context: 'receiving BLE notifications');
      },
    );
    await conn.setNotify(ref, true);
    _throwIfNotificationLinkDisconnected();
    await Future<void>.delayed(_timings.gattGap);
    _throwIfNotificationLinkDisconnected();
  }

  void _throwIfNotificationLinkDisconnected() {
    _throwIfDisconnectingDuringSetup();
    if (_connection == null ||
        _connectionState != BleConnectionState.connected) {
      throw BleFailure(
        kind: BleFailureKind.deviceDisconnected,
        operation: BleOperation.subscribe,
        diagnosticCode: 'aidex.subscribe.link-disconnected',
      );
    }
  }

  Future<void> _clearNotificationSubscriptions() async {
    for (final subscription in _notificationSubscriptions.values) {
      await subscription.cancel();
    }
    _notificationSubscriptions.clear();
  }

  Future<void> _pairVendor() async {
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.pairing,
        statusText: 'Running vendor pair handshake',
      ),
    );
    final prefetchedSerial = _snapshot.sessionInfo.serial.trim().toUpperCase();
    final serial =
        sensor.metadata['serial'] ??
        (prefetchedSerial.isEmpty ? null : prefetchedSerial) ??
        extractAidexSerial(sensor.displayName);
    if (serial.isEmpty) {
      throw StateError(
        'Cannot derive Aidex serial from ${sensor.displayName}.',
      );
    }
    final crypto = deriveAidexCrypto(serial);
    _sessionIv = crypto.iv;
    final seedFuture = _f001Notifications.stream.first.timeout(
      _timings.vendorPairTimeout,
    );
    await _write(_characteristic(AidexUuids.f001), crypto.secret);
    _rawVendorSeed = Uint8List.fromList(await seedFuture);
    final pairResponse = await _read(_characteristic(AidexUuids.f002));
    final pairResult = processVendorPairResponse(
      Uint8List.fromList(pairResponse),
      _rawVendorSeed!,
      crypto.iv,
    );
    if (pairResult == null) {
      throw StateError('Aidex vendor pair response failed CRC8 validation.');
    }
    _sessionKey = pairResult.sessionKey;
    _setSnapshot(
      _snapshot.copyWith(
        metadata: <String, String>{
          ..._snapshot.metadata,
          'vendorPaired': 'true',
        },
      ),
    );
    _emitLog(CgmLogLevel.info, 'Vendor session key established');
  }

  Future<void> _refreshBaseline() async {
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.syncing,
        statusText: 'Reading baseline characteristics',
      ),
    );
    await _prefetchIdentity();
    final manufacturer = _snapshot.sessionInfo.manufacturer;
    final model = _snapshot.sessionInfo.model;
    final serial = _snapshot.sessionInfo.serial;
    final firmware = _snapshot.sessionInfo.firmware;
    final feature = await _read(_characteristic(AidexUuids.feature));
    final statusBytes = await _read(_characteristic(AidexUuids.status));
    final sessionStartBytes = await _read(
      _characteristic(AidexUuids.sessionStart),
    );
    final sessionRunTime = await _read(
      _characteristic(AidexUuids.sessionRunTime),
    );

    _rawHex[AidexUuids.manufacturerName] = hexOf(utf8.encode(manufacturer));
    _rawHex[AidexUuids.modelNumber] = hexOf(utf8.encode(model));
    _rawHex[AidexUuids.serialNumber] = hexOf(utf8.encode(serial));
    _rawHex[AidexUuids.softwareRevision] = hexOf(utf8.encode(firmware));
    _rawHex[AidexUuids.feature] = hexOf(feature);
    _rawHex[AidexUuids.status] = hexOf(statusBytes);
    _rawHex[AidexUuids.sessionStart] = hexOf(sessionStartBytes);
    _rawHex[AidexUuids.sessionRunTime] = hexOf(sessionRunTime);

    final parsedStatus = parseCgmStatus(statusBytes);
    final parsedSessionStart = parseSessionStart(sessionStartBytes);
    // Brand-new AiDEX sensors expose an all-zero session start together with
    // the stopped bit until the explicit Start Session exchange completes.
    // That is an activation-ready state, not an expired session. Avoid
    // publishing a terminal snapshot during this narrow initialization phase;
    // the controller would otherwise correctly archive it before activation.
    final activationRequired =
        parsedStatus?.sessionStopped == true &&
        parsedSessionStart != null &&
        parsedSessionStart.isAllZero;
    final activationPending =
        activationRequired &&
        sensor.metadata[cgmAllowSessionActivationMetadataKey] == 'true';
    final stoppedExistingSession =
        parsedStatus?.sessionStopped == true &&
        parsedSessionStart != null &&
        !parsedSessionStart.isAllZero;
    final sessionStopped = stoppedExistingSession;
    final sessionInfo = _snapshot.sessionInfo.copyWith(
      manufacturer: manufacturer,
      model: model,
      serial: serial,
      firmware: firmware,
      sessionStart: _snapshot.sessionInfo.sessionStart,
      sessionStartPayloadHex: hexOf(sessionStartBytes),
      elapsedMinutes: parsedStatus?.timeOffsetMinutes,
      sessionStopped: sessionStopped,
    );
    final health = _snapshot.health.copyWith(
      warningFlagsHex: parsedStatus == null
          ? _snapshot.health.warningFlagsHex
          : '0x${parsedStatus.warningFlags.toRadixString(16).padLeft(2, '0')}',
      statusText: activationPending
          ? 'Awaiting activation'
          : activationRequired
          ? 'Activation required'
          : sessionStopped
          ? 'Session stopped'
          : parsedStatus?.sessionStopped == true
          ? 'Session state unavailable'
          : 'Session active',
      expired: sessionStopped,
    );
    _setSnapshot(
      _snapshot.copyWith(
        sessionInfo: sessionInfo,
        health: health,
        metadata: <String, String>{
          ..._snapshot.metadata,
          'featureHex': hexOf(feature),
          'sessionRunTimeHex': hexOf(sessionRunTime),
        },
      ),
    );
    final gattStart = parsedSessionStart?.absoluteStart;
    if (gattStart != null) {
      _adoptSessionStartIfPlausible(gattStart, source: 'gatt');
    }
    _reconcileSessionStartToElapsedClock(source: 'status');
  }

  Future<void> _ensureLiveUpdateConfiguration() async {
    if (!_snapshot.capabilities.supportsAutoUpdateControl) {
      return;
    }
    try {
      final enabled = await _getAutoUpdateStatusInternal();
      if (enabled == true) {
        _emitLog(CgmLogLevel.debug, 'Vendor auto-update already enabled');
        return;
      }
      await _setAutoUpdateStatusInternal(true);
      _emitLog(CgmLogLevel.info, 'Enabled vendor auto-update');
    } catch (error) {
      _emitLog(
        CgmLogLevel.warning,
        'Could not ensure vendor auto-update is enabled '
        '(${error.runtimeType})',
      );
    }
  }

  Future<void> _prefetchIdentity() async {
    final manufacturer = await _readUtf8(AidexUuids.manufacturerName);
    final model = await _readUtf8(AidexUuids.modelNumber);
    final serial = await _readUtf8(AidexUuids.serialNumber);
    final firmware = parseFirmwareRevision(
      await _read(_characteristic(AidexUuids.softwareRevision)),
    );

    _rawHex[AidexUuids.manufacturerName] = hexOf(utf8.encode(manufacturer));
    _rawHex[AidexUuids.modelNumber] = hexOf(utf8.encode(model));
    _rawHex[AidexUuids.serialNumber] = hexOf(utf8.encode(serial));
    _rawHex[AidexUuids.softwareRevision] = hexOf(utf8.encode(firmware));

    _setSnapshot(
      _snapshot.copyWith(
        sessionInfo: _snapshot.sessionInfo.copyWith(
          manufacturer: manufacturer,
          model: model,
          serial: serial,
          firmware: firmware,
        ),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'serial': serial,
          'model': model,
          'firmware': firmware,
        },
      ),
    );
  }

  bool _requiresGattIdentityForVendorPair() {
    final metadataSerial = sensor.metadata['serial']?.trim() ?? '';
    if (metadataSerial.isNotEmpty) {
      return false;
    }
    final snapshotSerial = _snapshot.sessionInfo.serial.trim();
    if (snapshotSerial.isNotEmpty) {
      return false;
    }
    return extractAidexSerial(sensor.displayName).isEmpty;
  }

  Future<
    ({
      BleConnection connection,
      BleCharacteristicRef controlPoint,
      CgmBondTransferPlan plan,
    })
  >
  _inspectBondTransferContext() async {
    final connection = _connection;
    if (connection == null ||
        _snapshot.stage != CgmSyncStage.ready ||
        _disconnecting ||
        _connectionState != BleConnectionState.connected) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.sessionNotReady,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    if (!connection.supportsBondLifecycle) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.unsupportedPlatform,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }
    if (_sessionKey == null || _sessionIv == null) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.linkNotAuthenticated,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }

    BleBondState bondState;
    try {
      bondState = await connection.currentBondState();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        const CgmBondTransferException(
          CgmBondTransferFailureKind.bondStateUnavailable,
          outcome: CgmBondTransferOutcome.notStarted,
        ),
        stackTrace,
      );
    }
    if (bondState != BleBondState.bonded) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondMissing,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }

    final controlPoint =
        _characteristics[_normalizeUuid(AidexUuids.bondManagementControlPoint)];
    final featureRef =
        _characteristics[_normalizeUuid(AidexUuids.bondManagementFeature)];
    if (controlPoint == null ||
        featureRef == null ||
        !controlPoint.properties.write ||
        !featureRef.properties.read) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.serviceUnavailable,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }

    List<int> feature;
    try {
      feature = await _read(featureRef);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        const CgmBondTransferException(
          CgmBondTransferFailureKind.featureUnavailable,
          outcome: CgmBondTransferOutcome.notStarted,
        ),
        stackTrace,
      );
    }
    final plan = parseAidexBondTransferFeature(feature);
    return (connection: connection, controlPoint: controlPoint, plan: plan);
  }

  Future<CgmBondTransferPlan> _inspectBondTransferInternal() async {
    final context = await _inspectBondTransferContext();
    _emitLog(
      CgmLogLevel.info,
      context.plan.removesAllLeBonds
          ? 'Sensor transfer supports all-LE bond deletion'
          : 'Sensor transfer supports requesting-phone LE bond deletion',
    );
    return context.plan;
  }

  Future<void> _executeBondTransferInternal(
    CgmBondTransferPlan expectedPlan, {
    required Future<void> Function() onSensorAccepted,
  }) async {
    final context = await _inspectBondTransferContext();
    if (context.plan != expectedPlan) {
      throw const CgmBondTransferException(
        CgmBondTransferFailureKind.featureChanged,
        outcome: CgmBondTransferOutcome.notStarted,
      );
    }

    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    _liveCatchUpQueued = false;
    _disconnecting = true;
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.bonding,
        statusText: 'Preparing sensor transfer',
        clearLastError: true,
        metadata: <String, String>{
          ..._snapshot.metadata,
          cgmBondTransferStateMetadataKey: 'requesting',
        }..remove(cgmBondTransferDiagnosticMetadataKey),
      ),
    );

    try {
      // Bluetooth BMS requires Write with Response. This irreversible write is
      // issued once; any missing response has an unknown outcome and is never
      // retried automatically.
      await _write(context.controlPoint, <int>[
        aidexBondTransferOpcode(expectedPlan),
      ], withoutResponse: false);
    } catch (error, stackTrace) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.sensorResponseUnknown,
        outcome: CgmBondTransferOutcome.unknown,
      );
      await _stopBondTransferLink(context.connection);
      _setBondTransferFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }

    try {
      await onSensorAccepted();
    } catch (error, stackTrace) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.statePersistenceFailed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      );
      await _stopBondTransferLink(context.connection);
      _setBondTransferFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }

    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.bonding,
        statusText: 'Disconnecting sensor',
        metadata: <String, String>{
          ..._snapshot.metadata,
          cgmBondTransferStateMetadataKey: 'sensor-accepted',
        },
      ),
    );
    await _cancelBondTransferListeners();

    try {
      // The BMS deletion takes effect only after the LE transport is inactive.
      await context.connection.disconnect();
    } catch (error, stackTrace) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.disconnectUnconfirmed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      );
      _setBondTransferFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }
    _connection = null;
    _connectionState = BleConnectionState.disconnected;

    try {
      // The CGM profile permits local deletion only after the sensor accepted
      // its procedure and the requested transport is no longer active.
      await context.connection.removeBond();
    } catch (error, stackTrace) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondRemovalFailed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      );
      _setBondTransferFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }

    BleBondState localBondState;
    try {
      localBondState = await context.connection.currentBondState();
    } catch (error, stackTrace) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondRemovalUnconfirmed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      );
      _setBondTransferFailure(failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }
    if (localBondState != BleBondState.unbonded) {
      final failure = const CgmBondTransferException(
        CgmBondTransferFailureKind.localBondRemovalUnconfirmed,
        outcome: CgmBondTransferOutcome.sensorAccepted,
      );
      _setBondTransferFailure(failure);
      throw failure;
    }

    _sessionKey = null;
    _sessionIv = null;
    _rawVendorSeed = null;
    _sensorPairedBeforeBond = false;
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Ready to pair with another device',
        clearLastError: true,
        metadata: <String, String>{
          ..._snapshot.metadata,
          cgmBondTransferStateMetadataKey: 'complete',
        }..remove(cgmBondTransferDiagnosticMetadataKey),
      ),
    );
  }

  Future<void> _cancelBondTransferListeners() async {
    try {
      await _connectionStateSubscription?.cancel();
    } catch (_) {
      _emitLog(CgmLogLevel.warning, 'Sensor transfer monitor cleanup failed');
    }
    _connectionStateSubscription = null;
    try {
      await _clearNotificationSubscriptions();
    } catch (_) {
      _emitLog(
        CgmLogLevel.warning,
        'Sensor transfer notification cleanup failed',
      );
    }
  }

  Future<void> _stopBondTransferLink(BleConnection connection) async {
    await _cancelBondTransferListeners();
    try {
      await connection.disconnect();
      if (identical(_connection, connection)) {
        _connection = null;
      }
      _connectionState = BleConnectionState.disconnected;
    } catch (_) {
      // The sensor-side outcome is already unknown. Keep the local bond and
      // report that terminal outcome instead of obscuring it with cleanup.
      _emitLog(
        CgmLogLevel.warning,
        'Sensor transfer cleanup disconnect failed',
      );
    }
  }

  void _setBondTransferFailure(CgmBondTransferException failure) {
    _emitLog(CgmLogLevel.error, failure.diagnosticCode);
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Sensor transfer stopped',
        lastError: failure.userMessage,
        metadata: <String, String>{
          ..._snapshot.metadata,
          cgmBondTransferStateMetadataKey: switch (failure.outcome) {
            CgmBondTransferOutcome.notStarted => 'not-started',
            CgmBondTransferOutcome.unknown => 'unknown',
            CgmBondTransferOutcome.sensorAccepted => 'sensor-accepted',
          },
          cgmBondTransferDiagnosticMetadataKey: failure.diagnosticCode,
        },
      ),
    );
  }

  Future<void> _startSession() async {
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.activating,
        statusText: 'Starting sensor session',
      ),
    );
    final responseFuture = _specificOpsNotifications.stream.first.timeout(
      _timings.vendorCommandTimeout,
    );
    await _write(
      _characteristic(AidexUuids.specificOps),
      buildSpecificOpsRequest(0x1A),
    );
    final response = await responseFuture;
    if (response.length < 3 || response[0] != 0x1C || response[1] != 0x1A) {
      throw StateError('Unexpected Start Session response ${hexOf(response)}');
    }
    final status = response[2];
    if (status != 0x01 && status != 0x03) {
      throw StateError(
        'Start Session rejected with status 0x${status.toRadixString(16)}',
      );
    }
    await Future<void>.delayed(_timings.postStartSession);
    await _write(
      _characteristic(AidexUuids.sessionStart),
      buildAidexSessionStartPayload(_clock()),
    );
    await Future<void>.delayed(_timings.postSessionStartWrite);
    await _refreshBaseline();
  }

  Future<void> _syncHistoryInternal({
    required bool includeRawHistory,
    int? requestedStartOffset,
  }) async {
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    final warmupRemaining = _warmupRemaining;
    if (warmupRemaining != null) {
      _liveCatchUpQueued = false;
      _emitLog(
        CgmLogLevel.debug,
        'Deferring Aidex history sync during sensor warmup',
      );
      _scheduleHistoryResume(
        startOffset: _normalizeResumeOffset(requestedStartOffset),
        reason: 'Aidex warmup in progress',
        delay: _warmupResumeDelay(warmupRemaining),
      );
      return;
    }
    final shouldPreserveReadyStage = _snapshot.stage == CgmSyncStage.ready;
    _setSnapshot(
      _snapshot.copyWith(
        stage: shouldPreserveReadyStage
            ? CgmSyncStage.ready
            : CgmSyncStage.syncing,
        statusText: 'Syncing Aidex history',
        historySync: _snapshot.historySync.copyWith(inProgress: true),
      ),
    );
    AidexVendorResponse rangeResponse;
    try {
      rangeResponse = await _sendVendorCommandWithRetry(
        AidexVendorOpcode.getHistoryRange,
        context: 'Aidex history range',
      );
    } on TimeoutException catch (error) {
      final resumeFrom = _normalizeResumeOffset(requestedStartOffset);
      _pauseHistorySync(
        totalAvailable: _snapshot.historySync.totalAvailable,
        resumeFromOffset: resumeFrom,
      );
      _scheduleHistoryResume(
        startOffset: resumeFrom,
        reason: 'Aidex history range timed out',
      );
      _emitLog(
        CgmLogLevel.warning,
        'Aidex history range timed out (${error.runtimeType})',
      );
      return;
    }
    final range = parseVendorRangePayload(rangeResponse.payload);
    if (range == null || range.status != 0x01) {
      throw StateError('Could not parse Aidex history range.');
    }
    final plan = planVendorHistorySync(
      range: range,
      storedCount: _historyByMinute.length,
      latestStoredOffset: _latestStoredOffset(),
      requestedStartOffset: requestedStartOffset,
    );
    if (plan.shouldResetCache) {
      _historyByMinute.clear();
    }
    _setSnapshot(
      _snapshot.copyWith(
        historySync: _snapshot.historySync.copyWith(
          inProgress: true,
          totalAvailable: plan.totalAvailable,
          startIndex: plan.startIndex,
          targetIndex: plan.targetIndex,
          storedCount: _historyByMinute.length,
        ),
      ),
    );
    if (!plan.isAlreadyCurrent) {
      var nextIndex = plan.startIndex;
      while (nextIndex <= plan.targetIndex) {
        AidexVendorResponse pageResponse;
        try {
          pageResponse = await _sendVendorCommandWithRetry(
            AidexVendorOpcode.getHistories,
            payload: littleEndian16(nextIndex),
            context: 'Aidex history page',
          );
        } on TimeoutException catch (error) {
          _pauseHistorySync(
            totalAvailable: plan.totalAvailable,
            resumeFromOffset: nextIndex,
          );
          _scheduleHistoryResume(
            startOffset: nextIndex,
            reason: 'Aidex history page timed out',
          );
          _emitLog(
            CgmLogLevel.warning,
            'Aidex history page timed out after retries '
            '(${error.runtimeType})',
          );
          return;
        }
        final page = parseVendorHistoryPagePayload(
          pageResponse.payload,
          source: CgmRecordSource.vendor,
        );
        if (page == null || page.status != 0x01) {
          throw StateError(
            'Could not parse Aidex history page at index $nextIndex.',
          );
        }
        _mergeHistory(_historyByMinute, page.records);
        final partialHistory = _sortedHistory(_historyByMinute);
        final partialLatest = partialHistory.isEmpty
            ? null
            : partialHistory.last;
        nextIndex = _nextHistoryPageIndex(page, fallbackIndex: nextIndex);
        _setSnapshot(
          _snapshot.copyWith(
            latestReading: partialLatest,
            history: partialHistory,
            historySync: _snapshot.historySync.copyWith(
              inProgress: true,
              storedCount: _historyByMinute.length,
              latestStoredOffset: _latestStoredOffset(),
            ),
            metadata: <String, String>{
              ..._snapshot.metadata,
              'historyCount': _historyByMinute.length.toString(),
            },
          ),
        );
      }
    }
    if (includeRawHistory) {
      await _fetchRawHistoryInternal(
        requestedStartOffset: requestedStartOffset,
      );
    }
    final latest = _historyByMinute.isEmpty
        ? null
        : _historyByMinute[_historyByMinute.keys.reduce(math.max)];
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: latest == null
            ? 'History synced'
            : 'Latest ${latest.valueMgdl.toStringAsFixed(0)} mg/dL',
        latestReading: latest,
        history: _sortedHistory(_historyByMinute),
        historySync: _snapshot.historySync.copyWith(
          inProgress: false,
          storedCount: _historyByMinute.length,
          totalAvailable: plan.totalAvailable,
          latestStoredOffset: _latestStoredOffset(),
          lastSyncAt: _clock(),
        ),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _historyByMinute.length.toString(),
        },
      ),
    );
    _reconcileSessionStartToElapsedClock(source: 'history');
    if (_liveDataIsStale()) {
      await _refreshVendorStartTimeInternal();
    }
    _liveCatchUpQueued = false;
    _scheduleLiveRefresh(Duration.zero);
  }

  Future<AidexVendorResponse> _sendVendorCommandWithRetry(
    AidexVendorOpcode opcode, {
    Uint8List? payload,
    required String context,
    int maxAttempts = _historyCommandMaxAttempts,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _sendVendorCommand(opcode, payload: payload);
      } on TimeoutException catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        final isLastAttempt = attempt >= maxAttempts;
        _emitLog(
          CgmLogLevel.warning,
          '$context timed out on attempt $attempt/$maxAttempts',
        );
        if (isLastAttempt) {
          break;
        }
        await Future<void>.delayed(
          Duration(milliseconds: _historyRetryDelay.inMilliseconds * attempt),
        );
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<List<CgmReading>> _fetchRawHistoryInternal({
    int? requestedStartOffset,
  }) async {
    final rangeResponse = await _sendVendorCommand(
      AidexVendorOpcode.getHistoryRange,
    );
    final range = parseVendorRangePayload(rangeResponse.payload);
    if (range == null || range.status != 0x01) {
      throw StateError('Could not parse Aidex raw history range.');
    }
    final startIndex = math.max(
      requestedStartOffset ?? range.lowIndex,
      range.lowIndex,
    );
    final targetIndex = range.lowIndex + math.max(0, range.count - 1);
    var nextIndex = startIndex;
    while (nextIndex <= targetIndex) {
      final pageResponse = await _sendVendorCommand(
        AidexVendorOpcode.getRawHistories,
        payload: littleEndian16(nextIndex),
      );
      final page = parseVendorHistoryPagePayload(
        pageResponse.payload,
        source: CgmRecordSource.raw,
      );
      if (page == null || page.status != 0x01) {
        throw StateError(
          'Could not parse Aidex raw history page at index $nextIndex.',
        );
      }
      _mergeHistory(_rawHistoryByMinute, page.records);
      nextIndex = _nextHistoryPageIndex(page, fallbackIndex: nextIndex);
    }
    final rawHistory = _sortedHistory(_rawHistoryByMinute);
    _setSnapshot(_snapshot.copyWith(rawHistory: rawHistory));
    return rawHistory;
  }

  Future<List<CgmCalibrationEntry>> _fetchCalibrationsInternal() async {
    final rangeResponse = await _sendVendorCommand(
      AidexVendorOpcode.getCalibrationRange,
    );
    final range = parseVendorRangePayload(rangeResponse.payload);
    if (range == null || range.status != 0x01) {
      return const <CgmCalibrationEntry>[];
    }
    final entries = <CgmCalibrationEntry>[];
    for (var index = range.lowIndex; index <= range.highIndex; index++) {
      final response = await _sendVendorCommand(
        AidexVendorOpcode.getCalibration,
        payload: littleEndian16(index),
      );
      if (response.payload.length < 3) {
        continue;
      }
      entries.add(
        CgmCalibrationEntry(index: index, payloadHex: hexOf(response.payload)),
      );
    }
    _setSnapshot(_snapshot.copyWith(calibrations: entries));
    return entries;
  }

  Future<void> _submitCalibrationInternal({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {
    final effectiveMinute =
        sensorMinute ??
        _sensorMinuteFromRecordedAt(recordedAt) ??
        _snapshot.sessionInfo.elapsedMinutes ??
        0;
    await _sendVendorCommand(
      AidexVendorOpcode.calibration,
      payload: Uint8List.fromList(<int>[
        ...littleEndian16(glucoseMgdl),
        ...littleEndian16(effectiveMinute),
      ]),
    );
    _emitLog(CgmLogLevel.info, 'Submitted calibration to sensor');
  }

  Future<AidexCommunicationIntervalState>
  _getCommunicationIntervalInternal() async {
    final responseFuture = _specificOpsNotifications.stream.first.timeout(
      _timings.vendorCommandTimeout,
    );
    await _write(
      _characteristic(AidexUuids.specificOps),
      buildSpecificOpsRequest(0x02),
    );
    final payload = await responseFuture;
    return AidexCommunicationIntervalState(
      current: parseSpecificOpsCommunicationIntervalGet(payload),
      normalized: parseSpecificOpsCommunicationIntervalGet(payload),
      responseHex: hexOf(payload),
    );
  }

  Future<AidexCommunicationIntervalState> _setCommunicationIntervalInternal(
    int interval,
  ) async {
    final responseFuture = _specificOpsNotifications.stream.first.timeout(
      _timings.vendorCommandTimeout,
    );
    await _write(
      _characteristic(AidexUuids.specificOps),
      buildSpecificOpsRequest(0x01, payload: <int>[interval & 0xFF]),
    );
    final payload = await responseFuture;
    return parseSpecificOpsCommunicationIntervalSet(payload);
  }

  Future<bool?> _getAutoUpdateStatusInternal() async {
    final response = await _sendVendorCommand(
      AidexVendorOpcode.getAutoUpdateStatus,
    );
    if (response.payload.isEmpty) {
      return null;
    }
    if (response.payload.length >= 2) {
      if (response.payload.first != 0x01) {
        return null;
      }
      return response.payload[1] == 0x01;
    }
    return response.payload.first == 0x01;
  }

  Future<void> _setAutoUpdateStatusInternal(bool enabled) async {
    await _sendVendorCommand(
      AidexVendorOpcode.setAutoUpdateStatus,
      payload: Uint8List.fromList(<int>[enabled ? 1 : 0]),
    );
  }

  Future<void> _setDynamicAdvertisementModeInternal(int mode) async {
    await _sendVendorCommand(
      AidexVendorOpcode.setDynamicAdvMode,
      payload: Uint8List.fromList(<int>[mode & 0xFF]),
    );
  }

  Future<List<CgmDiagnosticItem>> _fetchDeviceLogsInternal() async {
    final rangeResponse = await _sendVendorCommand(
      AidexVendorOpcode.getLogRange,
    );
    final range = parseVendorRangePayload(rangeResponse.payload);
    if (range == null || range.status != 0x01) {
      return const <CgmDiagnosticItem>[];
    }
    final items = <CgmDiagnosticItem>[];
    for (var index = range.lowIndex; index <= range.highIndex; index++) {
      final response = await _sendVendorCommand(
        AidexVendorOpcode.getLogs,
        payload: littleEndian16(index),
      );
      items.add(
        CgmDiagnosticItem(
          key: 'log-$index',
          title: 'Diagnostic Log $index',
          rawHex: hexOf(response.payload),
        ),
      );
    }
    return items;
  }

  Future<String> _fetchErrorLogsHexInternal() async {
    final response = await _sendVendorCommand(AidexVendorOpcode.getErrorLogs);
    return hexOf(response.payload);
  }

  Future<List<CgmDiagnosticItem>> _refreshDiagnosticsInternal() async {
    final diagnostics = <CgmDiagnosticItem>[];
    final pairState = await _read(_characteristic(AidexUuids.f005));
    final vendorDeviceInfo = await _sendVendorCommand(
      AidexVendorOpcode.getDeviceInfo,
    );
    final vendorBroadcast = await _sendVendorCommand(
      AidexVendorOpcode.getBroadcastData,
    );
    final vendorStartTime = await _sendVendorCommand(
      AidexVendorOpcode.getStartTime,
    );
    final vendorSensorCheck = await _sendVendorCommand(
      AidexVendorOpcode.getSensorCheck,
      payload: Uint8List.fromList(const <int>[0x00]),
    );
    final vendorAutoUpdate = await _sendVendorCommand(
      AidexVendorOpcode.getAutoUpdateStatus,
    );
    final parsedVendorStartTime = parseVendorStartTimeResponse(
      vendorStartTime.payload,
    );
    final vendorStart = parsedVendorStartTime?.startTime;
    if (vendorStart != null) {
      _adoptSessionStartIfPlausible(vendorStart, source: 'vendor');
    }

    diagnostics.add(
      CgmDiagnosticItem(
        key: 'device-info',
        title: 'Device Information',
        fields: <String, String>{
          'manufacturer': _snapshot.sessionInfo.manufacturer,
          'model': _snapshot.sessionInfo.model,
          'serial': _snapshot.sessionInfo.serial,
          'firmware': _snapshot.sessionInfo.firmware,
        },
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'standard-cgm',
        title: 'Standard CGM Characteristics',
        fields: <String, String>{
          'featureHex': _rawHex[AidexUuids.feature] ?? '',
          'statusHex': _rawHex[AidexUuids.status] ?? '',
          'sessionStartHex': _rawHex[AidexUuids.sessionStart] ?? '',
          'sessionRunTimeHex': _rawHex[AidexUuids.sessionRunTime] ?? '',
        },
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-pair',
        title: 'Vendor Pair State',
        rawHex: hexOf(pairState),
        fields: <String, String>{'f003Hex': _lastF003Hex},
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-device-info',
        title: 'Vendor Device Info',
        rawHex: hexOf(vendorDeviceInfo.payload),
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-broadcast',
        title: 'Vendor Broadcast Data',
        rawHex: hexOf(vendorBroadcast.payload),
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-start-time',
        title: 'Vendor Start Time',
        rawHex: hexOf(vendorStartTime.payload),
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-sensor-check',
        title: 'Vendor Sensor Check',
        rawHex: hexOf(vendorSensorCheck.payload),
      ),
    );
    diagnostics.add(
      CgmDiagnosticItem(
        key: 'vendor-auto-update',
        title: 'Vendor Auto Update',
        rawHex: hexOf(vendorAutoUpdate.payload),
      ),
    );
    _setSnapshot(
      _snapshot.copyWith(
        diagnostics: diagnostics,
        health: _snapshot.health.copyWith(
          sensorCheckHex: hexOf(vendorSensorCheck.payload),
        ),
      ),
    );
    return diagnostics;
  }

  Future<AidexVendorResponse> _sendVendorCommand(
    AidexVendorOpcode opcode, {
    Uint8List? payload,
  }) async {
    final sessionKey = _sessionKey;
    final sessionIv = _sessionIv;
    if (sessionKey == null || sessionIv == null) {
      throw StateError('Aidex vendor session is not ready.');
    }
    final commandPayload = payload ?? Uint8List(0);
    final completer = Completer<AidexVendorResponse>();
    late final StreamSubscription<List<int>> subscription;
    Timer? timeout;
    _emitLog(
      CgmLogLevel.debug,
      'vendor -> F002 ${opcode.title} '
      'op=0x${opcode.code.toRadixString(16).padLeft(2, '0')} '
      'payloadBytes=${commandPayload.length}',
    );
    subscription = _f002Notifications.stream.listen((bytes) {
      final encrypted = Uint8List.fromList(bytes);
      _emitLog(
        CgmLogLevel.debug,
        'F002 encrypted update (${encrypted.length} bytes)',
      );
      final response = decryptVendorResponse(encrypted, sessionKey, sessionIv);
      if (response == null) {
        _emitLog(
          CgmLogLevel.warning,
          'Ignoring undecodable post-pair F002 update '
          '(${encrypted.length} bytes)',
        );
        return;
      }
      final responseOpcode = AidexVendorOpcode.fromCode(response.opcode);
      _emitLog(
        CgmLogLevel.debug,
        'vendor <- F002 ${responseOpcode?.title ?? 'unknown opcode'} '
        'op=0x${response.opcode.toRadixString(16).padLeft(2, '0')} '
        'payloadBytes=${response.payload.length}',
      );
      if (response.opcode != opcode.code) {
        _emitLog(
          CgmLogLevel.warning,
          'Ignoring post-pair F002 update while waiting for ${opcode.title}; '
          'got 0x${response.opcode.toRadixString(16).padLeft(2, '0')}',
        );
        return;
      }
      if (!completer.isCompleted) {
        completer.complete(response);
      }
    });
    timeout = Timer(_timings.vendorCommandTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Timed out waiting for ${opcode.title}.'),
        );
      }
    });
    await _write(
      _characteristic(AidexUuids.f002),
      buildVendorCommand(
        opcode,
        sessionKey,
        sessionIv,
        payload: commandPayload,
      ),
      withoutResponse: true,
    );

    try {
      final response = await completer.future;
      await Future<void>.delayed(_timings.gattGap);
      return response;
    } finally {
      timeout.cancel();
      await subscription.cancel();
    }
  }

  BleConnection get _requireConnection {
    final conn = _connection;
    if (conn == null) {
      throw StateError('BLE connection lost');
    }
    return conn;
  }

  Future<void> _write(
    BleCharacteristicRef ref,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    await _requireConnection.write(
      ref,
      value,
      withoutResponse: withoutResponse,
    );
    await Future<void>.delayed(_timings.gattGap);
  }

  Future<List<int>> _read(BleCharacteristicRef ref) async {
    final value = await _requireConnection.read(ref);
    await Future<void>.delayed(_timings.gattGap);
    return value;
  }

  Future<String> _readUtf8(String uuid) async {
    final bytes = await _read(_characteristic(uuid));
    return String.fromCharCodes(bytes.takeWhile((byte) => byte != 0)).trim();
  }

  BleCharacteristicRef _characteristic(String uuid) {
    final ref = _characteristics[_normalizeUuid(uuid)];
    if (ref == null) {
      throw StateError('Missing Aidex characteristic $uuid.');
    }
    return ref;
  }

  void _mergeHistory(
    Map<int, CgmReading> target,
    Iterable<CgmReading> records,
  ) {
    for (final record in records) {
      final minute = record.sensorMinute;
      if (minute == null) {
        continue;
      }
      target[minute] = _applyAbsoluteRecordedAt(record);
    }
  }

  int? _latestStoredOffset() {
    if (_historyByMinute.isEmpty) {
      return null;
    }
    return _historyByMinute.keys.reduce(math.max);
  }

  DateTime? _latestRecordedAt() {
    return _snapshot.latestReading?.recordedAt;
  }

  Duration? get _warmupRemaining {
    final sessionInfo = _snapshot.sessionInfo;
    if (sessionInfo.sessionStopped || sessionInfo.warmupMinutes <= 0) {
      return null;
    }
    final elapsedMinutes = sessionInfo.elapsedMinutes;
    if (elapsedMinutes != null) {
      if (elapsedMinutes >= sessionInfo.warmupMinutes) {
        return null;
      }
      return Duration(minutes: sessionInfo.warmupMinutes - elapsedMinutes);
    }
    final sessionStart = sessionInfo.sessionStart;
    if (sessionStart != null) {
      final warmupEndsAt = sessionStart.add(
        Duration(minutes: sessionInfo.warmupMinutes),
      );
      final remaining = warmupEndsAt.difference(_clock());
      return remaining > Duration.zero ? remaining : null;
    }
    return null;
  }

  Duration _warmupResumeDelay(Duration remaining) {
    final pollInterval = _timings.warmupResumePollInterval;
    if (pollInterval <= Duration.zero || pollInterval >= remaining) {
      return remaining;
    }
    return pollInterval;
  }

  int? _latestKnownMinute() {
    final candidates = <int>[
      if (_snapshot.latestReading?.sensorMinute != null)
        _snapshot.latestReading!.sensorMinute!,
      if (_snapshot.sessionInfo.elapsedMinutes != null)
        _snapshot.sessionInfo.elapsedMinutes!,
      if (_latestStoredOffset() != null) _latestStoredOffset()!,
    ];
    if (candidates.isEmpty) {
      return null;
    }
    return candidates.reduce(math.max);
  }

  bool _liveDataIsStale([DateTime? reference]) {
    final now = reference ?? _clock();
    final latestReading = _snapshot.latestReading;
    if (latestReading == null) {
      return true;
    }
    final latestRecordedAt = _latestRecordedAt();
    if (latestRecordedAt != null &&
        now.difference(latestRecordedAt) > _liveStaleThreshold) {
      return true;
    }
    final latestMinute = latestReading.sensorMinute;
    final elapsedMinutes = _snapshot.sessionInfo.elapsedMinutes;
    if (latestMinute != null &&
        elapsedMinutes != null &&
        elapsedMinutes - latestMinute > _liveStaleThreshold.inMinutes) {
      return true;
    }
    return latestRecordedAt == null && latestMinute == null;
  }

  void _queueCatchUpSyncIfStale({required String reason}) {
    if (_liveDataIsStale()) {
      _queueCatchUpSync(reason: reason);
    }
  }

  void _queueCatchUpSync({int? requestedStartOffset, required String reason}) {
    if (_disconnecting ||
        _snapshot.historySync.inProgress ||
        _liveCatchUpQueued) {
      return;
    }
    final warmupRemaining = _warmupRemaining;
    if (warmupRemaining != null) {
      _scheduleHistoryResume(
        startOffset: _normalizeResumeOffset(requestedStartOffset),
        reason: reason,
        delay: _warmupResumeDelay(warmupRemaining),
      );
      return;
    }
    final latestStoredOffset = _latestStoredOffset();
    final effectiveStartOffset =
        requestedStartOffset ??
        (latestStoredOffset == null ? null : latestStoredOffset + 1);
    _liveCatchUpQueued = true;
    _emitLog(CgmLogLevel.info, '$reason; queuing catch-up history sync');
    unawaited(
      _runQueued<void>(
        () => _syncHistoryInternal(
          includeRawHistory: false,
          requestedStartOffset: effectiveStartOffset,
        ),
      ).catchError((Object error, StackTrace stackTrace) {
        _handleError(error, stackTrace, context: 'syncing history');
      }),
    );
  }

  void _pauseHistorySync({
    required int totalAvailable,
    required int resumeFromOffset,
  }) {
    final partialHistory = _sortedHistory(_historyByMinute);
    final latest = partialHistory.isEmpty
        ? _snapshot.latestReading
        : partialHistory.last;
    _liveCatchUpQueued = false;
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.ready,
        statusText: 'Connected',
        latestReading: latest,
        history: partialHistory,
        historySync: _snapshot.historySync.copyWith(
          inProgress: false,
          storedCount: _historyByMinute.length,
          totalAvailable: totalAvailable,
          latestStoredOffset: _latestStoredOffset(),
          startIndex: resumeFromOffset,
        ),
        metadata: <String, String>{
          ..._snapshot.metadata,
          'historyCount': _historyByMinute.length.toString(),
        },
      ),
    );
    _scheduleLiveRefresh(Duration.zero);
  }

  void _scheduleHistoryResume({
    required int startOffset,
    required String reason,
    Duration delay = _historyResumeDelay,
  }) {
    if (_disconnecting) {
      return;
    }
    _historyResumeTimer?.cancel();
    _emitLog(CgmLogLevel.info, '$reason; scheduling history sync resume');
    _historyResumeTimer = Timer(delay, () {
      _historyResumeTimer = null;
      if (_disconnecting) {
        return;
      }
      _queueCatchUpSync(
        requestedStartOffset: startOffset,
        reason: 'Resuming Aidex history sync',
      );
    });
  }

  int _normalizeResumeOffset(int? requestedStartOffset) {
    final storedOffset = _latestStoredOffset();
    if (requestedStartOffset != null && requestedStartOffset > 0) {
      return requestedStartOffset;
    }
    if (storedOffset != null) {
      return storedOffset + 1;
    }
    return 1;
  }

  Future<void> _refreshVendorStartTimeInternal() async {
    if (_disconnecting || _sessionKey == null || _sessionIv == null) {
      return;
    }
    final response = await _sendVendorCommand(AidexVendorOpcode.getStartTime);
    final parsed = parseVendorStartTimeResponse(response.payload);
    final startTime = parsed?.startTime;
    if (startTime != null) {
      _adoptSessionStartIfPlausible(startTime, source: 'vendor');
    }
    _reconcileSessionStartToElapsedClock(source: 'vendor');
  }

  DateTime? _sessionStartCandidateLatestDate(DateTime absoluteStart) {
    final latestMinute = _latestKnownMinute();
    if (latestMinute == null) {
      return null;
    }
    return absoluteStart.add(Duration(minutes: latestMinute));
  }

  bool _shouldAcceptSessionStartCandidate(DateTime absoluteStart) {
    final candidateLatest = _sessionStartCandidateLatestDate(absoluteStart);
    if (candidateLatest == null) {
      return true;
    }
    final deltaUs = candidateLatest.difference(_clock()).inMicroseconds.abs();
    return deltaUs <= _sessionStartTolerance.inMicroseconds;
  }

  Duration? _sessionStartCandidateLatestDrift(DateTime absoluteStart) {
    final candidateLatest = _sessionStartCandidateLatestDate(absoluteStart);
    if (candidateLatest == null) {
      return null;
    }
    return candidateLatest.difference(_clock()).abs();
  }

  void _adoptSessionStartIfPlausible(
    DateTime absoluteStart, {
    required String source,
  }) {
    if (!_shouldAcceptSessionStartCandidate(absoluteStart)) {
      _emitLog(
        CgmLogLevel.warning,
        'Rejected implausible $source session start',
      );
      return;
    }
    final existing = _snapshot.sessionInfo.sessionStart;
    if (existing != null && existing.isAtSameMomentAs(absoluteStart)) {
      return;
    }
    final existingDrift = existing == null
        ? null
        : _sessionStartCandidateLatestDrift(existing);
    final candidateDrift = _sessionStartCandidateLatestDrift(absoluteStart);
    if (existingDrift != null &&
        candidateDrift != null &&
        candidateDrift >= existingDrift - const Duration(minutes: 2)) {
      return;
    }
    _applySessionStart(absoluteStart, source: source);
  }

  List<CgmReading> _rebaseHistoryMap(Map<int, CgmReading> target) {
    if (target.isEmpty) {
      return const <CgmReading>[];
    }
    final rebased = <int, CgmReading>{};
    for (final entry in target.entries) {
      rebased[entry.key] = _applyAbsoluteRecordedAt(entry.value);
    }
    target
      ..clear()
      ..addAll(rebased);
    return _sortedHistory(target);
  }

  void _reconcileSessionStartToElapsedClock({required String source}) {
    final latestMinute = _latestKnownMinute();
    if (latestMinute == null) {
      return;
    }
    final inferredStart = _clock().subtract(Duration(minutes: latestMinute));
    final existing = _snapshot.sessionInfo.sessionStart;
    if (existing == null) {
      _applySessionStart(inferredStart, source: '$source-clock');
      return;
    }
    final drift = _sessionStartCandidateLatestDrift(existing);
    if (drift == null ||
        drift < _sessionStartDriftCorrectionThreshold ||
        drift > _sessionStartDriftCorrectionLimit) {
      return;
    }
    _applySessionStart(inferredStart, source: '$source-clock');
  }

  void _applySessionStart(DateTime absoluteStart, {required String source}) {
    final existing = _snapshot.sessionInfo.sessionStart;
    if (existing != null && existing.isAtSameMomentAs(absoluteStart)) {
      return;
    }
    _setSnapshot(
      _snapshot.copyWith(
        sessionInfo: _snapshot.sessionInfo.copyWith(
          sessionStart: absoluteStart,
        ),
      ),
    );
    final rebasedHistory = _rebaseHistoryMap(_historyByMinute);
    final rebasedRawHistory = _rebaseHistoryMap(_rawHistoryByMinute);
    final latestReading = _snapshot.latestReading == null
        ? (rebasedHistory.isEmpty ? null : rebasedHistory.last)
        : _applyAbsoluteRecordedAt(_snapshot.latestReading!);
    _setSnapshot(
      _snapshot.copyWith(
        latestReading: latestReading,
        history: rebasedHistory,
        rawHistory: rebasedRawHistory,
      ),
    );
    _emitLog(CgmLogLevel.info, 'Adopted $source session start');
  }

  void _hydrateRestoredHistory() {
    final restoredHistory = _decodeRestoredHistory(
      sensor.metadata['resumeHistory'],
    );
    if (restoredHistory.isNotEmpty) {
      _mergeHistory(_historyByMinute, restoredHistory);
    }
    final restoredOffset = int.tryParse(sensor.metadata['resumeOffset'] ?? '');
    final restoredCount =
        int.tryParse(sensor.metadata['resumeCount'] ?? '') ??
        _historyByMinute.length;
    final sortedHistory = _sortedHistory(_historyByMinute);
    final latestStoredOffset = restoredOffset ?? _latestStoredOffset();
    if (restoredCount <= 0 && latestStoredOffset == null) {
      return;
    }
    _snapshot = _snapshot.copyWith(
      latestReading: sortedHistory.isEmpty ? null : sortedHistory.last,
      history: sortedHistory,
      historySync: _snapshot.historySync.copyWith(
        storedCount: math.max(restoredCount, _historyByMinute.length),
        latestStoredOffset: latestStoredOffset,
      ),
    );
  }

  List<CgmReading> _decodeRestoredHistory(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return const <CgmReading>[];
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! List<dynamic>) {
      return const <CgmReading>[];
    }
    return decoded
        .whereType<Map<dynamic, dynamic>>()
        .map((value) => CgmReading.fromJson(Map<String, Object?>.from(value)))
        .where((reading) => reading.sensorMinute != null)
        .toList(growable: false);
  }

  CgmReading _applyAbsoluteRecordedAt(CgmReading reading) {
    final sessionStart = _snapshot.sessionInfo.sessionStart;
    final minute = reading.sensorMinute;
    if (sessionStart == null || minute == null) {
      return reading;
    }
    return reading.copyWith(
      recordedAt: sessionStart.add(Duration(minutes: minute)),
    );
  }

  int _nextHistoryPageIndex(
    AidexVendorHistoryPage page, {
    required int fallbackIndex,
  }) {
    final nextIndex =
        page.indexEcho + math.max(1, page.rawPairs.length).toInt();
    if (nextIndex <= fallbackIndex) {
      return fallbackIndex + 1;
    }
    return nextIndex;
  }

  List<CgmReading> _sortedHistory(Map<int, CgmReading> values) {
    final records = values.values.toList(growable: false);
    records.sort((left, right) {
      final leftMinute = left.sensorMinute ?? 0;
      final rightMinute = right.sensorMinute ?? 0;
      return leftMinute.compareTo(rightMinute);
    });
    return records;
  }

  int? _sensorMinuteFromRecordedAt(DateTime? recordedAt) {
    final sessionStart = _snapshot.sessionInfo.sessionStart;
    if (recordedAt == null || sessionStart == null) {
      return null;
    }
    return recordedAt.difference(sessionStart).inMinutes;
  }

  void _emitLog(CgmLogLevel level, String message) {
    // Keep diagnostics local to the app. Process and OS logs can be collected
    // outside OpenGlucose's retention controls.
    if (!_logController.isClosed) {
      _logController.add(
        CgmLogEntry(timestamp: _clock(), level: level, message: message),
      );
    }
  }

  void _setSnapshot(CgmSessionSnapshot snapshot) {
    final isErrorSnapshot = snapshot.stage == CgmSyncStage.error;
    if (isErrorSnapshot) {
      _debugAidexSetupTrace('error-snapshot-set-start');
    }
    final shouldClearError =
        snapshot.lastError != null &&
        snapshot.stage != CgmSyncStage.error &&
        snapshot.stage != CgmSyncStage.disconnected;
    _snapshot = shouldClearError
        ? snapshot.copyWith(clearLastError: true)
        : snapshot;
    if (!_snapshotController.isClosed) {
      if (isErrorSnapshot) {
        _debugAidexSetupTrace('error-snapshot-broadcast-start');
      }
      _snapshotController.add(_snapshot);
      if (isErrorSnapshot) {
        _debugAidexSetupTrace('error-snapshot-broadcast-complete');
      }
    }
    if (isErrorSnapshot) {
      _debugAidexSetupTrace('error-snapshot-set-complete');
    }
  }

  void _setSetupPhase(String phase) {
    assert(AidexSetupPhase.values.contains(phase));
    final metadata = <String, String>{..._snapshot.metadata}
      ..[aidexSetupPhaseMetadataKey] = phase;
    if (phase != AidexSetupPhase.subscribe) {
      metadata
        ..remove(aidexSubscribeStepMetadataKey)
        ..remove(aidexSubscribeAttemptMetadataKey);
    }
    _setSnapshot(_snapshot.copyWith(metadata: metadata));
  }

  void _setSubscriptionProgress({
    required String step,
    required String attempt,
  }) {
    assert(AidexSubscribeStep.values.contains(step));
    assert(AidexSubscribeAttempt.values.contains(attempt));
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.bonding,
        statusText: 'Subscribing to notifications',
        metadata: <String, String>{
          ..._snapshot.metadata,
          aidexSetupPhaseMetadataKey: AidexSetupPhase.subscribe,
          aidexSubscribeStepMetadataKey: step,
          aidexSubscribeAttemptMetadataKey: attempt,
        },
      ),
    );
  }

  Future<T> _runQueued<T>(
    Future<T> Function() action, {
    bool allowWhileDisconnecting = false,
  }) {
    final completer = Completer<T>();
    _operationChain = _operationChain.catchError((Object _) {}).then((_) async {
      try {
        if (_disconnecting && !allowWhileDisconnecting) {
          throw StateError('Session is disconnecting');
        }
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  void _handleError(
    Object error,
    StackTrace stackTrace, {
    required String context,
  }) {
    if (_disconnecting) {
      return;
    }
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    _liveCatchUpQueued = false;
    final hasSpecificSessionFailure =
        _snapshot.stage == CgmSyncStage.error && _snapshot.lastError != null;
    final bleFailure = error is BleFailure
        ? error
        : context == 'initializing session' && !hasSpecificSessionFailure
        ? BleFailure(
            kind: BleFailureKind.unexpected,
            operation: BleOperation.connect,
            diagnosticCode: 'aidex.initialize.unexpected',
          )
        : null;
    final safeError = hasSpecificSessionFailure
        ? _snapshot.lastError!
        : bleFailure == null
        ? '$context failed (${error.runtimeType})'
        : 'Bluetooth setup could not be completed.';
    final diagnosticMessage = hasSpecificSessionFailure
        ? '$context failed (${error.runtimeType})'
        : bleFailure == null
        ? safeError
        : 'BLE ${bleFailure.operation.name} failed '
              '[${bleFailure.diagnosticCode}]';
    _emitLog(CgmLogLevel.error, diagnosticMessage);
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        metadata: <String, String>{
          ..._snapshot.metadata,
          ...?bleFailure?.toMetadata(),
        },
        lastError: safeError,
      ),
    );
  }

  String _normalizeUuid(String uuid) => uuid.toUpperCase();
}

class _SessionSetupCancelled implements Exception {
  const _SessionSetupCancelled();
}

class AidexUnsafeAdmin implements CgmUnsafeAdmin {
  AidexUnsafeAdmin._();

  AidexSession? _session;

  void attach(AidexSession session) {
    _session = session;
  }

  @override
  Set<CgmUnsafeOperation> get supportedOperations => const <CgmUnsafeOperation>{
    CgmUnsafeOperation.reset,
    CgmUnsafeOperation.shelfMode,
    CgmUnsafeOperation.clearStorage,
    CgmUnsafeOperation.factoryBiasTrim,
    CgmUnsafeOperation.factoryCurrentTrim,
  };

  @override
  Future<void> perform(CgmUnsafeOperation operation) async {
    final session = _session;
    if (session == null) {
      throw StateError('Aidex unsafe admin is not attached.');
    }
    await session._runQueued<void>(() async {
      switch (operation) {
        case CgmUnsafeOperation.reset:
          await session._sendVendorCommand(AidexVendorOpcode.reset);
        case CgmUnsafeOperation.shelfMode:
          await session._sendVendorCommand(AidexVendorOpcode.shelfMode);
        case CgmUnsafeOperation.unpair:
          throw UnsupportedError(
            'Use the confirmed sensor transfer flow to move a bond.',
          );
        case CgmUnsafeOperation.clearStorage:
          await session._sendVendorCommand(AidexVendorOpcode.clearStorage);
        case CgmUnsafeOperation.factoryBiasTrim:
        case CgmUnsafeOperation.factoryCurrentTrim:
          throw UnsupportedError('Use trim-specific Aidex unsafe APIs.');
      }
    });
  }

  Future<void> setGcBiasTrimming(int value) async {
    final session = _session;
    if (session == null) {
      throw StateError('Aidex unsafe admin is not attached.');
    }
    await session._runQueued<void>(() {
      return session._sendVendorCommand(
        AidexVendorOpcode.setGcBiasTrimming,
        payload: littleEndian16(value),
      );
    });
  }

  Future<void> setGcImeasTrimming({
    required int value,
    required int temperature,
  }) async {
    final session = _session;
    if (session == null) {
      throw StateError('Aidex unsafe admin is not attached.');
    }
    await session._runQueued<void>(() {
      return session._sendVendorCommand(
        AidexVendorOpcode.setGcImeasTrimming,
        payload: Uint8List.fromList(<int>[
          ...littleEndian16(value),
          ...littleEndian16(temperature),
        ]),
      );
    });
  }
}
