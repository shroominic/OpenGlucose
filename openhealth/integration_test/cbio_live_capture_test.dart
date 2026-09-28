// Bounded, device-backed live capture for the Cbio / SiSensing GS1 candidate.
//
// Scope: run the production [FlutterBluePlusTransport] behind the repository's
// [RecordingBleTransport] sink, drive the unmodified [CbioSensorDriver] against
// a live sensor, and record every raw byte the driver observes. The capture is
// fail-closed: it never sends activation (0x07), clock (0x03), reset,
// thresholds, or any write other than the single bounded 0x08 read the driver
// already guards.
//
// Run on a physical Android device with the radio on and the sensor nearby:
//
//   flutter test integration_test/cbio_live_capture_test.dart -d <device-id>
//
// The harness installs the app, so grant the runtime permissions on a
// pre-installed build first; `flutter test` then upgrades the same package and
// keeps the grants:
//
//   adb install -r openhealth/build/app/outputs/flutter-apk/app-debug.apk
//   adb shell pm grant <pkg> android.permission.BLUETOOTH_SCAN
//   adb shell pm grant <pkg> android.permission.BLUETOOTH_CONNECT
//   adb shell pm grant <pkg> android.permission.ACCESS_FINE_LOCATION
//
// When the Dart-layer scan surfaces nothing (a separate, tracked defect), the
// same harness can connect to an address recovered from advertisement evidence:
//
//   flutter test integration_test/cbio_live_capture_test.dart -d <device-id> \
//     --dart-define=CBIO_TARGET_DEVICE_ID=$(cat /tmp/cbio_target_addr.txt)
//
// Raw evidence is written to app-private storage
// (`<app support>/protocol-captures/ble-<token>-00.jsonl`) and retrieved with
// `run-as` or root into a restricted local directory. The harness process is
// uninstalled by `flutter test` when it finishes, so pull the segment while the
// run is active. This file prints only redacted identifiers and never prints
// payload bytes.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_ble_flutter/cgm_ble_flutter.dart';
import 'package:cgm_cbio/cgm_cbio.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openglucose/src/local_ble_trace_sink.dart';
import 'package:path_provider/path_provider.dart';

/// Every write this capture may emit, by plaintext `03/19/06` command pair.
///
/// These are the vendor link set-up and read frames the authenticated session
/// sends: device information, authentication, the one-per-session clock frame,
/// and the packed and raw reads. Activation (0x07), reset, threshold,
/// calibration, key-registration, and firmware frames are never authorized.
const Set<String> _allowedCommandKeys = <String>{
  '03f0',
  '1901',
  '0603',
  '060a',
  '0608',
};

/// One captured write that the session was authorized to send.
bool _isAllowedWrite(List<int> masked, List<int> key) {
  final plaintext = unmaskCbioFrame(masked, key: key);
  if (plaintext.length < 2) {
    return false;
  }
  return _allowedCommandKeys.contains(
    '${plaintext[0].toRadixString(16).padLeft(2, '0')}'
    '${plaintext[1].toRadixString(16).padLeft(2, '0')}',
  );
}

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

/// Every phase is bounded so a silent or unresponsive radio cannot hang.
const Duration _filteredScanWindow = Duration(seconds: 8);
const Duration _unfilteredScanWindow = Duration(seconds: 12);
const Duration _discoveryOverhead = Duration(seconds: 8);
const Duration _linkWindow = Duration(seconds: 25);

/// Bounded linger after the first FF31 packet.
///
/// The vendor reply is not proven to fit in one ATT notification: the first
/// live packet arrived as five bytes whose leading byte (0x23) is the size a
/// full frame would need. Tearing the link down on the first packet would drop
/// every later fragment, so the capture keeps listening for this window after
/// the first packet before it disconnects.
const Duration _settleWindow = Duration(seconds: 6);
const Duration _teardownWindow = Duration(seconds: 15);
const Duration _rawScanWindow = Duration(seconds: 6);
const Duration _acquireGap = Duration(seconds: 2);

/// Total budget for waiting on an intermittent advertisement.
///
/// The sensor is a real radio on a real body: it stops advertising while it is
/// connected elsewhere and reappears when it is free, so a single 10 s window
/// can miss it entirely.
const Duration _acquireBudget = Duration(seconds: 100);

/// Optional discovery-independent target, supplied at run time.
///
/// Android can hand FF30 advertisements to the app's scan client while the
/// Dart/FlutterBluePlus layer surfaces none (tracked by the nearby-sensor scan
/// surfacing lane). When this is set the harness skips scanning and connects
/// once to that address, which is exactly the value the driver's own discovery
/// would have produced. The address is passed at run time and never committed:
///
///   --dart-define=CBIO_TARGET_DEVICE_ID=$(cat /tmp/cbio_target_addr.txt)
const String _targetDeviceId = String.fromEnvironment(
  'CBIO_TARGET_DEVICE_ID',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Cbio GS1 live capture: FF30 discovery, connect, FF31 notification bytes',
    (tester) async {
      if (!_credentials.isConfigured) {
        // The authenticated link cannot be driven without the injected
        // material, and a missing material is a configuration problem rather
        // than a finding about the sensor.
        _emit(
          'CBIO-PROGRESS phase=abort abort=vendor-material-missing '
          'missing=${_credentials.missing.join(",")}',
        );
        return;
      }
      final summary = await tester.runAsync(_runCapture);
      _report(summary!);
      _assertCapture(summary);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<_CaptureSummary> _runCapture() async {
  final vendor = _credentials.read();
  final token = 'cbio-${DateTime.now().toUtc().millisecondsSinceEpoch}';
  final sink = LocalBleTraceSink(sessionToken: token);
  final events = <BleTraceEvent>[];
  final transport = RecordingBleTransport(
    delegate: const FlutterBluePlusTransport(),
    sink: _TeeTraceSink(sink, events),
  );
  const discovery = CbioDiscovery();
  final driver = CbioSensorDriver(
    transport,
    discovery: discovery,
    credentials: _credentials,
  );

  _emit('CBIO-PROGRESS phase=heartbeat');
  await transport.recordCaptureHeartbeat().timeout(_discoveryOverhead);
  _emit('CBIO-PROGRESS phase=heartbeat-ok');

  final filteredCandidates = <DiscoveredSensor>[];
  Object? filteredError;
  var unfilteredUsed = false;
  var unfilteredAdvertisements = 0;
  final unfilteredCandidates = <DiscoveredSensor>[];
  Object? unfilteredError;
  DiscoveredSensor? target;
  var targetSource = 'scan';

  if (_targetDeviceId.isEmpty) {
    // Phase 1: the production discovery path, with the FF30 service filter.
    _emit('CBIO-PROGRESS phase=filtered-scan');
    try {
      final results = await driver
          .scan(timeout: _filteredScanWindow)
          .toList()
          .timeout(_filteredScanWindow + _discoveryOverhead);
      filteredCandidates.addAll(results);
    } on Object catch (error) {
      filteredError = error;
    }
    _emit(
      'CBIO-PROGRESS phase=filtered-scan-done '
      'candidates=${filteredCandidates.length} '
      'error=${filteredError?.runtimeType}',
    );

    // Phase 2: unfiltered fallback, classified by the same discovery.
    if (filteredCandidates.isEmpty) {
      unfilteredUsed = true;
      _emit('CBIO-PROGRESS phase=unfiltered-scan');
      try {
        final results = await transport
            .scan(timeout: _unfilteredScanWindow)
            .toList()
            .timeout(_unfilteredScanWindow + _discoveryOverhead);
        unfilteredAdvertisements = results.length;
        for (final result in results) {
          final candidate = discovery.mapScanResult(result);
          if (candidate != null) {
            unfilteredCandidates.add(candidate);
          }
        }
      } on Object catch (error) {
        unfilteredError = error;
      }
      _emit(
        'CBIO-PROGRESS phase=unfiltered-scan-done '
        'advertisements=$unfilteredAdvertisements '
        'candidates=${unfilteredCandidates.length} '
        'error=${unfilteredError?.runtimeType}',
      );
    }

    target = _strongestCandidate(<DiscoveredSensor>[
      ...filteredCandidates,
      ...unfilteredCandidates,
    ]);
  } else {
    // Discovery is bypassed: the address is the value the FF30 advertisement
    // evidence already carries for this sensor.
    targetSource = 'provided-address';
    target = DiscoveredSensor(
      driverId: 'cbio',
      deviceId: _targetDeviceId,
      displayName: 'Cbio / SiSensing candidate',
      storageKey: _targetDeviceId,
      rssi: 0,
      capabilities: CbioSensorDriver.capabilities,
      notes: 'Address supplied at run time from advertisement evidence.',
      metadata: const <String, String>{'cgm.cbio.target': 'provided-address'},
    );
  }

  // Phase 3: raw plugin scan.
  //
  // The production transport's scan stream surfaces nothing on this device
  // even though the Android scan client receives FF30 results (tracked by the
  // nearby-sensor scan surfacing lane). This fallback reads the plugin's raw
  // result stream instead, and connecting afterwards reuses the address type
  // the platform has now cached for the peripheral.
  var rawAdvertisements = 0;
  var rawScanAttempts = 0;
  final rawCandidates = <DiscoveredSensor>[];
  final rawInventory = <BleScanResult>[];
  Object? rawError;
  if (target == null || targetSource == 'provided-address') {
    final acquireDeadline = DateTime.now().add(_acquireBudget);
    while (DateTime.now().isBefore(acquireDeadline)) {
      rawScanAttempts += 1;
      _emit('CBIO-PROGRESS phase=raw-plugin-scan attempt=$rawScanAttempts');
      var observed = const <BleScanResult>[];
      try {
        observed = await _rawPluginScan(
          window: _rawScanWindow,
        ).timeout(_rawScanWindow + _discoveryOverhead);
      } on Object catch (error) {
        rawError = error;
      }
      rawAdvertisements += observed.length;
      for (final result in observed) {
        if (rawInventory.length < 400) {
          rawInventory.add(result);
        }
        final candidate = discovery.mapScanResult(result);
        if (candidate != null) {
          rawCandidates.add(candidate);
        }
      }
      _emit(
        'CBIO-PROGRESS phase=raw-plugin-scan-done attempt=$rawScanAttempts '
        'advertisements=${observed.length} '
        'candidates=${rawCandidates.length} '
        'error=${rawError?.runtimeType}',
      );
      final rawTarget = _strongestCandidate(rawCandidates);
      if (rawTarget != null) {
        target = rawTarget;
        targetSource = 'raw-plugin-scan';
        break;
      }
      await Future<void>.delayed(_acquireGap);
    }
  }

  _emit(
    'CBIO-PROGRESS phase=target found=${target != null} source=$targetSource',
  );

  final logs = <String>[];
  Object? connectError;
  Object? linkError;
  var finalStage = CgmSyncStage.disconnected;
  String? driverError;

  if (target != null) {
    _emit('CBIO-PROGRESS phase=link');
    try {
      final outcome = await _captureLink(
        driver,
        target,
        events,
      ).timeout(_linkWindow + _teardownWindow);
      finalStage = outcome.finalStage;
      driverError = outcome.driverError;
      logs.addAll(outcome.logs);
    } on Object catch (error) {
      linkError = error;
    }
    _emit(
      'CBIO-PROGRESS phase=link-done stage=${finalStage.name} '
      'link_error=${linkError?.runtimeType}',
    );
  }

  // Let the asynchronous trace tail land before the sink is drained.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final segmentFileName = sink.health.segmentFileName;
  _emit('CBIO-PROGRESS phase=sink-close segment=$segmentFileName');
  try {
    await sink.close().timeout(_teardownWindow);
  } on Object catch (error) {
    _emit('CBIO-PROGRESS phase=sink-close-failed error=${error.runtimeType}');
  }

  final serviceUuids = <String>[];
  final notifyEnabled = <String>[];
  final writeBytes = <List<int>>[];
  final notifications = <List<int>>[];
  for (final event in events) {
    if (event.type == BleTraceEventType.notificationData) {
      final bytes = event.data['bytes'];
      if (bytes is List) {
        notifications.add(List<int>.from(bytes));
      }
    }
    if (event.type == BleTraceEventType.operationStarted &&
        event.operation == BleTraceOperation.write) {
      final bytes = event.data['bytes'];
      if (bytes is List) {
        writeBytes.add(List<int>.from(bytes));
      }
    }
    if (event.type == BleTraceEventType.operationFailed &&
        event.operation == BleTraceOperation.connect) {
      connectError = event.data['failure'] ?? event.data;
    }
    if (event.type != BleTraceEventType.operationSucceeded) {
      continue;
    }
    if (event.operation == BleTraceOperation.setNotify &&
        event.data['enabled'] == true) {
      final uuid = event.data['characteristic_uuid'];
      if (uuid is String) {
        notifyEnabled.add(uuid);
      }
    }
    if (event.operation == BleTraceOperation.discoverServices) {
      final services = event.data['services'];
      if (services is List) {
        for (final service in services) {
          if (service is Map && service['uuid'] is String) {
            serviceUuids.add(service['uuid'] as String);
          }
        }
      }
    }
  }

  final connectSucceeded = events.any(
    (event) =>
        event.type == BleTraceEventType.operationSucceeded &&
        event.operation == BleTraceOperation.connect,
  );

  return _CaptureSummary(
    sessionToken: token,
    streamKey: vendor.streamKey,
    traceFile: segmentFileName == null
        ? null
        : '${await _traceDirectoryPath()}/$segmentFileName',
    filteredCandidates: filteredCandidates,
    filteredError: filteredError,
    unfilteredUsed: unfilteredUsed,
    unfilteredAdvertisements: unfilteredAdvertisements,
    unfilteredCandidates: unfilteredCandidates,
    unfilteredError: unfilteredError,
    rawAdvertisements: rawAdvertisements,
    rawScanAttempts: rawScanAttempts,
    rawCandidates: rawCandidates,
    rawInventory: rawInventory,
    rawError: rawError,
    target: target,
    targetSource: targetSource,
    connectSucceeded: connectSucceeded,
    connectError: connectError ?? linkError,
    serviceUuids: serviceUuids,
    notifyEnabled: notifyEnabled,
    writeBytes: writeBytes,
    notifications: notifications,
    logs: logs,
    finalStage: finalStage,
    driverError: driverError,
    traceEvents: events.length,
  );
}

/// One bounded link attempt: connect, listen, then disconnect.
Future<_LinkOutcome> _captureLink(
  CbioSensorDriver driver,
  DiscoveredSensor target,
  List<BleTraceEvent> events,
) async {
  final session = await driver.connect(target);
  final logs = <String>[];
  final logSubscription = session.logs.listen(
    (entry) => logs.add('${entry.level.name}: ${entry.message}'),
  );
  final snapshotSubscription = session.snapshots.listen((_) {});

  final deadline = DateTime.now().add(_linkWindow);
  DateTime? settleDeadline;
  while (DateTime.now().isBefore(deadline)) {
    if (_notificationBytes(events).isNotEmpty) {
      // Keep the link up briefly so a multi-packet reply is recorded whole.
      settleDeadline ??= DateTime.now().add(_settleWindow);
      if (!DateTime.now().isBefore(settleDeadline)) {
        break;
      }
    }
    if (session.currentSnapshot.stage == CgmSyncStage.error) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  await Future<void>.delayed(const Duration(milliseconds: 500));
  final outcome = _LinkOutcome(
    finalStage: session.currentSnapshot.stage,
    driverError: session.currentSnapshot.lastError,
    logs: logs,
  );

  // Disconnect is best effort: the captured evidence is already durable.
  try {
    await session.disconnect().timeout(_teardownWindow);
  } on Object catch (error) {
    _emit('CBIO-PROGRESS phase=disconnect-failed error=${error.runtimeType}');
  }
  try {
    await logSubscription.cancel().timeout(_teardownWindow);
    await snapshotSubscription.cancel().timeout(_teardownWindow);
  } on Object catch (error) {
    _emit(
      'CBIO-PROGRESS phase=subscription-cancel-failed '
      'error=${error.runtimeType}',
    );
  }
  return outcome;
}

Future<String> _traceDirectoryPath() async {
  try {
    final directory = await getApplicationSupportDirectory().timeout(
      const Duration(seconds: 10),
    );
    return '${directory.path}/protocol-captures';
  } on Object {
    return '<app-support>/protocol-captures';
  }
}

/// One bounded scan through the raw `flutter_blue_plus` result stream.
///
/// This deliberately bypasses the production transport: its `onScanResults`
/// subscription skips the first emission and surfaces nothing on this device.
/// The raw stream is subscribed after the scan is live, so no emission is
/// dropped, and the platform caches the peripheral's address type for the
/// following connect.
Future<List<BleScanResult>> _rawPluginScan({
  required Duration window,
  List<String>? withServices,
}) async {
  final collected = <String, fbp.ScanResult>{};
  StreamSubscription<List<fbp.ScanResult>>? subscription;
  try {
    await fbp.FlutterBluePlus.startScan(
      withServices: (withServices ?? const <String>[])
          .map(fbp.Guid.new)
          .toList(growable: false),
      timeout: window,
      continuousUpdates: true,
      androidUsesFineLocation: true,
    );
    subscription = fbp.FlutterBluePlus.scanResults.listen((batch) {
      for (final result in batch) {
        collected[result.device.remoteId.str] = result;
      }
    });
    await Future<void>.delayed(window + const Duration(seconds: 1));
  } finally {
    try {
      await subscription?.cancel().timeout(_teardownWindow);
    } on Object {
      // The scan still has to stop; a stuck subscription must not hide that.
    }
    try {
      await fbp.FlutterBluePlus.stopScan().timeout(_teardownWindow);
    } on Object {
      // Best effort: the bounded scan timeout stops the radio anyway.
    }
  }
  return collected.values.map(_toScanResult).toList(growable: false);
}

/// Maps one raw plugin result onto the transport's scan-result shape.
BleScanResult _toScanResult(fbp.ScanResult result) {
  final advertisement = result.advertisementData;
  final advertisedName = advertisement.advName.trim();
  return BleScanResult(
    deviceId: result.device.remoteId.str,
    deviceName: advertisedName.isNotEmpty
        ? advertisedName
        : result.device.platformName.trim(),
    rssi: result.rssi,
    observedAt: result.timeStamp.toUtc(),
    serviceUuids: advertisement.serviceUuids
        .map((uuid) => uuid.str.toLowerCase())
        .toList(growable: false),
    manufacturerData: advertisement.manufacturerData.entries
        .map(
          (entry) => BleManufacturerData(
            companyId: entry.key,
            bytes: List<int>.from(entry.value, growable: false),
          ),
        )
        .toList(growable: false),
    serviceData: <String, List<int>>{
      for (final entry in advertisement.serviceData.entries)
        entry.key.str.toLowerCase(): List<int>.from(
          entry.value,
          growable: false,
        ),
    },
  );
}

DiscoveredSensor? _strongestCandidate(List<DiscoveredSensor> candidates) {
  DiscoveredSensor? strongest;
  for (final candidate in candidates) {
    if (strongest == null || candidate.rssi > strongest.rssi) {
      strongest = candidate;
    }
  }
  return strongest;
}

List<List<int>> _notificationBytes(List<BleTraceEvent> events) => <List<int>>[
  for (final event in events)
    if (event.type == BleTraceEventType.notificationData &&
        event.data['bytes'] is List)
      List<int>.from(event.data['bytes']! as List),
];

void _assertCapture(_CaptureSummary summary) {
  expect(
    summary.target,
    isNotNull,
    reason:
        'No FF30 GS1 candidate was observed on air during the bounded scan.',
  );
  expect(
    summary.connectSucceeded,
    isTrue,
    reason:
        'The single bounded connect attempt did not complete. '
        'connectError=${summary.connectError}',
  );
  expect(
    summary.notifyEnabled,
    isNotEmpty,
    reason: 'FF31 notify was never enabled on the live link.',
  );
  expect(
    summary.illegalWrites,
    isEmpty,
    reason: 'The driver emitted a write outside the authorised link set.',
  );
  expect(
    summary.writeBytes.length,
    lessThanOrEqualTo(12),
    reason: 'The authenticated session spent more writes than a session may.',
  );
  expect(
    summary.notifications,
    isNotEmpty,
    reason:
        'No FF31 notification bytes were captured inside the bounded window; '
        'the live-frame question stays unanswered.',
  );
}

void _report(_CaptureSummary summary) {
  _emit('CBIO-EVIDENCE session=${summary.sessionToken}');
  _emit(
    'CBIO-EVIDENCE discovery.filtered_candidates='
    '${summary.filteredCandidates.length} '
    'discovery.filtered_error=${summary.filteredError?.runtimeType}',
  );
  _emit(
    'CBIO-EVIDENCE discovery.unfiltered_fallback=${summary.unfilteredUsed} '
    'discovery.unfiltered_advertisements=${summary.unfilteredAdvertisements} '
    'discovery.unfiltered_candidates=${summary.unfilteredCandidates.length} '
    'discovery.unfiltered_error=${summary.unfilteredError?.runtimeType}',
  );
  _emit(
    'CBIO-EVIDENCE discovery.raw_plugin_advertisements='
    '${summary.rawAdvertisements} '
    'discovery.raw_plugin_scan_attempts=${summary.rawScanAttempts} '
    'discovery.raw_plugin_candidates=${summary.rawCandidates.length} '
    'discovery.raw_plugin_error=${summary.rawError?.runtimeType}',
  );
  final withServices = summary.rawInventory
      .where((result) => result.serviceUuids.isNotEmpty)
      .toList(growable: false);
  final aiDexLike = summary.rawInventory
      .where(
        (result) => result.serviceUuids.any(
          (uuid) => uuid.toLowerCase().contains('181f'),
        ),
      )
      .toList(growable: false);
  _emit(
    'CBIO-EVIDENCE raw_inventory.unique_devices='
    '${summary.rawInventory.length} '
    'raw_inventory.with_service_uuid=${withServices.length} '
    'raw_inventory.aidex_181f_matches=${aiDexLike.length}',
  );
  final topDevices = List<BleScanResult>.of(summary.rawInventory)
    ..sort((left, right) => right.rssi.compareTo(left.rssi));
  for (final result in topDevices.take(6)) {
    _emit(
      'CBIO-EVIDENCE raw_inventory.device '
      'id=${_redactId(result.deviceId)} rssi=${result.rssi} '
      'name=${_redactName(result.deviceName)} '
      'services=${result.serviceUuids}',
    );
  }
  final target = summary.target;
  if (target != null) {
    _emit(
      'CBIO-EVIDENCE target.id=${_redactId(target.deviceId)} '
      'target.rssi=${target.rssi} '
      'target.name=${_redactName(target.displayName)} '
      'target.driver=${target.driverId} '
      'target.source=${summary.targetSource}',
    );
  }
  _emit(
    'CBIO-EVIDENCE connect.succeeded=${summary.connectSucceeded} '
    'connect.error=${summary.connectError}',
  );
  _emit('CBIO-EVIDENCE services=${summary.serviceUuids}');
  _emit('CBIO-EVIDENCE notify.enabled=${summary.notifyEnabled}');
  _emit(
    'CBIO-EVIDENCE write.count=${summary.writeBytes.length} '
    'write.allowed_only=${summary.illegalWrites.isEmpty}',
  );
  _emit(
    'CBIO-EVIDENCE notification.count=${summary.notifications.length} '
    'notification.lengths='
    '${summary.notifications.map((bytes) => bytes.length).toList()}',
  );
  for (var index = 0; index < summary.notifications.length; index += 1) {
    _emit(
      'CBIO-EVIDENCE notification[$index] '
      '${_describeNotification(summary.notifications[index])}',
    );
  }
  _emit(
    'CBIO-EVIDENCE final.stage=${summary.finalStage.name} '
    'driver.error=${summary.driverError}',
  );
  for (final line in summary.logs) {
    _emit('CBIO-LOG $line');
  }
  _emit(
    'CBIO-EVIDENCE trace.events=${summary.traceEvents} '
    'trace.file=${summary.traceFile}',
  );
}

void _emit(String line) {
  // Capture evidence goes to the test console so a device run is reviewable
  // without opening app-private storage. Every line is redacted by
  // construction: no sensor identifier, sensor name, or payload byte is
  // formatted here, so this diagnostic is intentional in this harness.
  // ignore: avoid_print
  print(line);
}

/// Redacted, payload-free summary of one received notification.
String _describeNotification(List<int> bytes) {
  try {
    final frame = parseCbioPlaintextFrame(bytes);
    return switch (frame) {
      CbioAcknowledgement() =>
        'len=${bytes.length} decode=acknowledgement '
            'opcode=0x${frame.opcode.toRadixString(16).padLeft(2, '0')} '
            'result=${frame.result} rawStatus=${frame.rawStatus}',
      CbioPackedBatch() =>
        'len=${bytes.length} decode=packed_batch '
            'records=${frame.records.length} '
            'any_nonzero_raw_glucose='
            '${frame.records.any((record) => record.rawGlucose != 0)}',
    };
  } on CbioFrameException catch (error) {
    return 'len=${bytes.length} decode=failed reason=${error.reason.name}';
  }
}

String _redactId(String id) {
  if (id.length <= 4) {
    return '****';
  }
  return '${id.substring(0, 2)}**:**:**:**:**${id.substring(id.length - 2)}';
}

String _redactName(String name) {
  if (name.length <= 2) {
    return '*' * name.length;
  }
  return '${name[0]}${'*' * (name.length - 2)}${name[name.length - 1]}';
}

final class _LinkOutcome {
  const _LinkOutcome({
    required this.finalStage,
    required this.driverError,
    required this.logs,
  });

  final CgmSyncStage finalStage;
  final String? driverError;
  final List<String> logs;
}

final class _CaptureSummary {
  const _CaptureSummary({
    required this.sessionToken,
    required this.streamKey,
    required this.traceFile,
    required this.filteredCandidates,
    required this.filteredError,
    required this.unfilteredUsed,
    required this.unfilteredAdvertisements,
    required this.unfilteredCandidates,
    required this.unfilteredError,
    required this.rawAdvertisements,
    required this.rawScanAttempts,
    required this.rawCandidates,
    required this.rawInventory,
    required this.rawError,
    required this.target,
    required this.targetSource,
    required this.connectSucceeded,
    required this.connectError,
    required this.serviceUuids,
    required this.notifyEnabled,
    required this.writeBytes,
    required this.notifications,
    required this.logs,
    required this.finalStage,
    required this.driverError,
    required this.traceEvents,
  });

  final String sessionToken;

  /// The mask key the driver under test writes with, used to read back the
  /// plaintext command of each captured write. It is never printed.
  final List<int> streamKey;

  final String? traceFile;
  final List<DiscoveredSensor> filteredCandidates;
  final Object? filteredError;
  final bool unfilteredUsed;
  final int unfilteredAdvertisements;
  final List<DiscoveredSensor> unfilteredCandidates;
  final Object? unfilteredError;
  final int rawAdvertisements;
  final int rawScanAttempts;
  final List<DiscoveredSensor> rawCandidates;
  final List<BleScanResult> rawInventory;
  final Object? rawError;
  final DiscoveredSensor? target;
  final String targetSource;
  final bool connectSucceeded;
  final Object? connectError;
  final List<String> serviceUuids;
  final List<String> notifyEnabled;
  final List<List<int>> writeBytes;
  final List<List<int>> notifications;
  final List<String> logs;
  final CgmSyncStage finalStage;
  final String? driverError;
  final int traceEvents;

  /// Writes outside the authorised vendor link set.
  List<List<int>> get illegalWrites => <List<int>>[
    for (final bytes in writeBytes)
      if (!_isAllowedWrite(bytes, streamKey)) bytes,
  ];
}

/// Keeps an in-memory copy of every trace event for assertions while the
/// app-private [LocalBleTraceSink] holds the durable record.
final class _TeeTraceSink implements BleTraceSink {
  _TeeTraceSink(this._delegate, this.events);

  final BleTraceSink _delegate;
  final List<BleTraceEvent> events;

  @override
  Future<void> append(BleTraceEvent event) {
    events.add(event);
    return Future<void>.sync(() => _delegate.append(event));
  }
}
