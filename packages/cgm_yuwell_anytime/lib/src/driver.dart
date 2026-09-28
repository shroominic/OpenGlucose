import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart';

import 'commands.dart';
import 'constants.dart';
import 'discovery.dart';
import 'errors.dart';
import 'frames.dart';
import 'history_record.dart';
import 'record_state.dart';
import 'record_store.dart';
import 'session_security.dart';
import 'v1150_engineering_output.dart';
import 'authentication.dart';

const yuwellActivationRequiredMetadataKey = 'cgm.yuwell.activation-required';
const yuwellValidationStateMetadataKey = 'cgm.yuwell.validation-state';
const yuwellFailureCodeMetadataKey = 'cgm.yuwell.failure-code';
const yuwellSessionPhaseMetadataKey = 'cgm.yuwell.phase';
const yuwellOutputModeMetadataKey = 'cgm.yuwell.output-mode';
// The reported firmware branch (e.g. "V1150"), not a sensor identifier or
// health value. The evidence-boundary promotion gate asks for the exact
// firmware on record for any non-V1150 unit; this makes that automatic on
// the next attempt instead of relying on a human to note it down.
const yuwellFirmwareMetadataKey = 'cgm.yuwell.firmware';
// Whether the sensor reported itself already bound: 'bound' or 'unbound'.
// Matches the value _readBindingStatusForDiagnostic already publishes for a
// resumed session; _tryReadBindingStatusForEvidence reuses the same key for
// a non-V1150 unit's pre-fail-closed evidence.
const yuwellBindingStateMetadataKey = 'cgm.yuwell.binding-state';
const _maximumAheadLiveRecords = 256;

typedef _PendingEngineeringHistoryProof = ({
  int startIndex,
  int consumedSlots,
  int opcode,
  YuwellHistoryRecordLayout? layout,
});

void _debugYuwellTrace(String phase, String operation, String outcome) {
  assert(() {
    // Closed debug milestones only. Never add identifiers, packet bytes,
    // credentials, coefficients, timestamps, record indexes, or glucose.
    // ignore: avoid_print
    print('OGYW phase=$phase op=$operation outcome=$outcome');
    return true;
  }());
}

enum YuwellSessionFailureKind {
  invalidSensor,
  credentialStore,
  unresolvedWrite,
  connection,
  topology,
  notification,
  unsupportedFirmware,
  activationRequired,
  alreadyBound,
  authenticationRejected,
  calibrationCode,
  persistence,
  responseTimeout,
  malformedResponse,
  writeOutcomeUnknown,
  disconnected,
  unsupportedCapability,
  historyIncomplete,
  sessionInUse,
  recordPersistence,
}

final class YuwellSessionException implements Exception {
  const YuwellSessionException(this.kind, {this.firmware, this.bound});

  final YuwellSessionFailureKind kind;

  /// The reported firmware branch (e.g. "V1150") when [kind] is
  /// [YuwellSessionFailureKind.unsupportedFirmware] and a version response
  /// was actually parsed. Null when no fresh version query ran (for example,
  /// a resumed session inferring non-admission from saved credentials) —
  /// never guessed or backfilled.
  final String? firmware;

  /// Whether a non-V1150 unit reported itself already bound, from the one
  /// best-effort binding-status query [YuwellAnytimeSession] sends before
  /// failing closed on firmware. Null when that query was not sent or did
  /// not get a valid answer — never guessed.
  final bool? bound;

  String get diagnosticCode => 'yuwell.session.${kind.name}';

  @override
  String toString() => 'YuwellSessionException($diagnosticCode)';
}

final class YuwellTimingProfile {
  const YuwellTimingProfile({
    this.connectTimeout = const Duration(seconds: 12),
    this.responseTimeout = const Duration(seconds: 8),
    this.maxHistoryBatches = 8000,
  });

  final Duration connectTimeout;
  final Duration responseTimeout;
  final int maxHistoryBatches;
}

/// Process-local single-session lease for one durable sensor identity.
///
/// The default driver uses one shared registry across all driver instances.
/// Tests can inject an isolated registry. A process death releases all leases;
/// the durable write journal remains authoritative across process death.
final class YuwellSessionLeaseRegistry {
  final Set<String> _storageKeys = <String>{};

  bool _tryAcquire(String storageKey) => _storageKeys.add(storageKey);

  void _release(String storageKey) => _storageKeys.remove(storageKey);
}

final YuwellSessionLeaseRegistry _processYuwellSessionLeases =
    YuwellSessionLeaseRegistry();

/// Maps only exact CT5 candidate names. GATT compatibility is proved later.
final class YuwellAnytimeDiscovery {
  const YuwellAnytimeDiscovery();

  DiscoveredSensor? mapScanResult(BleScanResult result) {
    final name = result.deviceName;
    if (result.deviceId.isEmpty ||
        classifyYuwellAnytimeDeviceName(name) !=
            YuwellAnytimeNameKind.anytimeFamily) {
      return null;
    }
    final digest = sha256.convert(utf8.encode(name)).toString();
    return DiscoveredSensor(
      driverId: YuwellAnytimeDriver.driverIdentifier,
      deviceId: result.deviceId,
      displayName: 'Yuwell Anytime 5P',
      storageKey: 'yuwell:$digest',
      rssi: result.rssi,
      capabilities: YuwellAnytimeDriver.capabilities,
      notes: 'Exact CT5 candidate name; GATT topology is not verified yet.',
      metadata: const <String, String>{
        yuwellValidationStateMetadataKey: 'target-unverified',
      },
    );
  }
}

final class YuwellAnytimeDriver implements CgmDriver {
  YuwellAnytimeDriver(
    this._transport, {
    required YuwellCredentialStore credentialStore,
    required YuwellWriteIntentStore writeIntentStore,
    YuwellActivationGate? activationGate,
    YuwellSensorCodeDecoder sensorCodeDecoder =
        const YuwellCt5SensorCodeDecoder(),
    YuwellSecureIdentityGenerator? identityGenerator,
    YuwellRecordStore? recordStore,
    YuwellHistoryGenerationGenerator? historyGenerationGenerator,
    YuwellTimingProfile timingProfile = const YuwellTimingProfile(),
    YuwellV1150GlucoseOutputPolicy glucoseOutputPolicy =
        YuwellV1150GlucoseOutputPolicy.disabled,
    YuwellSessionLeaseRegistry? sessionLeaseRegistry,
    DateTime Function()? clock,
    this.discovery = const YuwellAnytimeDiscovery(),
  }) : _credentialStore = credentialStore,
       _writeIntentStore = writeIntentStore,
       _activationGate = activationGate,
       _sensorCodeDecoder = sensorCodeDecoder,
       _identityGenerator =
           identityGenerator ?? YuwellSecureIdentityGenerator(),
       _recordStore = recordStore,
       _historyGenerationGenerator =
           historyGenerationGenerator ??
           YuwellSecureHistoryGenerationGenerator(),
       _timing = timingProfile,
       _glucoseOutputPolicy = glucoseOutputPolicy,
       _sessionLeases = sessionLeaseRegistry ?? _processYuwellSessionLeases,
       _clock = clock ?? DateTime.now;

  static const driverIdentifier = 'yuwell-anytime';

  static const capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsVendorPairing: true,
    supportsHistory: true,
    supportsRawHistory: false,
    supportsDiagnostics: true,
  );

  final BleTransport _transport;
  final YuwellCredentialStore _credentialStore;
  final YuwellWriteIntentStore _writeIntentStore;
  final YuwellActivationGate? _activationGate;
  final YuwellSensorCodeDecoder _sensorCodeDecoder;
  final YuwellSecureIdentityGenerator _identityGenerator;
  final YuwellRecordStore? _recordStore;
  final YuwellHistoryGenerationGenerator _historyGenerationGenerator;
  final YuwellTimingProfile _timing;
  final YuwellV1150GlucoseOutputPolicy _glucoseOutputPolicy;
  final YuwellSessionLeaseRegistry _sessionLeases;
  final DateTime Function() _clock;
  final YuwellAnytimeDiscovery discovery;

  @override
  String get driverId => driverIdentifier;

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    final seen = <String, int>{};
    await for (final result in _transport.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
      // The official CT5 flow scans without a service filter. Name matching is
      // exact and topology is mandatory before any command.
      withServices: null,
    )) {
      final candidate = discovery.mapScanResult(result);
      if (candidate == null) {
        continue;
      }
      if (allowDuplicates || seen[candidate.storageKey] != candidate.rssi) {
        seen[candidate.storageKey] = candidate.rssi;
        yield candidate;
      }
    }
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    if (sensor.driverId != driverIdentifier ||
        sensor.deviceId.isEmpty ||
        !sensor.storageKey.startsWith('yuwell:')) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.invalidSensor,
      );
    }
    if (!_sessionLeases._tryAcquire(sensor.storageKey)) {
      throw const YuwellSessionException(YuwellSessionFailureKind.sessionInUse);
    }
    late final YuwellAnytimeSession session;
    try {
      session = YuwellAnytimeSession._(
        sensor: sensor,
        transport: _transport,
        credentialStore: _credentialStore,
        writeIntentStore: _writeIntentStore,
        activationGate: _activationGate,
        sensorCodeDecoder: _sensorCodeDecoder,
        identityGenerator: _identityGenerator,
        recordStore: _recordStore,
        historyGenerationGenerator: _historyGenerationGenerator,
        timing: _timing,
        glucoseOutputPolicy: _glucoseOutputPolicy,
        clock: _clock,
        releaseLease: () => _sessionLeases._release(sensor.storageKey),
      );
    } catch (_) {
      _sessionLeases._release(sensor.storageKey);
      rethrow;
    }
    unawaited(
      session.initialize().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    return session;
  }
}

final class YuwellAnytimeSession implements CgmSession {
  YuwellAnytimeSession._({
    required this.sensor,
    required BleTransport transport,
    required YuwellCredentialStore credentialStore,
    required YuwellWriteIntentStore writeIntentStore,
    required YuwellActivationGate? activationGate,
    required YuwellSensorCodeDecoder sensorCodeDecoder,
    required YuwellSecureIdentityGenerator identityGenerator,
    required YuwellRecordStore? recordStore,
    required YuwellHistoryGenerationGenerator historyGenerationGenerator,
    required YuwellTimingProfile timing,
    required YuwellV1150GlucoseOutputPolicy glucoseOutputPolicy,
    required DateTime Function() clock,
    required void Function() releaseLease,
  }) : _transport = transport,
       _credentialStore = credentialStore,
       _writeIntentStore = writeIntentStore,
       _activationGate = activationGate,
       _sensorCodeDecoder = sensorCodeDecoder,
       _identityGenerator = identityGenerator,
       _recordStore = recordStore,
       _historyGenerationGenerator = historyGenerationGenerator,
       _timing = timing,
       _engineeringOutput = YuwellV1150EngineeringOutput(
         policy: glucoseOutputPolicy,
         clock: clock,
       ),
       _releaseLeaseCallback = releaseLease,
       _clock = clock,
       _snapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting to Yuwell sensor',
         sensor: sensor,
         capabilities: sensor.capabilities,
         sessionInfo: const CgmSessionInfo(
           manufacturer: 'Yuwell',
           model: 'Anytime 5P',
           warmupMinutes: 45,
           expectedLifetimeMinutes: 23085,
         ),
         metadata: <String, String>{
           yuwellValidationStateMetadataKey: _validationStateForOutputPolicy(
             glucoseOutputPolicy,
           ),
           yuwellOutputModeMetadataKey: _outputModeForPolicy(
             glucoseOutputPolicy,
           ),
         },
       );

  @override
  final DiscoveredSensor sensor;

  final BleTransport _transport;
  final YuwellCredentialStore _credentialStore;
  final YuwellWriteIntentStore _writeIntentStore;
  final YuwellActivationGate? _activationGate;
  final YuwellSensorCodeDecoder _sensorCodeDecoder;
  final YuwellSecureIdentityGenerator _identityGenerator;
  final YuwellRecordStore? _recordStore;
  final YuwellHistoryGenerationGenerator _historyGenerationGenerator;
  final YuwellTimingProfile _timing;
  final YuwellV1150EngineeringOutput _engineeringOutput;
  final void Function() _releaseLeaseCallback;
  final DateTime Function() _clock;

  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();
  final Map<int, Queue<Completer<List<int>>>> _pending =
      <int, Queue<Completer<List<int>>>>{};
  final Map<int, YuwellHistoryRecord> _recordByIndex =
      <int, YuwellHistoryRecord>{};
  final Map<int, YuwellHistoryRecord> _aheadLiveRecordByIndex =
      <int, YuwellHistoryRecord>{};
  final Map<int, YuwellHistoryRecord> _pendingPrivateRecordByIndex =
      <int, YuwellHistoryRecord>{};
  final Set<int> _pendingPrivateObservedSlots = <int>{};
  final Set<int> _pendingPrivatePublishIndexes = <int>{};
  final Set<int> _pendingAheadDrainIndexes = <int>{};
  final List<_PendingEngineeringHistoryProof> _pendingPrivateEngineeringProofs =
      <_PendingEngineeringHistoryProof>[];
  final Map<int, CgmReading> _engineeringReadingByIndex = <int, CgmReading>{};
  final Set<int> _observedRecordSlots = <int>{};
  final Set<Future<void>> _notificationTasks = <Future<void>>{};

  late CgmSessionSnapshot _snapshot;
  BleConnection? _connection;
  BleCharacteristicRef? _notifyCharacteristic;
  BleCharacteristicRef? _writeCharacteristic;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BleConnectionState>? _connectionSubscription;
  Future<void> _writeTail = Future<void>.value();
  Future<void> _privateRecordTransitionTail = Future<void>.value();
  Future<void>? _initialization;
  Future<void>? _historyFuture;
  Future<void>? _publicHistoryFuture;
  YuwellSessionCredentials? _credentials;
  YuwellRecordStateOwner? _recordOwner;
  int _privateExpectedPrefixLength = 0;
  bool _privatePrefixValidated = false;
  YuwellUnresolvedWriteIntent? _unresolvedIntent;
  YuwellHistoryRecordLayout? _recordLayout;
  String? _firmware;
  bool _closing = false;
  bool _initializationFinished = false;
  bool _writeWithoutResponse = false;
  bool _autoHistoryStarted = false;
  bool _historySawSessionComplete = false;
  bool _stateChangingWritePostBarrier = false;
  bool _terminalFailure = false;
  bool _leaseReleased = false;
  int? _negotiatedMtu;
  String _phase = 'P01';

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  Future<void> initialize() => _initialization ??= _initializeGuarded();

  Future<void> _initializeGuarded() async {
    try {
      await _initialize();
    } catch (error, stackTrace) {
      final failure = error is YuwellSessionException
          ? error
          : const YuwellSessionException(YuwellSessionFailureKind.connection);
      _publishFailure(
        failure.kind,
        firmware: failure.firmware,
        bound: failure.bound,
      );
      if (!_closing) {
        await _cleanupAfterInitializationFailure();
        _releaseLease();
      }
      Error.throwWithStackTrace(failure, stackTrace);
    } finally {
      _initializationFinished = true;
    }
  }

  Future<void> _initialize() async {
    _setPhase('P01', 'connect');
    _log(CgmLogLevel.info, 'yuwell.connect.started');
    try {
      final hasUnresolved = await _writeIntentStore.hasUnresolved(
        sensor.storageKey,
      );
      _unresolvedIntent = await _writeIntentStore.readUnresolved(
        sensor.storageKey,
      );
      if (hasUnresolved != (_unresolvedIntent != null)) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.persistence,
        );
      }
      _credentials = await _credentialStore.read(sensor.storageKey);
    } catch (error) {
      if (error is YuwellSessionException) rethrow;
      throw const YuwellSessionException(
        YuwellSessionFailureKind.credentialStore,
      );
    }

    final connection = await _transport.connect(
      sensor.deviceId,
      timeout: _timing.connectTimeout,
    );
    if (_closing) {
      await connection.disconnect();
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    _connection = connection;
    _connectionSubscription = connection.connectionStates.listen(
      _onConnectionState,
      onError: (_) => _handleTransportDisconnect(),
    );
    _emit(stage: CgmSyncStage.connecting, statusText: 'Verifying sensor');

    try {
      await connection.requestMtu(512);
      if (connection case final BleNegotiatedMtu mtuCapable) {
        final mtu = mtuCapable.negotiatedMtu;
        if (mtu != null && mtu >= 23 && mtu <= 517) {
          _negotiatedMtu = mtu;
        }
      }
    } catch (_) {
      _log(CgmLogLevel.warning, 'yuwell.mtu.default');
    }
    final services = await connection.discoverServices();
    _setPhase('P02', 'topology');
    _verifyTopology(services);

    final notifyStream = connection.notifications(_notifyCharacteristic!);
    _notificationSubscription = notifyStream.listen(
      _dispatchNotification,
      onError: (_) => _handleTransportDisconnect(),
    );
    await connection.setNotify(_notifyCharacteristic!, true);
    _setPhase('P03', 'subscribe');
    _log(CgmLogLevel.info, 'yuwell.notify.enabled');

    final credentials = _credentials;
    if (_recordStore != null ||
        (credentials == null && _unresolvedIntent == null)) {
      // Persistence authority always requires the exact read-only firmware
      // response, including credential-less journal recovery. Without private
      // persistence, retain the reference client's new-session-only query.
      await _readAndRequireSupportedFirmware();
    } else {
      _firmware = credentials?.transmitterComputed == false
          ? 'unsupported'
          : 'V1150';
    }

    if (_unresolvedIntent != null) {
      await _recoverUnresolved(credentials, _unresolvedIntent!);
      return;
    }
    if (credentials == null) {
      await _beginFreshActivation();
    } else {
      await _resume(credentials);
    }
  }

  void _verifyTopology(List<BleService> services) {
    BleService? service;
    for (final candidate in services) {
      if (_uuid(candidate.uuid) == _uuid(yuwellCt5ServiceUuid)) {
        service = candidate;
        break;
      }
    }
    if (service == null) {
      throw const YuwellSessionException(YuwellSessionFailureKind.topology);
    }
    for (final characteristic in service.characteristics) {
      final uuid = _uuid(characteristic.characteristicUuid);
      if (uuid == _uuid(yuwellCt5NotifyCharacteristicUuid) &&
          (characteristic.properties.notify ||
              characteristic.properties.indicate)) {
        _notifyCharacteristic = characteristic;
      }
      if (uuid == _uuid(yuwellCt5WriteCharacteristicUuid)) {
        if (characteristic.properties.write) {
          _writeCharacteristic = characteristic;
          _writeWithoutResponse = false;
        } else if (_writeCharacteristic == null &&
            characteristic.properties.writeWithoutResponse) {
          _writeCharacteristic = characteristic;
          _writeWithoutResponse = true;
        }
      }
    }
    if (_notifyCharacteristic == null || _writeCharacteristic == null) {
      throw const YuwellSessionException(YuwellSessionFailureKind.topology);
    }
    _log(CgmLogLevel.info, 'yuwell.topology.verified');
  }

  Future<void> _recoverUnresolved(
    YuwellSessionCredentials? credentials,
    YuwellUnresolvedWriteIntent intent,
  ) async {
    if (credentials == null &&
        intent.operation == YuwellActivationWrite.setDate) {
      final statusResponse = await _sendAndWait(
        operation: 'binding-status-date-recovery',
        frame: YuwellCt5Commands.readBindingStatus(),
        responseOpcode: YuwellCt5Commands.bindingStatusCommand,
      );
      final bound = _validate(
        () => YuwellCt5Responses.bindingStatus(statusResponse),
      );
      if (bound) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      }
      await _requireActivationAuthorization();
      await _completeRecoveredIntent(intent);
      await _continueFreshActivationAuthorized();
      return;
    }
    if (credentials == null) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.unresolvedWrite,
      );
    }
    final authenticated = await _checkSavedCredentials(credentials);
    if (intent.operation == YuwellActivationWrite.setCommunicationId &&
        credentials.phase == YuwellCredentialPhase.identityPrepared) {
      if (authenticated) {
        // The identity reached the transmitter, but the response carrying the
        // cipher was not durably observed. Do not repeat or invent a bind.
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      }
      // A rejected check-ID proves only that this prepared identity is not the
      // current binding. Another phone could have bound while this app was
      // offline, so re-check the transmitter before any exact set-ID replay.
      await _requireUnboundForSetIdRecovery('binding-status-set-id-recovery');
      // Clear only through reviewed read-only recovery, then resend the exact
      // durable identity under the caller's one-shot authorization.
      await _requireActivationAuthorization();
      final replacementToken = await _replaceRecoveredWithPrepared(intent);
      await _setCommunicationIdentity(
        credentials.communicationIdentity,
        preparedToken: replacementToken,
      );
      await _completeActivationFromAuthenticated();
      return;
    }
    if (!authenticated) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.authenticationRejected,
      );
    }
    final recoveryCredentials =
        await _prepareRecordPersistenceAfterAuthentication(credentials);

    switch (intent.operation) {
      case YuwellActivationWrite.setDate:
        if (recoveryCredentials.phase != YuwellCredentialPhase.active) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.unresolvedWrite,
          );
        }
        await _completeRecoveredIntent(intent);
        await _setDateWithJournal();
        await _syncSavedSessionHistory();
        return;
      case YuwellActivationWrite.setCommunicationId:
        if (recoveryCredentials.phase == YuwellCredentialPhase.authenticated) {
          await _requireActivationAuthorization();
          await _completeRecoveredIntent(intent);
          await _completeActivationFromAuthenticated();
          return;
        }
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      case YuwellActivationWrite.configure:
        if (intent.state == YuwellWriteIntentState.prepared &&
            recoveryCredentials.phase == YuwellCredentialPhase.authenticated) {
          // The pre-BLE uncertainty barrier proves configuration was never
          // attempted. Cancel it and continue the already-authorized flow.
          await _cancelRecoveredPreparedIntent(intent);
          await _completeActivationFromAuthenticated();
          return;
        }
        if (recoveryCredentials.phase == YuwellCredentialPhase.configured) {
          await _requireActivationAuthorization();
          await _completeRecoveredIntent(intent);
          await _initializeConfigured(recoveryCredentials);
          return;
        }
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      case YuwellActivationWrite.initialize:
        if (intent.state == YuwellWriteIntentState.prepared &&
            recoveryCredentials.phase ==
                YuwellCredentialPhase.activationPrepared) {
          // activationPrepared was persisted before the journal, and a
          // prepared journal now proves initialize did not enter BLE.
          await _cancelRecoveredPreparedIntent(intent);
          await _initializeConfigured(recoveryCredentials);
          return;
        }
        if (recoveryCredentials.phase ==
            YuwellCredentialPhase.lowPowerPending) {
          // This phase is written only after a valid initialize response.
          // Complete the stale initialize tombstone, then run the separately
          // journaled low-power step without repeating initialize.
          await _completeRecoveredIntent(intent);
          await _enterLowPowerAndPublish(recoveryCredentials);
          return;
        }
        if (recoveryCredentials.phase == YuwellCredentialPhase.active) {
          // Compatibility with the pre-lowPowerPending schema: its active
          // phase proved initialize but did not prove low-power. Downgrade to
          // the explicit pending phase before clearing the stale initialize
          // tombstone, then run low-power once under its own journal.
          final lowPowerPending = recoveryCredentials.copyWith(
            phase: YuwellCredentialPhase.lowPowerPending,
          );
          await _persistCredentials(lowPowerPending);
          await _completeRecoveredIntent(intent);
          await _enterLowPowerAndPublish(lowPowerPending);
          return;
        }
        if (recoveryCredentials.phase !=
                YuwellCredentialPhase.activationPrepared ||
            recoveryCredentials.activationStartedAt == null) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.unresolvedWrite,
          );
        }
        // The reference interrupted-activation recovery is authenticated and
        // read-only: verify bound status, re-read calibration, probe history,
        // then retain the pre-write timestamp without repeating initialize.
        final statusResponse = await _sendAndWait(
          operation: 'binding-status-recovery',
          frame: YuwellCt5Commands.readBindingStatus(),
          responseOpcode: YuwellCt5Commands.bindingStatusCommand,
        );
        final bound = _validate(
          () => YuwellCt5Responses.bindingStatus(statusResponse),
        );
        if (!bound) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.unresolvedWrite,
          );
        }
        final sensorCodeResponse = await _sendAndWait(
          operation: 'sensor-code-recovery',
          frame: YuwellCt5Commands.querySensorCode(),
          responseOpcode: YuwellCt5Commands.querySensorCodeCommand,
        );
        final decoded = _validate(
          () => YuwellCt5Responses.decodedSensorCode(
            sensorCodeResponse,
            cipher: recoveryCredentials.cipher!,
          ),
        );
        YuwellActivationParameters recovered;
        try {
          recovered = await _sensorCodeDecoder.decode(decoded);
        } catch (_) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.calibrationCode,
          );
        }
        if ((recovered.k - recoveryCredentials.k).abs() > 0.0001 ||
            (recovered.r - recoveryCredentials.r).abs() > 0.0001) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.calibrationCode,
          );
        }
        final historyResponse = await _sendAndWait(
          operation: 'history-recovery',
          frame: YuwellCt5Commands.readHistoryVariant(
            startIndex: 0,
            transmitterComputed: true,
          ),
          responseOpcode: YuwellCt5Commands.alternateHistoryCommand,
        );
        final probe = _validate(
          () => YuwellHistoryFrame.parse(
            historyResponse,
            cipher: recoveryCredentials.cipher!,
            expectedLayout: YuwellHistoryRecordLayout.alert17,
          ),
        );
        if (probe.indexedRecords.isEmpty) {
          // Empty/all-FF/all-FC history is not evidence that initialize took
          // effect. Keep the tombstone and retry only these read-only checks.
          throw const YuwellSessionException(
            YuwellSessionFailureKind.unresolvedWrite,
          );
        }
        final lowPowerPending = recoveryCredentials.copyWith(
          phase: YuwellCredentialPhase.lowPowerPending,
        );
        await _persistCredentials(lowPowerPending);
        await _completeRecoveredIntent(intent);
        if (_recordOwner == null) {
          for (final indexed in probe.indexedRecords) {
            _recordLayout = indexed.record.layout;
            _storeRecord(
              indexed.index,
              indexed.record,
              isLive: false,
              publish: false,
            );
          }
          _markConsumedHistorySlots(probe);
        }
        // With persistence, this one-record activity probe remains evidence
        // only. The normal zero-based history cycle must revalidate the entire
        // quarantined prefix through the owner before any driver/projector
        // state changes.
        await _enterLowPowerAndPublish(lowPowerPending);
        return;
      case YuwellActivationWrite.lowPower:
        if (recoveryCredentials.phase !=
                YuwellCredentialPhase.lowPowerPending &&
            recoveryCredentials.phase != YuwellCredentialPhase.active) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.unresolvedWrite,
          );
        }
        // The official CT5 client sends 0x0F after initialization and after
        // every completed history cycle. That repeated production behavior
        // is the clean-room evidence that this command can be replayed after
        // an uncertain outcome. Persist the pending phase before clearing the
        // old tombstone so every process-death boundary remains recoverable.
        final lowPowerPending =
            recoveryCredentials.phase == YuwellCredentialPhase.lowPowerPending
            ? recoveryCredentials
            : recoveryCredentials.copyWith(
                phase: YuwellCredentialPhase.lowPowerPending,
              );
        if (recoveryCredentials.phase !=
            YuwellCredentialPhase.lowPowerPending) {
          await _persistCredentials(lowPowerPending);
        }
        await _completeRecoveredIntent(intent);
        await _enterLowPowerAndPublish(lowPowerPending);
        return;
    }
  }

  Future<void> _completeRecoveredIntent(
    YuwellUnresolvedWriteIntent intent,
  ) async {
    try {
      await _writeIntentStore.resolveRecovered(
        intent.token,
        expectedOperation: intent.operation,
        expectedState: intent.state,
      );
      _unresolvedIntent = null;
    } catch (_) {
      throw const YuwellSessionException(YuwellSessionFailureKind.persistence);
    }
  }

  Future<void> _cancelRecoveredPreparedIntent(
    YuwellUnresolvedWriteIntent intent,
  ) async {
    try {
      await _writeIntentStore.cancelPrepared(intent.token);
      _unresolvedIntent = null;
    } catch (_) {
      throw const YuwellSessionException(YuwellSessionFailureKind.persistence);
    }
  }

  Future<String> _replaceRecoveredWithPrepared(
    YuwellUnresolvedWriteIntent intent,
  ) async {
    try {
      final token = await _writeIntentStore.replaceRecoveredWithPrepared(
        intent.token,
        sensor.storageKey,
        YuwellActivationWrite.setCommunicationId,
        expectedOperation: intent.operation,
        expectedState: intent.state,
      );
      _unresolvedIntent = YuwellUnresolvedWriteIntent(
        token: token,
        operation: YuwellActivationWrite.setCommunicationId,
        state: YuwellWriteIntentState.prepared,
      );
      return token;
    } catch (_) {
      throw const YuwellSessionException(YuwellSessionFailureKind.persistence);
    }
  }

  Future<void> _beginFreshActivation() async {
    _setPhase('P05', 'fresh-auth');
    final statusResponse = await _sendAndWait(
      operation: 'binding-status',
      frame: YuwellCt5Commands.readBindingStatus(),
      responseOpcode: YuwellCt5Commands.bindingStatusCommand,
    );
    final alreadyBound = _validate(
      () => YuwellCt5Responses.bindingStatus(statusResponse),
    );
    if (alreadyBound) {
      throw const YuwellSessionException(YuwellSessionFailureKind.alreadyBound);
    }

    final metadataAuthorized =
        sensor.metadata[cgmAllowSessionActivationMetadataKey] == 'true';
    final gateAuthorized =
        _activationGate == null ||
        await _activationGate.consumeAuthorization(sensor);
    if (!metadataAuthorized || !gateAuthorized) {
      _emit(
        stage: CgmSyncStage.error,
        statusText: 'Activation confirmation required',
        metadata: <String, String>{
          ..._snapshot.metadata,
          yuwellActivationRequiredMetadataKey: 'true',
          'activationRequired': 'true',
        },
        lastError: 'yuwell.session.activationRequired',
      );
      throw const YuwellSessionException(
        YuwellSessionFailureKind.activationRequired,
      );
    }

    await _continueFreshActivationAuthorized();
  }

  Future<void> _continueFreshActivationAuthorized() async {
    _emit(stage: CgmSyncStage.activating, statusText: 'Activating sensor');
    await _setDateWithJournal();
    final identity = _identityGenerator.generate();
    await _setCommunicationIdentity(identity);
    await _completeActivationFromAuthenticated();
  }

  Future<void> _setCommunicationIdentity(
    YuwellCommunicationIdentity identity, {
    String? preparedToken,
  }) async {
    final preparedIdentity = YuwellSessionCredentials(
      communicationIdentity: identity,
      cipher: null,
      k: 0,
      r: 0,
      transmitterComputed: true,
      phase: YuwellCredentialPhase.identityPrepared,
    );
    // Identity recovery material must be durable before a journal can refer to
    // set-ID. A crash before journal creation is recovered with check-ID.
    await _persistCredentials(preparedIdentity);
    final setIdResponse = await _activationWrite<List<int>>(
      operation: YuwellActivationWrite.setCommunicationId,
      frame: identity.encodeSetId(),
      responseOpcode: 0x30,
      preparedToken: preparedToken,
      parse: (response) => response,
      persistAfterResponse: (response) async {
        final cipher = _validate(
          () => identity.deriveCipherFromSetIdResponse(response),
        );
        final credentials = YuwellSessionCredentials(
          communicationIdentity: identity,
          cipher: cipher,
          k: 0,
          r: 0,
          transmitterComputed: true,
          phase: YuwellCredentialPhase.authenticated,
          verifiedFirmware: _recordStore == null ? null : _firmware,
          historyGeneration: _recordStore == null
              ? null
              : _historyGenerationGenerator.generate(),
        );
        await _persistCredentials(credentials);
      },
    );
    // Ensure malformed responses cannot be accidentally accepted if a store
    // implementation invokes the callback differently.
    _validate(() => identity.deriveCipherFromSetIdResponse(setIdResponse));
    final credentials = _credentials;
    if (_recordStore != null && credentials != null) {
      await _restoreRecordOwner(credentials);
    }
  }

  Future<void> _resume(YuwellSessionCredentials credentials) async {
    if (!credentials.transmitterComputed) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.unsupportedFirmware,
      );
    }
    final accepted = await _checkSavedCredentials(credentials);
    if (credentials.phase == YuwellCredentialPhase.identityPrepared) {
      if (accepted) {
        // The sensor accepted the identity but no response-derived cipher was
        // durably observed. Never repeat set-ID in this state.
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      }
      await _requireUnboundForSetIdRecovery('binding-status-identity-recovery');
      await _requireActivationAuthorization();
      await _setCommunicationIdentity(credentials.communicationIdentity);
      await _completeActivationFromAuthenticated();
      return;
    }
    if (!accepted) {
      await _readBindingStatusForDiagnostic();
      throw const YuwellSessionException(
        YuwellSessionFailureKind.authenticationRejected,
      );
    }

    final resumedCredentials =
        await _prepareRecordPersistenceAfterAuthentication(credentials);

    switch (resumedCredentials.phase) {
      case YuwellCredentialPhase.identityPrepared:
        throw const YuwellSessionException(
          YuwellSessionFailureKind.unresolvedWrite,
        );
      case YuwellCredentialPhase.active:
        await _setDateWithJournal();
        await _syncSavedSessionHistory();
        return;
      case YuwellCredentialPhase.authenticated:
        await _requireActivationAuthorization();
        await _completeActivationFromAuthenticated();
        return;
      case YuwellCredentialPhase.configured:
        await _requireActivationAuthorization();
        await _initializeConfigured(resumedCredentials);
        return;
      case YuwellCredentialPhase.activationPrepared:
        // This phase is persisted immediately before the initialize journal.
        // With no unresolved intent, the process died before BLE was entered.
        await _initializeConfigured(resumedCredentials);
        return;
      case YuwellCredentialPhase.lowPowerPending:
        await _enterLowPowerAndPublish(resumedCredentials);
        return;
    }
  }

  Future<YuwellSessionCredentials> _prepareRecordPersistenceAfterAuthentication(
    YuwellSessionCredentials credentials,
  ) async {
    if (_recordStore == null) return credentials;
    final firmware = _firmware;
    if (firmware == null || firmware != 'V1150') {
      throw YuwellSessionException(
        YuwellSessionFailureKind.unsupportedFirmware,
        firmware: firmware,
      );
    }
    var prepared = credentials;
    if (credentials.canRestoreHistory) {
      if (credentials.verifiedFirmware != firmware) {
        throw YuwellSessionException(
          YuwellSessionFailureKind.unsupportedFirmware,
          firmware: firmware,
        );
      }
    } else {
      prepared = credentials.copyWith(
        verifiedFirmware: firmware,
        historyGeneration: _historyGenerationGenerator.generate(),
      );
      await _persistCredentials(prepared);
    }
    await _restoreRecordOwner(prepared);
    return prepared;
  }

  Future<void> _restoreRecordOwner(YuwellSessionCredentials credentials) async {
    final store = _recordStore;
    final firmware = credentials.verifiedFirmware;
    final generation = credentials.historyGeneration;
    if (store == null || firmware == null || generation == null) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
    final binding = YuwellRecordBinding(
      sensorBinding: sha256.convert(utf8.encode(sensor.storageKey)).toString(),
      historyGeneration: generation,
      firmware: firmware,
      historyOpcode: YuwellCt5Commands.alternateHistoryCommand,
      layout: YuwellHistoryRecordLayout.alert17,
    );
    final key = YuwellRecordStoreKey.forGeneration(
      sensorStorageKey: sensor.storageKey,
      historyGeneration: generation,
    );
    try {
      _recordOwner = await YuwellRecordStateOwner.restore(
        store: store,
        key: key,
        binding: binding,
      );
      _recordLayout = binding.layout;
    } catch (_) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
  }

  Future<void> _readAndRequireSupportedFirmware() async {
    _setPhase('P04', 'version');
    final versionResponse = await _sendAndWait(
      operation: 'version',
      frame: YuwellCt5Commands.readVersion(),
      responseOpcode: YuwellCt5Commands.versionCommand,
    );
    final version = _validate(
      () => YuwellCt5Responses.version(versionResponse),
    );
    _firmware = _parseFirmware(version);
    if (_firmware != 'V1150') {
      final bound = await _tryReadBindingStatusForEvidence();
      throw YuwellSessionException(
        YuwellSessionFailureKind.unsupportedFirmware,
        firmware: _firmware,
        bound: bound,
      );
    }
  }

  Future<bool> _checkSavedCredentials(
    YuwellSessionCredentials credentials,
  ) async {
    final response = await _sendAndWait(
      operation: 'check-id',
      frame: YuwellCt5Commands.checkId(
        credentials.communicationIdentity.randomB,
      ),
      responseOpcode: YuwellCt5Commands.checkIdCommand,
    );
    return _validate(() => YuwellCt5Responses.checkIdAccepted(response));
  }

  Future<void> _requireActivationAuthorization() async {
    final metadataAuthorized =
        sensor.metadata[cgmAllowSessionActivationMetadataKey] == 'true';
    final gateAuthorized =
        _activationGate == null ||
        await _activationGate.consumeAuthorization(sensor);
    if (!metadataAuthorized || !gateAuthorized) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.activationRequired,
      );
    }
    _emit(stage: CgmSyncStage.activating, statusText: 'Resuming activation');
  }

  Future<void> _completeActivationFromAuthenticated() async {
    _setPhase('P06', 'configure');
    final credentials = _credentials!;
    final sensorCodeResponse = await _sendAndWait(
      operation: 'sensor-code',
      frame: YuwellCt5Commands.querySensorCode(),
      responseOpcode: YuwellCt5Commands.querySensorCodeCommand,
    );
    final decoded = _validate(
      () => YuwellCt5Responses.decodedSensorCode(
        sensorCodeResponse,
        cipher: credentials.cipher!,
      ),
    );
    YuwellActivationParameters parameters;
    try {
      parameters = await _sensorCodeDecoder.decode(decoded);
    } catch (_) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.calibrationCode,
      );
    }
    if (!parameters.k.isFinite ||
        !parameters.r.isFinite ||
        parameters.k <= 0 ||
        parameters.k >= 256 ||
        parameters.r < 0 ||
        parameters.r >= 256 ||
        !parameters.transmitterComputed ||
        parameters.initializationIndex != 15) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.calibrationCode,
      );
    }

    final configured = credentials.copyWith(
      k: parameters.k,
      r: parameters.r,
      transmitterComputed: true,
      phase: YuwellCredentialPhase.configured,
      initializationIndex: parameters.initializationIndex,
    );
    await _activationWrite<void>(
      operation: YuwellActivationWrite.configure,
      frame: YuwellCt5Commands.setParameters(
        k: configured.k,
        r: configured.r,
        cipher: configured.cipher!,
        idPrefix: configured.communicationIdentity.idPrefix,
      ),
      responseOpcode: YuwellCt5Commands.setParametersCommand,
      parse: (response) => _validate(
        () => YuwellCt5Responses.parametersAccepted(
          response,
          cipher: configured.cipher!,
        ),
      ),
      persistAfterResponse: (_) => _persistCredentials(configured),
    );
    await _initializeConfigured(configured);
  }

  Future<void> _initializeConfigured(
    YuwellSessionCredentials credentials,
  ) async {
    _setPhase('P07', 'initialize');
    final startedAt = _clock().toUtc();
    final prepared = credentials.copyWith(
      phase: YuwellCredentialPhase.activationPrepared,
      activationStartedAt: startedAt,
    );
    final lowPowerPending = prepared.copyWith(
      phase: YuwellCredentialPhase.lowPowerPending,
    );
    // Avoid a journal-without-timestamp crash state. A crash before journal
    // creation leaves activationPrepared and fails closed on reconnect.
    await _persistCredentials(prepared);
    await _activationWrite<void>(
      operation: YuwellActivationWrite.initialize,
      frame: YuwellCt5Commands.initialize(
        transmitterComputed: true,
        initializationIndex: credentials.initializationIndex,
      ),
      responseOpcode: YuwellCt5Commands.initializeCommand,
      parse: (response) =>
          _validate(() => YuwellCt5Responses.initialized(response)),
      persistAfterResponse: (_) => _persistCredentials(lowPowerPending),
    );
    await _enterLowPowerAndPublish(lowPowerPending);
  }

  Future<void> _enterLowPowerAndPublish(
    YuwellSessionCredentials lowPowerPending,
  ) async {
    if (lowPowerPending.phase != YuwellCredentialPhase.lowPowerPending) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.unresolvedWrite,
      );
    }
    final active = lowPowerPending.copyWith(
      phase: YuwellCredentialPhase.active,
    );
    await _activationWrite<void>(
      operation: YuwellActivationWrite.lowPower,
      frame: YuwellCt5Commands.enterLowPower(),
      responseOpcode: YuwellCt5Commands.lowPowerCommand,
      parse: (response) =>
          _validate(() => YuwellCt5Responses.lowPowerAccepted(response)),
      persistAfterResponse: (_) => _persistCredentials(active),
    );
    _publishReady(active);
  }

  Future<void> _setDateWithJournal() async {
    await _activationWrite<void>(
      operation: YuwellActivationWrite.setDate,
      frame: YuwellCt5Commands.setDate(_clock()),
      responseOpcode: YuwellCt5Commands.setDateCommand,
      parse: (response) =>
          _validate(() => YuwellCt5Responses.dateAccepted(response)),
    );
  }

  Future<void> _syncSavedSessionHistory() async {
    // Saved CT5 sessions enter ready state only after the exact reviewed
    // check-ID -> date -> history -> status -> low-power sequence completes.
    _autoHistoryStarted = true;
    // Initialization owns this internal history leg. Calling the public
    // syncHistory() here would wait for initialization and deadlock itself.
    await _syncHistoryCoalesced();
  }

  Future<void> _readBindingStatusForDiagnostic() async {
    try {
      final bound = await _readBindingStatus('binding-status');
      _emit(
        metadata: <String, String>{
          ..._snapshot.metadata,
          yuwellBindingStateMetadataKey: bound ? 'bound' : 'unbound',
        },
      );
    } catch (_) {
      _log(CgmLogLevel.warning, 'yuwell.binding-status.unavailable');
    }
  }

  Future<bool> _readBindingStatus(String operation) async {
    final response = await _sendAndWait(
      operation: operation,
      frame: YuwellCt5Commands.readBindingStatus(),
      responseOpcode: YuwellCt5Commands.bindingStatusCommand,
    );
    return _validate(() => YuwellCt5Responses.bindingStatus(response));
  }

  /// Best-effort binding-status read for non-V1150 evidence, sent right
  /// before this session fails closed on firmware.
  ///
  /// [YuwellCt5Commands.readBindingStatus] is the exact query
  /// [_beginFreshActivation] already sends first, unconditionally, before
  /// any state-changing write. It needs no prior write and no cipher —
  /// unlike [YuwellCt5Commands.querySensorCode], whose response
  /// [_completeActivationFromAuthenticated] decrypts with the cipher that
  /// `set-communication-id` derives, so it cannot be sent meaningfully
  /// before that write and is never sent pre-activation in any existing
  /// path. Sending this one extra query for a non-V1150 unit carries no
  /// more risk than what the reviewed V1150 flow already does
  /// unconditionally as its very first step. A failure here must never
  /// replace the primary `unsupportedFirmware` diagnostic with a less
  /// specific one, so it is swallowed and reported as "unknown" (null),
  /// not surfaced as its own exception.
  Future<bool?> _tryReadBindingStatusForEvidence() async {
    try {
      return await _readBindingStatus('binding-status-firmware-gate');
    } catch (_) {
      return null;
    }
  }

  Future<void> _requireUnboundForSetIdRecovery(String operation) async {
    final bound = await _readBindingStatus(operation);
    if (bound) {
      throw const YuwellSessionException(YuwellSessionFailureKind.alreadyBound);
    }
  }

  Future<T> _activationWrite<T>({
    required YuwellActivationWrite operation,
    required List<int> frame,
    required int responseOpcode,
    required T Function(List<int>) parse,
    String? preparedToken,
    Future<void> Function()? persistBeforeWrite,
    Future<void> Function(T value)? persistAfterResponse,
  }) async {
    if (_terminalFailure) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.writeOutcomeUnknown,
      );
    }
    if (_closing ||
        _snapshot.stage == CgmSyncStage.error ||
        _snapshot.stage == CgmSyncStage.disconnected) {
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    late final String token;
    if (preparedToken == null) {
      try {
        token = await _writeIntentStore.prepare(sensor.storageKey, operation);
      } catch (_) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.persistence,
        );
      }
    } else {
      token = preparedToken;
    }
    _debugYuwellTrace(_phase, operation.name, 'intent-prepared');
    var attempted = false;
    Completer<List<int>>? completer;
    try {
      if (persistBeforeWrite != null) {
        await persistBeforeWrite();
      }
      // Commit the uncertainty barrier before entering the BLE stack. A
      // remaining prepared intent therefore proves that no write occurred.
      await _writeIntentStore.markTransmitted(token);
      attempted = true;
      _stateChangingWritePostBarrier = true;
      _debugYuwellTrace(_phase, operation.name, 'intent-transmitted');
      completer = _registerPending(responseOpcode);
      _debugYuwellTrace(_phase, operation.name, 'send');
      await _writeFrame(frame);
      _debugYuwellTrace(_phase, operation.name, 'write-returned');
      final response = await completer.future.timeout(_timing.responseTimeout);
      _debugYuwellTrace(_phase, operation.name, 'response');
      final value = parse(response);
      if (_terminalFailure) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.writeOutcomeUnknown,
        );
      }
      if (persistAfterResponse != null) {
        await persistAfterResponse(value);
      }
      if (_terminalFailure) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.writeOutcomeUnknown,
        );
      }
      _debugYuwellTrace(_phase, operation.name, 'state-durable');
      // Resulting credentials/state are durable before the tombstone clears.
      // Once both are known, a later transport drop is reconnect-safe even if
      // removing the completed tombstone is still in progress.
      _stateChangingWritePostBarrier = false;
      await _writeIntentStore.markCompleted(token);
      _debugYuwellTrace(_phase, operation.name, 'intent-complete');
      if (_unresolvedIntent?.token == token) _unresolvedIntent = null;
      return value;
    } on TimeoutException {
      if (completer != null) _removePending(responseOpcode, completer);
      _stateChangingWritePostBarrier = true;
      await _markUnknown(token);
      _debugYuwellTrace(_phase, operation.name, 'outcome-unknown');
      throw const YuwellSessionException(
        YuwellSessionFailureKind.writeOutcomeUnknown,
      );
    } on YuwellSessionException {
      if (completer != null) _removePending(responseOpcode, completer);
      if (attempted) {
        _stateChangingWritePostBarrier = true;
        await _markUnknown(token);
        _debugYuwellTrace(_phase, operation.name, 'outcome-unknown');
        // Once the durable transmitted barrier is crossed, a transport or
        // response failure cannot prove whether the transmitter changed
        // state. Surface that ambiguity, rather than the transient transport
        // symptom, so no caller can safely retry the state-changing command.
        throw const YuwellSessionException(
          YuwellSessionFailureKind.writeOutcomeUnknown,
        );
      } else {
        await _completePreparedIntent(token);
      }
      rethrow;
    } catch (_) {
      if (completer != null) _removePending(responseOpcode, completer);
      if (attempted) {
        _stateChangingWritePostBarrier = true;
        await _markUnknown(token);
        _debugYuwellTrace(_phase, operation.name, 'outcome-unknown');
        throw const YuwellSessionException(
          YuwellSessionFailureKind.writeOutcomeUnknown,
        );
      }
      await _completePreparedIntent(token);
      throw const YuwellSessionException(YuwellSessionFailureKind.persistence);
    }
  }

  Future<void> _completePreparedIntent(String token) async {
    try {
      await _writeIntentStore.cancelPrepared(token);
    } catch (_) {
      // A conservative unresolved prepared intent prevents a later write.
    }
  }

  Future<void> _markUnknown(String token) async {
    try {
      await _writeIntentStore.markUnknown(token);
    } catch (_) {
      // The original durable prepared/transmitted record remains unresolved.
    }
  }

  Future<void> _persistCredentials(YuwellSessionCredentials credentials) async {
    try {
      await _credentialStore.write(sensor.storageKey, credentials);
      _credentials = credentials;
    } catch (_) {
      throw const YuwellSessionException(YuwellSessionFailureKind.persistence);
    }
  }

  Future<List<int>> _sendAndWait({
    required String operation,
    required List<int> frame,
    required int responseOpcode,
  }) async {
    final completer = _registerPending(responseOpcode);
    try {
      _debugYuwellTrace(_phase, operation, 'send');
      await _writeFrame(frame);
      _log(CgmLogLevel.debug, 'yuwell.command.$operation.sent');
      final response = await completer.future.timeout(_timing.responseTimeout);
      _debugYuwellTrace(_phase, operation, 'response');
      return response;
    } on TimeoutException {
      _removePending(responseOpcode, completer);
      throw const YuwellSessionException(
        YuwellSessionFailureKind.responseTimeout,
      );
    } catch (_) {
      _removePending(responseOpcode, completer);
      rethrow;
    }
  }

  Completer<List<int>> _registerPending(int opcode) {
    final completer = Completer<List<int>>();
    (_pending[opcode] ??= Queue<Completer<List<int>>>()).add(completer);
    return completer;
  }

  void _removePending(int opcode, Completer<List<int>> completer) {
    final queue = _pending[opcode];
    queue?.remove(completer);
    if (queue != null && queue.isEmpty) {
      _pending.remove(opcode);
    }
  }

  Future<void> _writeFrame(List<int> frame) {
    final connection = _connection;
    final characteristic = _writeCharacteristic;
    if (_closing ||
        _terminalFailure ||
        connection == null ||
        characteristic == null) {
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      if (_closing || _terminalFailure) {
        completer.completeError(
          const YuwellSessionException(YuwellSessionFailureKind.disconnected),
        );
        return;
      }
      try {
        await connection.write(
          characteristic,
          frame,
          withoutResponse: _writeWithoutResponse,
        );
        completer.complete();
      } catch (_) {
        completer.completeError(
          const YuwellSessionException(YuwellSessionFailureKind.connection),
        );
      }
    });
    return completer.future;
  }

  Future<void> _handleNotification(List<int> frame) async {
    if (_terminalFailure) return;
    if (frame.isEmpty) return;
    final opcode = frame.first;
    if (opcode == YuwellCt5Commands.liveCommand ||
        opcode == YuwellCt5Commands.alternateLiveCommand) {
      // The reference device expects this before parsing or persistence, and
      // also for duplicates and malformed recognized notifications.
      try {
        await _writeFrame(
          YuwellCt5Commands.acknowledgeLive(
            alternate: opcode == YuwellCt5Commands.alternateLiveCommand,
          ),
        );
      } catch (_) {
        // A live ACK is operational, not a persistent activation/config write.
        // Reconnect plus authenticated history can safely recover it.
        _publishFailure(YuwellSessionFailureKind.connection);
        await _connection?.disconnect();
        return;
      }
      if (_closing) return;
      if (_firmware == 'V1150' &&
          opcode != YuwellCt5Commands.alternateLiveCommand) {
        // V1150 is statically tied to the 0x45/0x47 alert17 branch. ACK first
        // for transmitter compatibility, then reject base-branch evidence so
        // it cannot contaminate the private contiguous record series.
        _publishFailure(YuwellSessionFailureKind.malformedResponse);
        await _connection?.disconnect();
        return;
      }
      try {
        final credentials = _credentials;
        if (credentials == null) return;
        final live = YuwellLiveFrame.parse(frame, cipher: credentials.cipher!);
        if (_recordOwner != null && (live.index < 0 || live.index >= 7695)) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.recordPersistence,
          );
        }
        _recordLayout = live.record.layout;
        if (_recordOwner != null) {
          await _serializePrivateRecordTransition(() async {
            _acceptPrivateLiveFrame(live);
          });
        } else {
          _storeRecord(
            live.index,
            live.record,
            isLive: true,
            opcode: live.opcode,
          );
        }
      } catch (error) {
        final kind = error is YuwellSessionException
            ? error.kind
            : YuwellSessionFailureKind.malformedResponse;
        _publishFailure(kind);
        await _connection?.disconnect();
      }
      return;
    }

    final queue = _pending[opcode];
    if (queue == null || queue.isEmpty) {
      _log(CgmLogLevel.debug, 'yuwell.notification.unexpected');
      return;
    }
    final completer = queue.removeFirst();
    if (queue.isEmpty) _pending.remove(opcode);
    if (!completer.isCompleted) {
      completer.complete(List<int>.unmodifiable(frame));
    }
  }

  void _dispatchNotification(List<int> frame) {
    late final Future<void> task;
    task = _runNotification(frame).whenComplete(() {
      _notificationTasks.remove(task);
    });
    _notificationTasks.add(task);
  }

  Future<void> _runNotification(List<int> frame) async {
    try {
      await _handleNotification(frame);
    } catch (_) {
      if (!_closing) _publishFailure(YuwellSessionFailureKind.notification);
    }
  }

  Future<T> _serializePrivateRecordTransition<T>(
    Future<T> Function() operation,
  ) {
    final result = Completer<T>();
    _privateRecordTransitionTail = _privateRecordTransitionTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  void _acceptPrivateLiveFrame(YuwellLiveFrame live) {
    final pending = _pendingPrivateObservedSlots.contains(live.index);
    if (pending) {
      final record = _pendingPrivateRecordByIndex[live.index];
      if (record == null ||
          !_sameBytes(record.rawBytes, live.record.rawBytes)) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.recordPersistence,
        );
      }
      return;
    }

    final committed = _observedRecordSlots.contains(live.index);
    if (committed) {
      final record = _recordByIndex[live.index];
      if (record == null ||
          !_sameBytes(record.rawBytes, live.record.rawBytes)) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.recordPersistence,
        );
      }
      _storeRecord(live.index, live.record, isLive: true, opcode: live.opcode);
      return;
    }

    final existing = _aheadLiveRecordByIndex[live.index];
    if (existing != null &&
        !_sameBytes(existing.rawBytes, live.record.rawBytes)) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
    if (existing == null &&
        _aheadLiveRecordByIndex.length >= _maximumAheadLiveRecords) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
    _aheadLiveRecordByIndex.putIfAbsent(live.index, () => live.record);
  }

  void _storeRecord(
    int index,
    YuwellHistoryRecord record, {
    required bool isLive,
    int? opcode,
    bool publish = true,
  }) {
    if (_terminalFailure) return;
    if (index < 0 || index >= 7695) {
      throw const YuwellProtocolFormatException('sample index is out of range');
    }
    // Retain the complete clean-room record only in memory for differential
    // validation. The raw record is never published or persisted as a
    // CgmReading; the separate engineering projector is fail-closed.
    final existing = _recordByIndex[index];
    final duplicate = existing != null;
    if (existing != null && !_sameBytes(existing.rawBytes, record.rawBytes)) {
      throw const YuwellProtocolFormatException(
        'conflicting record received for an existing sample index',
      );
    }
    _recordByIndex.putIfAbsent(index, () => record);
    if (!publish) return;
    final credentials = _credentials;
    final recordOpcode =
        opcode ??
        (isLive
            ? YuwellCt5Commands.alternateLiveCommand
            : YuwellCt5Commands.alternateHistoryCommand);
    final reading = credentials == null
        ? null
        : _engineeringOutput.observe(
            firmware: _firmware ?? '',
            transmitterComputed: credentials.transmitterComputed,
            credentialPhase: credentials.phase,
            opcode: recordOpcode,
            index: index,
            record: record,
            activationStartedAt: credentials.activationStartedAt,
            initializationIndex: credentials.initializationIndex,
          );
    if (reading != null) {
      _engineeringReadingByIndex[index] = reading;
    }
    final engineeringHistory = _orderedEngineeringHistory();
    final deferSessionComplete =
        !isLive && _snapshot.historySync.inProgress && record.errorCode == 5;
    if (deferSessionComplete) _historySawSessionComplete = true;
    final warmup = index < YuwellV1150EngineeringOutput.firstDisplayIndex;
    final status = reading == null
        ? _statusForRecord(record.errorCode, warmup: warmup)
        : 'Engineering glucose received (unverified)';
    _emit(
      // A record can arrive during authentication or history sync. It must
      // never promote the lifecycle to ready before the enclosing protocol
      // chain reaches its reviewed completion point.
      stage: _snapshot.stage,
      statusText: status,
      latestReading: engineeringHistory.isEmpty
          ? null
          : engineeringHistory.last,
      history: engineeringHistory.isEmpty ? null : engineeringHistory,
      health: _snapshot.health.copyWith(
        statusText: status,
        error: _isErrorStatus(record.errorCode),
        expired: deferSessionComplete
            ? _snapshot.health.expired
            : record.errorCode == 5,
        malfunction: record.errorCode == 1 || record.errorCode == 2,
      ),
      metadata: <String, String>{
        ..._snapshot.metadata,
        yuwellValidationStateMetadataKey: _engineeringValidationState,
        yuwellOutputModeMetadataKey: _engineeringOutputMode,
        'cgm.yuwell.last-source': isLive ? 'live' : 'history',
        if (duplicate) 'cgm.yuwell.last-record': 'duplicate',
      },
      clearLastError: true,
    );
  }

  void _publishReady(YuwellSessionCredentials credentials) {
    if (_terminalFailure) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.writeOutcomeUnknown,
      );
    }
    if (_closing ||
        _snapshot.stage == CgmSyncStage.error ||
        _snapshot.stage == CgmSyncStage.disconnected) {
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    _setPhase('P08', 'ready');
    final elapsed = credentials.activationStartedAt == null
        ? null
        : _clock()
              .toUtc()
              .difference(credentials.activationStartedAt!)
              .inMinutes;
    final warmup = elapsed != null && elapsed < 45;
    final engineeringHistory = _orderedEngineeringHistory();
    _emit(
      stage: CgmSyncStage.ready,
      statusText: warmup ? 'Sensor warmup in progress' : _readyOutputStatus,
      latestReading: engineeringHistory.isEmpty
          ? null
          : engineeringHistory.last,
      history: engineeringHistory.isEmpty ? null : engineeringHistory,
      sessionInfo: _snapshot.sessionInfo.copyWith(
        firmware: _firmware ?? '',
        sessionStart: credentials.activationStartedAt,
        warmupMinutes: 45,
        expectedLifetimeMinutes: 23085,
      ),
      metadata: <String, String>{
        ..._snapshot.metadata,
        yuwellValidationStateMetadataKey: _engineeringValidationState,
        yuwellOutputModeMetadataKey: _engineeringOutputMode,
      },
      clearLastError: true,
    );
    _log(CgmLogLevel.info, 'yuwell.session.ready');
    if (!_autoHistoryStarted) {
      _autoHistoryStarted = true;
      unawaited(_autoSyncHistory());
    }
  }

  List<CgmReading> _orderedEngineeringHistory() {
    final entries = _engineeringReadingByIndex.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return List<CgmReading>.unmodifiable(entries.map((entry) => entry.value));
  }

  String get _engineeringValidationState =>
      _validationStateForOutputPolicy(_engineeringOutput.policy);

  String get _engineeringOutputMode =>
      _outputModeForPolicy(_engineeringOutput.policy);

  String get _readyOutputStatus {
    if (_engineeringOutput.policy !=
        YuwellV1150GlucoseOutputPolicy.engineeringProvisional) {
      return 'Waiting for target validation data';
    }
    return _engineeringReadingByIndex.isEmpty
        ? 'Waiting for engineering glucose (unverified)'
        : 'Engineering glucose available (unverified)';
  }

  String _statusForRecord(int code, {required bool warmup}) => switch (code) {
    0 when warmup => 'Sensor warmup in progress',
    0 => 'Provisional record received; target validation required',
    1 => 'Sensor data error',
    2 => 'Sensor algorithm data error',
    4 => 'Sensor warmup completed',
    5 => 'Sensor session completed',
    11 => 'Sensor signal noise detected',
    12 => 'Sensor sensitivity attenuation detected',
    13 => 'Sensor take-off detected',
    14 => 'Sensor breakage detected',
    15 => 'Sensor touch detected',
    16 => 'Sensor flooding detected',
    102 => 'Sensor current is high',
    103 => 'Sensor current is low',
    105 => 'Sensor recovery state',
    _ => 'Unknown sensor status',
  };

  bool _isErrorStatus(int code) => switch (code) {
    1 || 2 || 11 || 12 || 13 || 14 || 15 || 16 || 102 || 103 => true,
    _ => false,
  };

  Future<void> _autoSyncHistory() async {
    try {
      await _syncHistoryCoalesced();
    } catch (_) {
      _log(CgmLogLevel.warning, 'yuwell.history.auto-failed');
    }
  }

  @override
  Future<void> refresh() => syncHistory();

  @override
  Future<void> refreshLiveData() async {
    await syncHistory();
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) {
    final inFlight = _publicHistoryFuture;
    if (inFlight != null) return inFlight;

    // Public callers must not race the current connection's authentication or
    // setup-date write. Initialization uses the private coalesced leg above
    // so its own setup history remains part of the existing chain.
    final queuedDuringInitialization = !_initializationFinished;
    late final Future<void> operation;
    operation = (_initialization ?? initialize())
        .then<void>((_) async {
          if (queuedDuringInitialization) {
            // Saved-session setup has already completed its internal history
            // leg when initialization resolves. Fresh activation starts the
            // same leg from _publishReady; await either one if still active
            // instead of launching a redundant history/low-power exchange.
            await _historyFuture;
            return;
          }
          await _syncHistoryCoalesced(
            requestedStartOffset: requestedStartOffset,
          );
        })
        .whenComplete(() {
          if (identical(_publicHistoryFuture, operation)) {
            _publicHistoryFuture = null;
          }
        });
    _publicHistoryFuture = operation;
    return operation;
  }

  Future<void> _syncHistoryCoalesced({int? requestedStartOffset}) {
    final inFlight = _historyFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> operation;
    operation = _syncHistoryOnce(requestedStartOffset: requestedStartOffset)
        .whenComplete(() {
          if (identical(_historyFuture, operation)) _historyFuture = null;
        });
    _historyFuture = operation;
    return operation;
  }

  Future<void> _syncHistoryOnce({int? requestedStartOffset}) async {
    if (_terminalFailure) {
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    _setPhase('P09', 'history');
    final credentials = _credentials;
    if (credentials == null ||
        credentials.phase != YuwellCredentialPhase.active ||
        _snapshot.stage == CgmSyncStage.disconnected) {
      throw const YuwellSessionException(YuwellSessionFailureKind.disconnected);
    }
    final recordOwner = _recordOwner;
    if (recordOwner != null) {
      _privateExpectedPrefixLength = recordOwner.state.nextIndex;
      _privatePrefixValidated = _privateExpectedPrefixLength == 0;
      _pendingPrivateRecordByIndex.clear();
      _pendingPrivateObservedSlots.clear();
      _pendingPrivatePublishIndexes.clear();
      _pendingAheadDrainIndexes.clear();
      _pendingPrivateEngineeringProofs.clear();
    }
    var cursor = recordOwner != null
        ? 0
        : requestedStartOffset == null
        ? _nextContiguousRecordIndex()
        : (requestedStartOffset + 1) ~/ 3;
    cursor = cursor.clamp(0, 7694);
    _emit(
      stage: CgmSyncStage.syncing,
      statusText: 'Syncing sensor history',
      historySync: _snapshot.historySync.copyWith(
        inProgress: true,
        startIndex: cursor,
        targetIndex: 7694,
      ),
    );
    var completed = false;
    try {
      for (
        var batch = 0;
        batch < _timing.maxHistoryBatches && cursor < 7695;
        batch++
      ) {
        final count = _historyBatchSize(cursor);
        final opcode = credentials.transmitterComputed
            ? YuwellCt5Commands.alternateHistoryCommand
            : YuwellCt5Commands.historyCommand;
        final response = await _sendAndWait(
          operation: 'history',
          frame: YuwellCt5Commands.readHistoryVariant(
            startIndex: cursor,
            recordCount: count,
            transmitterComputed: credentials.transmitterComputed,
          ),
          responseOpcode: opcode,
        );
        final historyFrame = _validate(
          () => YuwellHistoryFrame.parse(
            response,
            cipher: credentials.cipher!,
            expectedLayout: _recordLayout,
          ),
        );
        if (historyFrame.startIndex != cursor) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.malformedResponse,
          );
        }
        if (recordOwner == null) {
          _recordLayout = historyFrame.layout ?? _recordLayout;
          _markConsumedHistorySlots(historyFrame);
          for (final indexed in historyFrame.indexedRecords) {
            _recordLayout = indexed.record.layout;
            _storeRecord(
              indexed.index,
              indexed.record,
              isLive: false,
              opcode: historyFrame.opcode,
            );
          }
        } else {
          await _acceptPrivateHistoryFrame(recordOwner, historyFrame);
        }
        if (historyFrame.terminated || historyFrame.consumedSlots == 0) {
          completed = true;
          break;
        }
        cursor += historyFrame.consumedSlots;
        if (cursor >= 7695) {
          completed = true;
        }
      }
      if (!completed) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.historyIncomplete,
        );
      }
      if (recordOwner != null) {
        if (!_privatePrefixValidated) {
          throw const YuwellSessionException(
            YuwellSessionFailureKind.recordPersistence,
          );
        }
        await _serializePrivateRecordTransition(() async {
          try {
            await recordOwner.completeHistoryCycle();
          } catch (_) {
            throw const YuwellSessionException(
              YuwellSessionFailureKind.recordPersistence,
            );
          }
          _commitPendingPrivateHistory();
        });
      }
      _debugYuwellTrace(_phase, 'history-cycle', 'complete');
      // The reviewed CT5 chain always checks reset/binding state after a
      // completed history pull and then returns the transmitter to low-power
      // mode. Persist the pending phase before journaling 0x0F so a crash at
      // any boundary resumes this replay-safe command instead of skipping it.
      final stillBound = await _readBindingStatus('binding-status-history');
      if (!stillBound) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.authenticationRejected,
        );
      }
      final lowPowerPending = credentials.copyWith(
        phase: YuwellCredentialPhase.lowPowerPending,
      );
      await _persistCredentials(lowPowerPending);
      await _enterLowPowerAndPublish(lowPowerPending);
      final contiguousThrough = _nextContiguousRecordIndex() - 1;
      final completedSession = _historySawSessionComplete;
      _historySawSessionComplete = false;
      _emit(
        stage: CgmSyncStage.ready,
        statusText: completedSession
            ? 'Sensor session completed'
            : _readyOutputStatus,
        health: completedSession
            ? _snapshot.health.copyWith(
                statusText: 'Sensor session completed',
                expired: true,
              )
            : null,
        historySync: CgmHistorySyncState(
          inProgress: false,
          storedCount: _recordByIndex.length,
          totalAvailable: _recordByIndex.length,
          latestStoredOffset: contiguousThrough < 0
              ? null
              : (contiguousThrough + 1) * 3,
          startIndex: requestedStartOffset,
          targetIndex: 7694,
          lastSyncAt: _clock(),
        ),
      );
    } catch (error, stackTrace) {
      _historySawSessionComplete = false;
      _emit(historySync: _snapshot.historySync.copyWith(inProgress: false));
      final failure = error is YuwellSessionException
          ? error
          : const YuwellSessionException(
              YuwellSessionFailureKind.historyIncomplete,
            );
      _publishFailure(failure.kind, firmware: failure.firmware);
      if (identical(failure, error)) rethrow;
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _acceptPrivateHistoryFrame(
    YuwellRecordStateOwner owner,
    YuwellHistoryFrame frame,
  ) => _serializePrivateRecordTransition(() async {
    final end = frame.startIndex + frame.consumedSlots;
    if (frame.terminated && end < _privateExpectedPrefixLength) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
    if (frame.consumedSlots == 0) return;

    final recordsByIndex = <int, YuwellHistoryRecord>{
      for (final indexed in frame.indexedRecords) indexed.index: indexed.record,
    };
    for (var index = frame.startIndex; index < end; index++) {
      final live = _aheadLiveRecordByIndex[index];
      if (live == null) continue;
      final historical = recordsByIndex[index];
      if (historical == null ||
          !_sameBytes(live.rawBytes, historical.rawBytes)) {
        throw const YuwellSessionException(
          YuwellSessionFailureKind.recordPersistence,
        );
      }
    }

    try {
      await owner.acceptBatch(
        YuwellRecordBatch(
          startIndex: frame.startIndex,
          consumedSlots: frame.consumedSlots,
          records: frame.indexedRecords,
        ),
      );
    } catch (_) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }

    _pendingPrivateEngineeringProofs.add((
      startIndex: frame.startIndex,
      consumedSlots: frame.consumedSlots,
      opcode: frame.opcode,
      layout: frame.layout,
    ));

    for (var index = frame.startIndex; index < end; index++) {
      _pendingPrivateObservedSlots.add(index);
      if (_aheadLiveRecordByIndex.containsKey(index)) {
        _pendingAheadDrainIndexes.add(index);
      }
    }
    for (final indexed in frame.indexedRecords) {
      _pendingPrivateRecordByIndex[indexed.index] = indexed.record;
      if (indexed.index >= _privateExpectedPrefixLength) {
        _pendingPrivatePublishIndexes.add(indexed.index);
      }
    }
    if (end >= _privateExpectedPrefixLength) {
      _privatePrefixValidated = true;
    }
    if (!owner.isDirty && _privatePrefixValidated) {
      _commitPendingPrivateHistory();
    }
  });

  void _commitPendingPrivateHistory() {
    for (final index in _pendingPrivateObservedSlots) {
      _observedRecordSlots.add(index);
    }
    // Index-only proof is released only after the complete saved prefix has
    // matched and the owner has reached its required durability boundary.
    // Restored records below _privateExpectedPrefixLength are still stored
    // with publish=false and never enter the projector as records.
    for (final proof in _pendingPrivateEngineeringProofs) {
      _observeEngineeringHistorySlots(
        opcode: proof.opcode,
        layout: proof.layout,
        startIndex: proof.startIndex,
        consumedSlots: proof.consumedSlots,
      );
    }
    final indexes = _pendingPrivateRecordByIndex.keys.toList()..sort();
    for (final index in indexes) {
      final record = _pendingPrivateRecordByIndex[index]!;
      _recordLayout = record.layout;
      _storeRecord(
        index,
        record,
        isLive: false,
        opcode: YuwellCt5Commands.alternateHistoryCommand,
        publish: _pendingPrivatePublishIndexes.contains(index),
      );
    }
    for (final index in _pendingAheadDrainIndexes) {
      _aheadLiveRecordByIndex.remove(index);
    }
    _pendingPrivateRecordByIndex.clear();
    _pendingPrivateObservedSlots.clear();
    _pendingPrivatePublishIndexes.clear();
    _pendingAheadDrainIndexes.clear();
    _pendingPrivateEngineeringProofs.clear();
  }

  int _nextContiguousRecordIndex() {
    var index = 0;
    while (index < 7695 && _observedRecordSlots.contains(index)) {
      index++;
    }
    return index;
  }

  void _markConsumedHistorySlots(YuwellHistoryFrame frame) {
    final end = frame.startIndex + frame.consumedSlots;
    for (var index = frame.startIndex; index < end && index < 7695; index++) {
      // An all-FF record is an intentional empty slot. It advances the sensor
      // ordinal even though it must never become a glucose reading. Keep that
      // fact only in memory so a later retry resumes at the first true gap.
      _observedRecordSlots.add(index);
    }
    _observeEngineeringHistorySlots(
      opcode: frame.opcode,
      layout: frame.layout,
      startIndex: frame.startIndex,
      consumedSlots: frame.consumedSlots,
    );
  }

  void _observeEngineeringHistorySlots({
    required int opcode,
    required YuwellHistoryRecordLayout? layout,
    required int startIndex,
    required int consumedSlots,
  }) {
    final credentials = _credentials;
    if (credentials == null) return;
    _engineeringOutput.observeHistorySlots(
      firmware: _firmware ?? '',
      transmitterComputed: credentials.transmitterComputed,
      credentialPhase: credentials.phase,
      opcode: opcode,
      layout: layout,
      startIndex: startIndex,
      consumedSlots: consumedSlots,
      activationStartedAt: credentials.activationStartedAt,
      initializationIndex: credentials.initializationIndex,
    );
  }

  int _historyBatchSize(int cursor) {
    final mtu = _negotiatedMtu;
    final layout = _recordLayout;
    if (mtu == null || layout == null) return 1;
    final recordLength = switch (layout) {
      YuwellHistoryRecordLayout.compact11 => 11,
      YuwellHistoryRecordLayout.voltage15 => 15,
      YuwellHistoryRecordLayout.alert17 => 17,
    };
    final capacity = ((mtu - 7) ~/ recordLength).clamp(1, 255);
    return capacity.clamp(1, 7695 - cursor);
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      throw const YuwellSessionException(
        YuwellSessionFailureKind.unsupportedCapability,
      );

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async => throw const YuwellSessionException(
    YuwellSessionFailureKind.unsupportedCapability,
  );

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async {
    final diagnostics = <CgmDiagnosticItem>[
      CgmDiagnosticItem(
        key: 'yuwell-session',
        title: 'Yuwell session',
        summary: 'Identifier-free live driver status.',
        fields: <String, String>{
          'stage': _snapshot.stage.name,
          'firmwareBranch': _firmware == 'V1150' ? 'V1150' : 'unsupported',
          'credentialPhase': _credentials?.phase.name ?? 'none',
          'recordLayout': _recordLayout?.name ?? 'unknown',
          'validation':
              _snapshot.metadata[yuwellValidationStateMetadataKey] ?? 'unknown',
          'outputMode':
              _snapshot.metadata[yuwellOutputModeMetadataKey] ?? 'unknown',
        },
      ),
    ];
    _emit(diagnostics: diagnostics);
    return diagnostics;
  }

  @override
  Future<void> disconnect() async {
    if (_closing) return;
    _closing = true;
    _failPending(YuwellSessionFailureKind.disconnected);
    await _notificationSubscription?.cancel();
    Object? drainError;
    try {
      if (_notificationTasks.isNotEmpty) {
        await Future.wait<void>(List<Future<void>>.of(_notificationTasks));
      }
      try {
        await _historyFuture;
      } catch (_) {
        // Pending history was failed above and cannot outlive this close.
      }
      try {
        await _writeTail;
      } catch (_) {
        // Queued writes are failed by the closing guard above.
      }
      try {
        await _recordOwner?.drain();
      } catch (error) {
        drainError = error;
        _log(CgmLogLevel.error, 'yuwell.failure.recordPersistence');
      }
      await _connection?.disconnect();
    } finally {
      await _connectionSubscription?.cancel();
      try {
        await _initialization;
      } catch (_) {
        // The terminal snapshot below is authoritative for an explicit close.
      }
      _snapshot = _snapshot.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Disconnected',
      );
      if (!_snapshotController.isClosed) _snapshotController.add(_snapshot);
      try {
        await _snapshotController.close();
        await _logController.close();
      } finally {
        _releaseLease();
      }
    }
    if (drainError != null) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.recordPersistence,
      );
    }
  }

  void _releaseLease() {
    if (_leaseReleased) return;
    _leaseReleased = true;
    _releaseLeaseCallback();
  }

  Future<void> _cleanupAfterInitializationFailure() async {
    // Stop callbacks before closing a failed setup connection so the primary
    // closed diagnostic is not replaced by a generic disconnect event.
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    if (_notificationTasks.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_notificationTasks));
    }
    try {
      await _connection?.disconnect();
    } catch (_) {
      // Cleanup failure cannot make the already-published diagnosis safer.
    } finally {
      _connection = null;
    }
  }

  void _onConnectionState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected && !_closing) {
      _handleTransportDisconnect();
    }
  }

  void _handleTransportDisconnect() {
    final kind = _stateChangingWritePostBarrier
        ? YuwellSessionFailureKind.writeOutcomeUnknown
        : YuwellSessionFailureKind.disconnected;
    // Publish a terminal unknown-write state synchronously when the transport
    // drops after the durable uncertainty barrier. This prevents the host from
    // scheduling a transient reconnect while the async journal update is
    // still in progress.
    _publishFailure(kind);
    _failPending(kind);
  }

  void _failPending(YuwellSessionFailureKind kind) {
    for (final queue in _pending.values) {
      for (final completer in queue) {
        if (!completer.isCompleted) {
          completer.completeError(YuwellSessionException(kind));
        }
      }
    }
    _pending.clear();
  }

  String _parseFirmware(List<int> frame) {
    final digits = frame.sublist(6, 10);
    if (digits.any((value) => value < 0 || value > 9)) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.malformedResponse,
      );
    }
    return 'V${digits.join()}';
  }

  T _validate<T>(T Function() parser) {
    try {
      return parser();
    } on YuwellSessionException {
      rethrow;
    } catch (_) {
      throw const YuwellSessionException(
        YuwellSessionFailureKind.malformedResponse,
      );
    }
  }

  void _publishFailure(
    YuwellSessionFailureKind kind, {
    String? firmware,
    bool? bound,
  }) {
    if (_closing || _snapshotController.isClosed) return;
    if (_terminalFailure) return;
    _log(CgmLogLevel.error, 'yuwell.failure.${kind.name}');
    _debugYuwellTrace(_phase, 'session', 'failure-${kind.name}');
    if (kind == YuwellSessionFailureKind.disconnected &&
        _snapshot.stage == CgmSyncStage.error &&
        _snapshot.lastError != null) {
      // A disconnect can be the cleanup consequence of a more precise frame
      // or write failure. Preserve that primary closed diagnostic.
      return;
    }
    if (!_allowsAutomaticReconnect(kind)) _terminalFailure = true;
    final bindingState = switch (bound) {
      true => 'bound',
      false => 'unbound',
      null => null,
    };
    _emit(
      stage: CgmSyncStage.error,
      statusText: _failureStatus(kind),
      metadata: <String, String>{
        ..._snapshot.metadata,
        yuwellFailureCodeMetadataKey: kind.name,
        if (!_allowsAutomaticReconnect(kind))
          cgmAutomaticReconnectAllowedMetadataKey: 'false',
        if (kind == YuwellSessionFailureKind.activationRequired)
          yuwellActivationRequiredMetadataKey: 'true',
        if (kind == YuwellSessionFailureKind.activationRequired)
          'activationRequired': 'true',
        yuwellFirmwareMetadataKey: ?firmware,
        yuwellBindingStateMetadataKey: ?bindingState,
      },
      lastError: 'yuwell.session.${kind.name}',
    );
  }

  String _failureStatus(YuwellSessionFailureKind kind) => switch (kind) {
    YuwellSessionFailureKind.activationRequired =>
      'Activation confirmation required',
    YuwellSessionFailureKind.alreadyBound =>
      'Sensor is already bound; automatic takeover is disabled',
    YuwellSessionFailureKind.unsupportedFirmware =>
      'This firmware requires an unverified glucose algorithm',
    YuwellSessionFailureKind.unresolvedWrite ||
    YuwellSessionFailureKind.writeOutcomeUnknown =>
      'A previous sensor write has an unknown outcome; do not retry',
    YuwellSessionFailureKind.authenticationRejected =>
      'Saved sensor authentication was rejected',
    YuwellSessionFailureKind.historyIncomplete =>
      'Sensor history did not reach a reviewed completion point',
    YuwellSessionFailureKind.sessionInUse =>
      'This sensor already has an active OpenGlucose session',
    _ => 'Yuwell sensor connection failed',
  };

  void _emit({
    CgmSyncStage? stage,
    String? statusText,
    CgmReading? latestReading,
    List<CgmReading>? history,
    List<CgmDiagnosticItem>? diagnostics,
    CgmSessionInfo? sessionInfo,
    CgmHealthSnapshot? health,
    CgmHistorySyncState? historySync,
    Map<String, String>? metadata,
    String? lastError,
    bool clearLastError = false,
  }) {
    if (_closing || _snapshotController.isClosed) return;
    _snapshot = _snapshot.copyWith(
      stage: stage,
      statusText: statusText,
      latestReading: latestReading,
      history: history,
      diagnostics: diagnostics,
      sessionInfo: sessionInfo,
      health: health,
      historySync: historySync,
      metadata: metadata,
      lastError: lastError,
      clearLastError: clearLastError,
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
    }
  }

  void _log(CgmLogLevel level, String message) {
    if (_logController.isClosed) return;
    _logController.add(
      CgmLogEntry(timestamp: _clock(), level: level, message: message),
    );
  }

  void _setPhase(String phase, String operation) {
    _phase = phase;
    _debugYuwellTrace(phase, operation, 'enter');
    _emit(
      metadata: <String, String>{
        ..._snapshot.metadata,
        yuwellSessionPhaseMetadataKey: phase,
      },
    );
  }
}

String _validationStateForOutputPolicy(YuwellV1150GlucoseOutputPolicy policy) =>
    switch (policy) {
      YuwellV1150GlucoseOutputPolicy.disabled => 'target-unverified',
      YuwellV1150GlucoseOutputPolicy.engineeringProvisional =>
        'engineering-unverified',
    };

String _outputModeForPolicy(YuwellV1150GlucoseOutputPolicy policy) =>
    switch (policy) {
      YuwellV1150GlucoseOutputPolicy.disabled => 'disabled',
      YuwellV1150GlucoseOutputPolicy.engineeringProvisional =>
        'engineering-provisional',
    };

bool _allowsAutomaticReconnect(YuwellSessionFailureKind kind) => switch (kind) {
  YuwellSessionFailureKind.connection ||
  YuwellSessionFailureKind.notification ||
  YuwellSessionFailureKind.responseTimeout ||
  YuwellSessionFailureKind.disconnected => true,
  _ => false,
};

String _uuid(String value) => value.toLowerCase();

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
