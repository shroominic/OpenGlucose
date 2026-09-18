/// Authenticated live session for the SIBIONICS / CBio GS1 sensor.
///
/// The session follows the vendor link in the order the SiSensing application
/// uses it: connect, enable FF31 notifications, authenticate the link, set the
/// sensor clock once, then read glucose. It is deliberately fail-closed and
/// write-minimal:
///
///   * `03 F0 01 C` device information
///   * `19 01 00 <6 address octets> <16 credential bytes> C` authentication
///   * `06 03 LE32(epoch) C` vendor clock, sent at most once per session
///   * `06 0A LE16(index) 00 00 C` packed glucose read
///   * `06 08 LE16(index) 00 00 C` raw history / live read
///
/// Activation (`07`), reset, threshold, calibration, key-registration, and
/// firmware frames are not built here and are rejected before the transport
/// sees them. The vendor material is resolved once per session from an injected
/// [CbioCredentialSource], and the link credential never reaches a log, a
/// snapshot, or an exception message.
///
/// The sensor answers one `06 08` request with a stream of `08` batches pushed
/// to the same characteristic, so history is an ingest problem rather than a
/// request/response pair. Every raw record carries a derived, explicitly
/// unverified glucose value; [CbioRawGlucoseRecord.isUnitVerified] stays false
/// and every emitted [CgmReading] is marked provisional.
library;

import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'cbio_credentials.dart';
import 'cbio_crypto.dart';
import 'cbio_driver.dart';
import 'cbio_history_archive.dart';
import 'cbio_index_time_anchor.dart';
import 'cbio_vendor_frames.dart';

/// Snapshot metadata key carrying the closed session phase.
const String cbioPhaseMetadataKey = 'cgm.cbio.phase';

/// Sensor-provided resume offset left by the app for the next connection.
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

/// Closed failure codes. They carry no payload and no credential.
abstract final class CbioSessionFailure {
  static const String connect = 'cbio.connect.failed';
  static const String topology = 'cbio.topology.failed';
  static const String authMaterial = 'cbio.auth.material';
  static const String authTimeout = 'cbio.auth.timeout';
  static const String authRejected = 'cbio.auth.rejected';
  static const String write = 'cbio.write.failed';
  static const String disconnected = 'cbio.disconnected';
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
    this.maxReadsPerSession = 480,
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

  /// Hard ceiling on reads inside one session. The clock frame is not a read.
  final int maxReadsPerSession;

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

/// One authenticated GS1 session: history ingest plus live polling.
final class CbioGlucoseSession implements CgmSession {
  CbioGlucoseSession({
    required this.sensor,
    required BleTransport transport,
    CbioCredentialSource credentials = const CbioDefineCredentialSource(),
    this.timing = const CbioSessionTiming(),
    DateTime Function() clock = DateTime.now,
  }) : _transport = transport,
       _credentials = credentials,
       _clock = clock,
       _resumeOffset = _resumeOffsetFrom(sensor),
       _snapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting to the GS1 sensor',
         sensor: sensor,
         capabilities: capabilities,
         sessionInfo: const CgmSessionInfo(
           manufacturer: 'Sibionics',
           model: 'GS1',
           warmupMinutes: 0,
           expectedLifetimeMinutes: 15 * 24 * 60,
         ),
         metadata: const <String, String>{
           cbioPhaseMetadataKey: CbioSessionPhase.connecting,
         },
       );

  /// The link set-up and read commands this driver may ever send.
  static const Set<String> allowedCommandKeys = <String>{
    '03f0',
    '1901',
    '0603',
    '060a',
    '0608',
  };

  static const CgmCapabilities capabilities = CgmCapabilities(
    supportsDirectBle: true,
    supportsHistory: true,
    supportsRawHistory: true,
    supportsDiagnostics: true,
  );

  @override
  final DiscoveredSensor sensor;

  final CbioSessionTiming timing;

  final BleTransport _transport;
  final CbioCredentialSource _credentials;
  final DateTime Function() _clock;
  final int? _resumeOffset;
  final CbioHistoryArchive _archive = CbioHistoryArchive();
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
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BleConnectionState>? _connectionSubscription;
  Completer<int>? _authReply;
  Timer? _historyDeadlineTimer;
  Timer? _historyIdleTimer;
  Timer? _liveTimer;
  Timer? _liveResponseTimer;
  Timer? _catchUpTimer;
  Timer? _publishTimer;
  Future<void>? _initialization;
  Completer<void>? _liveWindow;
  DateTime? _lastSyncAt;
  String _phase = CbioSessionPhase.connecting;
  String _statusText = 'Connecting to the GS1 sensor';
  String? _lastError;
  CgmSyncStage _stage = CgmSyncStage.connecting;
  int _readsUsed = 0;
  bool _clockWritten = false;
  int? _clockReferenceEpochSeconds;
  CbioIndexTimeAnchor? _anchor;
  bool _anchorLogged = false;
  bool _catchUpOpen = false;
  bool _budgetExhausted = false;
  bool _automaticReconnectAllowed = true;
  bool _closing = false;
  bool _linkDropped = false;

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
    _log(CgmLogLevel.info, 'cbio.connect.started');
    final connection = await _transport
        .connect(sensor.deviceId, timeout: timing.connectTimeout)
        .timeout(timing.connectTimeout);
    _connection = connection;
    _connectionSubscription = connection.connectionStates.listen(
      _onConnectionState,
      onError: (_) => _onTransportDrop(),
    );
    if (_closing) {
      await connection.disconnect();
      return;
    }
    try {
      await connection.requestMtu(247).timeout(timing.writeTimeout);
    } on Object {
      // The MTU exchange is an ATT-level negotiation, not a vendor frame.
      _log(CgmLogLevel.debug, 'cbio.mtu.default');
    }
    final services = await connection.discoverServices().timeout(
      timing.discoveryTimeout,
    );
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
    _log(CgmLogLevel.info, 'cbio.ff31.subscribed');

    if (!await _authenticate()) {
      return;
    }
    if (!await _writeClock()) {
      return;
    }
    if (_closing) {
      return;
    }
    // The vendor application issues one packed read first. This firmware
    // answers it with frozen zeros, so its content is ignored and the raw
    // path below carries every reading.
    await _sendMasked(
      buildMaskedCbioGlucoseQuery(0, key: _streamKey),
      label: 'glucose-0a',
      isRead: true,
    );
    _beginHistory(_historyStartIndex);
  }

  int get _historyStartIndex => (_resumeOffset ?? 0) + 1;

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
    if (!wrote) {
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
      final serial = await connection
          .read(
            BleCharacteristicRef(
              serviceUuid: '',
              characteristicUuid: CbioUuids.serial,
              properties: const BleCharacteristicProperties(read: true),
            ),
          )
          .timeout(timing.writeTimeout);
      if (serial.length == 6) {
        _log(CgmLogLevel.debug, 'cbio.address.serial');
        return serial;
      }
    } on Object {
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

  Future<bool> _writeClock() async {
    if (_clockWritten) {
      return true;
    }
    final epoch = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final wrote = await _sendMasked(
      buildMaskedCbioClock(epoch, key: _streamKey),
      label: 'clock',
      isRead: false,
    );
    if (!wrote) {
      return false;
    }
    _clockWritten = true;
    // The one reference the app can offer the record index: the epoch it just
    // pushed into the sensor clock. The index that corresponds to it is
    // derived later, from the sensor's own stamps, never from the counter
    // alone.
    _clockReferenceEpochSeconds = epoch;
    _log(CgmLogLevel.info, 'cbio.clock.set');
    return true;
  }

  void _beginHistory(int startIndex) {
    _catchUpOpen = false;
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _setPhase(
      CbioSessionPhase.history,
      CgmSyncStage.syncing,
      'Fetching sensor history',
      force: true,
    );
    unawaited(
      _sendMasked(
        buildMaskedCbioRawQuery(startIndex, key: _streamKey),
        label: 'raw-history',
        isRead: true,
      ),
    );
    _historyDeadlineTimer?.cancel();
    _historyDeadlineTimer = Timer(timing.historyWindow, _finishHistory);
    _restartHistoryIdleTimer();
  }

  void _restartHistoryIdleTimer() {
    if (_stage != CgmSyncStage.syncing) {
      return;
    }
    _historyIdleTimer?.cancel();
    _historyIdleTimer = Timer(timing.historyIdleWindow, _finishHistory);
  }

  void _finishHistory() {
    if (_closing) {
      return;
    }
    _historyDeadlineTimer?.cancel();
    _historyDeadlineTimer = null;
    _historyIdleTimer?.cancel();
    _historyIdleTimer = null;
    _lastSyncAt ??= _clock().toUtc();
    _setPhase(
      CbioSessionPhase.live,
      CgmSyncStage.ready,
      'Live. Reading every minute.',
      force: true,
    );
    _scheduleLivePoll();
  }

  void _scheduleLivePoll() {
    if (_closing || _budgetExhausted) {
      return;
    }
    _liveTimer?.cancel();
    _liveTimer = Timer(timing.livePollInterval, () {
      _liveTimer = null;
      unawaited(_pollLive());
    });
  }

  /// One bounded live read at the first index this session has not seen.
  Future<void> _pollLive() async {
    if (_closing || _linkDropped) {
      return;
    }
    if (_budgetExhausted) {
      _publishBudgetState();
      return;
    }
    await _readFrom(_nextIndex(), label: 'live-read');
  }

  int _nextIndex() => (_archive.newestIndex ?? 0) + 1;

  Future<void> _readFrom(int index, {required String label}) async {
    final window = _liveWindow = Completer<void>();
    final wrote = await _sendMasked(
      buildMaskedCbioRawQuery(index, key: _streamKey),
      label: label,
      isRead: true,
    );
    if (!wrote) {
      _liveWindow = null;
      _publishBudgetState();
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
    if (_closing || _linkDropped) {
      return;
    }
    _emit(force: true);
    _scheduleLivePoll();
  }

  Future<void> _catchUp(int startIndex) async {
    _catchUpOpen = true;
    _catchUpTimer?.cancel();
    _catchUpTimer = Timer(timing.catchUpWindow, () {
      _catchUpTimer = null;
      _catchUpOpen = false;
      _emit(force: true);
    });
    _emit(force: true);
    await _readFrom(startIndex, label: 'sync-read');
    _catchUpOpen = false;
    _catchUpTimer?.cancel();
    _catchUpTimer = null;
    _emit(force: true);
  }

  void _onConnectionState(BleConnectionState state) {
    if (state == BleConnectionState.disconnected) {
      _onTransportDrop();
    }
  }

  void _onTransportDrop() {
    if (_closing || _linkDropped) {
      return;
    }
    _linkDropped = true;
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
    if (_closing || bytes.isEmpty || _resolved == null) {
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
    final status = _archive.ingest(plaintext);
    switch (status) {
      case CbioArchiveIngestStatus.accepted:
      case CbioArchiveIngestStatus.gap:
        _lastSyncAt = _clock().toUtc();
        _log(CgmLogLevel.debug, 'cbio.raw.records=${_archive.length}');
        _restartHistoryIdleTimer();
        _emit();
      case CbioArchiveIngestStatus.duplicate:
      case CbioArchiveIngestStatus.notRawBatch:
        break;
    }
  }

  Future<bool> _sendMasked(
    List<int> masked, {
    required String label,
    required bool isRead,
  }) async {
    if (_closing) {
      return false;
    }
    final connection = _connection;
    final command = _command;
    if (connection == null || command == null) {
      return false;
    }
    // Reachable only before the session resolved its material, and then no
    // frame is written.
    final CbioCredentials? resolved = _resolved;
    if (resolved == null) {
      return false;
    }
    final plaintext = unmaskCbioFrame(masked, key: resolved.streamKey);
    if (!_isAllowedCommand(plaintext)) {
      // Defence in depth: an unrecognised command never reaches the radio.
      _log(CgmLogLevel.error, 'cbio.write.blocked:$label');
      return false;
    }
    if (isRead && _readsUsed >= timing.maxReadsPerSession) {
      _budgetExhausted = true;
      _log(CgmLogLevel.warning, 'cbio.read.budget');
      return false;
    }
    if (isRead) {
      _readsUsed += 1;
    }
    try {
      await connection
          .write(command, masked, withoutResponse: false)
          .timeout(timing.writeTimeout);
      _log(CgmLogLevel.info, 'cbio.write.$label');
      return true;
    } on Object {
      _log(CgmLogLevel.error, 'cbio.write.failed:$label');
      return false;
    }
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
    final serviceUuid = CbioUuids.canonical(CbioUuids.service);
    for (final service in services) {
      if (CbioUuids.canonical(service.uuid) != serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final uuid = CbioUuids.canonical(characteristic.characteristicUuid);
        if (uuid == CbioUuids.canonical(CbioUuids.receive)) {
          _receive = characteristic;
        } else if (uuid == CbioUuids.canonical(CbioUuids.command)) {
          _command = characteristic;
        }
      }
    }
  }

  bool get _atLiveEdge {
    if (_archive.length == 0 || _archive.hasGap) {
      return false;
    }
    if (_archive.oldestIndex != _historyStartIndex) {
      return false;
    }
    final newestTime = _archive.newestTime;
    if (newestTime == null) {
      return false;
    }
    final newest = DateTime.fromMillisecondsSinceEpoch(
      newestTime * 1000,
      isUtc: true,
    );
    return _clock().toUtc().difference(newest).abs() <= timing.liveEdgeWindow;
  }

  CgmHistorySyncState get _historySyncState => CgmHistorySyncState(
    inProgress: !_atLiveEdge || _catchUpOpen,
    storedCount: _archive.length,
    totalAvailable: _archive.newestIndex ?? 0,
    latestStoredOffset: _archive.newestIndex,
    startIndex: _historyStartIndex,
    targetIndex: _archive.newestIndex,
    lastSyncAt: _lastSyncAt,
  );

  /// The history as published. A record carries a timestamp only when the
  /// session holds an anchor that covers its position; the counter is never
  /// the source of that timestamp, only the index the anchor steps from.
  List<CgmReading> _historyReadingsFor(CbioIndexTimeAnchor? anchor) =>
      <CgmReading>[
        for (final record in _archive.records)
          CgmReading(
            valueMgdl: record.derivedMilligramsPerDecilitre.toDouble(),
            source: CgmRecordSource.raw,
            sensorMinute: record.index,
            recordedAt: anchor != null && anchor.coversIndex(record.index)
                ? anchor.timeForIndex(record.index)
                : null,
            rawValue: record.rawCurrent,
            isDisplayProvisional: true,
          ),
      ];

  /// The anchor this session can support right now, recomputed on every
  /// publication. It appears only once the sensor's own newest record stamp
  /// agrees with the app's clock, so a sensor that never took the written
  /// clock publishes no timestamp at all rather than a guessed one.
  CbioIndexTimeAnchor? _publishAnchor() {
    final anchor = deriveCbioIndexTimeAnchor(
      records: _archive.records,
      clockReferenceEpochSeconds: _clockReferenceEpochSeconds,
      now: _clock().toUtc(),
    );
    _anchor = anchor;
    if (anchor != null && !_anchorLogged) {
      _anchorLogged = true;
      _log(CgmLogLevel.info, 'cbio.clock.anchor=index${anchor.anchorIndex}');
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
    if (_snapshotController.isClosed) {
      return;
    }
    void publish() {
      final anchor = _publishAnchor();
      final history = _historyReadingsFor(anchor);
      _snapshot = _snapshot.copyWith(
        stage: _stage,
        statusText: _statusText,
        history: history,
        rawHistory: history,
        latestReading: history.isEmpty ? null : history.last,
        historySync: _historySyncState,
        metadata: <String, String>{
          ...sensor.metadata,
          cbioPhaseMetadataKey: _phase,
          'cgm.cbio.unit': 'provisional',
          ...?anchor?.toMetadata(),
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
    if (_stage == CgmSyncStage.ready) {
      _setPhase(
        CbioSessionPhase.live,
        CgmSyncStage.ready,
        'Live updates paused. Read budget reached.',
      );
    }
  }

  void _log(CgmLogLevel level, String message) {
    if (_logController.isClosed) {
      return;
    }
    _logController.add(
      CgmLogEntry(timestamp: _clock().toUtc(), level: level, message: message),
    );
  }

  void _fail(String code, {String statusText = 'Connection failed'}) {
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
  }

  static String _failureCodeFor(Object error) => switch (error) {
    CbioProtocolException() => CbioSessionFailure.topology,
    TimeoutException() => CbioSessionFailure.connect,
    _ => CbioSessionFailure.connect,
  };

  void _cancelTimers() {
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

  static int? _resumeOffsetFrom(DiscoveredSensor sensor) {
    final raw = sensor.metadata[cbioResumeOffsetMetadataKey];
    if (raw == null) {
      return null;
    }
    final value = int.tryParse(raw);
    if (value == null || value < 0) {
      return null;
    }
    return value;
  }

  @override
  Future<void> refresh() => refreshLiveData();

  @override
  Future<void> refreshLiveData() async {
    if (_closing || _linkDropped || _stage != CgmSyncStage.ready) {
      return;
    }
    _liveTimer?.cancel();
    _liveTimer = null;
    await _pollLive();
  }

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {
    if (_closing || _linkDropped) {
      return;
    }
    await _catchUp(requestedStartOffset ?? _nextIndex());
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
      <CgmDiagnosticItem>[
        CgmDiagnosticItem(
          key: 'cbio.gs1.session',
          title: 'GS1 link',
          summary: _statusText,
          fields: <String, String>{
            'phase': _phase,
            'reads': '$_readsUsed',
            'clockWritten': _clockWritten.toString(),
            'clockAnchor': _anchor == null
                ? 'unsynced: no position on the sensor clock this app set'
                : 'index ${_anchor!.anchorIndex} at '
                      '${_anchor!.anchorEpochSeconds} (source '
                      '${_anchor!.source}, covers from '
                      '${_anchor!.coveredFromIndex})',
            'storedRecords': '${_archive.length}',
            'newestIndex': '${_archive.newestIndex ?? 0}',
            'unit': cbioProvisionalUnitNotice,
          },
        ),
      ];

  @override
  Future<void> disconnect() async {
    if (_closing) {
      return;
    }
    _closing = true;
    _cancelTimers();
    final live = _liveWindow;
    if (live != null && !live.isCompleted) {
      live.complete();
    }
    _liveWindow = null;
    try {
      await _notificationSubscription?.cancel();
    } on Object {
      // Best effort; the link is released below regardless.
    }
    _notificationSubscription = null;
    try {
      await _connectionSubscription?.cancel();
    } on Object {
      // Best effort.
    }
    _connectionSubscription = null;
    try {
      await _connection?.disconnect();
    } on Object {
      // Best effort: a native description must never leak.
    }
    _connection = null;
    _receive = null;
    _command = null;
    _authReply = null;
    _stage = CgmSyncStage.disconnected;
    _phase = CbioSessionPhase.disconnected;
    _statusText = 'Disconnected';
    _snapshot = _snapshot.copyWith(
      stage: _stage,
      statusText: _statusText,
      metadata: <String, String>{
        ...sensor.metadata,
        cbioPhaseMetadataKey: _phase,
        'cgm.cbio.unit': 'provisional',
        ...?_anchor?.toMetadata(),
      },
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
      await _snapshotController.close();
    }
    if (!_logController.isClosed) {
      await _logController.close();
    }
  }
}
