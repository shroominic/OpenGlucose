import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openglucose/src/local_ble_trace_sink.dart';
import 'package:path_provider/path_provider.dart';

import 'support/cbio_private_capture_support.dart';

const _captureCutoff = Duration(minutes: 4);
const _hardDeadline = Duration(minutes: 5);
const _teardownBudget = Duration(seconds: 15);
const _startWait = Duration(minutes: 1);
const _standaloneCapture = bool.fromEnvironment('CBIO_CAPTURE_STANDALONE');

final _context = CaptureRunContext.fromValues(<String, String>{
  'CBIO_CAPTURE_RUN_ID': const String.fromEnvironment('CBIO_CAPTURE_RUN_ID'),
  'CBIO_CAPTURE_START_NONCE': const String.fromEnvironment(
    'CBIO_CAPTURE_START_NONCE',
  ),
  'CBIO_CAPTURE_ACK_NONCE': const String.fromEnvironment(
    'CBIO_CAPTURE_ACK_NONCE',
  ),
  'CBIO_TARGET_DEVICE_ID': const String.fromEnvironment(
    'CBIO_TARGET_DEVICE_ID',
  ),
  'CBIO_EXPECTED_SERIAL_HEX': const String.fromEnvironment(
    'CBIO_EXPECTED_SERIAL_HEX',
  ),
  'CBIO_LABEL_SHA256': const String.fromEnvironment('CBIO_LABEL_SHA256'),
  'CBIO_REPLAY_CONTEXT': const String.fromEnvironment('CBIO_REPLAY_CONTEXT'),
  'CBIO_RAW_START_INDEX': const String.fromEnvironment(
    'CBIO_RAW_START_INDEX',
  ),
  'CBIO_SOURCE_REVISION': const String.fromEnvironment('CBIO_SOURCE_REVISION'),
  'CBIO_CAPTURE_APP_PACKAGE': const String.fromEnvironment(
    'CBIO_CAPTURE_APP_PACKAGE',
  ),
});

const _credentialSource = CbioDefineCredentialSource();

Future<void> main() async {
  if (_standaloneCapture) {
    WidgetsFlutterBinding.ensureInitialized();
    await _runCapture();
    _emit('CBIO-CAPTURE-COMPLETE run=${_context.runId}');
    return;
  }

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'GS1 private no-clock index-one capture',
    (tester) async {
      await tester.runAsync(_runCapture);
    },
    timeout: const Timeout(Duration(minutes: 7)),
  );
}

Future<void> _runCapture() async {
  final credentials = _credentialSource.read();
  final support = await getApplicationSupportDirectory();
  final captureRoot = Directory('${support.path}/gs1-private-capture');
  final runDirectory = Directory('${captureRoot.path}/${_context.runId}');
  final handshake = CaptureHandshake(
    runDirectory: runDirectory,
    context: _context,
  );
  await handshake.prepare();
  final store = CaptureFullRecordStore(
    root: captureRoot,
    runId: _context.runId,
  );
  final traceSink = LocalBleTraceSink(
    directoryProvider: () async => Directory('${runDirectory.path}/trace'),
    sessionToken: 'gs1-${_context.runId}',
  );
  final promptSink = CapturePromptTraceSink(
    delegate: traceSink,
    runId: _context.runId,
    expectedPrompt: credentials.authenticationTrigger,
  );
  final recording = RecordingBleTransport(
    delegate: const FlutterBluePlusTransport(),
    sink: promptSink,
  );
  final exactTransport = ExactCaptureTransport(
    delegate: recording,
    expectedDeviceId: _context.targetDeviceId,
    expectedSerial: _context.expectedSerial,
    allowedWrites: <List<int>>[
      buildMaskedCbioAuthentication(
        _context.expectedSerial,
        key: credentials.streamKey,
        material: credentials.authMaterial,
      ),
      buildMaskedCbioGlucoseQuery(0, key: credentials.streamKey),
      buildMaskedCbioRawQuery(
        _context.rawStartIndex,
        key: credentials.streamKey,
      ),
    ],
  );
  final driver = CbioSensorDriver(
    exactTransport,
    credentials: _credentialSource,
    privateStateStore: store,
    timing: const CbioSessionTiming(
      historyWindow: Duration(minutes: 3),
      historyIdleWindow: Duration(seconds: 20),
      livePollInterval: Duration(minutes: 10),
      maxReadsPerSession: 2,
    ),
  );

  await handshake.markArmed();
  _emit('CBIO-CAPTURE-ARMED run=${_context.runId} start=start.json');
  await _waitForStart(handshake);

  final stopwatch = Stopwatch()..start();
  _emit('CBIO-CAPTURE-STARTED run=${_context.runId}');

  CgmSession? session;
  var historyWindowClosed = false;
  // This is the last acquisition state observed before intentional teardown.
  // A successful cleanup disconnect must not be confused with a premature
  // acquisition disconnect.
  var acquisitionStage = CgmSyncStage.connecting.name;
  String? driverError;
  Object? runFailure;
  try {
    await recording.recordCaptureHeartbeat().timeout(
      _bounded(stopwatch, const Duration(seconds: 8)),
    );
    final sensor = DiscoveredSensor(
      driverId: 'cbio',
      deviceId: _context.targetDeviceId,
      displayName: 'Private GS1 capture target',
      storageKey: _context.targetDeviceId,
      rssi: 0,
      capabilities: CbioSensorDriver.capabilities,
      notes: 'Exact private capture context; identity requires matching 2A25.',
      metadata: const <String, String>{
        'cgm.cbio.target': 'private-context-exact',
      },
    );
    session = await driver.connect(sensor);
    while (stopwatch.elapsed < _captureCutoff) {
      final snapshot = session.currentSnapshot;
      acquisitionStage = snapshot.stage.name;
      driverError = snapshot.lastError;
      if (snapshot.stage == CgmSyncStage.ready) {
        historyWindowClosed = true;
        break;
      }
      if (snapshot.stage == CgmSyncStage.error ||
          snapshot.stage == CgmSyncStage.disconnected) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } on Object catch (error) {
    runFailure = error;
  } finally {
    if (session != null) {
      try {
        await session.disconnect().timeout(
          _bounded(stopwatch, _teardownBudget),
        );
      } on Object catch (error) {
        runFailure ??= error;
      }
    }
    try {
      await traceSink.close().timeout(_bounded(stopwatch, _teardownBudget));
    } on Object catch (error) {
      runFailure ??= error;
    }
  }

  final envelope = await store.readFullRecords(_context.targetDeviceId);
  if (envelope == null) {
    throw StateError('Capture full-record envelope is unavailable.');
  }
  final authenticatedRawQuery = exactTransport.commandSequenceComplete;
  driverError = captureExportDriverError(
    driverError: driverError,
    runFailure: runFailure,
  );
  final summary = inspectCaptureEnvelope(
    envelope,
    sensorKey: _context.targetDeviceId,
    historyWindowClosed: historyWindowClosed,
    authenticatedRawQuery: authenticatedRawQuery,
  );
  final fullSha = _sha256(envelope);
  final fullBytes = utf8.encode(envelope).length;
  final promptReceipt = promptSink.encodeReceipt();
  final promptSha = _sha256(promptReceipt);
  final promptFile = File('${runDirectory.path}/auth-prompt-receipt.json');
  await _atomicWrite(promptFile, promptReceipt);
  final commandAudit = exactTransport.encodeCommandAudit(runId: _context.runId);
  final commandAuditSha = _sha256(commandAudit);
  final commandAuditBytes = utf8.encode(commandAudit).length;
  final commandAuditFile = File('${runDirectory.path}/command-audit.json');
  await _atomicWrite(commandAuditFile, commandAudit);
  final manifest = buildCaptureManifest(
    context: _context,
    summary: summary,
    artifactSha256: fullSha,
    artifactBytes: fullBytes,
    promptReceiptSha256: promptSha,
    commandAuditSha256: commandAuditSha,
    commandAuditBytes: commandAuditBytes,
    authPromptObserved: promptSink.observed,
    authPromptMatchCount: promptSink.matchCount,
    driverStage: acquisitionStage,
    driverError: driverError,
    identityMatched: exactTransport.identityMatched,
    topologyMatched: exactTransport.topologyMatched,
    attemptedWriteCount: exactTransport.attemptedWrites.length,
    successfulWriteCount: exactTransport.successfulWrites.length,
    commandSequenceComplete: exactTransport.commandSequenceComplete,
    historyWindowClosed: historyWindowClosed,
  );
  final manifestFile = File('${runDirectory.path}/manifest.json');
  await _atomicWrite(manifestFile, manifest);
  final manifestSha = _sha256(manifest);
  final manifestBytes = utf8.encode(manifest).length;
  final promptBytes = utf8.encode(promptReceipt).length;
  final outcome = _outcome(summary.captureCompleteness);

  _emit(
    'CBIO-CAPTURE-READY run=${_context.runId} '
    'full=full-records.json full_bytes=$fullBytes full_sha=$fullSha '
    'manifest=manifest.json manifest_bytes=$manifestBytes '
    'manifest_sha=$manifestSha prompt=auth-prompt-receipt.json '
    'prompt_bytes=$promptBytes prompt_sha=$promptSha outcome=$outcome '
    'audit=command-audit.json audit_bytes=$commandAuditBytes '
    'audit_sha=$commandAuditSha '
    'ack=ack.json',
  );
  await _waitForAck(
    handshake,
    manifestSha256: manifestSha,
    stopwatch: stopwatch,
  );

  expect(
    exactTransport.commandSequenceComplete,
    isTrue,
    reason:
        'Private artifacts were preserved, but the raw index-one query did not complete.',
  );
  if (runFailure != null) {
    fail('Private artifacts were preserved after a bounded capture failure.');
  }
}

Future<void> _waitForStart(CaptureHandshake handshake) async {
  final deadline = DateTime.now().add(_startWait);
  while (DateTime.now().isBefore(deadline)) {
    if (await handshake.consumeStartIfValid()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('Capture START was not received.');
}

Future<void> _waitForAck(
  CaptureHandshake handshake, {
  required String manifestSha256,
  required Stopwatch stopwatch,
}) async {
  while (stopwatch.elapsed < _hardDeadline) {
    if (await handshake.consumeAckIfValid(manifestSha256: manifestSha256)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(
    'Capture ACK was not received before the hard deadline.',
  );
}

Duration _bounded(Stopwatch stopwatch, Duration preferred) {
  final remaining = _hardDeadline - stopwatch.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('Capture hard deadline expired.');
  }
  return remaining < preferred ? remaining : preferred;
}

Future<void> _atomicWrite(File canonical, String value) async {
  final pending = File('${canonical.path}.next');
  await pending.writeAsString(value, flush: true);
  await pending.rename(canonical.path);
}

String _sha256(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();

String _outcome(CaptureCompleteness value) => switch (value) {
  CaptureCompleteness.contiguousPrefixTailUnproven =>
    'contiguous_prefix_tail_unproven',
  CaptureCompleteness.contiguousPrefixCutOff => 'contiguous_prefix_cut_off',
  CaptureCompleteness.authenticatedQueryNoRecords =>
    'authenticated_query_no_records',
  CaptureCompleteness.noAuthenticatedRawQuery => 'no_authenticated_raw_query',
};

void _emit(String value) {
  // Values are schema-limited and contain no sensor identifiers, credentials,
  // raw observations, prompt bytes or label content.
  // ignore: avoid_print
  print(value);
}
