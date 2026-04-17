import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'aidex_protocol.dart';

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

class AidexSession implements CgmSession {
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
         metadata: <String, String>{'deviceId': sensor.deviceId},
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
  bool _didRetryInitializationAfterBondReset = false;
  String _lastF003Hex = '';

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  AidexUnsafeAdmin get unsafeAdmin => _unsafeAdmin;

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
      _emitLog(CgmLogLevel.warning, 'BLE disconnect failed: $error');
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
      _emitLog(CgmLogLevel.info, 'Connecting to ${sensor.displayName}');
      _connection = await _transport.connect(sensor.deviceId);
      _connectionState = BleConnectionState.connected;
      _emitLog(CgmLogLevel.debug, 'BLE link connected');
      _monitorConnectionState();
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.bonding,
          statusText: 'Discovering services',
        ),
      );
      _emitLog(CgmLogLevel.debug, 'Discovering services');
      await _discoverServices();
      var conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      final bondStateBeforeSetup = conn.supportsBondLifecycle
          ? await conn.currentBondState()
          : BleBondState.bonded;
      _emitLog(CgmLogLevel.debug, 'Subscribing to notifications');
      await _subscribeToNotifications();
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.bonding,
          statusText: 'Bonding BLE link',
        ),
      );
      conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      _emitLog(CgmLogLevel.debug, 'Ensuring BLE bond');
      await conn.ensureBonded();
      conn = _connection;
      if (conn == null) throw StateError('Disconnected during setup');
      final bondStateAfterSetup = conn.supportsBondLifecycle
          ? await conn.currentBondState()
          : BleBondState.bonded;
      final didEstablishBond =
          conn.supportsBondLifecycle &&
          bondStateBeforeSetup != BleBondState.bonded &&
          bondStateAfterSetup == BleBondState.bonded;
      if (didEstablishBond) {
        await Future<void>.delayed(_timings.gattGap);
        _emitLog(CgmLogLevel.debug, 'Refreshing services after bond');
        await _discoverServices();
      }
      if (_requiresGattIdentityForVendorPair()) {
        _emitLog(CgmLogLevel.debug, 'Prefetching identity for vendor pair');
        await _prefetchIdentity();
      }
      _emitLog(CgmLogLevel.debug, 'Running vendor pair handshake');
      await _pairVendor();
      if (!_requiresGattIdentityForVendorPair()) {
        _emitLog(CgmLogLevel.debug, 'Prefetching identity');
        await _prefetchIdentity();
      }
      _emitLog(CgmLogLevel.debug, 'Refreshing baseline');
      await _refreshBaseline();
      final sessionStart = parseSessionStart(
        bytesFromHex(_rawHex[AidexUuids.sessionStart] ?? ''),
      );
      final status = parseCgmStatus(
        bytesFromHex(_rawHex[AidexUuids.status] ?? ''),
      );
      if (sessionStart == null ||
          sessionStart.isAllZero ||
          status?.sessionStopped == true) {
        _emitLog(CgmLogLevel.debug, 'Starting CGM session');
        await _startSession();
      }
      await _refreshVendorStartTimeInternal();
      await _ensureLiveUpdateConfiguration();
      _setSnapshot(
        _snapshot.copyWith(stage: CgmSyncStage.ready, statusText: 'Connected'),
      );
      _emitLog(CgmLogLevel.info, 'Aidex session connected');
      unawaited(_runInitialBackgroundSync());
      _scheduleLiveRefresh(const Duration(seconds: 1));
    } catch (error, stackTrace) {
      if (await _retryInitializationAfterBondReset(error)) {
        return;
      }
      _handleError(error, stackTrace, context: 'initializing session');
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
            _emitLog(CgmLogLevel.warning, 'Live refresh failed: $error');
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
    _connectionStateSubscription = connection.connectionStates.listen((state) {
      _connectionState = state;
      if (_disconnecting) {
        return;
      }
      if (state == BleConnectionState.disconnected) {
        _handleUnexpectedDisconnect();
      }
    });
  }

  void _handleUnexpectedDisconnect() {
    if (_disconnecting || _snapshot.stage == CgmSyncStage.disconnected) {
      return;
    }
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
        lastError: 'BLE connection lost',
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
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        _characteristics[_normalizeUuid(characteristic.characteristicUuid)] =
            characteristic.copyWith(serviceUuid: _normalizeUuid(service.uuid));
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
      if (!_characteristics.containsKey(uuid)) {
        throw StateError('Missing required Aidex characteristic $uuid.');
      }
    }
  }

  Future<void> _subscribeToNotifications() async {
    await _attachNotification(AidexUuids.f001, _f001Notifications);
    await _attachNotification(AidexUuids.f002, _f002Notifications);
    if (_characteristics.containsKey(AidexUuids.f003)) {
      await _attachNotification(AidexUuids.f003, _f003Notifications);
    }
    await _attachNotification(
      AidexUuids.specificOps,
      _specificOpsNotifications,
    );
    await _attachNotification(AidexUuids.racp, _racpNotifications);
    await _attachNotification(
      AidexUuids.measurement,
      _measurementNotifications,
    );
  }

  Future<void> _attachNotification(
    String uuid,
    StreamController<List<int>> sink,
  ) async {
    final ref = _characteristic(uuid);
    final conn = _requireConnection;
    final stream = conn.notifications(ref);
    _notificationSubscriptions[uuid] = stream.listen((bytes) {
      _rawHex[uuid] = hexOf(bytes);
      if (!sink.isClosed) {
        sink.add(bytes);
      }
      if (uuid == AidexUuids.f003) {
        _lastF003Hex = hexOf(bytes);
      } else if (uuid == AidexUuids.measurement) {
        _handleMeasurementNotification(bytes);
      }
    });
    await conn.setNotify(ref, true);
    await Future<void>.delayed(_timings.gattGap);
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
    final sessionInfo = _snapshot.sessionInfo.copyWith(
      manufacturer: manufacturer,
      model: model,
      serial: serial,
      firmware: firmware,
      sessionStart: _snapshot.sessionInfo.sessionStart,
      sessionStartPayloadHex: hexOf(sessionStartBytes),
      elapsedMinutes: parsedStatus?.timeOffsetMinutes,
      sessionStopped: parsedStatus?.sessionStopped ?? false,
    );
    final health = _snapshot.health.copyWith(
      warningFlagsHex: parsedStatus == null
          ? _snapshot.health.warningFlagsHex
          : '0x${parsedStatus.warningFlags.toRadixString(16).padLeft(2, '0')}',
      statusText: parsedStatus?.sessionStopped == true
          ? 'Session stopped'
          : 'Session active',
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
        'Could not ensure vendor auto-update is enabled: $error',
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

  Future<void> _clearSensorBondState() async {
    if (_connection == null) {
      return;
    }

    if (_sessionKey == null || _sessionIv == null) {
      try {
        await _clearBondViaBms();
      } catch (error) {
        _emitLog(CgmLogLevel.warning, 'BMS bond clear failed: $error');
      }
      return;
    }

    try {
      await _sendVendorCommand(AidexVendorOpcode.unpair);
      _emitLog(CgmLogLevel.info, 'Vendor unpair command sent');
    } catch (error) {
      _emitLog(CgmLogLevel.warning, 'Vendor unpair failed: $error');
    }

    try {
      await _clearBondViaBms();
    } catch (error) {
      _emitLog(CgmLogLevel.warning, 'BMS bond clear failed: $error');
    }
  }

  Future<void> _removeLocalBond() async {
    final connection = _connection;
    if (connection == null || !connection.supportsBondLifecycle) {
      return;
    }
    try {
      await connection.removeBond();
      _emitLog(CgmLogLevel.info, 'Removed local BLE bond');
    } catch (error) {
      _emitLog(CgmLogLevel.warning, 'OS bond removal failed: $error');
    }
  }

  Future<void> _clearBondViaBms() async {
    final controlPoint =
        _characteristics[_normalizeUuid(AidexUuids.bondManagementControlPoint)];
    if (controlPoint == null) {
      return;
    }
    final featureRef =
        _characteristics[_normalizeUuid(AidexUuids.bondManagementFeature)];
    if (featureRef != null) {
      final feature = await _read(featureRef);
      _rawHex[AidexUuids.bondManagementFeature] = hexOf(feature);
    }
    await _write(controlPoint, const <int>[0x06]);
    _emitLog(CgmLogLevel.info, 'Bond Management delete-all opcode sent');
  }

  Future<bool> _retryInitializationAfterBondReset(Object error) async {
    final connection = _connection;
    if (_disconnecting ||
        _didRetryInitializationAfterBondReset ||
        connection == null ||
        !connection.supportsBondLifecycle ||
        _sessionKey != null) {
      return false;
    }

    final bondState = await connection.currentBondState();
    if (bondState != BleBondState.bonded && bondState != BleBondState.bonding) {
      return false;
    }

    _didRetryInitializationAfterBondReset = true;
    _emitLog(
      CgmLogLevel.warning,
      'Initialization failed while a local BLE bond exists; removing the '
      'local bond and retrying once: $error',
    );
    await _resetBleLinkForRetry(removeBond: true);
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.connecting,
        statusText: 'Retrying after bond reset',
        lastError: null,
      ),
    );
    await Future<void>.delayed(_timings.gattGap);
    await _initializeInternal();
    return true;
  }

  Future<void> _resetBleLinkForRetry({required bool removeBond}) async {
    _liveRefreshTimer?.cancel();
    _liveRefreshTimer = null;
    _historyResumeTimer?.cancel();
    _historyResumeTimer = null;
    _liveCatchUpQueued = false;

    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    for (final subscription in _notificationSubscriptions.values) {
      await subscription.cancel();
    }
    _notificationSubscriptions.clear();

    if (removeBond) {
      try {
        await _connection?.removeBond();
        _emitLog(CgmLogLevel.info, 'Removed stale Android bond before retry');
      } catch (bondError) {
        _emitLog(
          CgmLogLevel.warning,
          'Could not remove stale Android bond before retry: $bondError',
        );
      }
    }

    try {
      await _connection?.disconnect();
    } catch (_) {}

    _characteristics.clear();
    _connection = null;
    _connectionState = BleConnectionState.disconnected;
    _sessionKey = null;
    _sessionIv = null;
    _rawVendorSeed = null;
    _lastF003Hex = '';
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
      _emitLog(CgmLogLevel.warning, 'Aidex history range timed out: $error');
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
            context: 'Aidex history page $nextIndex',
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
            'Aidex history page $nextIndex timed out after retries: $error',
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
    _emitLog(
      CgmLogLevel.info,
      'Submitted calibration $glucoseMgdl mg/dL at sensor minute $effectiveMinute',
    );
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
      'vendor -> F002 ${opcode.title} op=0x${opcode.code.toRadixString(16).padLeft(2, '0')} '
      'payload=${hexOf(commandPayload)}',
    );
    subscription = _f002Notifications.stream.listen((bytes) {
      final encrypted = Uint8List.fromList(bytes);
      _emitLog(
        CgmLogLevel.debug,
        'F002 ${encrypted.length}B ${hexOf(encrypted)}',
      );
      final response = decryptVendorResponse(encrypted, sessionKey, sessionIv);
      if (response == null) {
        _emitLog(
          CgmLogLevel.warning,
          'Ignoring undecodable post-pair F002 update ${hexOf(encrypted)}',
        );
        return;
      }
      final responseOpcode = AidexVendorOpcode.fromCode(response.opcode);
      _emitLog(
        CgmLogLevel.debug,
        'vendor <- F002 ${responseOpcode?.title ?? '0x${response.opcode.toRadixString(16).padLeft(2, '0')}'} '
        'op=0x${response.opcode.toRadixString(16).padLeft(2, '0')} '
        'payload=${hexOf(response.payload)} plain=${hexOf(response.plaintext)}',
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
    await _requireConnection.write(ref, value, withoutResponse: withoutResponse);
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
    final latestStoredOffset = _latestStoredOffset();
    final effectiveStartOffset =
        requestedStartOffset ??
        (latestStoredOffset == null ? null : latestStoredOffset + 1);
    _liveCatchUpQueued = true;
    _emitLog(
      CgmLogLevel.info,
      '$reason; queuing catch-up history sync from '
      '${effectiveStartOffset ?? 'start'}',
    );
    unawaited(
      _runQueued<void>(
        () => _syncHistoryInternal(
          includeRawHistory: false,
          requestedStartOffset: effectiveStartOffset,
        ),
      ),
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
  }) {
    if (_disconnecting) {
      return;
    }
    _historyResumeTimer?.cancel();
    _emitLog(
      CgmLogLevel.info,
      '$reason; resuming from index $startOffset in '
      '${_historyResumeDelay.inSeconds}s',
    );
    _historyResumeTimer = Timer(_historyResumeDelay, () {
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
      final candidateLatest = _sessionStartCandidateLatestDate(absoluteStart);
      _emitLog(
        CgmLogLevel.warning,
        'Rejected $source session start ${absoluteStart.toIso8601String()} '
        'because latest reading would land at '
        '${candidateLatest?.toIso8601String() ?? 'unknown'}',
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
    _emitLog(
      CgmLogLevel.info,
      'Adopted $source session start ${absoluteStart.toIso8601String()}',
    );
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
    print('[Aidex][${level.name}] $message');
    if (!_logController.isClosed) {
      _logController.add(
        CgmLogEntry(timestamp: _clock(), level: level, message: message),
      );
    }
  }

  void _setSnapshot(CgmSessionSnapshot snapshot) {
    final shouldClearError =
        snapshot.lastError != null &&
        snapshot.stage != CgmSyncStage.error &&
        snapshot.stage != CgmSyncStage.disconnected;
    _snapshot = shouldClearError
        ? snapshot.copyWith(clearLastError: true)
        : snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
    }
  }

  Future<T> _runQueued<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationChain = _operationChain.catchError((Object _) {}).then((_) async {
      try {
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
    _emitLog(CgmLogLevel.error, '$context failed: $error');
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        lastError: '$context: $error',
      ),
    );
  }

  String _normalizeUuid(String uuid) => uuid.toUpperCase();
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
    CgmUnsafeOperation.unpair,
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
          await session._clearSensorBondState();
          await session._removeLocalBond();
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
