import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'cbio_frames.dart';

/// UUID candidates recovered from both SiSensing GS1 and GS3 Java payloads.
/// Shared UUIDs do not establish a sensor model or protocol compatibility.
abstract final class CbioUuids {
  static const String service = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const String receive = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const String command = '0000ff32-0000-1000-8000-00805f9b34fb';

  /// Canonicalises a UUID for comparison.
  ///
  /// Android reports 16-bit and 32-bit UUIDs in their short form (`FF30`)
  /// while the constants above are written in the full Bluetooth base form,
  /// so both sides are expanded onto that base before they are compared.
  /// A UUID that is already fully qualified is only case-folded.
  static String canonical(String uuid) {
    final normalized = uuid.trim().toLowerCase();
    return switch (normalized.length) {
      4 => '0000$normalized-0000-1000-8000-00805f9b34fb',
      8 => '$normalized-0000-1000-8000-00805f9b34fb',
      _ => normalized,
    };
  }
}

/// Pure candidate mapping; performs no Bluetooth operations.
final class CbioDiscovery {
  const CbioDiscovery();

  static const List<String> scanServiceUuids = <String>[CbioUuids.service];

  DiscoveredSensor? mapScanResult(BleScanResult result) {
    final matches = result.serviceUuids.any(
      (uuid) =>
          CbioUuids.canonical(uuid) == CbioUuids.canonical(CbioUuids.service),
    );
    if (!matches || result.deviceId.trim().isEmpty) return null;
    return DiscoveredSensor(
      driverId: 'cbio',
      deviceId: result.deviceId,
      displayName: 'Cbio / SiSensing candidate',
      storageKey: result.deviceId,
      rssi: result.rssi,
      capabilities: CbioSensorDriver.capabilities,
      notes: 'FF30 service candidate. Sensor model and protocol unverified.',
      metadata: const {'cgm.cbio.discovery': 'ff30-candidate'},
    );
  }
}

/// Live, read-only Cbio GS1 driver.
///
/// This driver discovers the FF30 service, connects, enables notifications on
/// FF31, and decodes received bytes with the offline [parseCbioPlaintextFrame]
/// contract. It is deliberately fail-closed: the only write it can emit is one
/// bounded, non-activating 0x08 read after a short passive window. Activation,
/// clock writes, reset, thresholds, and every other write are never sent.
class CbioSensorDriver implements CgmDriver {
  CbioSensorDriver(
    this._transport, {
    this.discovery = const CbioDiscovery(),
    this.passiveWindow = const Duration(seconds: 12),
  });

  final BleTransport _transport;
  final CbioDiscovery discovery;
  final Duration passiveWindow;

  static const CgmCapabilities capabilities = CgmCapabilities(
    supportsDirectBle: true,
  );

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    final seen = <String, DiscoveredSensor>{};
    await for (final result in _transport.scan(
      timeout: timeout,
      allowDuplicates: allowDuplicates,
      withServices: CbioDiscovery.scanServiceUuids,
    )) {
      final candidate = discovery.mapScanResult(result);
      if (candidate == null) {
        continue;
      }
      final existing = seen[candidate.deviceId];
      if (allowDuplicates ||
          existing == null ||
          existing.rssi != candidate.rssi) {
        seen[candidate.deviceId] = candidate;
        yield candidate;
      }
    }
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    final session = CbioSession._(
      sensor: sensor,
      transport: _transport,
      passiveWindow: passiveWindow,
    );
    unawaited(session.initialize());
    return session;
  }
}

final class CbioSession implements CgmSession {
  CbioSession._({
    required this.sensor,
    required BleTransport transport,
    required Duration passiveWindow,
  }) : _transport = transport,
       _passiveWindow = passiveWindow,
       _snapshot = CgmSessionSnapshot(
         stage: CgmSyncStage.connecting,
         statusText: 'Connecting to Cbio sensor',
         sensor: sensor,
         capabilities: sensor.capabilities,
         metadata: const {'cgm.cbio.discovery': 'ff30-candidate'},
       );

  /// The one read command this driver may send: `06 08 01 00 00 00 F1`.
  static const List<int> _readCommand = <int>[
    0x06,
    0x08,
    0x01,
    0x00,
    0x00,
    0x00,
    0xf1,
  ];
  @override
  final DiscoveredSensor sensor;

  final BleTransport _transport;
  final Duration _passiveWindow;
  final StreamController<CgmSessionSnapshot> _snapshotController =
      StreamController<CgmSessionSnapshot>.broadcast();
  final StreamController<CgmLogEntry> _logController =
      StreamController<CgmLogEntry>.broadcast();

  CgmSessionSnapshot _snapshot;
  BleConnection? _connection;
  BleCharacteristicRef? _receive;
  BleCharacteristicRef? _command;
  StreamSubscription<List<int>>? _notificationSubscription;
  Timer? _passiveTimer;
  Future<void>? _initializationFuture;
  bool _readSent = false;
  bool _disconnecting = false;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmSessionSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CgmLogEntry> get logs => _logController.stream;

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  Future<void> initialize() => _initializationFuture ??= _initializeInternal();

  Future<void> _initializeInternal() async {
    try {
      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.connecting,
          statusText: 'Connecting',
        ),
      );
      _probeTrace('connect-start');
      _connection = await _transport.connect(sensor.deviceId);
      _probeTrace('connect-ok');
      _emitLog(CgmLogLevel.debug, 'BLE link connected');

      final services = await _connection!.discoverServices();
      _locateCharacteristics(services);

      if (_receive == null) {
        throw const CbioProtocolException(
          CbioProtocolFailure.missingNotifyCharacteristic,
        );
      }
      if (!(_receive!.properties.notify || _receive!.properties.indicate)) {
        throw const CbioProtocolException(
          CbioProtocolFailure.notifyUnavailable,
        );
      }

      await _connection!.setNotify(_receive!, true);
      _probeTrace('notify-enabled');
      _notificationSubscription = _connection!
          .notifications(_receive!)
          .listen(_onNotification);
      _emitLog(CgmLogLevel.info, 'FF31 notifications enabled');

      _setSnapshot(
        _snapshot.copyWith(
          stage: CgmSyncStage.syncing,
          statusText: _command == null
              ? 'Listening (FF32 not found)'
              : 'Listening for notifications',
        ),
      );
      _passiveTimer?.cancel();
      _passiveTimer = Timer(_passiveWindow, _onPassiveTimeout);
    } catch (error) {
      _handleError(error, context: 'initializing Cbio session');
    }
  }

  void _locateCharacteristics(List<BleService> services) {
    final serviceUuid = _normalizeUuid(CbioUuids.service);
    for (final service in services) {
      if (_normalizeUuid(service.uuid) != serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        final uuid = _normalizeUuid(characteristic.characteristicUuid);
        if (uuid == _normalizeUuid(CbioUuids.receive)) {
          _receive = characteristic;
        } else if (uuid == _normalizeUuid(CbioUuids.command)) {
          _command = characteristic;
        }
      }
    }
  }

  void _onNotification(List<int> bytes) {
    _passiveTimer?.cancel();
    _passiveTimer = null;
    _probeTrace('notify len=${bytes.length}');
    _emitLog(CgmLogLevel.debug, 'FF31 notification length=${bytes.length}');
    try {
      final frame = parseCbioPlaintextFrame(bytes);
      final opcode = frame.opcode.toRadixString(16).padLeft(2, '0');
      _probeTrace('decode-ok opcode=0x$opcode kind=${frame.runtimeType}');
      _emitLog(CgmLogLevel.info, 'Decoded FF31 frame opcode 0x$opcode');
      _setSnapshot(
        _snapshot.copyWith(statusText: 'Decoded notification opcode 0x$opcode'),
      );
    } on CbioFrameException catch (error) {
      _probeTrace('decode-fail reason=${error.reason.name}');
      _emitLog(
        CgmLogLevel.warning,
        'FF31 frame did not decode (${error.reason.name})',
      );
    } on Object {
      _probeTrace('decode-fail reason=unexpected');
    }
  }

  void _onPassiveTimeout() {
    if (_disconnecting || _readSent) {
      return;
    }
    if (_command == null) {
      _probeTrace('passive-timeout ff32-missing');
      _emitLog(
        CgmLogLevel.warning,
        'No FF31 notification and no FF32 command characteristic; staying passive',
      );
      return;
    }
    unawaited(_sendReadCommand());
  }

  Future<void> _sendReadCommand() async {
    if (_readSent) {
      return;
    }
    _readSent = true;
    final command = _command;
    final connection = _connection;
    if (command == null || connection == null) {
      return;
    }
    _probeTrace('read-send opcode=0x08 len=${_readCommand.length}');
    _emitLog(CgmLogLevel.info, 'Issuing single 0x08 read');
    try {
      await connection.write(command, _readCommand, withoutResponse: false);
      _probeTrace('read-write-complete');
      _setSnapshot(
        _snapshot.copyWith(statusText: 'Issued read; waiting for response'),
      );
    } catch (error) {
      _handleError(error, context: 'sending 0x08 read');
    }
  }

  @override
  Future<void> refresh() => Future<void>.value();

  @override
  Future<void> refreshLiveData() => Future<void>.value();

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) => Future<void>.value();

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
      const <CgmDiagnosticItem>[];

  @override
  Future<void> disconnect() async {
    if (_disconnecting) {
      return;
    }
    _disconnecting = true;
    _passiveTimer?.cancel();
    _passiveTimer = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    try {
      await _connection?.disconnect();
    } on Object {
      // Disconnect is best-effort and must never leak a native description.
    }
    _connection = null;
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.disconnected,
        statusText: 'Disconnected',
      ),
    );
    await _snapshotController.close();
    await _logController.close();
  }

  void _setSnapshot(CgmSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _emitLog(CgmLogLevel level, String message) {
    if (_logController.isClosed) {
      return;
    }
    _logController.add(
      CgmLogEntry(timestamp: DateTime.now(), level: level, message: message),
    );
  }

  void _probeTrace(String milestone) {
    assert(() {
      // Debug-only closed milestone. No identifier, raw payload, or reading.
      // ignore: avoid_print
      print('OGCB $milestone');
      return true;
    }());
  }

  void _handleError(Object error, {required String context}) {
    if (_disconnecting) {
      return;
    }
    _passiveTimer?.cancel();
    _passiveTimer = null;
    final safeMessage = error is CbioProtocolException
        ? error.toString()
        : '$context failed (${error.runtimeType})';
    final metadata = <String, String>{
      ..._snapshot.metadata,
      if (error is BleFailure) ...error.toMetadata(),
    };
    _emitLog(CgmLogLevel.error, safeMessage);
    _setSnapshot(
      _snapshot.copyWith(
        stage: CgmSyncStage.error,
        statusText: 'Error',
        metadata: metadata,
        lastError: safeMessage,
      ),
    );
  }

  String _normalizeUuid(String uuid) => CbioUuids.canonical(uuid);
}

enum CbioProtocolFailure { missingNotifyCharacteristic, notifyUnavailable }

/// A closed, identifier-free failure from the read-only Cbio session.
final class CbioProtocolException implements Exception {
  const CbioProtocolException(this.failure);

  final CbioProtocolFailure failure;

  String get diagnosticCode => 'cgm.cbio.live.${failure.name}';

  @override
  String toString() => 'CbioProtocolException(${failure.name})';
}
