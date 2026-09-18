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
import 'dart:io' show Platform;

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
final CbioMapCredentialSource _credentials =
    CbioMapCredentialSource(<String, String>{
      ...Platform.environment,
      if (cbioStreamKeyHex.isNotEmpty) cbioStreamKeyDefine: cbioStreamKeyHex,
      if (cbioAuthMaterialHex.isNotEmpty)
        cbioAuthMaterialDefine: cbioAuthMaterialHex,
      if (cbioAuthTriggerHex.isNotEmpty)
        cbioAuthTriggerDefine: cbioAuthTriggerHex,
    });

/// First raw (`08`) index to request. Zero starts a full history replay; a
/// higher value resumes partway so a bounded window can reach the newest
/// stored record instead of re-reading the whole archive.
const int _rawStartIndex = int.fromEnvironment('CBIO_RAW_START_INDEX');

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
      await tester.runAsync(_runSession);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _runSession() async {
  if (!_credentials.isConfigured) {
    _emit(
      'CBIO-A abort=vendor-material-missing '
      'missing=${_credentials.missing.join(",")}',
    );
    return;
  }
  final vendor = _credentials.read();

  final targetId = _targetDeviceId.isNotEmpty
      ? _targetDeviceId
      : await _acquireTargetId();
  if (targetId == null) {
    _emit('CBIO-A abort=no-target');
    return;
  }
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
      return;
    }

    final mtu = await device.requestMtu(247).timeout(_writeWindow);
    _emit('CBIO-A mtu=$mtu');

    subscription = notify.onValueReceived.listen((bytes) {
      masked.add((elapsed(), List<int>.from(bytes)));
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
      writes += 1;
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
    }
    if (!authenticated) {
      _emit('CBIO-A abort=authentication-failed');
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
        _emit(
          'CBIO-A 08-batch count=${rawBatch.records.length} '
          'first=${rawBatch.records.first.packed.index} '
          'last=${rawBatch.records.last.packed.index} '
          'raw=${rawBatch.records.map((r) => r.packed.rawGlucose).join(',')} '
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
        'CBIO-A raw first=${rawRecords.first.packed.index} '
        'last=${rawRecords.last.packed.index} '
        'raw=${rawRecords.map((r) => r.packed.rawGlucose).join(',')}',
      );
    }
  } on Object catch (error) {
    _emit('CBIO-A failed error=${error.runtimeType}');
  } finally {
    try {
      await subscription?.cancel().timeout(_teardownWindow);
    } on Object {
      // Best effort: the link is released below regardless.
    }
    try {
      await device.disconnect().timeout(_teardownWindow);
      _emit('CBIO-A disconnect-ok');
    } on Object {
      _emit('CBIO-A disconnect-failed');
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
