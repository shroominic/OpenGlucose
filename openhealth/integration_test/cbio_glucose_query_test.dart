// Bounded, device-backed vendor read queries for the CBio / SiSensing GS1
// sensor (V120).
//
// Scope: drive the raw `flutter_blue_plus` link from the phone, send only the
// vendor's documented READ queries, and record every FF31 notification with a
// timestamp and its raw bytes. The write set is fixed:
//
//   * `03 F0 04 09` storage-state information read
//   * `03 F0 03 0A` device-time / last-index information read
//   * `06 0A <index LE16> 00 00 C` glucose read
//
// Activation (0x07), clock updates, resets, thresholds, calibration, and any
// key or authentication write are never sent. Pairing/bonding is never
// requested. Every write is logged byte for byte before it is sent.
//
// Run on a physical Android device with the radio on and the sensor nearby:
//
//   flutter test integration_test/cbio_glucose_query_test.dart -d <device-id>
//
// An address recovered from advertisement evidence can be supplied instead of
// scanning: --dart-define=CBIO_TARGET_DEVICE_ID=AA:BB:CC:DD:EE:FF
import 'dart:async';

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
const Duration _replyWindow = Duration(seconds: 5);
const Duration _teardownWindow = Duration(seconds: 15);

/// Total writes allowed in one run: five read queries and no retries.
const int _maxWrites = 5;

const String _targetDeviceId = String.fromEnvironment('CBIO_TARGET_DEVICE_ID');

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

void _emit(String line) {
  // The harness reports through stdout so the run script can tee it to a file.
  // ignore: avoid_print
  print(line);
}

/// The vendor's device-information/read builder `03 F0 x C`.
List<int> vendorInformationQuery(int selector) {
  final head = <int>[0x03, 0xf0, selector];
  return [
    ...head,
    (0x100 - (head.fold<int>(0, (a, b) => a + b) & 0xff)) & 0xff,
  ];
}

/// The vendor's glucose builder `06 0A LE16(index) LE16(0) C`.
List<int> vendorGlucoseQuery(int index) {
  final head = <int>[0x06, 0x0a, index & 0xff, (index >> 8) & 0xff, 0x00, 0x00];
  return [
    ...head,
    (0x100 - (head.fold<int>(0, (a, b) => a + b) & 0xff)) & 0xff,
  ];
}

/// One decoded vendor `0x0A` glucose batch, without a unit or epoch claim.
final class _GlucoseBatch {
  const _GlucoseBatch({
    required this.count,
    required this.initialIndex,
    required this.initialTime,
    required this.records,
    required this.baseReindex,
  });

  final int count;
  final int initialIndex;
  final int initialTime;
  final List<int> records;
  final int baseReindex;

  int get lastIndex => initialIndex + count - 1;
  List<int> get rawGlucose => [
    for (var i = 0; i < count; i++)
      (records[2 * i] >> 6) | (records[2 * i + 1] << 2),
  ];
}

String? _frameFailure(List<int> bytes) {
  if (bytes.length < 5 || bytes.length > 256) return 'size';
  if (bytes[0] + 1 != bytes.length) return 'length';
  if ((bytes.fold<int>(0, (a, b) => a + b) & 255) != 0) return 'checksum';
  return null;
}

_GlucoseBatch? _decodeGlucose(List<int> bytes) {
  if (bytes.length < 12 || _frameFailure(bytes) != null) return null;
  if (bytes[1] != 0x0a) return null;
  final count = bytes[2];
  if (bytes.length != 12 + 2 * count) return null;
  int le16(int o) => bytes[o] | (bytes[o + 1] << 8);
  return _GlucoseBatch(
    count: count,
    initialIndex: le16(3),
    initialTime: le16(5) | (le16(7) << 16),
    records: bytes.sublist(9, 9 + 2 * count),
    baseReindex: le16(bytes.length - 3),
  );
}

/// Decoded `F0/03` time information, without an epoch claim.
final class _TimeInformation {
  const _TimeInformation({
    required this.rawActivationTime,
    required this.rawCurrentTime,
    required this.rawLastTime,
    required this.rawLastIndex,
  });

  final int rawActivationTime;
  final int rawCurrentTime;
  final int rawLastTime;
  final int rawLastIndex;
}

_TimeInformation? _decodeTimeInformation(List<int> bytes) {
  if (bytes.length != 20 || _frameFailure(bytes) != null) return null;
  if (bytes[1] != 0xf0 || bytes[2] != 0x03) return null;
  int le16(int o) => bytes[o] | (bytes[o + 1] << 8);
  int le32(int o) => le16(o) | (le16(o + 2) << 16);
  return _TimeInformation(
    rawActivationTime: le32(5),
    rawCurrentTime: le32(9),
    rawLastTime: le32(13),
    rawLastIndex: le16(17),
  );
}

/// Storage-state information, without a status interpretation.
final class _StorageInformation {
  const _StorageInformation({
    required this.rawStatus,
    required this.rawStorageNumber,
    required this.rawConfigTimes,
    required this.rawKeyTimes,
  });

  final int rawStatus;
  final int rawStorageNumber;
  final int rawConfigTimes;
  final int rawKeyTimes;
}

_StorageInformation? _decodeStorageInformation(List<int> bytes) {
  if (bytes.length != 9 || _frameFailure(bytes) != null) return null;
  if (bytes[1] != 0xf0 || bytes[2] != 0x04) return null;
  return _StorageInformation(
    rawStatus: bytes[3],
    rawStorageNumber: bytes[4] | (bytes[5] << 8),
    rawConfigTimes: bytes[6],
    rawKeyTimes: bytes[7],
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Cbio GS1 vendor read queries: storage, time, and glucose batches',
    (tester) async {
      await tester.runAsync(_runQueries);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<void> _runQueries() async {
  final targetId = _targetDeviceId.isNotEmpty
      ? _targetDeviceId
      : await _acquireTargetId();
  if (targetId == null) {
    _emit('CBIO-Q abort=no-target');
    return;
  }
  _emit('CBIO-Q target-found');

  final device = fbp.BluetoothDevice.fromId(targetId);
  final notifications = <(int, List<int>)>[];
  StreamSubscription<List<int>>? subscription;
  final started = DateTime.now().toUtc();
  int elapsed() => DateTime.now().toUtc().difference(started).inMilliseconds;

  try {
    _emit('CBIO-Q connect-start');
    await device
        .connect(
          // The app locks flutter_blue_plus 2.2.x, where the license argument
          // is required for a connected link.
          license: fbp.License.free,
          timeout: _connectWindow,
          autoConnect: false,
        )
        .timeout(_connectWindow);
    _emit('CBIO-Q connect-ok');

    final services = await device
        .discoverServices(
          subscribeToServicesChanged: false,
          timeout: _discoveryWindow.inSeconds,
        )
        .timeout(_discoveryWindow);
    String? notifyUuid;
    fbp.BluetoothCharacteristic? notify;
    fbp.BluetoothCharacteristic? write;
    for (final service in services) {
      if (service.uuid.str.toLowerCase() != 'ff30') continue;
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str.toLowerCase();
        if (characteristic.properties.notify && uuid == 'ff31') {
          notify = characteristic;
          notifyUuid = uuid;
        }
        if (characteristic.properties.write && uuid == 'ff32') {
          write = characteristic;
        }
      }
    }
    _emit('CBIO-Q services=${services.map((s) => s.uuid.str).join(',')}');
    if (notify == null || write == null) {
      _emit('CBIO-Q abort=missing-characteristics notify=$notifyUuid');
      return;
    }

    final mtu = await device.requestMtu(247).timeout(_writeWindow);
    _emit('CBIO-Q mtu=$mtu');

    subscription = notify.onValueReceived.listen((bytes) {
      notifications.add((elapsed(), List<int>.from(bytes)));
      _emit('CBIO-Q notify t=${elapsed()} bytes=${_hex(bytes)}');
    });
    await notify
        .setNotifyValue(true, timeout: _subscribeWindow.inSeconds)
        .timeout(_subscribeWindow + _writeWindow);
    _emit('CBIO-Q notify-enabled=ff31');

    var writes = 0;
    Future<void> send(List<int> query, String label) async {
      if (writes >= _maxWrites) {
        _emit('CBIO-Q skip label=$label reason=write-budget');
        return;
      }
      writes += 1;
      final before = notifications.length;
      _emit('CBIO-Q write n=$writes label=$label bytes=${_hex(query)}');
      try {
        await write!
            .write(
              query,
              withoutResponse: false,
              timeout: _writeWindow.inSeconds,
            )
            .timeout(_writeWindow);
        _emit('CBIO-Q write-ok n=$writes');
      } on Object catch (error) {
        _emit('CBIO-Q write-failed n=$writes error=${error.runtimeType}');
      }
      final deadline = DateTime.now().add(_replyWindow);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final replies = notifications.sublist(before);
      for (final (at, bytes) in replies) {
        final failure = _frameFailure(bytes);
        _emit(
          'CBIO-Q reply label=$label t=$at bytes=${_hex(bytes)} '
          'failure=${failure ?? 'none'}',
        );
        final glucose = _decodeGlucose(bytes);
        if (glucose != null) {
          _emit(
            'CBIO-Q glucose count=${glucose.count} '
            'initial=${glucose.initialIndex} last=${glucose.lastIndex} '
            'baseReindex=${glucose.baseReindex} '
            'raw=${glucose.rawGlucose.join(',')} unit=unverified',
          );
        }
        final time = _decodeTimeInformation(bytes);
        if (time != null) {
          _emit(
            'CBIO-Q time activation=${time.rawActivationTime} '
            'current=${time.rawCurrentTime} last=${time.rawLastTime} '
            'lastIndex=${time.rawLastIndex}',
          );
        }
        final storage = _decodeStorageInformation(bytes);
        if (storage != null) {
          _emit(
            'CBIO-Q storage status=${storage.rawStatus} '
            'number=${storage.rawStorageNumber} '
            'config=${storage.rawConfigTimes} key=${storage.rawKeyTimes}',
          );
        }
      }
      if (replies.isEmpty) {
        _emit(
          'CBIO-Q reply label=$label none-within-${_replyWindow.inSeconds}s',
        );
      }
    }

    await send(vendorInformationQuery(4), 'storage');
    await send(vendorInformationQuery(3), 'time');

    final newestIndex = _newestIndexSeen(notifications);
    if (newestIndex != null) {
      _emit('CBIO-Q plan source=time-or-storage newest=$newestIndex');
      await send(vendorGlucoseQuery(newestIndex), 'glucose-newest');
    }
    await send(vendorGlucoseQuery(0), 'glucose-index0');
    await send(vendorGlucoseQuery(1), 'glucose-index1');

    _emit(
      'CBIO-Q summary writes=$writes notifications=${notifications.length}',
    );
  } on Object catch (error) {
    _emit('CBIO-Q failed error=${error.runtimeType}');
  } finally {
    try {
      await subscription?.cancel().timeout(_teardownWindow);
    } on Object {
      // Best effort: the link is released below regardless.
    }
    try {
      await device.disconnect().timeout(_teardownWindow);
      _emit('CBIO-Q disconnect-ok');
    } on Object {
      _emit('CBIO-Q disconnect-failed');
    }
  }
}

/// The newest stored index a `F0/03` time reply reported, if any.
int? _newestIndexSeen(List<(int, List<int>)> notifications) {
  for (final (_, bytes) in notifications) {
    final time = _decodeTimeInformation(bytes);
    if (time != null && time.rawLastIndex > 0) {
      return time.rawLastIndex;
    }
  }
  return null;
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
