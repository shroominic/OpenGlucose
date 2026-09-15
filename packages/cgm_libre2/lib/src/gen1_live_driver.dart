import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'events.dart';
import 'gen1_glucose_decoder.dart';
import 'gen1_lifecycle.dart';
import 'gen1_observation_store.dart';
import 'gen1_security.dart';
import 'gen1_timing.dart';
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
  bluetoothOff,
  permissionRequired,
  bluetoothUnavailable,
  scanFailed,
  observationStorageUnavailable,
  observationQueueOverflow,
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

/// One bounded recovery after a validated stream physically disconnects.
/// Durable sessions earn another recovery only after stable fresh reception.
/// Optional conversion supplies provisional readings;
/// this driver contains no conversion algorithm, bond operation, or NFC write.
final class LibreGen1Driver implements CgmDriver, CgmSensorDataProfileProvider {
  /// Inject [observationStore] for atomic observation/history retention. Set
  /// [requireDurableObservations] in durable app compositions; no-store callers
  /// retain only the historical private/test in-process behavior. The optional
  /// [observationMonotonicNow] is a deterministic clock seam, not a wall clock.
  LibreGen1Driver({
    required BleTransport transport,
    required LibreGen1StreamingBootstrapProvider bootstrapProvider,
    required LibreGen1LoginCounterStore counterStore,
    LibreGen1GlucoseDecoderProvider? glucoseDecoderProvider,
    LibreGen1ObservationStore? observationStore,
    bool requireDurableObservations = false,
    Duration observationTimeout = const Duration(seconds: 5),
    int observationQueueLimit = 3,
    Duration Function()? observationMonotonicNow,
    int historyLimit = 0x10000,
    Duration advertisementTimeout = const Duration(seconds: 150),
    Duration timingFreshness = const Duration(minutes: 10),
    DateTime Function()? utcNow,
  }) : _transport = transport,
       _bootstrapProvider = bootstrapProvider,
       _counterStore = counterStore,
       _glucoseDecoderProvider = glucoseDecoderProvider,
       _observationStore = observationStore,
       _observationTimeout = observationTimeout,
       _observationQueueLimit = observationQueueLimit,
       _observationMonotonicNow = observationMonotonicNow,
       _historyLimit = historyLimit,
       _advertisementTimeout = advertisementTimeout,
       _timingFreshness = timingFreshness,
       _utcNow = utcNow ?? DateTime.now {
    // The no-store mode preserves the existing explicit private/test caller
    // contract. It is not restart-durable. Production composition must require
    // and inject its real restricted observation store.
    if (requireDurableObservations && observationStore == null) {
      throw ArgumentError('Durable Libre observations require a store.');
    }
    if (observationTimeout <= Duration.zero ||
        observationTimeout > const Duration(seconds: 5)) {
      throw ArgumentError.value(observationTimeout, 'observationTimeout');
    }
    if (observationQueueLimit < 1 || observationQueueLimit > 3) {
      throw ArgumentError.value(observationQueueLimit, 'observationQueueLimit');
    }
    if (historyLimit < 1 || historyLimit > 0x10000) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
    if (advertisementTimeout <= Duration.zero ||
        advertisementTimeout > const Duration(seconds: 150)) {
      throw ArgumentError.value(advertisementTimeout, 'advertisementTimeout');
    }
    if (timingFreshness <= Duration.zero ||
        timingFreshness > const Duration(minutes: 10)) {
      throw ArgumentError.value(timingFreshness, 'timingFreshness');
    }
  }

  static const driverIdentifier = 'libre2-gen1';
  static const dataProfile = CgmSensorDataProfile(
    warmupMinutes: 60,
    expectedLifetimeMinutes: 14 * 24 * 60,
    timestampBasis: CgmReadingTimestampBasis.acquisitionRelative,
    duplicatePolicy: CgmHistoryDuplicatePolicy.keepFirst,
    currentReadingPolicy: CgmCurrentReadingPolicy.liveOnly,
    retainedLifecyclePolicy: CgmRetainedLifecyclePolicy.reportedOnly,
  );

  @override
  CgmSensorDataProfile get sensorDataProfile => dataProfile;

  static const capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsDiagnostics: true,
  );
  static const scanServiceUuids = <String>[LibreUuids.sasService];

  final BleTransport _transport;
  final LibreGen1StreamingBootstrapProvider _bootstrapProvider;
  final LibreGen1LoginCounterStore _counterStore;
  final LibreGen1GlucoseDecoderProvider? _glucoseDecoderProvider;
  final LibreGen1ObservationStore? _observationStore;
  final Duration _observationTimeout;
  final int _observationQueueLimit;
  final Duration Function()? _observationMonotonicNow;
  final int _historyLimit;
  final Duration _advertisementTimeout;
  final Duration _timingFreshness;
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
    var observationLoadUncertain = false;
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
      final binding = LibreGen1ObservationBinding.forSensor(
        bootstrapId: bootstrap.bootstrapId,
        uid: bootstrap.uid,
        initialPatchInfo: bootstrap.initialPatchInfo,
      );
      LibreGen1ObservationState? retained;
      final observationStore = _observationStore;
      if (observationStore != null) {
        try {
          retained = await observationStore
              .load(binding)
              .timeout(_observationTimeout);
        } catch (_) {
          // Loading can migrate the durable envelope. A failed or timed-out
          // reply cannot prove that no write occurred, even if it replies later.
          observationLoadUncertain = true;
          throw const LibreGen1LiveException(
            LibreGen1LiveFailure.observationStorageUnavailable,
          );
        }
      }
      final session = LibreGen1Session._(
        sensor: _sensorFor(bootstrap, sensor.rssi),
        bootstrap: bootstrap,
        bootstrapProvider: _bootstrapProvider,
        glucoseDecoderProvider: _glucoseDecoderProvider,
        observationStore: observationStore,
        observationBinding: binding,
        retainedObservations: retained,
        observationTimeout: _observationTimeout,
        observationQueueLimit: _observationQueueLimit,
        observationMonotonicNow: _observationMonotonicNow,
        timingFreshness: _timingFreshness,
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
      _leased = observationLoadUncertain;
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
    required LibreGen1ObservationStore? observationStore,
    required LibreGen1ObservationBinding observationBinding,
    required LibreGen1ObservationState? retainedObservations,
    required Duration observationTimeout,
    required int observationQueueLimit,
    required Duration Function()? observationMonotonicNow,
    required Duration timingFreshness,
    required int historyLimit,
    required BleTransport transport,
    required LibreGen1LoginCounterStore counterStore,
    required Duration advertisementTimeout,
    required DateTime Function() utcNow,
    required void Function() releaseLease,
  }) : _bootstrap = bootstrap,
       _bootstrapProvider = bootstrapProvider,
       _glucoseDecoderProvider = glucoseDecoderProvider,
       _observationStore = observationStore,
       _observationBinding = observationBinding,
       _observationTimeout = observationTimeout,
       _observationQueueLimit = observationQueueLimit,
       _observationMonotonicNow = observationMonotonicNow,
       _timingFreshness = timingFreshness,
       _historyLimit = historyLimit,
       _transport = transport,
       _counterStore = counterStore,
       _advertisementTimeout = advertisementTimeout,
       _utcNow = utcNow,
       _releaseLease = releaseLease {
    if (retainedObservations != null) {
      _restoreObservations(retainedObservations);
    }
    _installAttempt(bootstrap);
  }

  @override
  final DiscoveredSensor sensor;
  final LibreGen1StreamingBootstrap _bootstrap;
  final LibreGen1StreamingBootstrapProvider _bootstrapProvider;
  final LibreGen1GlucoseDecoderProvider? _glucoseDecoderProvider;
  final LibreGen1ObservationStore? _observationStore;
  final LibreGen1ObservationBinding _observationBinding;
  final Duration _observationTimeout;
  final int _observationQueueLimit;
  final Duration Function()? _observationMonotonicNow;
  final int _historyLimit;
  final _history = ListQueue<CgmReading>();
  final Duration _timingFreshness;
  List<CgmReading> _historySnapshot = const [];
  // Keep the store's complete first-acquisition evidence for acknowledgements,
  // even when the caller configures a smaller presentation history limit.
  List<CgmReading> _acknowledgedHistory = const [];
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
  int _recoveryAttempts = 0;
  bool _cancelled = false;
  bool _released = false;
  bool _observationStorageUncertain = false;
  // Independent of decoder success: rejected/warmup packets still consume their
  // observed minute. Preserve this frontier across the bounded link recovery.
  int? _observedMinute;
  // Imported historical age is only a replay fence, never live timing proof.
  int? _replayBarrierMinute;

  void _installAttempt(
    LibreGen1StreamingBootstrap bootstrap, {
    bool recovering = false,
  }) {
    final attempt = _LibreGen1Attempt._(
      sensor: sensor,
      bootstrap: bootstrap,
      transport: _transport,
      counterStore: _counterStore,
      advertisementTimeout: _advertisementTimeout,
      timingFreshness: _timingFreshness,
      utcNow: _utcNow,
      releaseLease: () {},
      observeMinute: (minute) {
        if (_replayBarrierMinute != null && minute <= _replayBarrierMinute!) {
          return false;
        }
        _observedMinute = minute;
        _replayBarrierMinute = minute;
        return true;
      },
      recordAcceptedReadings: _recordAcceptedReadings,
      readObservedMinute: () => _replayBarrierMinute,
      commitObservation: _observationStore == null ? null : _commitObservation,
      observationTimeout: _observationTimeout,
      observationQueueLimit: _observationQueueLimit,
      observationMonotonicNow: _observationMonotonicNow,
      readHistory: () => _historySnapshot,
      confirmReceiverAfterAdvertisement: recovering && _observationStore != null
          ? _revalidateRecoveryBootstrap
          : null,
    );
    _attempt = attempt;
    _forward(attempt.currentSnapshot);
    _subscription = attempt.snapshots.listen((snapshot) {
      if (_cancelled || !identical(_attempt, attempt)) return;
      if (snapshot.stage == CgmSyncStage.error &&
          !identical(_settling, attempt)) {
        _settling = attempt;
        final recover =
            (_recoveryAttempts == 0 || attempt._hasStableReception) &&
            attempt._unexpectedPhysicalDisconnect &&
            attempt._loginAcknowledged &&
            attempt._subscribed &&
            attempt._validatedPacketCount > 0 &&
            attempt.currentStatus.failure == LibreGen1LiveFailure.disconnected;
        if (recover) {
          // Consume before cleanup. A replacement must establish its own
          // stable committed stream; setup success or replay cannot rearm it.
          _recoveryAttempts += 1;
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
    } catch (error) {
      final failure = error is LibreGen1LiveException
          ? error.kind
          : LibreGen1LiveFailure.cleanupUnconfirmed;
      if (!_cancelled) _publishFailure(failure);
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
      _installAttempt(bootstrap, recovering: true);
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

  Future<void> _revalidateRecoveryBootstrap() async {
    try {
      final current = await _bootstrapProvider.readBootstrap().timeout(
        const Duration(seconds: 15),
      );
      if (_cancelled) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.cancelled);
      }
      if (current == null) {
        throw const LibreGen1LiveException(
          LibreGen1LiveFailure.bootstrapUnavailable,
        );
      }
      if (!_sameBootstrap(_bootstrap, current)) {
        throw const LibreGen1LiveException(LibreGen1LiveFailure.targetMismatch);
      }
    } on LibreGen1LiveException {
      rethrow;
    } catch (_) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.bootstrapUnavailable,
      );
    }
  }

  void _release() {
    if (_released || _observationStorageUncertain) return;
    _released = true;
    _releaseLease();
  }

  void _recordAcceptedReadings(List<CgmReading> readings) {
    // Non-durable private/test mode still preserves first acquisition and
    // sensor-minute ordering. Older packet slots never replace live readings.
    final retained = <(CgmRecordSource, int?), CgmReading>{
      for (final reading in _history)
        (reading.source, reading.sensorMinute): reading,
    };
    for (final reading in readings) {
      retained.putIfAbsent((
        reading.source,
        reading.sensorMinute,
      ), () => reading);
    }
    final ordered = retained.values.toList()
      ..sort(
        (left, right) => left.sensorMinute!.compareTo(right.sensorMinute!),
      );
    _history.clear();
    _history.addAll(
      ordered.skip(
        ordered.length > _historyLimit ? ordered.length - _historyLimit : 0,
      ),
    );
    _historySnapshot = List<CgmReading>.unmodifiable(_history);
  }

  void _restoreObservations(LibreGen1ObservationState state) {
    final prior = _observedMinute;
    final priorBarrier = _replayBarrierMinute;
    final barrier = state.effectiveReplayBarrierMinute;
    if (prior != null &&
            (state.observedMinute == null || state.observedMinute! < prior) ||
        priorBarrier != null && (barrier == null || barrier < priorBarrier)) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
    }
    _observedMinute = state.observedMinute;
    _replayBarrierMinute = barrier;
    _acknowledgedHistory = state.history;
    _history.clear();
    _history.addAll(
      state.history.skip(
        state.history.length > _historyLimit
            ? state.history.length - _historyLimit
            : 0,
      ),
    );
    _historySnapshot = List<CgmReading>.unmodifiable(_history);
  }

  Future<LibreGen1ObservationCommit> _commitObservation({
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings = const [],
  }) async {
    final priorMinute = _replayBarrierMinute;
    final priorHistory = _acknowledgedHistory;
    // Preserve the original transaction after timeout. Its completion can
    // retain history, but cannot clear uncertainty or publish to a closed owner.
    final operation =
        Future<LibreGen1ObservationCommit>.sync(
          () => _observationStore!.commit(
            _observationBinding,
            sensorMinute: sensorMinute,
            receivedAt: receivedAt,
            reading: reading,
            historicalReadings: historicalReadings,
          ),
        ).then((result) {
          final minute = result.state.observedMinute;
          final barrier = result.state.effectiveReplayBarrierMinute;
          if (barrier == null ||
              barrier < sensorMinute ||
              (result.advanced &&
                  (minute != sensorMinute ||
                      barrier != sensorMinute ||
                      (priorMinute != null && sensorMinute <= priorMinute)))) {
            throw const LibreGen1LiveException(
              LibreGen1LiveFailure.observationStorageUnavailable,
            );
          }
          if (result.advanced &&
              reading != null &&
              !result.state.history.any(
                (retained) =>
                    jsonEncode(retained.toJson()) ==
                    jsonEncode(reading.toJson()),
              )) {
            throw const LibreGen1LiveException(
              LibreGen1LiveFailure.observationStorageUnavailable,
            );
          }
          if (result.advanced) {
            for (final candidate in historicalReadings) {
              final before = priorHistory
                  .where(
                    (retained) =>
                        retained.sensorMinute ==
                            candidate.reading.sensorMinute &&
                        retained.source == candidate.reading.source,
                  )
                  .firstOrNull;
              final after = result.state.history
                  .where(
                    (retained) =>
                        retained.sensorMinute ==
                            candidate.reading.sensorMinute &&
                        retained.source == candidate.reading.source,
                  )
                  .firstOrNull;
              // A clear can omit an old slot. Without a clear cutoff in this
              // contract, only slots above the prior barrier must be present.
              // Every retained slot must keep its first value and receipt.
              if ((after == null &&
                      (priorMinute == null ||
                          candidate.reading.sensorMinute! > priorMinute)) ||
                  (after != null &&
                      jsonEncode(after.toJson()) !=
                          jsonEncode((before ?? candidate.reading).toJson()))) {
                throw const LibreGen1LiveException(
                  LibreGen1LiveFailure.observationStorageUnavailable,
                );
              }
            }
          }
          _restoreObservations(result.state);
          return result;
        });
    try {
      return await operation.timeout(_observationTimeout);
    } catch (_) {
      // The store has no definite-not-committed error type. Any dispatched
      // failure can have crossed its atomic commit point before losing a reply.
      _observationStorageUncertain = true;
      rethrow;
    }
  }

  void _forward(CgmSessionSnapshot snapshot) {
    _snapshot = snapshot.copyWith(
      metadata: {
        ...snapshot.metadata,
        'cgm.libre2.recoveryAttempts': '$_recoveryAttempts',
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
        sessionInfo: _sessionInfoForBootstrap(_bootstrap),
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
    Object? attemptError;
    try {
      await _attempt.disconnect();
    } catch (error) {
      attemptError = error;
    }
    await _transition;
    final cleanupConfirmed = _attempt._cleanupConfirmed;
    if (cleanupConfirmed) _release();
    _forward(_attempt.currentSnapshot.copyWith(history: _historySnapshot));
    await _subscription?.cancel();
    await _snapshots.close();
    await _statuses.close();
    if (_observationStorageUncertain ||
        attemptError is LibreGen1LiveException &&
            attemptError.kind ==
                LibreGen1LiveFailure.observationStorageUnavailable) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
    }
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

CgmSessionInfo _sessionInfoForBootstrap(
  LibreGen1StreamingBootstrap bootstrap, {
  int? elapsedMinutes,
}) => CgmSessionInfo(
  elapsedMinutes: elapsedMinutes,
  warmupMinutes: LibreGen1Driver.dataProfile.warmupMinutes,
  expectedLifetimeMinutes: LibreGen1Driver.dataProfile.expectedLifetimeMinutes,
  sensorVariant: bootstrap.initialPatchInfo.sensorVariant,
);

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
    required Duration timingFreshness,
    required DateTime Function() utcNow,
    required void Function() releaseLease,
    required bool Function(int minute) observeMinute,
    required void Function(List<CgmReading> readings) recordAcceptedReadings,
    required int? Function() readObservedMinute,
    required Future<LibreGen1ObservationCommit> Function({
      required int sensorMinute,
      required DateTime receivedAt,
      CgmReading? reading,
      List<LibreGen1HistoricalReading> historicalReadings,
    })?
    commitObservation,
    required Duration observationTimeout,
    required int observationQueueLimit,
    required Duration Function()? observationMonotonicNow,
    required List<CgmReading> Function() readHistory,
    required Future<void> Function()? confirmReceiverAfterAdvertisement,
  }) : _bootstrap = bootstrap,
       _transport = transport,
       _counterStore = counterStore,
       _advertisementTimeout = advertisementTimeout,
       _timingFreshness = timingFreshness,
       _utcNow = utcNow,
       _releaseLease = releaseLease,
       _observeMinute = observeMinute,
       _recordAcceptedReadings = recordAcceptedReadings,
       _readObservedMinute = readObservedMinute,
       _commitObservation = commitObservation,
       _observationTimeout = observationTimeout,
       _observationQueueLimit = observationQueueLimit,
       _observationMonotonicNow = observationMonotonicNow,
       _readHistory = readHistory,
       _confirmReceiverAfterAdvertisement = confirmReceiverAfterAdvertisement,
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
  final Future<void> Function()? _confirmReceiverAfterAdvertisement;
  final DateTime Function() _utcNow;
  final void Function() _releaseLease;
  final Duration _timingFreshness;
  final bool Function(int minute) _observeMinute;
  LibreGen1BleTiming? _latestTiming;
  Timer? _timingExpiry;
  String _timingOutcome = 'unavailable';
  final void Function(List<CgmReading> readings) _recordAcceptedReadings;
  final int? Function() _readObservedMinute;
  final Future<LibreGen1ObservationCommit> Function({
    required int sensorMinute,
    required DateTime receivedAt,
    CgmReading? reading,
    List<LibreGen1HistoricalReading> historicalReadings,
  })?
  _commitObservation;
  final Duration _observationTimeout;
  final int _observationQueueLimit;
  final Duration Function()? _observationMonotonicNow;
  final _observations = ListQueue<_PendingLibreObservation>();
  Future<void>? _observationDrain;
  bool _observationInFlight = false;
  bool _observationStorageUncertain = false;
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
  final List<
    ({
      LibreLiveNotification notification,
      DateTime receivedAt,
      Duration observedAt,
    })
  >
  _earlyNotifications = [];
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
  int _stableObservationCount = 0;
  int? _stableLastMinute;
  Duration? _stableFirstReceipt;
  Duration? _stableLastReceipt;
  int? _reservedCount;
  bool _loginStarted = false;
  bool _loginAcknowledged = false;
  bool _unexpectedPhysicalDisconnect = false;
  bool _cleanupConfirmed = false;
  Map<String, String> _preLoginFailureDiagnostics = const {};
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

  // Link recovery policy, not a sensor cadence claim. Require three advancing,
  // committed observations over at least two monotonic minutes. A gap over
  // two minutes, a regressed clock, or a minute jump starts a new window.
  void _recordStableReception(int minute, Duration observedAt) {
    if (_commitObservation == null || observedAt < Duration.zero) return;
    final lastReceipt = _stableLastReceipt;
    final lastMinute = _stableLastMinute;
    final continues =
        lastReceipt != null &&
        lastMinute != null &&
        minute > lastMinute &&
        minute - lastMinute <= 2 &&
        observedAt > lastReceipt &&
        observedAt - lastReceipt <= const Duration(minutes: 2);
    if (!continues) {
      _stableFirstReceipt = observedAt;
      _stableObservationCount = 1;
    } else if (_stableObservationCount < 3) {
      _stableObservationCount += 1;
    }
    _stableLastMinute = minute;
    _stableLastReceipt = observedAt;
  }

  bool get _hasStableReception {
    final first = _stableFirstReceipt;
    final last = _stableLastReceipt;
    if (_commitObservation == null ||
        _stableObservationCount < 3 ||
        first == null ||
        last == null ||
        last - first < const Duration(minutes: 2)) {
      return false;
    }
    final now = _observationMonotonicNow?.call() ?? _clock.elapsed;
    return now >= last && now - last <= const Duration(minutes: 2);
  }

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
      // A saved receiver may have changed while its sensor was absent. A
      // matching advertisement alone cannot authorize a late connection.
      final confirmReceiver = _confirmReceiverAfterAdvertisement;
      if (confirmReceiver != null) {
        await confirmReceiver();
        _checkCurrent();
      }
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
      for (final received in _earlyNotifications) {
        if (_stopped) break;
        _consumeNotification(
          received.notification,
          received.receivedAt,
          received.observedAt,
        );
      }
      _earlyNotifications.clear();
    } catch (error) {
      if (!_stopped &&
          _status.phase == LibreGen1LivePhase.connecting &&
          _connection == null &&
          error is BleFailure) {
        // Keep only closed pre-login evidence, never native descriptions or
        // arbitrary diagnostic codes. GATT 133 does not prove a bond problem.
        // These fields do not select recovery or change connection authority.
        _preLoginFailureDiagnostics = {
          'transportFailurePhase': LibreGen1LivePhase.connecting.name,
          'transportFailureKind': error.kind.name,
          'transportOperation': error.operation.name,
          'transportCode':
              error.operation == BleOperation.connect &&
                  error.kind == BleFailureKind.sensorPossiblyInUse &&
                  error.diagnosticCode ==
                      'fbp.android.connect.133.sensorpossiblyinuse'
              ? 'androidGatt133'
              : 'connectionFailed',
        };
      }
      final failure = error is LibreGen1LiveException
          ? error.kind
          : switch (_status.phase) {
              LibreGen1LivePhase.awaitingAdvertisement => _scanFailure(error),
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
    final scanClock = Stopwatch()..start();
    final completion = Completer<void>();
    _advertisementWait = completion;
    void failScan(LibreGen1LiveFailure failure) {
      if (!completion.isCompleted) {
        completion.completeError(LibreGen1LiveException(failure));
      }
    }

    // Only an earned durable recovery can keep a single cancellable, filtered scan
    // open for a returning sensor. Absence never consumes a login counter or
    // starts a polling/reconnect loop. Initial setup and no-store callers keep
    // their bounded window; native scan failure still terminates the attempt.
    final timeout = _confirmReceiverAfterAdvertisement == null
        ? _advertisementTimeout
        : null;
    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            failScan(LibreGen1LiveFailure.advertisementUnavailable);
          });
    try {
      final source = _transport.scan(
        timeout: timeout,
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
        onError: (Object error, StackTrace _) => failScan(_scanFailure(error)),
        // A scanner that stops early did not complete the discovery window.
        // Do not tell the user that their sensor is absent when scanning failed.
        onDone: () => failScan(
          timeout != null && scanClock.elapsed >= timeout
              ? LibreGen1LiveFailure.advertisementUnavailable
              : LibreGen1LiveFailure.scanFailed,
        ),
      );
      await completion.future;
    } finally {
      timer?.cancel();
      scanClock.stop();
      _advertisementWait = null;
      await _cancelAdvertisementScan();
    }
  }

  static LibreGen1LiveFailure _scanFailure(Object error) {
    // Native descriptions and diagnostic codes can contain identifiers. Use
    // only closed adapter/scan enums supplied by the transport, never text.
    if (error is BleFailure &&
        (error.operation == BleOperation.adapter ||
            error.operation == BleOperation.scan)) {
      return switch (error.kind) {
        BleFailureKind.bluetoothOff => LibreGen1LiveFailure.bluetoothOff,
        BleFailureKind.permissionRequired =>
          LibreGen1LiveFailure.permissionRequired,
        BleFailureKind.bluetoothUnavailable =>
          LibreGen1LiveFailure.bluetoothUnavailable,
        _ => LibreGen1LiveFailure.scanFailed,
      };
    }
    return LibreGen1LiveFailure.scanFailed;
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
      final receivedAt = _utcNow().toUtc();
      final observedAt =
          _observationMonotonicNow?.call() ?? notification.observedAt;
      if (_subscribing) {
        // Some adapters deliver during CCCD completion. Bound to one packet;
        // never publish data before the subscription acknowledgement.
        if (_earlyNotifications.length >= 3 ||
            bytes.length != const [20, 18, 8][_earlyNotifications.length]) {
          _fail(LibreGen1LiveFailure.invalidPacket);
          return;
        }
        _earlyNotifications.add((
          notification: notification,
          receivedAt: receivedAt,
          observedAt: observedAt,
        ));
      } else if (_subscribed) {
        _consumeNotification(notification, receivedAt, observedAt);
      }
    } catch (_) {
      _fail(LibreGen1LiveFailure.invalidPacket);
    }
    if (_stopped && _initializationDone.isCompleted) unawaited(_cleanup());
  }

  void _consumeNotification(
    LibreLiveNotification notification,
    DateTime receivedAt,
    Duration observedAt,
  ) {
    final update = _planner.recordNotification(notification);
    for (final event in update.events) {
      if (event is LibreProtocolFailureEvent) {
        _fail(LibreGen1LiveFailure.invalidPacket);
        return;
      }
      if (event is LibreEncryptedCompositeEvent) {
        // CRC integrity is mandatory before any optional, independently
        // supplied conversion. The transport never treats ADC bytes as mg/dL.
        final payload = _core.decryptBle(event.value.bytes);
        final timing = parseLibreGen1BleTiming(payload);
        _validatedPacketCount += 1;
        if (_commitObservation != null) {
          if (_observations.length + (_observationInFlight ? 1 : 0) >=
              _observationQueueLimit) {
            _fail(LibreGen1LiveFailure.observationQueueOverflow);
            return;
          }
          _observations.add(
            _PendingLibreObservation(
              encryptedPacket: event.value.bytes,
              timing: timing,
              receivedAt: receivedAt,
              observedAt: observedAt,
            ),
          );
          _observationDrain ??= _drainObservations();
          continue;
        }
        if (_observeMinute(timing.elapsedMinutes)) {
          final decoded = _decodePacketSamples(
            event.value.bytes,
            timing.elapsedMinutes,
            receivedAt,
          );
          if (_stopped) return;
          _recordAcceptedReadings([
            for (final historical in decoded.history) historical.reading,
            if (decoded.reading != null) decoded.reading!,
          ]);
          _applyLiveObservation(timing, decoded, _timingFreshness, observedAt);
        } else {
          _latestReading = null;
          _timingOutcome = 'repeatedOrRegressed';
          _decoderOutcome = 'invalidData';
        }
        _publish(LibreGen1LivePhase.validatedPacket);
      }
    }
  }

  Future<void> _drainObservations() async {
    try {
      while (_observations.isNotEmpty && !_stopped) {
        final observation = _observations.removeFirst();
        _observationInFlight = true;
        final frontier = _readObservedMinute();
        final decoded =
            frontier != null && observation.timing.elapsedMinutes <= frontier
            ? const _DecodedLibreSample(null, 'invalidData')
            : _decodePacketSamples(
                observation.encryptedPacket,
                observation.timing.elapsedMinutes,
                observation.receivedAt,
              );
        if (_stopped) break;
        final result = await _commitObservation!(
          sensorMinute: observation.timing.elapsedMinutes,
          receivedAt: observation.receivedAt,
          reading: decoded.reading,
          historicalReadings: decoded.history,
        );
        // The store/session keeps committed history even if cancellation wins.
        // That is not permission to republish current data or reopen transport.
        if (_stopped) break;
        if (result.advanced) {
          final elapsed =
              (_observationMonotonicNow?.call() ?? _clock.elapsed) -
              observation.observedAt;
          final remaining = elapsed < Duration.zero
              ? Duration.zero
              : _timingFreshness - elapsed;
          _applyLiveObservation(
            observation.timing,
            decoded,
            remaining,
            observation.observedAt,
          );
        } else {
          _latestReading = null;
          _timingOutcome = 'repeatedOrRegressed';
          _decoderOutcome = 'invalidData';
        }
        _publish(LibreGen1LivePhase.validatedPacket);
        _observationInFlight = false;
      }
    } catch (_) {
      _observationStorageUncertain = true;
      if (!_stopped) _fail(LibreGen1LiveFailure.observationStorageUnavailable);
    } finally {
      _observationInFlight = false;
      _observations.clear();
      _observationDrain = null;
      if (_stopped && _initializationDone.isCompleted) unawaited(_cleanup());
    }
  }

  void _applyLiveObservation(
    LibreGen1BleTiming timing,
    _DecodedLibreSample decoded,
    Duration remaining,
    Duration observedAt,
  ) {
    _timingExpiry?.cancel();
    if (remaining <= Duration.zero) {
      _latestTiming = null;
      _latestReading = null;
      _timingOutcome = 'stale';
      _decoderOutcome = 'stale';
      return;
    }
    _latestTiming = timing;
    _recordStableReception(timing.elapsedMinutes, observedAt);
    _latestReading = decoded.reading;
    _timingOutcome = 'observed';
    _decoderOutcome = decoded.outcome;
    // Storage time consumes, rather than extends, the receipt-based deadline.
    _timingExpiry = Timer(remaining, () {
      if (_stopped) return;
      _latestTiming = null;
      _latestReading = null;
      _timingOutcome = 'stale';
      _decoderOutcome = 'stale';
      _publish(LibreGen1LivePhase.validatedPacket);
    });
  }

  _DecodedLibreSample _decodePacketSamples(
    List<int> encryptedPacket,
    int observedMinute,
    DateTime receivedAt,
  ) {
    final decoder = _decoder;
    if (decoder == null) return const _DecodedLibreSample(null, 'unavailable');
    try {
      final result = decoder.decode(
        encryptedPacket: List<int>.unmodifiable(encryptedPacket),
        receivedAt: receivedAt,
      );
      final age = result.sensorAgeMinutes;
      final life = result.expectedLifetimeMinutes;
      final glucose = result.glucoseMgdl;
      if (age != observedMinute ||
          age < 0 ||
          age > 0xffff ||
          (life != null && (life <= 0 || life > 0xffff || age >= life))) {
        return const _DecodedLibreSample(null, 'invalidData');
      }
      final history = _decodeHistoricalSamples(result, age, receivedAt);
      if (age < 60 || result.rejection == LibreGen1GlucoseRejection.warmingUp) {
        return _DecodedLibreSample(null, 'warmingUp', history);
      } else if (result.rejection != null ||
          result.sampleAgeMinutes != age ||
          glucose == null ||
          !glucose.isFinite ||
          glucose <= 0) {
        return _DecodedLibreSample(null, 'invalidData', history);
      } else {
        final reading = CgmReading(
          valueMgdl: glucose,
          source: CgmRecordSource.vendor,
          sensorMinute: age,
          recordedAt: receivedAt,
          isDisplayProvisional: true,
        );
        return _DecodedLibreSample(reading, 'reading', history);
      }
    } catch (_) {
      return const _DecodedLibreSample(null, 'invalidData');
    }
  }

  List<LibreGen1HistoricalReading> _decodeHistoricalSamples(
    LibreGen1GlucoseResult result,
    int age,
    DateTime receivedAt,
  ) {
    if (result.historySamples.length > 9) {
      throw StateError('Invalid Libre historical samples.');
    }
    final samples = List<LibreGen1GlucoseHistorySample>.of(
      result.historySamples,
    );
    final trendMinutes = {
      for (final offset in [2, 4, 6, 7, 12, 15]) age - offset,
    };
    final historyStart = ((age - 2) ~/ 15) * 15;
    final historyMinutes = {historyStart, historyStart - 15, historyStart - 30};
    final slots = <(LibreGen1BleHistoryKind, int)>{};
    for (final sample in samples) {
      final allowed = sample.kind == LibreGen1BleHistoryKind.trend
          ? trendMinutes
          : historyMinutes;
      if (!allowed.contains(sample.sampleAgeMinutes) ||
          sample.sampleAgeMinutes >= age ||
          !slots.add((sample.kind, sample.sampleAgeMinutes)) ||
          (sample.rejection != null && sample.glucoseMgdl != null)) {
        throw StateError('Invalid Libre historical samples.');
      }
    }
    final accepted = <int, LibreGen1HistoricalReading>{};
    // Same-minute ring overlap prefers an accepted trend slot, regardless of
    // decoder order. A rejected trend must not hide a valid history slot.
    for (final kind in LibreGen1BleHistoryKind.values) {
      for (final sample in samples.where((sample) => sample.kind == kind)) {
        final minute = sample.sampleAgeMinutes;
        final glucose = sample.glucoseMgdl;
        if (sample.rejection != null ||
            minute < 60 ||
            (result.expectedLifetimeMinutes != null &&
                minute >= result.expectedLifetimeMinutes!) ||
            glucose == null ||
            !glucose.isFinite ||
            glucose <= 0) {
          continue;
        }
        accepted.putIfAbsent(
          minute,
          () => LibreGen1HistoricalReading(
            reading: CgmReading(
              valueMgdl: glucose,
              source: CgmRecordSource.vendor,
              sensorMinute: minute,
              recordedAt: receivedAt.subtract(Duration(minutes: age - minute)),
              isDisplayProvisional: true,
            ),
            kind: kind,
          ),
        );
      }
    }
    final history = accepted.values.toList()
      ..sort(
        (left, right) =>
            left.reading.sensorMinute!.compareTo(right.reading.sensorMinute!),
      );
    return List<LibreGen1HistoricalReading>.unmodifiable(history);
  }

  void _checkCurrent() {
    if (_stopped) {
      throw const LibreGen1LiveException(LibreGen1LiveFailure.cancelled);
    }
  }

  void _fail(LibreGen1LiveFailure failure) {
    if (_stopped) return;
    _stopped = true;
    _observations.clear();
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
        _latestTiming == null
            ? 'Waiting for a recent sensor update.'
            : _latestTiming!.elapsedMinutes <
                  LibreGen1Driver.dataProfile.warmupMinutes
            ? 'Sensor warming up.'
            : _latestReading == null
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
      sessionInfo: _sessionInfoForBootstrap(
        _bootstrap,
        elapsedMinutes: phase == LibreGen1LivePhase.validatedPacket
            ? _latestTiming?.elapsedMinutes
            : null,
      ),
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
            ..._preLoginFailureDiagnostics,
          },
        ),
      ],
      metadata: {
        cgmAutomaticReconnectAllowedMetadataKey: 'false',
        if (_confirmReceiverAfterAdvertisement != null &&
            phase == LibreGen1LivePhase.awaitingAdvertisement)
          'cgm.libre2.waitingForReturn': 'true',
        'cgm.libre2.phase': phase.name,
        'cgm.libre2.decoder': _decoderOutcome,
        'cgm.libre2.timing': _timingOutcome,
        // Session-selection evidence is independent of glucose acceptance.
        // Never derive it from restored history, a replay, or GATT setup alone.
        if (_commitObservation != null &&
            phase == LibreGen1LivePhase.validatedPacket &&
            _timingOutcome == 'observed' &&
            _latestTiming != null)
          'cgm.libre2.observationCommitted': 'true',
      },
      lastError: failure == null ? null : 'libre2.${failure.name}',
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
    if (!_statuses.isClosed) _statuses.add(_status);
  }

  Future<void> _cleanup() => _cleanupFuture ??= _closeTransport();

  Future<void> _closeTransport() async {
    _timingExpiry?.cancel();
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
      _observations.clear();
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
    // Only the already-dispatched commit can remain. The callback has its own
    // bounded deadline; waiting here cannot authorize late live publication.
    try {
      await _observationDrain?.timeout(_observationTimeout);
    } on TimeoutException {
      _observationStorageUncertain = true;
    }
    if (_commitObservation != null) {
      _publish(_status.phase, failure: _status.failure);
    }
    await _snapshots.close();
    await _statuses.close();
    if (_observationStorageUncertain) {
      throw const LibreGen1LiveException(
        LibreGen1LiveFailure.observationStorageUnavailable,
      );
    }
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

final class _PendingLibreObservation {
  const _PendingLibreObservation({
    required this.encryptedPacket,
    required this.timing,
    required this.receivedAt,
    required this.observedAt,
  });
  final List<int> encryptedPacket;
  final LibreGen1BleTiming timing;
  final DateTime receivedAt;
  final Duration observedAt;
}

final class _DecodedLibreSample {
  const _DecodedLibreSample(
    this.reading,
    this.outcome, [
    this.history = const [],
  ]);
  final CgmReading? reading;
  final String outcome;
  final List<LibreGen1HistoricalReading> history;
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
