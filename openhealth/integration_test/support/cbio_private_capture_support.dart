import 'dart:convert';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
// The full-record codec is intentionally not part of the app-facing package
// API. This integration-only harness validates the exact private envelope
// without widening that API.
import 'package:cgm_cbio/src/cbio_full_record_state.dart';
import 'package:crypto/crypto.dart' as crypto;

enum CaptureCompleteness {
  contiguousPrefixTailUnproven,
  contiguousPrefixCutOff,
  authenticatedQueryNoRecords,
  noAuthenticatedRawQuery,
}

final class CaptureRunContext {
  CaptureRunContext._({
    required this.runId,
    required this.startNonce,
    required this.ackNonce,
    required this.targetDeviceId,
    required List<int> expectedSerial,
    required this.labelSha256,
    required this.replayContext,
    required this.rawStartIndex,
    required this.sourceRevision,
  }) : expectedSerial = List<int>.unmodifiable(expectedSerial);

  factory CaptureRunContext.fromValues(Map<String, String> values) {
    String require(String key) {
      final value = values[key] ?? '';
      if (value.isEmpty) {
        throw const FormatException('Capture context is incomplete.');
      }
      return value;
    }

    final runId = require('CBIO_CAPTURE_RUN_ID');
    final startNonce = require('CBIO_CAPTURE_START_NONCE');
    final ackNonce = require('CBIO_CAPTURE_ACK_NONCE');
    final targetDeviceId = require('CBIO_TARGET_DEVICE_ID');
    final serialHex = require('CBIO_EXPECTED_SERIAL_HEX');
    final labelSha256 = require('CBIO_LABEL_SHA256');
    final replayContext = require('CBIO_REPLAY_CONTEXT');
    final rawStartIndex = int.tryParse(require('CBIO_RAW_START_INDEX'));
    final sourceRevision = require('CBIO_SOURCE_REVISION');
    if (!_hex32.hasMatch(runId) ||
        !_hex32.hasMatch(startNonce) ||
        !_hex32.hasMatch(ackNonce) ||
        startNonce == ackNonce ||
        !_deviceIdPattern.hasMatch(targetDeviceId) ||
        !_hex12.hasMatch(serialHex) ||
        !_hex64.hasMatch(labelSha256) ||
        replayContext != 'V1.1.6A' ||
        rawStartIndex != 1 ||
        !_hex40.hasMatch(sourceRevision)) {
      throw const FormatException('Capture context is invalid.');
    }
    return CaptureRunContext._(
      runId: runId,
      startNonce: startNonce,
      ackNonce: ackNonce,
      targetDeviceId: targetDeviceId,
      expectedSerial: <int>[
        for (var index = 0; index < serialHex.length; index += 2)
          int.parse(serialHex.substring(index, index + 2), radix: 16),
      ],
      labelSha256: labelSha256,
      replayContext: replayContext,
      rawStartIndex: rawStartIndex!,
      sourceRevision: sourceRevision,
    );
  }

  static final _hex12 = RegExp(r'^[0-9a-f]{12}$');
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');
  static final _hex40 = RegExp(r'^[0-9a-f]{40}$');
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _deviceIdPattern = RegExp(
    r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$',
  );

  final String runId;
  final String startNonce;
  final String ackNonce;
  final String targetDeviceId;
  final List<int> expectedSerial;
  final String labelSha256;
  final String replayContext;
  final int rawStartIndex;
  final String sourceRevision;

  @override
  String toString() => 'CaptureRunContext(<redacted>)';
}

final class CaptureHandshake {
  CaptureHandshake({
    required Directory runDirectory,
    required CaptureRunContext context,
  }) : _runDirectory = runDirectory,
       _context = context {
    final components = runDirectory.path.split(Platform.pathSeparator);
    if (components.isEmpty || components.last != context.runId) {
      throw const FormatException('Capture run directory is not bound.');
    }
  }

  final Directory _runDirectory;
  final CaptureRunContext _context;

  File get startFile => File('${_runDirectory.path}/start.json');
  File get ackFile => File('${_runDirectory.path}/ack.json');

  Future<void> prepare() async {
    final parent = _runDirectory.parent;
    await parent.create(recursive: true);
    final claim = File('${_runDirectory.path}.claim');
    try {
      await claim.create(exclusive: true);
    } on FileSystemException {
      throw StateError('Capture run is already claimed.');
    }
    try {
      if (FileSystemEntity.typeSync(_runDirectory.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Capture run directory already exists.');
      }
      await _runDirectory.create();
      if (!await _runDirectory.list(followLinks: false).isEmpty) {
        throw StateError('Capture run directory is not empty.');
      }
    } finally {
      await claim.delete();
    }
  }

  Future<bool> consumeStartIfValid() async {
    if (!startFile.existsSync()) return false;
    final value = await _readObject(startFile);
    _requireExactKeys(value, const <String>{'runId', 'nonce'});
    if (value['runId'] != _context.runId ||
        value['nonce'] != _context.startNonce) {
      throw const FormatException('Capture START binding is invalid.');
    }
    await startFile.delete();
    return true;
  }

  Future<bool> consumeAckIfValid({required String manifestSha256}) async {
    if (!ackFile.existsSync()) return false;
    if (!CaptureRunContext._hex64.hasMatch(manifestSha256)) {
      throw const FormatException('Capture manifest digest is invalid.');
    }
    final value = await _readObject(ackFile);
    _requireExactKeys(
      value,
      const <String>{'runId', 'nonce', 'manifestSha256'},
    );
    if (value['runId'] != _context.runId ||
        value['nonce'] != _context.ackNonce ||
        value['manifestSha256'] != manifestSha256) {
      throw const FormatException('Capture ACK binding is invalid.');
    }
    await ackFile.delete();
    return true;
  }

  static Future<Map<String, dynamic>> _readObject(File file) async {
    if (await file.length() > 1024) {
      throw const FormatException('Capture handshake file is too large.');
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) throw const FormatException();
      return value;
    } on Object {
      throw const FormatException('Capture handshake file is invalid.');
    }
  }

  static void _requireExactKeys(
    Map<String, dynamic> value,
    Set<String> expected,
  ) {
    if (value.length != expected.length ||
        !value.keys.every(expected.contains) ||
        value.values.any((entry) => entry is! String)) {
      throw const FormatException('Capture handshake shape is invalid.');
    }
  }
}

final class CaptureEnvelopeSummary {
  const CaptureEnvelopeSummary({
    required this.prefixValid,
    required this.recordCount,
    required this.firstIndex,
    required this.lastIndex,
    required this.indexGapCount,
    required this.rawTimeBreakCount,
    required this.rawTimeSegmentCount,
    required this.captureCompleteness,
  });

  final bool prefixValid;
  final int recordCount;
  final int? firstIndex;
  final int? lastIndex;
  final int indexGapCount;
  final int rawTimeBreakCount;
  final int rawTimeSegmentCount;
  final CaptureCompleteness captureCompleteness;
  String get retainedTailProof => 'unavailable_no_protocol_watermark';
}

final class CapturePromptTraceSink implements BleTraceSink {
  CapturePromptTraceSink({
    required BleTraceSink delegate,
    required String runId,
    required List<int> expectedPrompt,
  }) : _delegate = delegate,
       _runId = runId,
       _expectedPrompt = List<int>.unmodifiable(expectedPrompt) {
    if (!CaptureRunContext._hex32.hasMatch(runId) ||
        expectedPrompt.length != CbioCredentials.authenticationTriggerLength) {
      throw const FormatException('Auth-prompt observer is misconfigured.');
    }
  }

  final BleTraceSink _delegate;
  final String _runId;
  final List<int> _expectedPrompt;
  var _matchCount = 0;

  int get matchCount => _matchCount;
  bool get observed => _matchCount > 0;
  String encodeReceipt() => jsonEncode({
    'schemaVersion': 1,
    'runId': _runId,
    'observed': observed,
    'matchCount': matchCount,
    'maskedBytesHex': observed
        ? _expectedPrompt
              .map((value) => value.toRadixString(16).padLeft(2, '0'))
              .join()
        : null,
  });

  @override
  Future<void> append(BleTraceEvent event) async {
    if (event.type == BleTraceEventType.notificationData) {
      final raw = event.data['bytes'];
      if (raw is List) {
        final bytes = <int>[];
        var valid = true;
        for (final value in raw) {
          if (value is! int || value < 0 || value > 255) {
            valid = false;
            break;
          }
          bytes.add(value);
        }
        if (valid && _sameBytes(bytes, _expectedPrompt)) _matchCount++;
      }
    }
    await _delegate.append(event);
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

final class CaptureFullRecordStore implements CbioFullRecordStore {
  CaptureFullRecordStore({required Directory root, required String runId})
    : _directory = Directory('${root.path}/$runId') {
    if (!_runIdPattern.hasMatch(runId)) {
      throw const FormatException('Capture run id is invalid.');
    }
  }

  static final _runIdPattern = RegExp(r'^[0-9a-f]{32}$');
  final Directory _directory;
  String? _sensorKey;
  Future<void> _writeTail = Future<void>.value();

  File get canonicalFile => File('${_directory.path}/full-records.json');

  @override
  String legacySha256(String legacyEnvelope) =>
      crypto.sha256.convert(utf8.encode(legacyEnvelope)).toString();

  @override
  Future<String?> read(String sensorKey) async {
    _bind(sensorKey);
    _requireRunDirectory();
    return null;
  }

  @override
  Future<String?> readFullRecords(String sensorKey) async {
    _bind(sensorKey);
    _requireRunDirectory();
    if (!canonicalFile.existsSync()) return null;
    return canonicalFile.readAsString();
  }

  @override
  Future<void> write(String sensorKey, String envelope) async {
    _bind(sensorKey);
    _requireRunDirectory();
    throw StateError('Legacy capture state is not supported.');
  }

  @override
  Future<void> writeFullRecords(String sensorKey, String envelope) {
    _bind(sensorKey);
    final write = _writeTail.then((_) => _replaceCanonical(envelope));
    _writeTail = write;
    return write;
  }

  void _bind(String sensorKey) {
    if (sensorKey.isEmpty) {
      throw const FormatException('Capture sensor binding is empty.');
    }
    final bound = _sensorKey;
    if (bound != null && bound != sensorKey) {
      throw const FormatException('Capture store binding changed.');
    }
    _sensorKey = sensorKey;
  }

  Future<void> _replaceCanonical(String envelope) async {
    _requireRunDirectory();
    final pending = File('${canonicalFile.path}.next');
    await pending.writeAsString(envelope, flush: true);
    await pending.rename(canonicalFile.path);
  }

  void _requireRunDirectory() {
    if (FileSystemEntity.typeSync(_directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Capture run directory is unavailable.');
    }
  }
}

CaptureEnvelopeSummary inspectCaptureEnvelope(
  String envelope, {
  required String sensorKey,
  required bool historyWindowClosed,
  required bool authenticatedRawQuery,
}) {
  final state = CbioFullRecordState.decode(envelope, sensorKey: sensorKey);
  final records = state.records;
  if (state.currentCheckpoint case final checkpoint?) {
    final value = jsonDecode(checkpoint);
    if (value is Map && value.containsKey('anchor')) {
      throw const FormatException('Fresh capture cannot contain an anchor.');
    }
  }
  var gaps = 0;
  var timeBreaks = 0;
  for (var index = 1; index < records.length; index++) {
    if (records[index].index != records[index - 1].index + 1) gaps++;
    if (records[index].rawTime - records[index - 1].rawTime != 60) {
      timeBreaks++;
    }
  }
  final prefixValid =
      !state.isPending &&
      state.legacyDigest == null &&
      records.isNotEmpty &&
      records.first.index == 1 &&
      gaps == 0;
  final completeness = prefixValid
      ? historyWindowClosed
            ? CaptureCompleteness.contiguousPrefixTailUnproven
            : CaptureCompleteness.contiguousPrefixCutOff
      : authenticatedRawQuery
      ? CaptureCompleteness.authenticatedQueryNoRecords
      : CaptureCompleteness.noAuthenticatedRawQuery;
  return CaptureEnvelopeSummary(
    prefixValid: prefixValid,
    recordCount: records.length,
    firstIndex: records.isEmpty ? null : records.first.index,
    lastIndex: records.isEmpty ? null : records.last.index,
    indexGapCount: gaps,
    rawTimeBreakCount: timeBreaks,
    rawTimeSegmentCount: records.isEmpty ? 0 : timeBreaks + 1,
    captureCompleteness: completeness,
  );
}

final class ExactCaptureTransport
    implements BleTransport, BleSingleAttemptTransport {
  ExactCaptureTransport({
    required BleTransport delegate,
    required String expectedDeviceId,
    required List<int> expectedSerial,
    required List<List<int>> allowedWrites,
  }) : _delegate = delegate,
       _expectedDeviceId = expectedDeviceId,
       _expectedSerial = List<int>.unmodifiable(expectedSerial),
       _allowedWrites = List<List<int>>.unmodifiable(
         allowedWrites.map(List<int>.unmodifiable),
       ) {
    if (expectedDeviceId.isEmpty ||
        expectedSerial.length != 6 ||
        allowedWrites.length != 3 ||
        allowedWrites.any((value) => value.isEmpty)) {
      throw const FormatException('Exact capture transport is misconfigured.');
    }
  }

  final BleTransport _delegate;
  final String _expectedDeviceId;
  final List<int> _expectedSerial;
  final List<List<int>> _allowedWrites;
  final List<List<int>> _attemptedWrites = <List<int>>[];
  final List<List<int>> _successfulWrites = <List<int>>[];
  bool _connectStarted = false;
  bool _identityMatched = false;
  bool _topologyMatched = false;
  bool _writeGateFailed = false;
  int _nextWrite = 0;

  bool get identityMatched => _identityMatched;
  bool get topologyMatched => _topologyMatched;
  bool get writeGateFailed => _writeGateFailed;
  bool get commandSequenceComplete =>
      !_writeGateFailed &&
      _nextWrite == _allowedWrites.length &&
      _sameFrames(_attemptedWrites, _allowedWrites) &&
      _sameFrames(_successfulWrites, _allowedWrites);
  List<List<int>> get attemptedWrites => _copyFrames(_attemptedWrites);
  List<List<int>> get successfulWrites => _copyFrames(_successfulWrites);

  String encodeCommandAudit({required String runId}) {
    if (!CaptureRunContext._hex32.hasMatch(runId)) {
      throw const FormatException('Capture command audit run id is invalid.');
    }
    List<String> digests(List<List<int>> frames) => <String>[
      for (final frame in frames) crypto.sha256.convert(frame).toString(),
    ];
    return jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'runId': runId,
      'attemptedFrameSha256': digests(_attemptedWrites),
      'successfulFrameSha256': digests(_successfulWrites),
      'writeGateFailed': _writeGateFailed,
      'commandSequenceComplete': commandSequenceComplete,
    });
  }

  @override
  bool get supportsSingleAttemptConnect => true;

  @override
  Stream<BleScanResult> scan({
    Duration? timeout,
    bool allowDuplicates = true,
    List<String>? withServices,
  }) => _delegate
      .scan(
        timeout: timeout,
        allowDuplicates: allowDuplicates,
        withServices: withServices,
      )
      .where((result) => result.deviceId == _expectedDeviceId);

  @override
  Future<BleConnection> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => _open(deviceId, timeout);

  @override
  Future<BleConnection> connectOnce(
    String deviceId, {
    Duration timeout = const Duration(seconds: 10),
  }) => _open(deviceId, timeout);

  Future<BleConnection> _open(String deviceId, Duration timeout) async {
    if (deviceId != _expectedDeviceId) {
      throw StateError('Capture target does not match the private context.');
    }
    if (_connectStarted) {
      throw StateError('Capture permits only one physical connection.');
    }
    final delegate = _delegate;
    if (delegate is! BleSingleAttemptTransport ||
        !delegate.supportsSingleAttemptConnect) {
      throw StateError('Single-attempt BLE connection is unavailable.');
    }
    _connectStarted = true;
    final connection = await delegate.connectOnce(deviceId, timeout: timeout);
    if (connection.deviceId != _expectedDeviceId) {
      await connection.disconnect();
      throw StateError('Connected device does not match the private context.');
    }
    return _ExactCaptureConnection(delegate: connection, owner: this);
  }

  static List<List<int>> _copyFrames(List<List<int>> values) =>
      List<List<int>>.unmodifiable(
        values.map(List<int>.unmodifiable),
      );

  static bool _sameFrames(List<List<int>> left, List<List<int>> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_ExactCaptureConnection._sameBytes(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
}

String buildCaptureManifest({
  required CaptureRunContext context,
  required CaptureEnvelopeSummary summary,
  required String artifactSha256,
  required int artifactBytes,
  required String promptReceiptSha256,
  required String commandAuditSha256,
  required int commandAuditBytes,
  required bool authPromptObserved,
  required int authPromptMatchCount,
  required String driverStage,
  required String? driverError,
  required bool identityMatched,
  required bool topologyMatched,
  required int attemptedWriteCount,
  required int successfulWriteCount,
  required bool commandSequenceComplete,
  required bool historyWindowClosed,
}) {
  if (!CaptureRunContext._hex64.hasMatch(artifactSha256) ||
      !CaptureRunContext._hex64.hasMatch(promptReceiptSha256) ||
      !CaptureRunContext._hex64.hasMatch(commandAuditSha256) ||
      artifactBytes < 1 ||
      commandAuditBytes < 1 ||
      authPromptMatchCount < 0 ||
      attemptedWriteCount < 0 ||
      successfulWriteCount < 0 ||
      successfulWriteCount > attemptedWriteCount ||
      authPromptObserved != (authPromptMatchCount > 0) ||
      driverStage.isEmpty) {
    throw const FormatException('Capture manifest input is invalid.');
  }
  final completeness = switch (summary.captureCompleteness) {
    CaptureCompleteness.contiguousPrefixTailUnproven =>
      'contiguous_prefix_tail_unproven',
    CaptureCompleteness.contiguousPrefixCutOff => 'contiguous_prefix_cut_off',
    CaptureCompleteness.authenticatedQueryNoRecords =>
      'authenticated_query_no_records',
    CaptureCompleteness.noAuthenticatedRawQuery => 'no_authenticated_raw_query',
  };
  return jsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'sourceRevision': context.sourceRevision,
    'packageId': 'com.openglucose.app.debug',
    'runId': context.runId,
    'replayContext': context.replayContext,
    'labelSha256': context.labelSha256,
    'artifactSha256': artifactSha256,
    'artifactBytes': artifactBytes,
    'authPromptReceiptSha256': promptReceiptSha256,
    'commandAuditSha256': commandAuditSha256,
    'commandAuditBytes': commandAuditBytes,
    'authPromptObserved': authPromptObserved,
    'authPromptMatchCount': authPromptMatchCount,
    'versionEvidence': authPromptObserved
        ? 'incoming_auth_prompt_exact_match'
        : 'declared_context_only',
    'driverStage': driverStage,
    'driverError': driverError,
    'identityMatched': identityMatched,
    'topologyMatched': topologyMatched,
    'attemptedWriteCount': attemptedWriteCount,
    'successfulWriteCount': successfulWriteCount,
    'commandSequenceComplete': commandSequenceComplete,
    'state': summary.recordCount == 0 ? 'pending' : 'observing',
    'bootstrap': 'fresh',
    'prefixValid': summary.prefixValid,
    'recordCount': summary.recordCount,
    'firstIndex': summary.firstIndex,
    'lastIndex': summary.lastIndex,
    'indexGapCount': summary.indexGapCount,
    'rawTimeBreakCount': summary.rawTimeBreakCount,
    'rawTimeSegmentCount': summary.rawTimeSegmentCount,
    'anchorPresent': false,
    'historyWindowClosed': historyWindowClosed,
    'retainedTailProof': summary.retainedTailProof,
    'captureCompleteness': completeness,
  });
}

String? captureExportDriverError({
  required String? driverError,
  required Object? runFailure,
}) => driverError ?? (runFailure == null ? null : 'capture_run_failure');

final class _ExactCaptureConnection implements BleConnection, BleNegotiatedMtu {
  _ExactCaptureConnection({
    required BleConnection delegate,
    required ExactCaptureTransport owner,
  }) : _delegate = delegate,
       _owner = owner;

  final BleConnection _delegate;
  final ExactCaptureTransport _owner;

  @override
  String get deviceId => _delegate.deviceId;

  @override
  Stream<BleConnectionState> get connectionStates => _delegate.connectionStates;

  @override
  bool get supportsBondLifecycle => false;

  @override
  int? get negotiatedMtu => switch (_delegate) {
    final BleNegotiatedMtu capable => capable.negotiatedMtu,
    _ => null,
  };

  @override
  Future<void> ensureBonded() => Future<void>.error(
    UnsupportedError('Capture must not change bond state.'),
  );

  @override
  Future<BleBondState> currentBondState() => Future<BleBondState>.error(
    UnsupportedError('Capture does not inspect bond state.'),
  );

  @override
  Future<void> requestMtu(int mtu) => _delegate.requestMtu(mtu);

  @override
  Future<List<BleService>> discoverServices() async {
    final services = await _delegate.discoverServices();
    final vendor = services.where(
      (service) =>
          CbioUuids.canonical(service.uuid) ==
          CbioUuids.canonical(CbioUuids.service),
    );
    if (vendor.length != 1) {
      throw StateError('Expected one GS1 vendor service.');
    }
    final characteristics = vendor.single.characteristics;
    final receives = characteristics.where(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.receive),
    );
    final commands = characteristics.where(
      (value) =>
          CbioUuids.canonical(value.characteristicUuid) ==
          CbioUuids.canonical(CbioUuids.command),
    );
    if (receives.length != 1 ||
        commands.length != 1 ||
        !(receives.single.properties.notify ||
            receives.single.properties.indicate) ||
        !commands.single.properties.write) {
      throw StateError('GS1 vendor topology does not match the capture.');
    }
    _owner._topologyMatched = true;
    return services;
  }

  @override
  Future<List<int>> read(BleCharacteristicRef characteristic) async {
    if (!_owner._topologyMatched ||
        CbioUuids.canonical(characteristic.characteristicUuid) !=
            CbioUuids.canonical(CbioUuids.serial)) {
      throw StateError('Capture permits only the bound 2A25 identity read.');
    }
    final value = await _delegate.read(characteristic);
    if (!_sameBytes(value, _owner._expectedSerial)) {
      throw StateError('GS1 2A25 identity does not match the private context.');
    }
    _owner._identityMatched = true;
    return List<int>.unmodifiable(value);
  }

  @override
  Future<void> write(
    BleCharacteristicRef characteristic,
    List<int> value, {
    bool withoutResponse = false,
  }) async {
    final attempted = List<int>.unmodifiable(value);
    _owner._attemptedWrites.add(attempted);
    if (_owner._writeGateFailed ||
        !_owner._topologyMatched ||
        !_owner._identityMatched ||
        CbioUuids.canonical(characteristic.serviceUuid) !=
            CbioUuids.canonical(CbioUuids.service) ||
        CbioUuids.canonical(characteristic.characteristicUuid) !=
            CbioUuids.canonical(CbioUuids.command) ||
        withoutResponse ||
        _owner._nextWrite >= _owner._allowedWrites.length ||
        !_sameBytes(value, _owner._allowedWrites[_owner._nextWrite])) {
      _owner._writeGateFailed = true;
      throw StateError('Capture vendor write is not authorized.');
    }
    _owner._nextWrite++;
    try {
      await _delegate.write(
        characteristic,
        value,
        withoutResponse: withoutResponse,
      );
      _owner._successfulWrites.add(attempted);
    } on Object {
      _owner._writeGateFailed = true;
      rethrow;
    }
  }

  @override
  Future<void> setNotify(
    BleCharacteristicRef characteristic,
    bool enabled,
  ) {
    if (!_owner._topologyMatched ||
        CbioUuids.canonical(characteristic.characteristicUuid) !=
            CbioUuids.canonical(CbioUuids.receive)) {
      return Future<void>.error(
        StateError('Capture notify characteristic is not authorized.'),
      );
    }
    return _delegate.setNotify(characteristic, enabled);
  }

  @override
  Stream<List<int>> notifications(BleCharacteristicRef characteristic) {
    if (!_owner._topologyMatched ||
        CbioUuids.canonical(characteristic.characteristicUuid) !=
            CbioUuids.canonical(CbioUuids.receive)) {
      throw StateError('Capture notification stream is not authorized.');
    }
    return _delegate.notifications(characteristic);
  }

  @override
  Future<void> removeBond() => Future<void>.error(
    UnsupportedError('Capture must not remove bonds.'),
  );

  @override
  Future<void> disconnect() => _delegate.disconnect();

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
