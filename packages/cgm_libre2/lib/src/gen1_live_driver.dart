import 'dart:async';
import 'dart:collection';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'events.dart';
import 'gen1_glucose_decoder.dart';
import 'gen1_lifecycle.dart';
import 'gen1_security.dart';
import 'live_handshake.dart';
import 'model.dart';
import 'topology.dart';
import 'uuid.dart';

/// Restricted bootstrap from the reviewed, journaled NFC streaming executor.
///
/// Constructing this object does not prove sensor compatibility. The provider
/// must supply only the durable result of the authorized streaming operation,
/// with its exact response-derived Android device address and initial patch.
/// A passive NFC read, advertisement, or activation result is insufficient.
final class LibreGen1StreamingBootstrap
    implements LibreStreamingBootstrapContext {
  LibreGen1StreamingBootstrap({
    required this.bootstrapId,
    required String deviceId,
    required this.uid,
    required this.initialPatchInfo,
    required this.streamingBase,
    required this.lifecycle,
  }) : deviceId = _deviceAddress(deviceId) {
    if (bootstrapId.isEmpty ||
        bootstrapId.length > 128 ||
        initialPatchInfo.model != LibreGen1Model.libre2 ||
        streamingBase < 0 ||
        streamingBase >= 0xffffffff ||
        (lifecycle != LibreGen1LifecycleState.warmingUp &&
            lifecycle != LibreGen1LifecycleState.active)) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidBootstrap);
    }
  }

  final String bootstrapId;
  final String deviceId;
  final LibreGen1Uid uid;
  final LibreGen1PatchInfo initialPatchInfo;
  final int streamingBase;
  final LibreGen1LifecycleState lifecycle;

  @override
  LibreSecurityGeneration get generation => LibreSecurityGeneration.gen1;

  @override
  String toString() => 'LibreGen1StreamingBootstrap(data: <redacted>)';
}

abstract interface class LibreGen1StreamingBootstrapProvider {
  Future<LibreGen1StreamingBootstrap?> readBootstrap();
}

enum LibreGen1LoginOutcome { acknowledged, unknown }

/// Durable, atomic reservation; increments must reach protected storage before
/// return. Reject missing/replaced bootstrap IDs and never reuse a count,
/// including after cancellation, process death, or unknown write outcomes.
/// An unknown outcome can advance only on a new explicit user connection.
abstract interface class LibreGen1LoginCounterStore {
  Future<int> reserveNextUnlockCount(String bootstrapId);

  Future<void> markLoginOutcome(
    String bootstrapId,
    int unlockCount,
    LibreGen1LoginOutcome outcome,
  );
}

enum LibreGen1LiveFailure {
  invalidBootstrap,
  bootstrapUnavailable,
  targetMismatch,
  sessionInUse,
  topologyRejected,
  counterUnavailable,
  advertisementUnavailable,
  oneShotUnavailable,
  connectionFailed,
  loginOutcomeUnknown,
  subscriptionFailed,
  invalidPacket,
  disconnected,
  cancelled,
  cleanupUnconfirmed,
}

final class LibreGen1LiveException implements Exception {
  const LibreGen1LiveException(this.kind);
  final LibreGen1LiveFailure kind;
  @override
  String toString() => 'LibreGen1LiveException(${kind.name})';
}

enum LibreGen1LivePhase {
  reconnecting,
  awaitingAdvertisement,
  connecting,
  discovering,
  reservingLogin,
  loggingIn,
  subscribing,
  awaitingPacket,
  validatedPacket,
  disconnected,
  failed,
}

/// Closed transport evidence. No health value, identifier, key, or payload.
final class LibreGen1LiveStatus {
  const LibreGen1LiveStatus({
    required this.phase,
    this.validatedPacketCount = 0,
    this.failure,
  });

  final LibreGen1LivePhase phase;
  final int validatedPacketCount;
  final LibreGen1LiveFailure? failure;

  @override
  String toString() =>
      'LibreGen1LiveStatus(phase: ${phase.name}, '
      'validatedPackets: $validatedPacketCount, failure: ${failure?.name})';
}

/// One explicit session with at most one recovery after a validated stream is
/// physically disconnected. Optional conversion supplies provisional readings;
/// this driver contains no conversion algorithm, bond operation, or NFC write.
final class LibreGen1Driver implements CgmDriver {
  LibreGen1Driver({
    required BleTransport transport,
    required LibreGen1StreamingBootstrapProvider bootstrapProvider,
    required LibreGen1LoginCounterStore counterStore,
    LibreGen1GlucoseDecoderProvider? glucoseDecoderProvider,
    int historyLimit = 0x10000,
    Duration advertisementTimeout = const Duration(seconds: 150),
    DateTime Function()? utcNow,
  }) : _transport = transport,
       _bootstrapProvider = bootstrapProvider,
       _counterStore = counterStore,
       _glucoseDecoderProvider = glucoseDecoderProvider,
       _historyLimit = historyLimit,
       _advertisementTimeout = advertisementTimeout,
       _utcNow = utcNow ?? DateTime.now {
    if (historyLimit < 1 || historyLimit > 0x10000) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
    if (advertisementTimeout <= Duration.zero ||
        advertisementTimeout > const Duration(seconds: 150)) {
      throw ArgumentError.value(advertisementTimeout, 'advertisementTimeout');
    }
  }

  static const driverIdentifier = 'libre2-gen1';
  static const capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsDiagnostics: true,
  );
  static const scanServiceUuids = <String>[LibreUuids.sasService];

  final BleTransport _transport;
  final LibreGen1StreamingBootstrapProvider _bootstrapProvider;
  final LibreGen1LoginCounterStore _counterStore;
  final LibreGen1GlucoseDecoderProvider? _glucoseDecoderProvider;
  final int _historyLimit;
  final Duration _advertisementTimeout;
  final DateTime Function() _utcNow;
  LibreGen1StreamingBootstrap? _bootstrap;
  bool _leased = false;

  @override
  String get driverId => driverIdentifier;

  /// Refresh before a shared registry scan, including after NFC bootstrap.
  Future<bool> reloadBootstrap() async {
    _bootstrap = null;
    try {
      _bootstrap = await _bootstrapProvider.readBootstrap().timeout(
        const Duration(seconds: 15),
      );
      return _bootstrap != null;
    } catch (_) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.bootstrapUnavailable,
      );
    }
  }

  DiscoveredSensor? mapScanResult(BleScanResult result) {
    final bootstrap = _bootstrap;
    if (bootstrap == null ||
        !_sameDevice(result.deviceId, bootstrap.deviceId)) {
      return null;
    }
    return _sensorFor(bootstrap, result.rssi);
  }

  /// The NFC response selects the target. Connection still requires a fresh
  /// advertisement from that exact address before opening the Android link.
  DiscoveredSensor? get bootstrappedSensor =>
      _bootstrap == null ? null : _sensorFor(_bootstrap!, 0);

  DiscoveredSensor _sensorFor(
    LibreGen1StreamingBootstrap bootstrap,
    int rssi,
  ) => DiscoveredSensor(
    driverId: driverIdentifier,
    deviceId: bootstrap.deviceId,
    displayName: 'FreeStyle Libre 2',
    storageKey: '$driverIdentifier:${bootstrap.bootstrapId}',
    rssi: rssi,
    capabilities: capabilities,
  );

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    if (!await reloadBootstrap()) return;
    await for (final result in _transport.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
      withServices: const <String>[],
    )) {
      final sensor = mapScanResult(result);
      if (sensor != null) yield sensor;
    }
  }

  @override
  Future<LibreGen1Session> connect(DiscoveredSensor sensor) async {
    if (_leased) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.sessionInUse);
    }
    _leased = true;
    try {
      if (!await reloadBootstrap()) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.bootstrapUnavailable,
        );
      }
      final bootstrap = _bootstrap!;
      if (sensor.driverId != driverIdentifier ||
          !_sameDevice(sensor.deviceId, bootstrap.deviceId) ||
          sensor.storageKey != _sensorFor(bootstrap, 0).storageKey) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.targetMismatch);
      }
      final session = LibreGen1Session._(
        sensor: _sensorFor(bootstrap, sensor.rssi),
        bootstrap: bootstrap,
        bootstrapProvider: _bootstrapProvider,
        glucoseDecoderProvider: _glucoseDecoderProvider,
        historyLimit: _historyLimit,
        transport: _transport,
        counterStore: _counterStore,
        advertisementTimeout: _advertisementTimeout,
        utcNow: _utcNow,
        releaseLease: () => _leased = false,
      );
      unawaited(session._initialize());
      return session;
    } catch (error) {
      _leased = false;
      if (error is LibreGen1LiveException) rethrow;
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.bootstrapUnavailable,
      );
    }
  }
}

final class LibreGen1Session implements CgmSession {
  LibreGen1Session._({
    required this.sensor,
    required LibreGen1StreamingBootstrap bootstrap,
    required LibreGen1StreamingBootstrapProvider bootstrapProvider,
    required LibreGen1GlucoseDecoderProvider? glucoseDecoderProvider,
    required int historyLimit,
    required BleTransport transport,
    required LibreGen1LoginCounterStore counterStore,
    required Duration advertisementTimeout,
    required DateTime Function() utcNow,
    required void Function() releaseLease,
  }) : _bootstrap = bootstrap,
       _bootstrapProvider = bootstrapProvider,
       _glucoseDecoderProvider = glucoseDecoderProvider,
       _historyLimit = historyLimit,
       _transport = transport,
       _counterStore = counterStore,
       _advertisementTimeout = advertisementTimeout,
       _utcNow = utcNow,
       _releaseLease = releaseLease {
    _installAttempt(bootstrap);
  }

  @override
  final DiscoveredSensor sensor;
  final LibreGen1StreamingBootstrap _bootstrap;
  final LibreGen1StreamingBootstrapProvider _bootstrapProvider;
  final LibreGen1GlucoseDecoderProvider? _glucoseDecoderProvider;
  final int _historyLimit;
  final _history = ListQueue<CgmReading>();
  List<CgmReading> _historySnapshot = const [];
  final BleTransport _transport;
  final LibreGen1LoginCounterStore _counterStore;
  final Duration _advertisementTimeout;
  final DateTime Function() _utcNow;
  final void Function() _releaseLease;
  final _snapshots = StreamController<CgmSessionSnapshot>.broadcast();
  final _statuses = StreamController<LibreGen1LiveStatus>.broadcast();
  late _LibreGen1Attempt _attempt;
  late CgmSessionSnapshot _snapshot;
  late LibreGen1LiveStatus _status;
  StreamSubscription<CgmSessionSnapshot>? _subscription;
  Future<void>? _transition;
  Future<void>? _disconnectFuture;
  _LibreGen1Attempt? _settling;
  bool _recoveryUsed = false;
  bool _cancelled = false;
  bool _released = false;
  int? _acceptedMinute;

  void _installAttempt(LibreGen1StreamingBootstrap bootstrap) {
    final attempt = _LibreGen1Attempt._(
      sensor: sensor,
      bootstrap: bootstrap,
      transport: _transport,
      counterStore: _counterStore,
      advertisementTimeout: _advertisementTimeout,
      utcNow: _utcNow,
      releaseLease: () {},
      acceptMinute: (minute) {
        if (_acceptedMinute != null && minute <= _acceptedMinute!) return false;
        _acceptedMinute = minute;
        return true;
      },
      recordAcceptedReading: _recordAcceptedReading,
      readHistory: () => _historySnapshot,
    );
    _attempt = attempt;
    _forward(attempt.currentSnapshot);
    _subscription = attempt.snapshots.listen((snapshot) {
      if (_cancelled || !identical(_attempt, attempt)) return;
      if (snapshot.stage == CgmSyncStage.error &&
          !identical(_settling, attempt)) {
        _settling = attempt;
        final recover =
            !_recoveryUsed &&
            attempt._unexpectedPhysicalDisconnect &&
            attempt._loginAcknowledged &&
            attempt._subscribed &&
            attempt._validatedPacketCount > 0 &&
            attempt.currentStatus.failure == LibreGen1LiveFailure.disconnected;
        if (recover) {
          // Consume the budget before awaiting cleanup. A later packet never
          // replenishes it, and no failure during replacement can retry again.
          _recoveryUsed = true;
          _publishRecovery();
        } else {
          _forward(snapshot);
        }
        _transition = _settleAttempt(attempt, recover: recover);
      } else if (!identical(_settling, attempt)) {
        _forward(snapshot);
      }
    });
  }

  Future<void> _initialize() => _prepareAndInitialize(_attempt, _bootstrap);

  Future<void> _prepareAndInitialize(
    _LibreGen1Attempt attempt,
    LibreGen1StreamingBootstrap bootstrap,
  ) async {
    try {
      final provider = _glucoseDecoderProvider;
      if (provider != null && !_cancelled) {
        final decoder = await provider
            .prepare(bootstrap)
            .timeout(const Duration(seconds: 15));
        if (!_cancelled && identical(_attempt, attempt)) {
          attempt._decoder = decoder;
        }
      }
    } catch (_) {
      // Conversion is optional. Do not let private decoder errors affect the
      // proven transport path or become user-visible diagnostic text.
    }
    await attempt._initialize();
  }

  Future<void> _settleAttempt(
    _LibreGen1Attempt previous, {
    required bool recover,
  }) async {
    try {
      await previous.disconnect();
    } catch (_) {
      if (!_cancelled) _publishFailure(LibreGen1LiveFailure.cleanupUnconfirmed);
      return;
    }
    if (!previous._cleanupConfirmed) {
      if (!_cancelled) _forward(previous.currentSnapshot);
      return; // Retain the driver lease on any uncertain old cleanup.
    }
    if (_cancelled || !recover) {
      _release();
      return;
    }
    try {
      final bootstrap = await _bootstrapProvider.readBootstrap().timeout(
        const Duration(seconds: 15),
      );
      if (_cancelled) {
        _release();
        return;
      }
      if (bootstrap == null) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.bootstrapUnavailable,
        );
      }
      if (!_sameBootstrap(_bootstrap, bootstrap)) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.targetMismatch);
      }
      await _subscription?.cancel();
      if (_cancelled) {
        _release();
        return;
      }
      _installAttempt(bootstrap);
      // This is a new planner, fresh advertisement window and durable count.
      // The previous login payload is never retained or replayed.
      unawaited(_prepareAndInitialize(_attempt, bootstrap));
    } catch (error) {
      if (!_cancelled) {
        final failure = error is LibreGen1LiveException
            ? error.kind
            : LibreGen1LiveFailure.bootstrapUnavailable;
        _publishFailure(failure);
      }
      _release();
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    _releaseLease();
  }

  void _recordAcceptedReading(CgmReading reading) {
    // Called synchronously only after all current-sample acceptance gates.
    // Store the original immutable reading, not a wall-clock reconstruction.
    // Recording here also survives disconnect before queued snapshot delivery.
    _history.addLast(reading);
    if (_history.length > _historyLimit) _history.removeFirst();
    _historySnapshot = List<CgmReading>.unmodifiable(_history);
  }

  void _forward(CgmSessionSnapshot snapshot) {
    _snapshot = snapshot.copyWith(
      metadata: {
        ...snapshot.metadata,
        'cgm.libre2.recoveryAttempts': _recoveryUsed ? '1' : '0',
      },
    );
    final diagnostic = snapshot.diagnostics.single;
    _status = LibreGen1LiveStatus(
      phase: LibreGen1LivePhase.values.byName(diagnostic.fields['phase']!),
      validatedPacketCount: int.parse(diagnostic.fields['validatedPackets']!),
      failure: diagnostic.fields['failure'] == null
          ? null
          : LibreGen1LiveFailure.values.byName(diagnostic.fields['failure']!),
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
    if (!_statuses.isClosed) _statuses.add(_status);
  }

  void _publishRecovery() => _publishControl(
    LibreGen1LivePhase.reconnecting,
    'Connection lost. Reconnecting once to your sensor.',
  );

  void _publishFailure(LibreGen1LiveFailure failure) => _publishControl(
    LibreGen1LivePhase.failed,
    'Sensor connection failed. Try connecting again.',
    failure: failure,
  );

  void _publishControl(
    LibreGen1LivePhase phase,
    String text, {
    LibreGen1LiveFailure? failure,
  }) {
    _forward(
      CgmSessionSnapshot(
        stage: failure == null ? CgmSyncStage.connecting : CgmSyncStage.error,
        statusText: text,
        sensor: sensor,
        capabilities: LibreGen1Driver.capabilities,
        history: _historySnapshot,
        diagnostics: [
          CgmDiagnosticItem(
            key: 'libre2.gen1.transport',
            title: 'Libre 2 connection',
            summary: text,
            fields: {
              'phase': phase.name,
              'validatedPackets': '${_status.validatedPacketCount}',
              'lifecycleAtNfcBootstrap': _bootstrap.lifecycle.name,
              'glucoseDecoded': 'false',
              if (failure != null) 'failure': failure.name,
            },
          ),
        ],
        metadata: {
          cgmAutomaticReconnectAllowedMetadataKey: 'false',
          'cgm.libre2.phase': phase.name,
        },
        lastError: failure == null ? null : 'libre2.${failure.name}',
      ),
    );
  }

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;
  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;
  LibreGen1LiveStatus get currentStatus => _status;
  Stream<LibreGen1LiveStatus> get statuses => _statuses.stream;
  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  @override
  Future<void> disconnect() => _disconnectFuture ??= () async {
    _cancelled = true;
    await _attempt.disconnect();
    await _transition;
    final cleanupConfirmed = _attempt._cleanupConfirmed;
    if (cleanupConfirmed) _release();
    _forward(_attempt.currentSnapshot);
    await _subscription?.cancel();
    await _snapshots.close();
    await _statuses.close();
    if (!cleanupConfirmed) {
      // Preserve the terminal snapshot and quarantined lease. Closing Dart
      // streams is not proof that the physical connection or scan was closed.
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.cleanupUnconfirmed,
      );
    }
  }();
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      _snapshot.diagnostics;
  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) => _attempt.syncHistory(
    includeRawHistory: includeRawHistory,
    requestedStartOffset: requestedStartOffset,
  );
  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() =>
      _attempt.fetchCalibrations();
  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) => _attempt.submitCalibration(
    glucoseMgdl: glucoseMgdl,
    sensorMinute: sensorMinute,
    recordedAt: recordedAt,
  );
}

bool _sameBootstrap(
  LibreGen1StreamingBootstrap a,
  LibreGen1StreamingBootstrap b,
) {
  bool bytesEqual(List<int> left, List<int> right) =>
      left.length == right.length &&
      Iterable<int>.generate(left.length).every((i) => left[i] == right[i]);
  return a.bootstrapId == b.bootstrapId &&
      a.deviceId == b.deviceId &&
      a.streamingBase == b.streamingBase &&
      a.lifecycle == b.lifecycle &&
      bytesEqual(a.uid.value.bytes, b.uid.value.bytes) &&
      bytesEqual(
        a.initialPatchInfo.value.bytes,
        b.initialPatchInfo.value.bytes,
      );
}

final class _LibreGen1Attempt implements CgmSession {
  _LibreGen1Attempt._({
    required this.sensor,
    required LibreGen1StreamingBootstrap bootstrap,
    required BleTransport transport,
    required LibreGen1LoginCounterStore counterStore,
    required Duration advertisementTimeout,
    required DateTime Function() utcNow,
    required void Function() releaseLease,
    required bool Function(int minute) acceptMinute,
    required void Function(CgmReading reading) recordAcceptedReading,
    required List<CgmReading> Function() readHistory,
  }) : _bootstrap = bootstrap,
       _transport = transport,
       _counterStore = counterStore,
       _advertisementTimeout = advertisementTimeout,
       _utcNow = utcNow,
       _releaseLease = releaseLease,
       _acceptMinute = acceptMinute,
       _recordAcceptedReading = recordAcceptedReading,
       _readHistory = readHistory,
       _planner = LibreLiveHandshakePlanner(bootstrap: bootstrap),
       _core = LibreGen1OfflineCore(
         uid: bootstrap.uid,
         patchInfo: bootstrap.initialPatchInfo,
       ) {
    _publish(LibreGen1LivePhase.awaitingAdvertisement);
  }

  @override
  final DiscoveredSensor sensor;
  final LibreGen1StreamingBootstrap _bootstrap;
  final BleTransport _transport;
  final LibreGen1LoginCounterStore _counterStore;
  final Duration _advertisementTimeout;
  final DateTime Function() _utcNow;
  final void Function() _releaseLease;
  final bool Function(int minute) _acceptMinute;
  final void Function(CgmReading reading) _recordAcceptedReading;
  final List<CgmReading> Function() _readHistory;
  LibreGen1GlucoseDecoder? _decoder;
  CgmReading? _latestReading;
  String _decoderOutcome = 'unavailable';
  final LibreLiveHandshakePlanner _planner;
  final LibreGen1OfflineCore _core;
  final Stopwatch _clock = Stopwatch()..start();
  final _snapshots = StreamController<CgmSessionSnapshot>.broadcast();
  final _statuses = StreamController<LibreGen1LiveStatus>.broadcast();
  final _initializationDone = Completer<void>();
  final List<LibreLiveNotification> _earlyNotifications = [];
  BleConnection? _connection;
  StreamSubscription<BleConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BleScanResult>? _advertisementSubscription;
  Completer<void>? _advertisementWait;
  Future<void>? _scanCancellation;
  bool _scanCleanupConfirmed = true;
  Future<void>? _cleanupFuture;
  bool _stopped = false;
  bool _subscribing = false;
  bool _subscribed = false;
  int _validatedPacketCount = 0;
  int? _reservedCount;
  bool _loginStarted = false;
  bool _loginAcknowledged = false;
  bool _unexpectedPhysicalDisconnect = false;
  bool _cleanupConfirmed = false;
  late CgmSessionSnapshot _snapshot;
  late LibreGen1LiveStatus _status;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;
  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();
  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;
  LibreGen1LiveStatus get currentStatus => _status;
  Stream<LibreGen1LiveStatus> get statuses => _statuses.stream;

  Future<void> _initialize() async {
    try {
      _checkCurrent();
      final oneShot = _transport;
      if (oneShot is! BleSingleAttemptTransport ||
          !oneShot.supportsSingleAttemptConnect) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.oneShotUnavailable,
        );
      }
      await _awaitFreshAdvertisement();
      _checkCurrent();
      _publish(LibreGen1LivePhase.connecting);
      final connect = _next<LibreConnectAction>(_planner.begin());
      _connection = await oneShot.connectOnce(
        _bootstrap.deviceId,
        timeout: const Duration(seconds: 15),
      );
      _checkCurrent();
      if (!_sameDevice(_connection!.deviceId, _bootstrap.deviceId)) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.targetMismatch);
      }
      _connectionSubscription = _connection!.connectionStates.listen(
        (state) {
          if (state == BleConnectionState.disconnected && !_stopped) {
            _unexpectedPhysicalDisconnect = true;
            _fail(LibreGen1LiveFailure.disconnected);
            if (_initializationDone.isCompleted) unawaited(_cleanup());
          }
        },
        onError: (Object _, StackTrace _) {
          _fail(LibreGen1LiveFailure.disconnected);
          if (_initializationDone.isCompleted) unawaited(_cleanup());
        },
      );
      _publish(LibreGen1LivePhase.discovering);
      final discover = _next<LibreDiscoverTopologyAction>(
        _planner.recordConnected(operationId: connect.operationId),
      );
      final services = await _connection!.discoverServices().timeout(
        const Duration(seconds: 15),
      );
      _checkCurrent();
      final authorize = _next<LibreCreateGen1AuthorizationAction>(
        _planner.recordTopology(
          operationId: discover.operationId,
          services: services.map(
            (service) => LibreGattServiceSnapshot(
              uuid: service.uuid,
              characteristicUuids: service.characteristics.map(
                (characteristic) => characteristic.characteristicUuid,
              ),
            ),
          ),
        ),
      );
      final sas = services.singleWhere(
        (service) => normalizeLibreUuid(service.uuid) == LibreUuids.sasService,
      );
      final login = _characteristic(sas, LibreUuids.sasLogin);
      final data = _characteristic(sas, LibreUuids.sasData);
      if (!login.properties.write || !data.properties.notify) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.topologyRejected,
        );
      }
      _publish(LibreGen1LivePhase.reservingLogin);
      _reservedCount = await _counterStore
          .reserveNextUnlockCount(_bootstrap.bootstrapId)
          .timeout(const Duration(seconds: 15));
      _checkCurrent();
      final value = _core.planBleLogin(
        streamingBase: _bootstrap.streamingBase,
        unlockCount: _reservedCount!,
      );
      final write = _next<LibreWriteAction>(
        _planner.provideGen1Authorization(
          operationId: authorize.operationId,
          request: LibreGen1AuthorizationRequest(value.value.bytes),
        ),
      );
      _publish(LibreGen1LivePhase.loggingIn);
      _loginStarted = true;
      await _connection!
          .write(login, write.value.bytes, withoutResponse: false)
          .timeout(const Duration(seconds: 15));
      _checkCurrent();
      await _counterStore
          .markLoginOutcome(
            _bootstrap.bootstrapId,
            _reservedCount!,
            LibreGen1LoginOutcome.acknowledged,
          )
          .timeout(const Duration(seconds: 15));
      _checkCurrent();
      _loginAcknowledged = true;
      final subscribe = _next<LibreSubscribeAction>(
        _planner.recordWriteCompleted(operationId: write.operationId),
      );
      _publish(LibreGen1LivePhase.subscribing);
      _subscribing = true;
      _notificationSubscription = _connection!
          .notifications(data)
          .listen(
            _onNotification,
            onError: (Object _, StackTrace _) {
              _fail(LibreGen1LiveFailure.subscriptionFailed);
              if (_initializationDone.isCompleted) unawaited(_cleanup());
            },
            onDone: () {
              if (!_stopped) {
                _fail(LibreGen1LiveFailure.disconnected);
                if (_initializationDone.isCompleted) unawaited(_cleanup());
              }
            },
          );
      await _connection!
          .setNotify(data, true)
          .timeout(const Duration(seconds: 15));
      _checkCurrent();
      _next<LibreStreamingReadyAction>(
        _planner.recordSubscriptionEnabled(operationId: subscribe.operationId),
      );
      _subscribing = false;
      _subscribed = true;
      _publish(LibreGen1LivePhase.awaitingPacket);
      for (final notification in _earlyNotifications) {
        if (_stopped) break;
        _consumeNotification(notification);
      }
      _earlyNotifications.clear();
    } catch (error) {
      final failure = error is LibreGen1LiveException
          ? error.kind
          : switch (_status.phase) {
              LibreGen1LivePhase.awaitingAdvertisement =>
                LibreGen1LiveFailure.advertisementUnavailable,
              LibreGen1LivePhase.discovering =>
                LibreGen1LiveFailure.topologyRejected,
              LibreGen1LivePhase.reservingLogin =>
                LibreGen1LiveFailure.counterUnavailable,
              LibreGen1LivePhase.loggingIn =>
                LibreGen1LiveFailure.loginOutcomeUnknown,
              LibreGen1LivePhase.subscribing =>
                LibreGen1LiveFailure.subscriptionFailed,
              _ => LibreGen1LiveFailure.connectionFailed,
            };
      if (!_stopped) _fail(failure);
      if (_loginStarted && !_loginAcknowledged && _reservedCount != null) {
        try {
          await _counterStore
              .markLoginOutcome(
                _bootstrap.bootstrapId,
                _reservedCount!,
                LibreGen1LoginOutcome.unknown,
              )
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          // The reservation is durable. Never reuse it if outcome save fails.
        }
      }
    } finally {
      if (_stopped) await _cleanup();
      _initializationDone.complete();
    }
  }

  Future<void> _awaitFreshAdvertisement() async {
    final startedAt = _utcNow().toUtc();
    final completion = Completer<void>();
    _advertisementWait = completion;
    void unavailable() {
      if (!completion.isCompleted) {
        completion.completeError(
          const LibreGen1LiveException(
            LibreGen1LiveFailure.advertisementUnavailable,
          ),
        );
      }
    }

    final timer = Timer(_advertisementTimeout, unavailable);
    try {
      final source = _transport.scan(
        timeout: _advertisementTimeout,
        allowDuplicates: true,
        withServices: LibreGen1Driver.scanServiceUuids,
      );
      _scanCleanupConfirmed = false;
      _advertisementSubscription = source.listen(
        (result) {
          if (_stopped || completion.isCompleted) return;
          final observedAt = result.observedAt?.toUtc();
          // Delivery is not proof of freshness: shared/plugin streams can
          // replay older observations. Missing or future timestamps fail closed.
          if (observedAt == null ||
              observedAt.isBefore(startedAt) ||
              observedAt.isAfter(_utcNow().toUtc()) ||
              !_sameDevice(result.deviceId, _bootstrap.deviceId)) {
            return;
          }
          final services = [...result.serviceUuids, ...result.serviceData.keys];
          final sasAdvertised = services.any((uuid) {
            try {
              return normalizeLibreUuid(uuid) == LibreUuids.sasService;
            } catch (_) {
              return false;
            }
          });
          if (sasAdvertised) completion.complete();
        },
        onError: (Object _, StackTrace _) => unavailable(),
        onDone: unavailable,
      );
      await completion.future;
    } finally {
      timer.cancel();
      _advertisementWait = null;
      await _cancelAdvertisementScan();
    }
  }

  Future<void> _cancelAdvertisementScan() => _scanCancellation ??= () async {
    try {
      final subscription = _advertisementSubscription;
      if (subscription != null) {
        await subscription.cancel().timeout(const Duration(seconds: 5));
        _scanCleanupConfirmed = true;
      }
      if (!_scanCleanupConfirmed) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.cleanupUnconfirmed,
        );
      }
    } catch (_) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.cleanupUnconfirmed,
      );
    }
  }();

  T _next<T extends LibreLiveAction>(LibreLivePlanUpdate update) {
    if (_planner.isFailed ||
        update.actions.length != 1 ||
        update.actions.single is! T) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.topologyRejected);
    }
    return update.actions.single as T;
  }

  BleCharacteristicRef _characteristic(BleService service, String uuid) {
    final result = service.characteristics.singleWhere(
      (entry) => normalizeLibreUuid(entry.characteristicUuid) == uuid,
    );
    if (normalizeLibreUuid(result.serviceUuid) != LibreUuids.sasService) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.topologyRejected);
    }
    return result;
  }

  void _onNotification(List<int> bytes) {
    if (_stopped) return;
    try {
      if (bytes.length > 20) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidPacket);
      }
      final notification = LibreLiveNotification(
        characteristicUuid: LibreUuids.sasData,
        value: bytes,
        observedAt: _clock.elapsed,
      );
      if (_subscribing) {
        // Some adapters deliver during CCCD completion. Bound to one packet;
        // never publish data before the subscription acknowledgement.
        if (_earlyNotifications.length >= 3 ||
            bytes.length != const [20, 18, 8][_earlyNotifications.length]) {
          _fail(LibreGen1LiveFailure.invalidPacket);
          return;
        }
        _earlyNotifications.add(notification);
      } else if (_subscribed) {
        _consumeNotification(notification);
      }
    } catch (_) {
      _fail(LibreGen1LiveFailure.invalidPacket);
    }
    if (_stopped && _initializationDone.isCompleted) unawaited(_cleanup());
  }

  void _consumeNotification(LibreLiveNotification notification) {
    final update = _planner.recordNotification(notification);
    for (final event in update.events) {
      if (event is LibreProtocolFailureEvent) {
        _fail(LibreGen1LiveFailure.invalidPacket);
        return;
      }
      if (event is LibreEncryptedCompositeEvent) {
        // CRC integrity is mandatory before any optional, independently
        // supplied conversion. The transport never treats ADC bytes as mg/dL.
        _core.decryptBle(event.value.bytes);
        _validatedPacketCount += 1;
        _decodeCurrentSample(event.value.bytes);
        _publish(LibreGen1LivePhase.validatedPacket);
      }
    }
  }

  void _decodeCurrentSample(List<int> encryptedPacket) {
    _latestReading = null;
    _decoderOutcome = 'unavailable';
    final decoder = _decoder;
    if (decoder == null) return;
    try {
      final receivedAt = _utcNow().toUtc();
      final result = decoder.decode(
        encryptedPacket: List<int>.unmodifiable(encryptedPacket),
        receivedAt: receivedAt,
      );
      final age = result.sensorAgeMinutes;
      final life = result.expectedLifetimeMinutes;
      final glucose = result.glucoseMgdl;
      if (age < 0 ||
          age > 0xffff ||
          (life != null && (life <= 0 || age >= life))) {
        _decoderOutcome = 'invalidData';
      } else if (age < 60 ||
          result.rejection == LibreGen1GlucoseRejection.warmingUp) {
        _decoderOutcome = 'warmingUp';
      } else if (result.rejection != null ||
          result.sampleAgeMinutes != age ||
          glucose == null ||
          !glucose.isFinite ||
          glucose <= 0 ||
          !_acceptMinute(age)) {
        _decoderOutcome = 'invalidData';
      } else {
        _latestReading = CgmReading(
          valueMgdl: glucose,
          source: CgmRecordSource.vendor,
          sensorMinute: age,
          recordedAt: receivedAt,
          isDisplayProvisional: true,
        );
        _recordAcceptedReading(_latestReading!);
        _decoderOutcome = 'reading';
      }
    } catch (_) {
      _decoderOutcome = 'invalidData';
    }
  }

  void _checkCurrent() {
    if (_stopped) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.cancelled);
    }
  }

  void _fail(LibreGen1LiveFailure failure) {
    if (_stopped) return;
    _stopped = true;
    _planner.recordDisconnected();
    _publish(LibreGen1LivePhase.failed, failure: failure);
  }

  void _publish(LibreGen1LivePhase phase, {LibreGen1LiveFailure? failure}) {
    _status = LibreGen1LiveStatus(
      phase: phase,
      validatedPacketCount: _validatedPacketCount,
      failure: failure,
    );
    final text = switch (phase) {
      LibreGen1LivePhase.reconnecting => 'Reconnecting to your sensor',
      LibreGen1LivePhase.awaitingAdvertisement =>
        'Looking for your FreeStyle Libre 2 sensor',
      LibreGen1LivePhase.connecting => 'Connecting to FreeStyle Libre 2',
      LibreGen1LivePhase.discovering => 'Checking the sensor connection',
      LibreGen1LivePhase.reservingLogin ||
      LibreGen1LivePhase.loggingIn => 'Signing in to the sensor',
      LibreGen1LivePhase.subscribing => 'Starting sensor updates',
      LibreGen1LivePhase.awaitingPacket =>
        'Connected. Waiting for sensor data.',
      LibreGen1LivePhase.validatedPacket =>
        _latestReading == null
            ? 'Receiving sensor data. Glucose decoding is not ready.'
            : 'Receiving provisional sensor readings.',
      LibreGen1LivePhase.disconnected => 'Sensor disconnected',
      LibreGen1LivePhase.failed =>
        'Sensor connection failed. Try connecting again.',
    };
    _snapshot = CgmSessionSnapshot(
      stage: switch (phase) {
        LibreGen1LivePhase.failed => CgmSyncStage.error,
        LibreGen1LivePhase.disconnected => CgmSyncStage.disconnected,
        LibreGen1LivePhase.validatedPacket when _latestReading != null =>
          CgmSyncStage.ready,
        LibreGen1LivePhase.awaitingPacket ||
        LibreGen1LivePhase.validatedPacket => CgmSyncStage.syncing,
        _ => CgmSyncStage.connecting,
      },
      statusText: text,
      sensor: sensor,
      capabilities: LibreGen1Driver.capabilities,
      history: _readHistory(),
      latestReading: phase == LibreGen1LivePhase.validatedPacket
          ? _latestReading
          : null,
      diagnostics: [
        CgmDiagnosticItem(
          key: 'libre2.gen1.transport',
          title: 'Libre 2 connection',
          summary: text,
          fields: {
            'phase': phase.name,
            'validatedPackets': '$_validatedPacketCount',
            'lifecycleAtNfcBootstrap': _bootstrap.lifecycle.name,
            'glucoseDecoded':
                '${phase == LibreGen1LivePhase.validatedPacket && _latestReading != null}',
            'decoderOutcome': _decoderOutcome,
            if (failure != null) 'failure': failure.name,
          },
        ),
      ],
      metadata: {
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
        'cgm.libre2.phase': phase.name,
        'cgm.libre2.decoder': _decoderOutcome,
      },
      lastError: failure == null ? null : 'libre2.${failure.name}',
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
    if (!_statuses.isClosed) _statuses.add(_status);
  }

  Future<void> _cleanup() => _cleanupFuture ??= _closeTransport();

  Future<void> _closeTransport() async {
    bool clean = true;
    try {
      await _cancelAdvertisementScan();
    } catch (_) {
      clean = false;
    }
    try {
      await _notificationSubscription?.cancel().timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {
      clean = false;
    }
    try {
      await _connectionSubscription?.cancel().timeout(
        const Duration(seconds: 5),
      );
    } catch (_) {
      clean = false;
    }
    try {
      await _connection?.disconnect().timeout(const Duration(seconds: 15));
    } catch (_) {
      clean = false;
    }
    _earlyNotifications.clear();
    _clock.stop();
    if (clean) {
      _cleanupConfirmed = true;
      _releaseLease();
    } else {
      _publish(
        LibreGen1LivePhase.failed,
        failure: LibreGen1LiveFailure.cleanupUnconfirmed,
      );
    }
  }

  @override
  Future<void> disconnect() async {
    if (!_stopped) {
      _stopped = true;
      _planner.recordDisconnected();
      _publish(LibreGen1LivePhase.disconnected);
      final waiting = _advertisementWait;
      if (waiting != null && !waiting.isCompleted) {
        waiting.completeError(
          const LibreGen1LiveException(LibreGen1LiveFailure.cancelled),
        );
      }
    }
    await _initializationDone.future;
    await _cleanup();
    await _snapshots.close();
    await _statuses.close();
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshLiveData() async {}
  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      _snapshot.diagnostics;
  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    throw UnsupportedError('Libre history decoding is not available.');
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async => const [];
  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {
    throw UnsupportedError('Libre calibration is not available.');
  }
}

String _deviceAddress(String value) {
  if (!RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(value)) {
    throw const LibreGen1LiveException(LibreGen1LiveFailure.invalidBootstrap);
  }
  return value.toUpperCase();
}

bool _sameDevice(String left, String right) {
  try {
    return _deviceAddress(left) == _deviceAddress(right);
  } catch (_) {
    return false;
  }
}
