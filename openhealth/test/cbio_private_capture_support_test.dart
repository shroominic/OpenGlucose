import 'dart:convert';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/cbio_private_capture_support.dart';

const _runId = '0123456789abcdef0123456789abcdef';
const _sensorKey = 'private-sensor-key';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cbio-private-capture-test.',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('capture store starts empty and never admits legacy state', () async {
    await Directory('${temporaryDirectory.path}/$_runId').create();
    final store = CaptureFullRecordStore(
      root: temporaryDirectory,
      runId: _runId,
    );

    expect(await store.read(_sensorKey), isNull);
    expect(await store.readFullRecords(_sensorKey), isNull);
    await expectLater(
      store.write(_sensorKey, 'legacy'),
      throwsA(isA<StateError>()),
    );
    expect(
      store.legacySha256('abc'),
      'ba7816bf8f01cfea414140de5dae2223b'
      '00361a396177a9cb410ff61f20015ad',
    );
  });

  test('capture store replaces only the canonical full envelope', () async {
    final runDirectory = Directory('${temporaryDirectory.path}/$_runId');
    await runDirectory.create();
    final store = CaptureFullRecordStore(
      root: temporaryDirectory,
      runId: _runId,
    );

    await store.writeFullRecords(_sensorKey, 'first');
    await File('${store.canonicalFile.path}.next').writeAsString('stale');
    expect(await store.readFullRecords(_sensorKey), 'first');

    await store.writeFullRecords(_sensorKey, 'second');
    final reopened = CaptureFullRecordStore(
      root: temporaryDirectory,
      runId: _runId,
    );
    expect(await reopened.readFullRecords(_sensorKey), 'second');
    expect(await store.canonicalFile.readAsString(), 'second');
  });

  test('capture store never recreates a missing run directory', () async {
    final runDirectory = Directory('${temporaryDirectory.path}/$_runId');
    await runDirectory.create();
    final store = CaptureFullRecordStore(
      root: temporaryDirectory,
      runId: _runId,
    );
    await runDirectory.delete();

    await expectLater(
      store.writeFullRecords(_sensorKey, 'record'),
      throwsA(isA<StateError>()),
    );
    expect(runDirectory.existsSync(), isFalse);
  });

  test('observing envelope reports a contiguous tail-unproven prefix', () {
    final summary = inspectCaptureEnvelope(
      _observingEnvelope(),
      sensorKey: _sensorKey,
      historyWindowClosed: true,
      authenticatedRawQuery: true,
    );

    expect(summary.prefixValid, isTrue);
    expect(summary.recordCount, 3);
    expect(summary.firstIndex, 1);
    expect(summary.lastIndex, 3);
    expect(summary.indexGapCount, 0);
    expect(summary.rawTimeBreakCount, 1);
    expect(summary.rawTimeSegmentCount, 2);
    expect(
      summary.captureCompleteness,
      CaptureCompleteness.contiguousPrefixTailUnproven,
    );
    expect(summary.retainedTailProof, 'unavailable_no_protocol_watermark');
  });

  test('capture cutoff and no-record attempt stay explicitly partial', () {
    final cutoff = inspectCaptureEnvelope(
      _observingEnvelope(),
      sensorKey: _sensorKey,
      historyWindowClosed: false,
      authenticatedRawQuery: true,
    );
    final pending = inspectCaptureEnvelope(
      _pendingEnvelope(),
      sensorKey: _sensorKey,
      historyWindowClosed: false,
      authenticatedRawQuery: true,
    );

    expect(
      cutoff.captureCompleteness,
      CaptureCompleteness.contiguousPrefixCutOff,
    );
    expect(pending.prefixValid, isFalse);
    expect(
      pending.captureCompleteness,
      CaptureCompleteness.authenticatedQueryNoRecords,
    );
  });

  test('run context accepts only the exact index-one capture shape', () {
    final context = CaptureRunContext.fromValues(_contextValues());

    expect(context.runId, _runId);
    expect(context.appPackage, 'com.openglucose.app.debug');
    expect(context.targetDeviceId, 'AA:BB:CC:DD:EE:FF');
    expect(context.expectedSerial, [0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa]);
    expect(context.replayContext, 'V1.1.6A');
    expect(context.rawStartIndex, 1);

    expect(
      () => CaptureRunContext.fromValues(
        _contextValues()..['CBIO_RAW_START_INDEX'] = '0',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('run context admits only the exact default and Owner packages', () {
    final ownerContext = CaptureRunContext.fromValues(
      _contextValues()
        ..['CBIO_CAPTURE_APP_PACKAGE'] = 'com.openglucose.app.debug.owner',
    );

    expect(ownerContext.appPackage, 'com.openglucose.app.debug.owner');
    expect(
      () => CaptureRunContext.fromValues(
        _contextValues()..['CBIO_CAPTURE_APP_PACKAGE'] = 'example.invalid',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('handshake consumes only exact run-bound start and ack files', () async {
    final context = CaptureRunContext.fromValues(_contextValues());
    final handshake = CaptureHandshake(
      runDirectory: Directory('${temporaryDirectory.path}/$_runId'),
      context: context,
    );
    await handshake.prepare();

    expect(await handshake.consumeStartIfValid(), isFalse);
    await handshake.startFile.writeAsString(
      jsonEncode({'runId': _runId, 'nonce': context.startNonce}),
      flush: true,
    );
    expect(await handshake.consumeStartIfValid(), isTrue);
    expect(handshake.startFile.existsSync(), isFalse);

    await handshake.ackFile.writeAsString(
      jsonEncode({
        'runId': _runId,
        'nonce': context.ackNonce,
        'manifestSha256': 'd' * 64,
      }),
      flush: true,
    );
    expect(
      await handshake.consumeAckIfValid(manifestSha256: 'd' * 64),
      isTrue,
    );
    expect(handshake.ackFile.existsSync(), isFalse);
  });

  test(
    'handshake publishes one exact run-bound private ARMED marker',
    () async {
      final context = CaptureRunContext.fromValues(_contextValues());
      final runDirectory = Directory('${temporaryDirectory.path}/$_runId');
      final handshake = CaptureHandshake(
        runDirectory: runDirectory,
        context: context,
      );

      await expectLater(handshake.markArmed(), throwsA(isA<StateError>()));
      await handshake.prepare();
      await handshake.markArmed();

      expect(
        jsonDecode(await handshake.armedFile.readAsString()),
        <String, Object>{
          'schemaVersion': 1,
          'runId': _runId,
          'state': 'armed',
        },
      );
      expect(File('${handshake.armedFile.path}.pending').existsSync(), isFalse);
      await expectLater(handshake.markArmed(), throwsA(isA<StateError>()));
    },
  );

  test('handshake admits only a freshly claimed empty run directory', () async {
    final staleEntries = <String, bool>{
      'existing empty directory': false,
      'start.json': false,
      'armed.json': false,
      'armed.json.pending': false,
      'ack.json': false,
      'start.json.pending': false,
      'ack.json.pending': false,
      'full-records.json': false,
      'full-records.json.next': false,
      'manifest.json': false,
      'manifest.json.next': false,
      'auth-prompt-receipt.json': false,
      'auth-prompt-receipt.json.next': false,
      'command-audit.json': false,
      'command-audit.json.next': false,
      'trace': true,
    };

    for (final MapEntry(key: name, value: directory) in staleEntries.entries) {
      final root = Directory('${temporaryDirectory.path}/${name.hashCode}');
      final runDirectory = Directory('${root.path}/$_runId');
      await runDirectory.create(recursive: true);
      if (name != 'existing empty directory') {
        final path = '${runDirectory.path}/$name';
        if (directory) {
          await Directory(path).create();
        } else {
          await File(path).writeAsString('stale', flush: true);
        }
      }
      final handshake = CaptureHandshake(
        runDirectory: runDirectory,
        context: CaptureRunContext.fromValues(_contextValues()),
      );

      await expectLater(
        handshake.prepare(),
        throwsA(isA<StateError>()),
        reason: name,
      );
    }
  });

  test('prompt observer retains an exact private incoming receipt', () async {
    final delegate = _CollectingTraceSink();
    final observer = CapturePromptTraceSink(
      delegate: delegate,
      runId: _runId,
      expectedPrompt: const [1, 2, 3, 4, 5],
    );
    await observer.append(_notificationEvent(const [9, 9, 9, 9, 9]));
    await observer.append(_notificationEvent(const [1, 2, 3, 4, 5]));

    expect(observer.matchCount, 1);
    expect(observer.observed, isTrue);
    expect(jsonDecode(observer.encodeReceipt()), {
      'schemaVersion': 1,
      'runId': _runId,
      'observed': true,
      'matchCount': 1,
      'maskedBytesHex': '0102030405',
    });
    expect(delegate.events, hasLength(2));
  });

  test('manifest keeps declared version separate from prompt evidence', () {
    final context = CaptureRunContext.fromValues(
      _contextValues()
        ..['CBIO_CAPTURE_APP_PACKAGE'] = 'com.openglucose.app.debug.owner',
    );
    final summary = inspectCaptureEnvelope(
      _pendingEnvelope(),
      sensorKey: _sensorKey,
      historyWindowClosed: false,
      authenticatedRawQuery: true,
    );
    final manifest =
        jsonDecode(
              buildCaptureManifest(
                context: context,
                summary: summary,
                artifactSha256: 'e' * 64,
                artifactBytes: 123,
                promptReceiptSha256: 'f' * 64,
                commandAuditSha256: 'a' * 64,
                commandAuditBytes: 456,
                authPromptObserved: false,
                authPromptMatchCount: 0,
                driverStage: 'disconnected',
                driverError: null,
                identityMatched: true,
                topologyMatched: true,
                attemptedWriteCount: 3,
                successfulWriteCount: 3,
                commandSequenceComplete: true,
                historyWindowClosed: false,
              ),
            )
            as Map<String, dynamic>;

    expect(manifest['replayContext'], 'V1.1.6A');
    expect(manifest['packageId'], 'com.openglucose.app.debug.owner');
    expect(manifest['authPromptObserved'], isFalse);
    expect(manifest['commandAuditSha256'], 'a' * 64);
    expect(manifest['commandAuditBytes'], 456);
    expect(manifest['versionEvidence'], 'declared_context_only');
    expect(
      manifest['captureCompleteness'],
      'authenticated_query_no_records',
    );
    expect(manifest['retainedTailProof'], 'unavailable_no_protocol_watermark');
    expect(manifest.keys, hasLength(34));
  });

  test('caught capture failure is bound into exported driver error', () {
    expect(
      captureExportDriverError(
        driverError: null,
        runFailure: StateError('private detail must not be exported'),
      ),
      'capture_run_failure',
    );
    expect(
      captureExportDriverError(
        driverError: 'driver_reported_error',
        runFailure: StateError('later teardown failure'),
      ),
      'driver_reported_error',
    );
    expect(
      captureExportDriverError(driverError: null, runFailure: null),
      isNull,
    );
  });
}

Map<String, String> _contextValues() => <String, String>{
  'CBIO_CAPTURE_RUN_ID': _runId,
  'CBIO_CAPTURE_START_NONCE': 'a' * 32,
  'CBIO_CAPTURE_ACK_NONCE': 'b' * 32,
  'CBIO_TARGET_DEVICE_ID': 'AA:BB:CC:DD:EE:FF',
  'CBIO_EXPECTED_SERIAL_HEX': 'ffeeddccbbaa',
  'CBIO_LABEL_SHA256': 'c' * 64,
  'CBIO_REPLAY_CONTEXT': 'V1.1.6A',
  'CBIO_RAW_START_INDEX': '1',
  'CBIO_SOURCE_REVISION': 'd' * 40,
  'CBIO_CAPTURE_APP_PACKAGE': 'com.openglucose.app.debug',
};

String _pendingEnvelope() => jsonEncode({
  'schemaVersion': 1,
  'driverId': 'cbio',
  'profile': 'raw08-observed',
  'sensorKey': _sensorKey,
  'captureId': _runId,
  'state': 'pending',
  'bootstrap': {'kind': 'fresh'},
  'records': <Object>[],
});

String _observingEnvelope() => jsonEncode({
  'schemaVersion': 1,
  'driverId': 'cbio',
  'profile': 'raw08-observed',
  'sensorKey': _sensorKey,
  'captureId': _runId,
  'state': 'observing',
  'bootstrap': {'kind': 'fresh'},
  'firstObservation': [1, 120],
  'currentCheckpoint': jsonEncode({
    'version': 1,
    'sensorKey': _sensorKey,
    'index': 3,
    'rawTime': 300,
  }),
  'records': <Object>[
    [1, 120, 9, 321, 7, 432, 5],
    [2, 180, 9, 322, 8, 433, 5],
    [3, 300, 9, 323, 9, 434, 5],
  ],
});

BleTraceEvent _notificationEvent(List<int> bytes) => BleTraceEvent(
  sequence: 1,
  correlationId: 'test',
  recordedAtUtc: DateTime.utc(2026, 9, 21),
  monotonicElapsed: Duration.zero,
  type: BleTraceEventType.notificationData,
  operation: BleTraceOperation.notifications,
  data: {'bytes': bytes},
);

final class _CollectingTraceSink implements BleTraceSink {
  final events = <BleTraceEvent>[];

  @override
  void append(BleTraceEvent event) => events.add(event);
}
