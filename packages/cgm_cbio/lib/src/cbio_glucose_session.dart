/// Authenticated live session for the SIBIONICS / CBio GS1 sensor.
///
/// The session connects, enables FF31 notifications, authenticates the link,
/// then uses only the observed read path. It is deliberately fail-closed and
/// write-minimal:
///
///   * `03 F0 01 C` device information
///   * `19 01 00 <6 address octets> <16 credential bytes> C` authentication
///   * `06 0A LE16(index) 00 00 C` packed glucose read
///   * `06 08 LE16(index) 00 00 C` raw history / live read
///
/// Clock (`06 03`), activation (`07`), reset, threshold, calibration,
/// key-registration, and firmware frames are not sent here and are rejected
/// before the transport sees them. The vendor material is resolved once per
/// session from an injected [CbioCredentialSource], and the link credential
/// never reaches a log, a snapshot, or an exception message.
///
/// The sensor answers one `06 08` request with a stream of `08` batches pushed
/// to the same characteristic, so history is an ingest problem rather than a
/// request/response pair. Raw records remain private protocol state;
/// [CbioRawGlucoseRecord.isUnitVerified] stays false and no public glucose
/// reading is emitted until a normalized decoder is independently verified.
library;

import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'cbio_credentials.dart';
import 'cbio_crypto.dart';
import 'cbio_driver.dart';
import 'cbio_history_archive.dart';
import 'cbio_index_time_anchor.dart';
import 'cbio_frames.dart';
import 'cbio_session_checkpoint.dart';
import 'cbio_vendor_frames.dart';
import 'cbio_history_state.dart';
import 'cbio_private_state.dart';
import 'cbio_private_state_owner.dart';

/// Snapshot metadata key carrying the closed session phase.
const String cbioPhaseMetadataKey = 'cgm.cbio.phase';

/// Legacy app resume offset. Not sufficient to resume a CBIO counter era;
/// hosts must restore [cbioCheckpointMetadataKey] with the archived records.
const String cbioResumeOffsetMetadataKey = 'resumeOffset';

/// The unit marker every CBio surface must show until a reference measurement
/// settles the scale. The raw field is divided by ten by two independent
/// clients of this protocol; nothing has confirmed it against blood glucose.
const String cbioProvisionalUnitNotice =
    'Provisional reading. Sensor raw / 10, scale unverified.';

/// Closed phase names published in [cbioPhaseMetadataKey].
abstract final class CbioSessionPhase {
  static const String connecting = 'connecting';
  static const String authenticating = 'authenticating';
  static const String history = 'history';
  static const String live = 'live';
  static const String disconnected = 'disconnected';
  static const String failed = 'failed';
}

/// Why a masked frame did, or did not, reach the radio.
///
/// These are not interchangeable. A refused write is terminal, an exhausted
/// read budget is not, and a blocked frame never left the app - so the session
/// can fail closed on the one and carry on with the others.
enum CbioFrameWrite {
  /// The command characteristic accepted the frame.
  sent,

  /// The transport threw or timed out: the sensor never received the frame.
  failed,

  /// The session is closing or the link is gone; there is nothing to send to.
  unavailable,

  /// The frame was not one of the permitted commands, so it stayed in the app.
  blocked,

  /// The per-session read budget is spent.
  budgetExhausted,
}

/// Closed failure codes. They carry no payload and no credential.
abstract final class CbioSessionFailure {
  static const String connect = 'cbio.connect.failed';
  static const String topology = 'cbio.topology.failed';
  static const String authMaterial = 'cbio.auth.material';
  static const String authTimeout = 'cbio.auth.timeout';
  static const String authRejected = 'cbio.auth.rejected';
  static const String write = 'cbio.write.failed';
  static const String disconnected = 'cbio.disconnected';
  static const String invalidResume = 'cbio.resume.invalid';
  static const String missingWitness = 'cbio.resume.witness-missing';
  static const String counterRestart = 'cbio.counter.restart';
  static const String conflictingHistory = 'cbio.history.conflicting';
  static const String privateState = 'cbio.private-state.failed';
}

/// Whether a closed failure code is worth another automatic attempt.
///
/// The host will reconnect a link that dropped, timed out, or never came up.
/// It must not reconnect a failure that is reproduced byte for byte: a
/// credential this build cannot read, a credential the sensor already refused,
/// and a firmware that does not present the GS1 link surface this build
/// expects. Each of those is a decision for the user, not for a timer.
bool cbioFailureAllowsAutomaticReconnect(String code) => switch (code) {
  CbioSessionFailure.authMaterial ||
  CbioSessionFailure.authRejected ||
  CbioSessionFailure.invalidResume ||
  CbioSessionFailure.missingWitness ||
  CbioSessionFailure.counterRestart ||
  CbioSessionFailure.conflictingHistory ||
  CbioSessionFailure.privateState ||
  CbioSessionFailure.topology => false,
  _ => true,
};

/// Bounded timings for one session. Every window has a deadline.
final class CbioSessionTiming {
  const CbioSessionTiming({
    this.connectTimeout = const Duration(seconds: 12),
    this.discoveryTimeout = const Duration(seconds: 25),
    this.writeTimeout = const Duration(seconds: 15),
    this.authTimeout = const Duration(seconds: 12),
    this.historyWindow = const Duration(seconds: 180),
    this.historyIdleWindow = const Duration(seconds: 20),
    this.livePollInterval = const Duration(seconds: 60),
    this.liveResponseWindow = const Duration(seconds: 12),
    this.catchUpWindow = const Duration(seconds: 20),
    this.liveEdgeWindow = const Duration(minutes: 3),
    this.publishInterval = const Duration(milliseconds: 400),
    this.maxReadsPerSession,
    this.maxFrameBytes = 512,
  });

  final Duration connectTimeout;
  final Duration discoveryTimeout;
  final Duration writeTimeout;
  final Duration authTimeout;

  /// Total time one history window may spend ingesting pushed batches.
  final Duration historyWindow;

  /// How long the archive may stop growing before a history window closes.
  final Duration historyIdleWindow;

  final Duration livePollInterval;
  final Duration liveResponseWindow;

  /// Deadline for an app-requested catch-up read.
  final Duration catchUpWindow;

  /// How recent the newest stored record must be to count as the live edge.
  final Duration liveEdgeWindow;

  /// Coalescing window for snapshot publication.
  final Duration publishInterval;

  /// Optional bench ceiling. Production sessions have no lifetime read cap.
  /// The clock frame is not a read. Null leaves paced reads unlimited.
  final int? maxReadsPerSession;

  /// Ceiling for one reassembly buffer, in bytes.
  final int maxFrameBytes;

  CbioSessionTiming copyWith({
    Duration? connectTimeout,
    Duration? discoveryTimeout,
    Duration? writeTimeout,
    Duration? authTimeout,
    Duration? historyWindow,
    Duration? historyIdleWindow,
    Duration? livePollInterval,
    Duration? liveResponseWindow,
    Duration? catchUpWindow,
    Duration? liveEdgeWindow,
    Duration? publishInterval,
    int? maxReadsPerSession,
    int? maxFrameBytes,
  }) {
    return CbioSessionTiming(
      connectTimeout: connectTimeout ?? this.connectTimeout,
      discoveryTimeout: discoveryTimeout ?? this.discoveryTimeout,
      writeTimeout: writeTimeout ?? this.writeTimeout,
      authTimeout: authTimeout ?? this.authTimeout,
      historyWindow: historyWindow ?? this.historyWindow,
      historyIdleWindow: historyIdleWindow ?? this.historyIdleWindow,
      livePollInterval: livePollInterval ?? this.livePollInterval,
      liveResponseWindow: liveResponseWindow ?? this.liveResponseWindow,
      catchUpWindow: catchUpWindow ?? this.catchUpWindow,
      liveEdgeWindow: liveEdgeWindow ?? this.liveEdgeWindow,
      publishInterval: publishInterval ?? this.publishInterval,
      maxReadsPerSession: maxReadsPerSession ?? this.maxReadsPerSession,
      maxFrameBytes: maxFrameBytes ?? this.maxFrameBytes,
    );
  }
}

/// Closed in-memory causes; no record fields or caller strings are retained.
enum _CounterFailureReason {
  beforeCheckpoint('before-checkpoint'),
  witnessTimeMismatch('witness-time-mismatch'),
  archiveTimeConflict('archive-time-conflict');

  const _CounterFailureReason(this.value);
  final String value;
}

/// One coalesced read generation; null cursor is resolved when executed.
final class _PendingRead {
  _PendingRead(this.index, this.catchUp);

  int? index;
  bool catchUp;
  final done = Completer<void>();
}

/// One authenticated GS1 session: history ingest plus live polling.
final class CbioGlucoseSession implements CgmSession {
  CbioGlucoseSession({
    required DiscoveredSensor sensor,
    required BleTransport transport,
    CbioCredentialSource credentials = const CbioDefineCredentialSource(),
    this.timing = const CbioSessionTiming(),
    DateTime Function() clock = DateTime.now,
    CbioPrivateStateStore? privateStateStore,
    CbioPrivateStateOwner? privateState,
  }) : sensor = _publicSensor(sensor),
       _transport = transport,
       _credentials = credentials,
       _clock = clock,
       _privateStateStore = privateStateStore,
       _privateState = privateState,
       _inputCheckpoint = privateState != null
           ? privateState.resumeCheckpoint
           : privateStateStore == null
           ? sensor.metadata[cbioCheckpointMetadataKey]
           : null,
       _snapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting to the GS1 sensor',
         sensor: _publicSensor(sensor),
         capabilities: capabilities,
         sessionInfo: const CgmSessionInfo(
           manufacturer: 'Sibionics',
           model: 'GS1',
           warmupMinutes: 0,
           expectedLifetimeMinutes: 15 * 24 * 60,
         ),
         metadata: <String, String>{
           cbioPhaseMetadataKey: CbioSessionPhase.connecting,
           cbioLifecycleMetadataKey: 'unknown',
         },
       );

  /// The link set-up and read commands this driver may ever send.
  static const Set<String> allowedCommandKeys = <String>{
    '03f0',
    '1901',
    '060a',
    '0608',
  };

  static const CgmCapabilities capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsHistory: false,
    supportsRawHistory: false,
    supportsDiagnostics: true,
  );

  @override
  final DiscoveredSensor sensor;

  static DiscoveredSensor _publicSensor(DiscoveredSensor sensor) =>
      DiscoveredSensor.fromJson({
        ...sensor.toJson(),
        'advertisement': null,
        'metadata': {
          for (final entry in sensor.metadata.entries)
            if (entry.key != cbioCheckpointMetadataKey &&
                !entry.key.startsWith('cgm.cbio.clock.') &&
                !entry.key.startsWith('cgm.cbio.resume.'))
              entry.key: entry.value,
        },
      });

  final CbioSessionTiming timing;

  final BleTransport _transport;
  final CbioCredentialSource _credentials;
  final DateTime Function() _clock;
  final CbioPrivateStateStore? _privateStateStore;
  CbioPrivateStateOwner? _privateState;
  String? _inputCheckpoint;
  CbioSessionCheckpoint? _checkpoint;
  Timer? _privateSaveTimer;
  bool _witnessConfirmed = false;
  _CounterFailureReason? _counterFailureReason;
  final CbioHistoryArchive _uninitializedArchive = CbioHistoryArchive();
  CbioHistoryArchive get _archive =>
      _privateState?.acquisitionArchive ?? _uninitializedArchive;
  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();
  final List<int> _reassemblyBuffer = <int>[];

  late CgmSessionSnapshot _snapshot;
  CbioCredentials? _resolved;
  BleConnection? _connection;
  BleCharacteristicRef? _receive;
  BleCharacteristicRef? _command;
  BleCharacteristicRef? _serial;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BleConnectionState>? _connectionSubscription;
  Completer<int>? _authReply;
  Timer? _historyDeadlineTimer;
  Timer? _historyIdleTimer;
  Timer? _liveTimer;
  Timer? _liveResponseTimer;
  Timer? _catchUpTimer;
  Timer? _publishTimer;
  _PendingRead? _activeRead;
  _PendingRead? _pendingRead;
  Future<void>? _initialization;
  Future<bool>? _failureCleanup;
  Future<void>? _recoveryTransition;
  Future<void>? _disconnecting;
  CbioGlucoseSession? _successor;
  StreamSubscription<CgmSessionSnapshot>? _successorSnapshots;
  StreamSubscription<CgmLogEntry>? _successorLogs;
  Completer<void>? _liveWindow;
  String _phase = CbioSessionPhase.connecting;
  String _statusText = 'Connecting to the GS1 sensor';
  String? _lastError;
  CgmSyncStage _stage = CgmSyncStage.connecting;
  int _readsUsed = 0;
  CbioIndexTimeAnchor? _anchor;
  bool _anchorLogged = false;
  bool _budgetExhausted = false;
  bool _automaticReconnectAllowed = true;
  bool _closing = false;
  bool _linkDropped = false;
  bool _terminalFailure = false;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  /// Starts the bounded session. Never throws: a failure is published.
  Future<void> initialize() => _initialization ??= _initializeGuarded();

  Future<void> _initializeGuarded() async {
    try {
      await _initialize();
    } catch (error) {
      _fail(_failureCodeFor(error));
    }
  }

  Future<void> _initialize() async {
    if (_privateState == null) {
      _privateState = await CbioPrivateStateOwner.load(
        sensor.storageKey,
        _privateStateStore ?? CbioMemoryPrivateStateStore(),
      );
      if (_privateStateStore != null) {
        _inputCheckpoint = _privateState!.resumeCheckpoint;
      }
    }
    if (_closing) return;
    if (_privateState!.usesFullRecords) {
      await _privateState!.adoptFullRecords();
      if (_closing) return;
      _inputCheckpoint = _privateState!.resumeCheckpoint;
    }
    _checkpoint = _inputCheckpoint == null
        ? null
        : CbioSessionCheckpoint.decode(_inputCheckpoint!, sensor.storageKey);
    if (_inputCheckpoint != null && _checkpoint == null) {
      _fail(
        CbioSessionFailure.invalidResume,
        statusText: 'Saved sensor state needs recovery. History preserved.',
      );
      return;
    }
    // The material is resolved once per session and before the radio is
    // touched. A build that does not carry it can neither authenticate nor
    // unmask a reply, so it fails closed here as a configuration problem
    // instead of opening a link it could never use.
    final CbioCredentials credentials;
    try {
      credentials = _credentials.read();
    } on CbioCredentialUnavailable {
      _log(CgmLogLevel.error, 'cbio.credentials.unavailable');
      _fail(
        CbioSessionFailure.authMaterial,
        statusText: 'GS1 vendor material is not configured for this build',
      );
      return;
    }
    _resolved = credentials;
    if (_closing) return;
    _log(CgmLogLevel.info, 'cbio.connect.started');
    final connection = await _transport
        .connect(sensor.deviceId, timeout: timing.connectTimeout)
        .timeout(timing.connectTimeout);
    _connection = connection;
    _connectionSubscription = connection.connectionStates.listen(
      _onConnectionState,
      onError: (_) => _onTransportDrop(),
    );
    if (_closing) return;
    try {
      await connection.requestMtu(247).timeout(timing.writeTimeout);
    } on Object {
      if (_closing) return;
      // The MTU exchange is an ATT-level negotiation, not a vendor frame.
      _log(CgmLogLevel.debug, 'cbio.mtu.default');
    }
    if (_closing) return;
    final services = await connection.discoverServices().timeout(
      timing.discoveryTimeout,
    );
    if (_closing) return;
    _locateCharacteristics(services);
    final receive = _receive;
    final command = _command;
    if (receive == null ||
        !(receive.properties.notify || receive.properties.indicate)) {
      throw const CbioProtocolException(
        CbioProtocolFailure.missingNotifyCharacteristic,
      );
    }
    if (command == null || !command.properties.write) {
      throw const CbioProtocolException(
        CbioProtocolFailure.missingWriteCharacteristic,
      );
    }
    if (_closing) {
      return;
    }
    _notificationSubscription = connection
        .notifications(receive)
        .listen(_onNotification, onError: (_) => _onTransportDrop());
    await connection.setNotify(receive, true).timeout(timing.writeTimeout);
    if (_closing) return;
    _log(CgmLogLevel.info, 'cbio.ff31.subscribed');

    if (!await _authenticate()) {
      return;
    }
    if (_closing) {
      return;
    }
    // The vendor application issues one packed read first. This firmware
    // answers it with frozen zeros, so its content is ignored and the raw
    // path below carries every reading.
    final query = await _sendMasked(
      buildMaskedCbioGlucoseQuery(0, key: _streamKey),
      label: 'glucose-0a',
      isRead: true,
    );
    if (!_requireWritten(query)) {
      return;
    }
    _beginHistory(_historyStartIndex);
  }

  int get _historyStartIndex => _checkpoint?.index ?? 1;

  /// The resolved per-frame stream key. Reached only after [_initialize]
  /// resolved the material, so no call site can mask or unmask without it.
  List<int> get _streamKey => _resolved!.streamKey;

  Future<bool> _authenticate() async {
    _setPhase(
      CbioSessionPhase.authenticating,
      CgmSyncStage.connecting,
      'Authenticating with the sensor',
    );
    final material = _resolved?.authMaterial;
    if (material == null || material.length != 16) {
      _fail(CbioSessionFailure.authMaterial);
      return false;
    }
    final octets = await _resolveAddressOctets();
    if (_closing) return false;
    if (octets == null) {
      _fail(CbioSessionFailure.authMaterial);
      return false;
    }
    final reply = _authReply = Completer<int>();
    final wrote = await _sendMasked(
      buildMaskedCbioAuthentication(
        octets,
        key: _streamKey,
        material: material,
      ),
      label: 'auth',
      isRead: false,
    );
    if (!_requireWritten(wrote)) {
      _authReply = null;
      return false;
    }
    int result;
    try {
      result = await reply.future.timeout(timing.authTimeout);
    } on TimeoutException {
      _authReply = null;
      _fail(CbioSessionFailure.authTimeout);
      return false;
    }
    _authReply = null;
    if (_closing) return false;
    if (result != 1) {
      _fail(CbioSessionFailure.authRejected);
      return false;
    }
    _log(CgmLogLevel.info, 'cbio.auth.ok');
    return true;
  }

  /// The 2A25 value already arrives in the vendor's reversed order; the
  /// advertised identifier is reversed locally when that read is unavailable.
  Future<List<int>?> _resolveAddressOctets() async {
    final connection = _connection;
    if (connection == null) {
      return null;
    }
    try {
      // Some Android stacks omit the standard 2A25 entry from the service
      // list even though the vendor endpoint answers it. Keep the discovered
      // GS1 service context rather than fabricating an empty service UUID; a
      // failed or non-six-byte response still takes the validated MAC fallback.
      final serialCharacteristic =
          _serial ??
          (_command == null
              ? null
              : BleCharacteristicRef(
                  serviceUuid: _command!.serviceUuid,
                  characteristicUuid: CbioUuids.serial,
                  properties: const BleCharacteristicProperties(read: true),
                ));
      if (serialCharacteristic == null) {
        throw StateError('serial characteristic not discovered');
      }
      final serial = await connection
          .read(serialCharacteristic)
          .timeout(timing.writeTimeout);
      if (_closing) return null;
      if (serial.length == 6) {
        _log(CgmLogLevel.debug, 'cbio.address.serial');
        return serial;
      }
    } on Object {
      if (_closing) return null;
      _log(CgmLogLevel.debug, 'cbio.address.serial-unavailable');
    }
    final parts = sensor.deviceId.split(':');
    if (parts.length != 6) {
      return null;
    }
    final octets = <int>[
      for (final part in parts.reversed) int.tryParse(part, radix: 16) ?? -1,
    ];
    if (octets.any((octet) => octet < 0 || octet > 0xff)) {
      return null;
    }
    _log(CgmLogLevel.debug, 'cbio.address.advertised');
    return octets;
  }

  void _beginHistory(int startIndex) {
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _setPhase(
      CbioSessionPhase.history,
      CgmSyncStage.syncing,
      'Fetching sensor history',
      force: true,
    );
    unawaited(_startHistoryRead(startIndex));
  }

  Future<void> _startHistoryRead(int startIndex) async {
    try {
      final outcome = await _sendMasked(
        buildMaskedCbioRawQuery(startIndex, key: _streamKey),
        label: 'raw-history',
        isRead: true,
      );
      if (!_requireWritten(outcome) ||
          _closing ||
          _linkDropped ||
          _terminalFailure) {
        return;
      }
      _historyDeadlineTimer?.cancel();
      _historyDeadlineTimer = Timer(timing.historyWindow, _finishHistory);
      _restartHistoryIdleTimer();
    } on Object {
      _fail(CbioSessionFailure.write);
    }
  }

  void _restartHistoryIdleTimer() {
    if (_stage != CgmSyncStage.syncing) {
      return;
    }
    _historyIdleTimer?.cancel();
    _historyIdleTimer = Timer(timing.historyIdleWindow, _finishHistory);
  }

  void _finishHistory() {
    if (_closing || _linkDropped || _terminalFailure) {
      return;
    }
    if (_checkpoint != null && !_witnessConfirmed) {
      _fail(
        CbioSessionFailure.missingWitness,
        statusText:
            'Sensor history could not be reconciled. Saved history preserved.',
      );
      return;
    }
    _historyDeadlineTimer?.cancel();
    _historyDeadlineTimer = null;
    _historyIdleTimer?.cancel();
    _historyIdleTimer = null;
    _setPhase(
      CbioSessionPhase.live,
      CgmSyncStage.ready,
      'Live. Reading every minute.',
      force: true,
    );
    _scheduleLivePoll();
  }

  void _scheduleLivePoll() {
    if (_readsStopped || _activeRead != null || _liveTimer != null) {
      return;
    }
    _liveTimer = Timer(timing.livePollInterval, () {
      _liveTimer = null;
      if (_readsStopped) return;
      if (_pendingRead != null) {
        _startPendingRead();
      } else if (_stage == CgmSyncStage.ready) {
        unawaited(_pollLive());
      }
    });
  }

  bool get _readsStopped =>
      _closing || _linkDropped || _terminalFailure || _budgetExhausted;

  /// One bounded live read at the first index this session has not seen.
  Future<void> _pollLive() async {
    if (_closing || _linkDropped) {
      return;
    }
    if (_budgetExhausted) {
      _publishBudgetState();
      return;
    }
    await _enqueueRead();
  }

  int _nextIndex() => (_archive.newestIndex ?? 0) + 1;

  Future<void> _enqueueRead({int? index, bool catchUp = false}) {
    if (_readsStopped) return Future<void>.value();
    final active = _activeRead;
    if (active != null && (index == null || index >= active.index!)) {
      return active.done.future;
    }
    final pending = _pendingRead ??= _PendingRead(index, catchUp);
    if (index != null && (pending.index == null || index < pending.index!)) {
      pending.index = index;
    }
    pending.catchUp = pending.catchUp || catchUp;
    if (active == null && _liveTimer == null) _startPendingRead();
    return pending.done.future;
  }

  void _startPendingRead() {
    if (_readsStopped || _activeRead != null) return;
    final request = _pendingRead;
    if (request == null) return;
    _pendingRead = null;
    request.index ??= _nextIndex();
    _activeRead = request;
    unawaited(_runRead(request));
  }

  Future<void> _runRead(_PendingRead request) async {
    try {
      if (request.catchUp) {
        await _performCatchUp(request.index!);
      } else {
        await _performRead(request.index!, label: 'live-read');
      }
    } on Object catch (error, stack) {
      _liveWindow = null;
      if (!request.done.isCompleted) request.done.completeError(error, stack);
    } finally {
      if (!request.done.isCompleted) request.done.complete();
      if (identical(_activeRead, request)) _activeRead = null;
      if (_readsStopped) _settlePendingRead();
      if (!_readsStopped &&
          (_stage == CgmSyncStage.ready || _pendingRead != null)) {
        _scheduleLivePoll();
      }
    }
  }

  Future<void> _performRead(int index, {required String label}) async {
    if (_closing || _linkDropped || _terminalFailure) {
      return;
    }
    final window = _liveWindow = Completer<void>();
    final wrote = await _sendMasked(
      buildMaskedCbioRawQuery(index, key: _streamKey),
      label: label,
      isRead: true,
    );
    // A late platform result must neither replace a terminal failure nor arm
    // a response timer after the link was closed.
    if (_closing || _linkDropped || _terminalFailure) return;
    if (wrote != CbioFrameWrite.sent) {
      _liveWindow = null;
      _requireWritten(wrote);
      return;
    }
    _liveResponseTimer?.cancel();
    _liveResponseTimer = Timer(timing.liveResponseWindow, () {
      _liveResponseTimer = null;
      final pending = _liveWindow;
      _liveWindow = null;
      if (pending != null && !pending.isCompleted) {
        pending.complete();
      }
    });
    await window.future;
    if (_closing ||
        _linkDropped ||
        _terminalFailure ||
        _stage != CgmSyncStage.ready) {
      return;
    }
    _emit(force: true);
  }

  Future<void> _catchUp(int? startIndex) =>
      _enqueueRead(index: startIndex, catchUp: true);

  Future<void> _performCatchUp(int startIndex) async {
    if (_closing || _linkDropped || _terminalFailure) {
      return;
    }
    _catchUpTimer?.cancel();
    _catchUpTimer = Timer(timing.catchUpWindow, () {
      _catchUpTimer = null;
      if (_closing || _linkDropped || _terminalFailure) {
        return;
      }
      _emit(force: true);
    });
    _emit(force: true);
    try {
      await _performRead(startIndex, label: 'sync-read');
    } finally {
      _catchUpTimer?.cancel();
      _catchUpTimer = null;
      if (!_closing && !_linkDropped && !_terminalFailure) {
        _emit(force: true);
      }
    }
  }

  void _onConnectionState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected) {
      _onTransportDrop();
    }
  }

  void _onTransportDrop() {
    if (_closing || _linkDropped || _terminalFailure) {
      return;
    }
    _linkDropped = true;
    _traceMilestone(CbioSessionFailure.disconnected);
    _settlePendingRead();
    _cancelTimers();
    _setPhase(
      CbioSessionPhase.disconnected,
      CgmSyncStage.disconnected,
      'Sensor disconnected',
      error: CbioSessionFailure.disconnected,
      force: true,
    );
  }

  void _onNotification(List<int> bytes) {
    if (_closing ||
        _terminalFailure ||
        _linkDropped ||
        bytes.isEmpty ||
        _resolved == null) {
      return;
    }
    _reassemblyBuffer.addAll(bytes);
    if (_reassemblyBuffer.length > timing.maxFrameBytes) {
      _reassemblyBuffer.clear();
      _log(CgmLogLevel.warning, 'cbio.frame.oversized');
      return;
    }
    while (_reassemblyBuffer.length >= 5) {
      // The vendor mask restarts at stream offset zero for every frame, so the
      // length byte is only readable after removing the mask. Unmasking an
      // assembled buffer from offset zero is exact whenever the buffer starts
      // on a frame boundary; anything else fails the checksum below.
      final plaintext = unmaskCbioFrame(_reassemblyBuffer, key: _streamKey);
      final expected = plaintext[0] + 1;
      if (expected < 5 || expected > 255) {
        // A fragment boundary the vendor layout cannot describe: drop it
        // instead of guessing a record.
        _reassemblyBuffer.clear();
        _log(CgmLogLevel.warning, 'cbio.frame.unusable');
        return;
      }
      if (_reassemblyBuffer.length < expected) {
        return;
      }
      final frame = List<int>.from(plaintext.sublist(0, expected));
      _reassemblyBuffer.removeRange(0, expected);
      _handlePlaintext(frame);
    }
  }

  void _handlePlaintext(List<int> plaintext) {
    if (_terminalFailure || _linkDropped) return;
    if (plaintext.length < 5) {
      return;
    }
    if (plaintext[0] + 1 != plaintext.length) {
      return;
    }
    if ((plaintext.fold<int>(0, (sum, byte) => sum + byte) & 0xff) != 0) {
      return;
    }
    final opcode = plaintext[1];
    if (opcode == 0x01 && plaintext.length == 5) {
      final reply = _authReply;
      if (reply != null && !reply.isCompleted) {
        reply.complete(plaintext[2]);
      }
      return;
    }
    if (opcode != 0x08) {
      // The packed 0x0a path is frozen and zero on this firmware, and the
      // five-byte control frames carry no reading.
      return;
    }
    final checkpoint = _checkpoint;
    if (checkpoint != null) {
      final CbioRawBatch batch;
      try {
        batch = parseCbioRawDataFrame(plaintext);
      } on CbioFrameException {
        return;
      }
      // A suffix-only restore has no witnesses for earlier positions. A
      // rollback cannot be classified as historical backfill versus a new
      // counter era, so do not merge it into the resumed archive.
      if (batch.records.any(
        (record) => record.processed.index < checkpoint.index,
      )) {
        _fail(
          CbioSessionFailure.counterRestart,
          counterFailureReason: _CounterFailureReason.beforeCheckpoint,
          statusText:
              'Sensor counter changed. Saved history preserved; recovery required.',
        );
        return;
      }
      if (!_witnessConfirmed) {
        final witnesses = batch.records.where(
          (record) => record.processed.index == checkpoint.index,
        );
        if (witnesses.isEmpty) {
          _fail(
            CbioSessionFailure.missingWitness,
            statusText:
                'Sensor history could not be reconciled. Saved history preserved.',
          );
          return;
        }
        if (witnesses.single.processed.rawTime != checkpoint.rawTime) {
          _fail(
            CbioSessionFailure.counterRestart,
            counterFailureReason: _CounterFailureReason.witnessTimeMismatch,
            statusText:
                'Sensor counter changed. Saved history preserved; recovery required.',
          );
          return;
        }
        _witnessConfirmed = true;
        _anchor = checkpoint.anchor;
      }
    }
    if (_privateState?.usesFullRecords ?? false) {
      try {
        final batch = parseCbioRawDataFrame(plaintext);
        _privateState!.validateFullObservations([
          for (final row in batch.records)
            CbioRawGlucoseRecord(
              index: row.processed.index,
              rawTime: row.processed.rawTime,
              reindex: row.processed.reindex,
              rawTemperature: row.rawTemperature,
              rawDump: row.rawDump,
              rawPayload: row.rawPayload,
              rawProcessed: row.processed.rawWord,
            ),
        ]);
      } on CbioFrameException {
        return;
      } on FormatException {
        _fail(CbioSessionFailure.conflictingHistory);
        return;
      }
    }
    final status = _archive.ingest(plaintext);
    switch (status) {
      case CbioArchiveIngestStatus.accepted:
      case CbioArchiveIngestStatus.gap:
        _log(CgmLogLevel.debug, 'cbio.raw.records');
        _restartHistoryIdleTimer();
        _emit();
      case CbioArchiveIngestStatus.counterRestart:
        // The sensor's numbering restarted and a position came back on a
        // different counter. The archive refused the batch rather than
        // splicing the new stretch onto the old numbering, so say so where a
        // reader can see it: a silently absorbed restart looks exactly like a
        // sensor that stopped producing records.
        _log(CgmLogLevel.warning, 'cbio.raw.counter-restart');
        _fail(
          CbioSessionFailure.counterRestart,
          counterFailureReason: _CounterFailureReason.archiveTimeConflict,
          statusText:
              'Sensor counter changed. Saved history preserved; recovery required.',
        );
      case CbioArchiveIngestStatus.duplicate:
      case CbioArchiveIngestStatus.notRawBatch:
        break;
    }
  }

  Future<CbioFrameWrite> _sendMasked(
    List<int> masked, {
    required String label,
    required bool isRead,
  }) async {
    if (_closing || _linkDropped || _terminalFailure) {
      return CbioFrameWrite.unavailable;
    }
    final connection = _connection;
    final command = _command;
    if (connection == null || command == null) {
      return CbioFrameWrite.unavailable;
    }
    // Reachable only before the session resolved its material, and then no
    // frame is written.
    final CbioCredentials? resolved = _resolved;
    if (resolved == null) {
      return CbioFrameWrite.unavailable;
    }
    final plaintext = unmaskCbioFrame(masked, key: resolved.streamKey);
    if (!_isAllowedCommand(plaintext)) {
      // Defence in depth: an unrecognised command never reaches the radio.
      _log(CgmLogLevel.error, 'cbio.write.blocked:$label');
      return CbioFrameWrite.blocked;
    }
    final maxReads = timing.maxReadsPerSession;
    if (isRead && maxReads != null && _readsUsed >= maxReads) {
      _budgetExhausted = true;
      _log(CgmLogLevel.warning, 'cbio.read.budget');
      return CbioFrameWrite.budgetExhausted;
    }
    if (isRead) {
      _readsUsed += 1;
    }
    try {
      await connection
          .write(command, masked, withoutResponse: false)
          .timeout(timing.writeTimeout);
      if (_closing || _linkDropped || _terminalFailure) {
        return CbioFrameWrite.unavailable;
      }
      _log(CgmLogLevel.info, 'cbio.write.$label');
      return CbioFrameWrite.sent;
    } on Object {
      if (_closing || _linkDropped || _terminalFailure) {
        return CbioFrameWrite.unavailable;
      }
      _log(CgmLogLevel.error, 'cbio.write.failed:$label');
      return CbioFrameWrite.failed;
    }
  }

  /// Ends setup when a frame the sensor must receive never reached the radio.
  ///
  /// Returning quietly here is what left a refused write parked in the
  /// connecting stage with no terminal state and no code to report.
  bool _requireWritten(CbioFrameWrite outcome) {
    if (outcome == CbioFrameWrite.sent) {
      return true;
    }
    if (outcome == CbioFrameWrite.failed) {
      _fail(CbioSessionFailure.write);
    }
    if (outcome == CbioFrameWrite.budgetExhausted) {
      _publishBudgetState();
    }
    return false;
  }

  static bool _isAllowedCommand(List<int> plaintext) {
    if (plaintext.length < 2) {
      return false;
    }
    final key =
        '${plaintext[0].toRadixString(16).padLeft(2, '0')}'
        '${plaintext[1].toRadixString(16).padLeft(2, '0')}';
    return allowedCommandKeys.contains(key);
  }

  void _locateCharacteristics(List<BleService> services) {
    _receive = null;
    _command = null;
    _serial = null;
    final serviceUuid = CbioUuids.canonical(CbioUuids.service);
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = CbioUuids.canonical(characteristic.characteristicUuid);
        if (uuid == CbioUuids.serial && _serial == null) {
          _serial = characteristic.copyWith(serviceUuid: service.uuid);
        } else if (CbioUuids.canonical(service.uuid) != serviceUuid) {
          continue;
        } else if (uuid == CbioUuids.receive) {
          _receive = characteristic;
        } else if (uuid == CbioUuids.command) {
          _command = characteristic;
        }
      }
    }
  }

  // Public history describes normalized glucose, not private raw acquisition.
  CgmHistorySyncState get _historySyncState => const CgmHistorySyncState();

  /// The history as published. A record carries a timestamp only when the
  /// session holds an anchor that covers its position; the counter is never
  /// the source of that timestamp, only the index the anchor steps from.
  List<CgmReading> _historyReadingsFor(CbioIndexTimeAnchor? anchor) =>
      <CgmReading>[
        for (final record in _archive.records)
          CgmReading(
            // The archive publishes no glucose unit, so the session publishes
            // the unverified /10 scale of the record's own raw field. This is
            // the same number the hero renders; it is deliberately not a
            // conversion into mg/dL, which no reference measurement supports.
            valueMgdl: record.rawPayloadScaled,
            source: CgmRecordSource.raw,
            sensorMinute: record.index,
            recordedAt: anchor != null && anchor.coversIndex(record.index)
                ? anchor.timeForIndex(record.index)
                : null,
            rawValue: record.rawPayload,
            isDisplayProvisional: true,
          ),
      ];

  /// Reuses a previously witnessed anchor only while every covered raw stamp
  /// remains an exact continuation. Fresh epoch-less records never create one.
  CbioIndexTimeAnchor? _publishAnchor() {
    final previous = _anchor;
    final anchor =
        previous != null &&
            _archive.records.every(
              (record) =>
                  !previous.coversIndex(record.index) ||
                  previous.timeForIndex(record.index).millisecondsSinceEpoch ~/
                          1000 ==
                      record.rawTime,
            )
        ? previous
        : null;
    _anchor = anchor;
    if (anchor != null && !_anchorLogged) {
      _anchorLogged = true;
      _log(CgmLogLevel.info, 'cbio.clock.anchor');
    }
    return anchor;
  }

  void _setPhase(
    String phase,
    CgmSyncStage stage,
    String statusText, {
    String? error,
    bool force = false,
  }) {
    _phase = phase;
    _stage = stage;
    _statusText = statusText;
    _lastError = error;
    _emit(force: true);
  }

  void _emit({bool force = false}) {
    if (_snapshotController.isClosed || _successor != null) {
      return;
    }
    void publish() {
      if (_snapshotController.isClosed || _successor != null) return;
      final anchor = _publishAnchor();
      final fullInputs = _privateState?.usesFullRecords ?? false;
      final history = fullInputs
          ? const <CgmReading>[]
          : _historyReadingsFor(anchor);
      final newest = _archive.records.lastOrNull;
      final canAdvance =
          !_terminalFailure &&
          newest != null &&
          _archive.contiguous &&
          _archive.oldestIndex == _historyStartIndex;
      final checkpoint = canAdvance
          ? CbioSessionCheckpoint(
              sensorKey: sensor.storageKey,
              index: newest.index,
              rawTime: newest.rawTime,
              anchor: anchor,
            ).encode()
          : _privateState?.resumeCheckpoint ?? _inputCheckpoint;
      if (!_terminalFailure &&
          (_checkpoint == null || _witnessConfirmed) &&
          checkpoint != null &&
          (fullInputs ? canAdvance : history.isNotEmpty)) {
        try {
          if (fullInputs) {
            _privateState!.acceptFullRecords(
              _archive.records,
              admittedInputCheckpoint: _inputCheckpoint ?? '',
              currentCheckpoint: checkpoint,
            );
          } else {
            _privateState?.accept(
              CbioHistoryState(
                sensorKey: sensor.storageKey,
                checkpoint: checkpoint,
                history: history,
              ),
            );
          }
          if (!_closing && !_linkDropped) {
            _privateSaveTimer ??= Timer(const Duration(milliseconds: 900), () {
              _privateSaveTimer = null;
              unawaited(
                flushPrivateState().catchError((Object _) {
                  _log(CgmLogLevel.error, 'cbio.private-state.write-failed');
                }),
              );
            });
          }
        } on FormatException {
          _fail(CbioSessionFailure.conflictingHistory);
          return;
        }
      }
      _snapshot = _snapshot.copyWith(
        stage: _stage,
        statusText: _statusText,
        history: const <CgmReading>[],
        rawHistory: const <CgmReading>[],
        latestReading: null,
        historySync: _historySyncState,
        metadata: <String, String>{
          cbioPhaseMetadataKey: _phase,
          cbioLifecycleMetadataKey: 'unknown',
          if (_terminalFailure &&
              _lastError == CbioSessionFailure.counterRestart &&
              _counterFailureReason != null)
            'cgm.cbio.resume.counterFailureReason':
                _counterFailureReason!.value,
          if (!_automaticReconnectAllowed)
            cgmAutomaticReconnectAllowedMetadataKey: 'false',
        },
        lastError: _lastError,
        clearLastError: _lastError == null,
      );
      _snapshotController.add(_snapshot);
    }

    if (force || timing.publishInterval == Duration.zero) {
      publish();
      return;
    }
    _publishTimer ??= Timer(timing.publishInterval, () {
      _publishTimer = null;
      publish();
    });
  }

  void _publishBudgetState() {
    if (!_closing && !_linkDropped && !_terminalFailure) {
      _setPhase(
        _phase,
        _stage,
        'Sensor reads paused. Read budget reached.',
        force: true,
      );
    }
  }

  void _log(CgmLogLevel level, String message) {
    if (_logController.isClosed) {
      return;
    }
    _traceMilestone(message);
    _logController.add(
      CgmLogEntry(timestamp: _clock().toUtc(), level: level, message: message),
    );
  }

  void _fail(
    String code, {
    String statusText = 'Connection failed',
    _CounterFailureReason? counterFailureReason,
  }) {
    if (_terminalFailure || _closing) {
      return;
    }
    _terminalFailure = true;
    _counterFailureReason = code == CbioSessionFailure.counterRestart
        ? counterFailureReason
        : null;
    _traceFailure(code);
    _settlePendingRead();
    _cancelTimers();
    if (!cbioFailureAllowsAutomaticReconnect(code)) {
      _automaticReconnectAllowed = false;
    }
    _setPhase(
      CbioSessionPhase.failed,
      CgmSyncStage.error,
      statusText,
      error: code,
      force: true,
    );
    _failureCleanup ??= _releaseConnectionAfterFailure();
    if (code == CbioSessionFailure.counterRestart &&
        counterFailureReason == _CounterFailureReason.witnessTimeMismatch &&
        (_privateState?.canRecoverWitnessMismatch ?? false)) {
      _recoveryTransition ??= _recoverAfterWitnessMismatch();
    }
  }

  Future<void> _recoverAfterWitnessMismatch() async {
    // Old terminal state is never reset. Only successful, completed cleanup
    // authorizes a new acquisition, and the pending capsule precedes its BLE.
    if (!await _failureCleanup! || _closing) return;
    final owner = _privateState!;
    try {
      await owner.recoverWitnessMismatch();
    } on Object {
      // Keep the exact original failure; a failed write cannot authorize BLE.
      return;
    }
    if (_closing) return;
    final successor = CbioGlucoseSession(
      sensor: sensor,
      transport: _transport,
      credentials: _credentials,
      timing: timing,
      clock: _clock,
      privateState: owner,
    );
    _successor = successor;
    _privateState = null; // Ownership now belongs solely to the new session.
    _successorSnapshots = successor.snapshots.listen((snapshot) {
      if (_closing || _snapshotController.isClosed) return;
      _snapshot = snapshot;
      _snapshotController.add(snapshot);
    });
    _successorLogs = successor.logs.listen((entry) {
      if (!_closing && !_logController.isClosed) _logController.add(entry);
    });
    _snapshot = successor.currentSnapshot;
    _snapshotController.add(_snapshot);
    await successor.initialize();
  }

  void _traceMilestone(String message) {
    if (!const bool.fromEnvironment('CBIO_FAILURE_TRACE')) return;
    final token = switch (message) {
      'cbio.connect.started' ||
      'cbio.ff31.subscribed' ||
      'cbio.auth.ok' ||
      'cbio.write.raw-history' ||
      CbioSessionFailure.disconnected => message,
      _ => null,
    };
    if (token == null) return;
    try {
      // Closed milestones only; never print other log text or native details.
      // ignore: avoid_print
      print('CBIO milestone=$token');
    } on Object {
      // Observation cannot interrupt acquisition or transport-drop handling.
    }
  }

  void _traceFailure(String code) {
    // Private diagnostic builds only. Never forward arbitrary strings from
    // transport exceptions, status text, identifiers, or acquired records.
    if (!const bool.fromEnvironment('CBIO_FAILURE_TRACE')) return;
    final closedCode = switch (code) {
      CbioSessionFailure.connect ||
      CbioSessionFailure.topology ||
      CbioSessionFailure.authMaterial ||
      CbioSessionFailure.authTimeout ||
      CbioSessionFailure.authRejected ||
      CbioSessionFailure.write ||
      CbioSessionFailure.disconnected ||
      CbioSessionFailure.invalidResume ||
      CbioSessionFailure.missingWitness ||
      CbioSessionFailure.counterRestart ||
      CbioSessionFailure.conflictingHistory ||
      CbioSessionFailure.privateState => code,
      _ => null,
    };
    if (closedCode == null) return;
    final reason = _counterFailureReason;
    try {
      // ignore: avoid_print
      print(
        'CBIO failure=$closedCode'
        '${reason == null ? '' : ' counterFailureReason=${reason.value}'}',
      );
    } on Object {
      // Observation must not prevent publishing the failure or releasing BLE.
    }
  }

  Future<bool> _releaseConnectionAfterFailure() async {
    var succeeded = true;
    final notifications = _notificationSubscription;
    _notificationSubscription = null;
    final states = _connectionSubscription;
    _connectionSubscription = null;
    final connection = _connection;
    _connection = null;
    _receive = null;
    _command = null;
    _serial = null;
    try {
      await notifications?.cancel();
    } on Object {
      succeeded = false;
    }
    try {
      await states?.cancel();
    } on Object {
      succeeded = false;
    }
    try {
      await connection?.disconnect();
    } on Object {
      succeeded = false;
    }
    return succeeded;
  }

  void _settlePendingRead() {
    for (final request in [_activeRead, _pendingRead]) {
      if (request != null && !request.done.isCompleted) {
        request.done.complete();
      }
    }
    _pendingRead = null;
    _liveResponseTimer?.cancel();
    _liveResponseTimer = null;
    final pending = _liveWindow;
    _liveWindow = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  static String _failureCodeFor(Object error) => switch (error) {
    CbioPrivateStateFailure() => CbioSessionFailure.privateState,
    CbioProtocolException() => CbioSessionFailure.topology,
    TimeoutException() => CbioSessionFailure.connect,
    _ => CbioSessionFailure.connect,
  };

  void _cancelTimers() {
    _privateSaveTimer?.cancel();
    _privateSaveTimer = null;
    _historyDeadlineTimer?.cancel();
    _historyDeadlineTimer = null;
    _historyIdleTimer?.cancel();
    _historyIdleTimer = null;
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveResponseTimer?.cancel();
    _liveResponseTimer = null;
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _publishTimer?.cancel();
    _publishTimer = null;
  }

  /// Drains private writes without exposing protocol records to the host.
  Future<void> flushPrivateState() async {
    final successor = _successor;
    if (successor != null) return successor.flushPrivateState();
    _privateSaveTimer?.cancel();
    _privateSaveTimer = null;
    try {
      await _privateState?.flush();
    } on Object {
      _fail(CbioSessionFailure.privateState);
      rethrow;
    }
  }

  @override
  Future<void> refresh() => refreshLiveData();

  @override
  Future<void> refreshLiveData() async {
    if (_closing) return;
    final successor = _successor;
    if (successor != null) return successor.refreshLiveData();
    if (_closing || _linkDropped || _stage != CgmSyncStage.ready) {
      return;
    }
    await _pollLive();
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    if (_closing) return;
    final successor = _successor;
    if (successor != null) {
      return successor.syncHistory(
        includeRawHistory: includeRawHistory,
        requestedStartOffset: requestedStartOffset,
      );
    }
    if (_closing || _linkDropped) {
      return;
    }
    await _catchUp(requestedStartOffset);
  }

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) {
    return Future<void>.error(
      UnsupportedError('Cbio calibration is not supported.'),
    );
  }

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      _successor != null
      ? _successor!.refreshDiagnostics()
      : <CgmDiagnosticItem>[
          CgmDiagnosticItem(
            key: 'cgm.session',
            title: 'Sensor connection',
            summary: _statusText,
            fields: <String, String>{'phase': _phase, 'failure': ?_lastError},
          ),
        ];

  @override
  Future<void> disconnect() => _disconnecting ??= _disconnect().whenComplete(
    () => _disconnecting = null,
  );

  void _requestClose() {
    if (_closing) return;
    // Publish the last coalesced acquisition into private state before closing.
    _emit(force: true);
    _closing = true;
    _cancelTimers();
    _settlePendingRead();
    final authReply = _authReply;
    if (authReply != null && !authReply.isCompleted) authReply.complete(0);
    // Stop the successor synchronously, without releasing its owner or link
    // while initialization is still awaiting a native operation.
    _successor?._requestClose();
  }

  Future<void> _disconnect() async {
    _requestClose();
    await _initialization;
    await _recoveryTransition;
    await (_failureCleanup ??= _releaseConnectionAfterFailure());
    await _successor?.disconnect();
    await _successorSnapshots?.cancel();
    await _successorLogs?.cancel();
    _authReply = null;
    _stage = CgmSyncStage.disconnected;
    _phase = CbioSessionPhase.disconnected;
    _statusText = 'Disconnected';
    _snapshot = _snapshot.copyWith(
      stage: _stage,
      statusText: _statusText,
      metadata: <String, String>{
        ..._snapshot.metadata,
        cbioPhaseMetadataKey: _phase,
      },
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
      await _snapshotController.close();
    }
    if (!_logController.isClosed) {
      await _logController.close();
    }
    await flushPrivateState();
    await _privateState?.close();
  }
}
