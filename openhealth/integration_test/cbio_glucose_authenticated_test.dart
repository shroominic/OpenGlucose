// Bounded, device-backed authenticated GS1 session: auth, live glucose, history.
//
// Scope: connect to the real sensor, send the vendor's masked link setup and
// read frames, and record every notification with its unmasked plaintext.
// Authorised writes only:
//
//   * `19 01 00 <6 reversed address octets> <16 auth material> C` (masked)
//   * `06 03 LE32(epoch) C` vendor clock frame, sent once (masked)
//   * `06 0A LE16(index) 00 00 C` glucose read (masked)
//   * `06 08 LE16(index) 00 00 C` raw/history read (masked)
//
// Activation (0x07), reset, thresholds, and key registration are never sent.
// Pairing/bonding is never requested and the GATT link is released at the end.
//
// Masked bytes are logged; the authentication frame's plaintext is not, because
// it carries the link credential.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const Duration _scanWindow = Duration(seconds: 8);
const Duration _scanOverhead = Duration(seconds: 8);
const Duration _acquisitionBudget = Duration(seconds: 80);
const Duration _acquireGap = Duration(seconds: 2);
const Duration _connectWindow = Duration(seconds: 25);
const Duration _discoveryWindow = Duration(seconds: 25);
const Duration _subscribeWindow = Duration(seconds: 15);
const Duration _writeWindow = Duration(seconds: 15);
const Duration _authWindow = Duration(seconds: 12);
const Duration _replyWindow = Duration(seconds: 8);
const Duration _streamWindow = Duration(
  seconds: int.fromEnvironment('CBIO_STREAM_SECONDS', defaultValue: 20),
);
const Duration _teardownWindow = Duration(seconds: 15);

const int _maxWrites = 9;

const String _targetDeviceId = String.fromEnvironment('CBIO_TARGET_DEVICE_ID');

/// Vendor material for this run.
///
/// Nothing in the repository carries the stream key or the link credential, so
/// the harness reads them from the process environment or from `--dart-define`
/// and aborts before touching the radio when they are absent. Provide them
/// without writing them to a committed file, for example with
/// `--dart-define-from-file` against a git-ignored local file.
final CbioMapCredentialSource _credentials = CbioMapCredentialSource(
  <String, String>{
    ...Platform.environment,
    if (cbioStreamKeyHex.isNotEmpty) cbioStreamKeyDefine: cbioStreamKeyHex,
    if (cbioAuthMaterialHex.isNotEmpty)
      cbioAuthMaterialDefine: cbioAuthMaterialHex,
    if (cbioAuthTriggerHex.isNotEmpty)
      cbioAuthTriggerDefine: cbioAuthTriggerHex,
  },
);

/// Build identity, supplied by the evidence run script. Never the sensor
/// address and never credential material.
const String _harnessRevision = String.fromEnvironment(
  'CBIO_REVISION',
  defaultValue: 'unknown',
);
const String _appPackage = String.fromEnvironment(
  'CBIO_APP_PACKAGE',
  defaultValue: 'unknown',
);
const String _appRevision = String.fromEnvironment(
  'CBIO_APP_REVISION',
  defaultValue: 'unknown',
);

/// Writes this harness may send: link setup, one clock set, and read queries.
/// A frame that does not classify into this set fails before it is transmitted.
const Set<CbioWriteKind> _allowedWrites = <CbioWriteKind>{
  CbioWriteKind.authentication,
  CbioWriteKind.clockSet,
  CbioWriteKind.glucoseRead,
  CbioWriteKind.rawHistoryRead,
};
const Set<CbioWriteKind> _requiredWrites = <CbioWriteKind>{
  CbioWriteKind.authentication,
  CbioWriteKind.glucoseRead,
  CbioWriteKind.rawHistoryRead,
};

/// First raw (`08`) index to request. Zero starts a full history replay; a
/// higher value resumes partway so a bounded window can reach the newest
/// stored record instead of re-reading the whole archive.
const int _rawStartIndex = int.fromEnvironment('CBIO_RAW_START_INDEX');

/// Records carried in the emitted comparison. The window itself is not
/// truncated; only the artifact's per-record table is.
const int _comparisonRecords = int.fromEnvironment(
  'CBIO_COMPARISON_RECORDS',
  defaultValue: 1520,
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

void _emit(String line) {
  // The harness reports through stdout so the run script can tee it to a file.
  // ignore: avoid_print
  print(line);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Cbio GS1 authenticated session: auth, live glucose, history',
    (tester) async {
      final run = _SessionRun(startedAtUtc: DateTime.now().toUtc());
      await tester.runAsync(() => _runSession(run));
      final evidence = run.evidence();
      // The artifact is emitted before the verdict, so a failed run still
      // leaves a reviewable record behind.
      _emit('CBIO-EVIDENCE ${jsonEncode(evidence.toJson())}');
      expect(
        evidence.invariantViolations(),
        isEmpty,
        reason: 'session invariants',
      );
      expect(
        evidence.outcome,
        CbioSessionOutcome.completed,
        reason: 'the session did not reach a completed verdict',
      );
      expect(
        evidence.notifications,
        greaterThan(0),
        reason: 'the link produced no FF31 notification',
      );
      expect(
        evidence.glucoseIndices.isNotEmpty || evidence.rawIndices.isNotEmpty,
        isTrue,
        reason: 'the link produced no glucose and no raw history record',
      );
      // Gate G1: the reading-bearing field must carry content, and the app's
      // live path and the harness path must report the same field for the same
      // records. A run that reports an empty field is not a passing run.
      final comparison = run.comparison;
      expect(comparison, isNotNull, reason: 'no side-by-side decode');
      expect(
        comparison!.processedCount,
        evidence.rawIndices.length,
        reason:
            'every raw record must contribute one payload and one '
            'processed sample',
      );
      expect(
        comparison.payloadNonZero,
        greaterThan(0),
        reason: 'the payload field the app renders decoded to zero everywhere',
      );
      expect(
        run.appPathAgrees,
        isTrue,
        reason:
            'the app path and the harness path disagree on the payload '
            'word',
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// Mutable verdict inputs for one authenticated session.
final class _SessionRun {
  _SessionRun({required this.startedAtUtc});

  final DateTime startedAtUtc;
  final Map<CbioWriteKind, int> writeKinds = <CbioWriteKind, int>{};
  final Map<int, int> glucoseByIndex = <int, int>{};
  final Map<int, int> rawByIndex = <int, int>{};
  final Map<int, int> processedByIndex = <int, int>{};
  final Map<String, int> errors = <String, int>{};
  int notifications = 0;
  bool targetAcquired = false;
  bool gattReleased = false;
  bool authenticationObserved = false;
  bool appPathAgrees = false;
  CbioDecodeComparison? comparison;
  CbioSessionOutcome outcome = CbioSessionOutcome.failed;

  void wrote(CbioWriteKind kind) =>
      writeKinds[kind] = (writeKinds[kind] ?? 0) + 1;

  void noteError(String reason) => errors[reason] = (errors[reason] ?? 0) + 1;

  CbioSessionEvidence evidence() => CbioSessionEvidence(
    harness: 'openhealth/integration_test/cbio_glucose_authenticated_test.dart',
    harnessRevision: _harnessRevision,
    appPackage: _appPackage,
    appRevision: _appRevision,
    platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    unitStatus: 'unverified',
    startedAtUtc: startedAtUtc,
    endedAtUtc: DateTime.now().toUtc(),
    outcome: outcome,
    targetAcquired: targetAcquired,
    gattReleased: gattReleased,
    notifications: notifications,
    writeKinds: writeKinds,
    requiredWrites: _requiredWrites,
    allowedWrites: _allowedWrites,
    glucoseIndices: glucoseByIndex.keys.toList()..sort(),
    rawIndices: rawByIndex.keys.toList()..sort(),
    rawPayloadValues: rawByIndex.values.toList(),
    processedGlucoseValues: [
      ...glucoseByIndex.values,
      ...processedByIndex.values,
    ],
    errors: errors,
  );
}

Future<void> _runSession(_SessionRun run) async {
  if (!_credentials.isConfigured) {
    _emit(
      'CBIO-A abort=vendor-material-missing '
      'missing=${_credentials.missing.join(",")}',
    );
    run.noteError('vendor_material_missing');
    run.outcome = CbioSessionOutcome.failed;
    return;
  }
  final vendor = _credentials.read();

  final targetId = _targetDeviceId.isNotEmpty
      ? _targetDeviceId
      : await _acquireTargetId();
  if (targetId == null) {
    _emit('CBIO-A abort=no-target');
    run.noteError('target_missing');
    run.outcome = CbioSessionOutcome.abortedNoTarget;
    return;
  }
  run.targetAcquired = true;
  _emit('CBIO-A target-found');

  final device = fbp.BluetoothDevice.fromId(targetId);
  final masked = <(int, List<int>)>[];
  StreamSubscription<List<int>>? subscription;
  final started = DateTime.now().toUtc();
  int elapsed() => DateTime.now().toUtc().difference(started).inMilliseconds;

  try {
    await device
        .connect(
          license: fbp.License.free,
          timeout: _connectWindow,
          autoConnect: false,
        )
        .timeout(_connectWindow);
    _emit('CBIO-A connect-ok');

    final services = await device
        .discoverServices(
          subscribeToServicesChanged: false,
          timeout: _discoveryWindow.inSeconds,
        )
        .timeout(_discoveryWindow);
    fbp.BluetoothCharacteristic? notify;
    fbp.BluetoothCharacteristic? write;
    fbp.BluetoothCharacteristic? serial;
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        if (characteristic.properties.notify && uuid == 'ff31') {
          notify = characteristic;
        }
        if (characteristic.properties.write && uuid == 'ff32') {
          write = characteristic;
        }
        if (characteristic.properties.read && uuid == '2a25') {
          serial = characteristic;
        }
      }
    }
    if (notify == null || write == null) {
      _emit('CBIO-A abort=missing-characteristics');
      run.noteError('characteristic_missing');
      run.outcome = CbioSessionOutcome.abortedMissingCharacteristics;
      return;
    }

    final mtu = await device.requestMtu(247).timeout(_writeWindow);
    _emit('CBIO-A mtu=$mtu');

    subscription = notify.onValueReceived.listen((bytes) {
      masked.add((elapsed(), List<int>.from(bytes)));
      run.notifications = masked.length;
      final plaintext = unmaskCbioFrame(bytes, key: vendor.streamKey);
      _emit(
        'CBIO-A notify t=${elapsed()} masked=${_hex(bytes)} '
        'plaintext=${_hex(plaintext)}',
      );
    });
    await notify
        .setNotifyValue(true, timeout: _subscribeWindow.inSeconds)
        .timeout(_subscribeWindow + _writeWindow);
    _emit('CBIO-A notify-enabled=ff31');

    // The vendor's authentication address is the sensor address in reversed
    // octet order, and the serial characteristic already reports it that way.
    // The first attempt at this step reversed the read a second time and was
    // rejected with `result=0 status=2`; the bytes below are used as read.
    List<int>? serialOctets;
    try {
      final serialBytes = await serial?.read(timeout: _writeWindow.inSeconds);
      if (serialBytes != null && serialBytes.length == 6) {
        serialOctets = serialBytes.toList();
        _emit('CBIO-A serial-read ok octets=6');
      } else {
        _emit('CBIO-A serial-read unusable length=${serialBytes?.length}');
      }
    } on Object catch (error) {
      _emit('CBIO-A serial-read failed error=${error.runtimeType}');
      run.noteError('serial_read_failed');
    }

    List<int> reversedFromDeviceId() {
      final parts = targetId.split(':');
      if (parts.length != 6) return const [];
      return [
        for (final part in parts.reversed) int.tryParse(part, radix: 16) ?? 0,
      ];
    }

    var writes = 0;
    Future<bool> send(List<int> bytes, String label, {bool wait = true}) async {
      if (writes >= _maxWrites) {
        _emit('CBIO-A skip label=$label reason=write-budget');
        return false;
      }
      final kind = CbioWriteKind.classify(
        unmaskCbioFrame(bytes, key: vendor.streamKey),
      );
      expect(
        _allowedWrites,
        contains(kind),
        reason: 'write $label is outside the allowed set',
      );
      writes += 1;
      run.wrote(kind);
      _emit('CBIO-A write n=$writes label=$label masked=${_hex(bytes)}');
      try {
        await write!
            .write(
              bytes,
              withoutResponse: false,
              timeout: _writeWindow.inSeconds,
            )
            .timeout(_writeWindow);
        _emit('CBIO-A write-ok n=$writes label=$label');
      } on Object catch (error) {
        _emit(
          'CBIO-A write-failed n=$writes label=$label error=${error.runtimeType}',
        );
        run.noteError('write_failed');
        return false;
      }
      if (wait) {
        await Future<void>.delayed(_replyWindow);
      }
      return true;
    }

    /// Returns true when the newest unmasked reply is an auth success ACK.
    bool authSucceeded() {
      for (final (_, bytes) in masked.reversed) {
        final plaintext = unmaskCbioFrame(bytes, key: vendor.streamKey);
        if (plaintext.length != 5) continue;
        if (plaintext.fold<int>(0, (a, b) => a + b) & 255 != 0) continue;
        if (plaintext[1] == 0x01) {
          run.authenticationObserved = true;
          _emit(
            'CBIO-A auth-reply opcode=01 result=${plaintext[2]} '
            'status=${plaintext[3]}',
          );
          return plaintext[2] == 1;
        }
      }
      return false;
    }

    final addressCandidates = <(String, List<int>)>[
      if (serialOctets != null) ('serial-2a25', serialOctets),
      if (reversedFromDeviceId().length == 6)
        ('remote-id', reversedFromDeviceId()),
    ];
    var authenticated = false;
    for (final (source, octets) in addressCandidates) {
      _emit('CBIO-A auth-attempt source=$source');
      final authFrame = buildMaskedCbioAuthentication(
        octets,
        key: vendor.streamKey,
        material: vendor.authMaterial,
      );
      await send(authFrame, 'auth-$source');
      final deadline = DateTime.now().add(_authWindow);
      while (DateTime.now().isBefore(deadline)) {
        if (authSucceeded()) {
          authenticated = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (authenticated) {
        _emit('CBIO-A auth-ok source=$source');
        break;
      }
      _emit('CBIO-A auth-failed source=$source');
      run.noteError('auth_rejected');
    }
    if (!authenticated) {
      _emit('CBIO-A abort=authentication-failed');
      run.outcome = CbioSessionOutcome.abortedAuthenticationFailed;
      return;
    }

    // One logged vendor clock frame so history timestamps are meaningful.
    await send(
      buildMaskedCbioClock(
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        key: vendor.streamKey,
      ),
      'clock',
    );

    final beforeReads = masked.length;
    await send(
      buildMaskedCbioGlucoseQuery(0, key: vendor.streamKey),
      'glucose-0a-index0',
    );
    await send(
      buildMaskedCbioRawQuery(_rawStartIndex, key: vendor.streamKey),
      'raw-08-index$_rawStartIndex',
    );

    // The sensor continues pushing records on the same characteristic.
    final streamDeadline = DateTime.now().add(_streamWindow);
    while (DateTime.now().isBefore(streamDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final glucoseRecords = <CbioGlucoseRecord>[];
    final rawRecords = <CbioRawRecord>[];
    final plaintextFrames = <List<int>>[];
    for (final (_, bytes) in masked.sublist(beforeReads)) {
      final plaintext = unmaskCbioFrame(bytes, key: vendor.streamKey);
      plaintextFrames.add(plaintext);
      try {
        final batch = parseCbioGlucoseBatch(plaintext);
        glucoseRecords.addAll(batch.records);
        for (final record in batch.records) {
          run.glucoseByIndex[record.index] = record.rawGlucose;
        }
        _emit(
          'CBIO-A 0a-batch count=${batch.count} initial=${batch.initialIndex} '
          'last=${batch.lastIndex} baseReindex=${batch.baseReindex}',
        );
      } on CbioFrameException {
        // Not a 0A batch.
      }
      try {
        final rawBatch = parseCbioRawDataFrame(plaintext);
        rawRecords.addAll(rawBatch.records);
        for (final record in rawBatch.records) {
          run.rawByIndex[record.processed.index] = record.rawPayload;
          run.processedByIndex[record.processed.index] =
              record.processed.rawGlucose;
        }
        _emit(
          'CBIO-A 08-batch count=${rawBatch.records.length} '
          'first=${rawBatch.records.first.processed.index} '
          'last=${rawBatch.records.last.processed.index} '
          'payload=${rawBatch.records.map((r) => r.rawPayload).join(',')} '
          'processed=${rawBatch.records.map((r) => r.processed.rawGlucose).join(',')} '
          'temp=${rawBatch.records.map((r) => r.rawTemperature).join(',')}',
        );
      } on CbioFrameException {
        // Not a 08 batch.
      }
    }

    _emit(
      'CBIO-A summary writes=$writes notifications=${masked.length} '
      'glucoseRecords=${glucoseRecords.length} rawRecords=${rawRecords.length} '
      'frames=${plaintextFrames.length}',
    );
    if (glucoseRecords.isNotEmpty) {
      _emit(
        'CBIO-A glucose first=${glucoseRecords.first.index} '
        'last=${glucoseRecords.last.index} '
        'raw=${glucoseRecords.map((r) => r.rawGlucose).join(',')} '
        'unit=unverified',
      );
    }
    if (rawRecords.isNotEmpty) {
      _emit(
        'CBIO-A raw first=${rawRecords.first.processed.index} '
        'last=${rawRecords.last.processed.index} '
        'payload=${rawRecords.map((r) => r.rawPayload).join(',')}',
      );
    }
    // Both decoders see the same bytes in the same session: the app's live path
    // (the history archive, which is what the installed app renders) and the
    // frame parser the evidence path uses. They must report the same field.
    final comparison = compareCbioDecode(
      plaintextFrames,
      maxRecords: _comparisonRecords,
    );
    final appPath = CbioHistoryArchive();
    plaintextFrames.forEach(appPath.ingest);
    final agreement = compareCbioWithArchive(comparison, appPath.records);
    run.appPathAgrees = agreement.agrees;
    run.comparison = comparison;
    _emit(
      'CBIO-A compare appPath agrees=${agreement.agrees} '
      'agreeing=${agreement.agreeing}/${agreement.compared} '
      'missing=${agreement.missing} disagreeing=${agreement.disagreeing} '
      'records=${comparison.recordCount} '
      'payload=${comparison.payloadMinimum}..${comparison.payloadMaximum} '
      'payloadNonZero=${comparison.payloadNonZero} '
      'processed=${comparison.processedMinimum}..${comparison.processedMaximum} '
      'processedNonZero=${comparison.processedNonZero} '
      'index=${comparison.firstIndex}..${comparison.lastIndex}',
    );
    _emit('CBIO-COMPARISON ${jsonEncode(comparison.toJson())}');
    run.outcome = CbioSessionOutcome.completed;
  } on TestFailure {
    // An in-flight assertion (an out-of-envelope write) is not a session
    // failure: record it and let the test fail loudly.
    run.noteError('unexpected_error');
    run.outcome = CbioSessionOutcome.failed;
    rethrow;
  } on Object catch (error) {
    _emit('CBIO-A failed error=${error.runtimeType}');
    run.noteError('unexpected_error');
    run.outcome = CbioSessionOutcome.failed;
  } finally {
    try {
      await subscription?.cancel().timeout(_teardownWindow);
    } on Object {
      // Best effort: the link is released below regardless.
    }
    try {
      await device.disconnect().timeout(_teardownWindow);
      _emit('CBIO-A disconnect-ok');
      run.gattReleased = true;
    } on Object {
      _emit('CBIO-A disconnect-failed');
      run.noteError('disconnect_failed');
    }
  }
}

/// One bounded raw-plugin scan for the FF30 Cbio / SiSensing advertiser.
Future<String?> _acquireTargetId() async {
  final deadline = DateTime.now().add(_acquisitionBudget);
  while (DateTime.now().isBefore(deadline)) {
    final collected = <String, fbp.ScanResult>{};
    StreamSubscription<List<fbp.ScanResult>>? subscription;
    try {
      await fbp.FlutterBluePlus.startScan(
        withServices: [fbp.Guid('ff30')],
        timeout: _scanWindow,
        continuousUpdates: true,
        androidUsesFineLocation: true,
      );
      subscription = fbp.FlutterBluePlus.scanResults.listen((batch) {
        for (final result in batch) {
          collected[result.device.remoteId.str] = result;
        }
      });
      await Future<void>.delayed(_scanWindow + _scanOverhead);
    } on Object {
      // A failed window just retries inside the acquisition budget.
    } finally {
      try {
        await subscription?.cancel().timeout(_teardownWindow);
      } on Object {
        // Best effort.
      }
      try {
        await fbp.FlutterBluePlus.stopScan().timeout(_teardownWindow);
      } on Object {
        // Best effort.
      }
    }
    if (collected.isNotEmpty) {
      return collected.keys.first;
    }
    await Future<void>.delayed(_acquireGap);
  }
  return null;
}
