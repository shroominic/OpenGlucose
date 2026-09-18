import 'dart:async';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

import 'cbio_credentials.dart';
import 'cbio_glucose_session.dart';

/// UUID candidates recovered from both SiSensing GS1 and GS3 Java payloads.
/// Shared UUIDs do not establish a sensor model or protocol compatibility.
abstract final class CbioUuids {
  static const String service = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const String receive = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const String command = '0000ff32-0000-1000-8000-00805f9b34fb';

  /// Serial-number characteristic. On the examined GS1 it already reports the
  /// Bluetooth address in the vendor's reversed byte order.
  static const String serial = '00002a25-0000-1000-8000-00805f9b34fb';

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

/// Live Cbio GS1 driver.
///
/// Discovers the FF30 service and hands the connection to
/// [CbioGlucoseSession], which authenticates the link, ingests the pushed raw
/// history, and polls for live records. The session is fail-closed: only the
/// vendor link set-up and read frames are ever written, and activation,
/// reset, threshold, calibration, key-registration, and firmware frames are
/// rejected before the radio sees them.
class CbioSensorDriver implements CgmDriver {
  CbioSensorDriver(
    this._transport, {
    this.discovery = const CbioDiscovery(),
    this.credentials = const CbioDefineCredentialSource(),
    this.timing = const CbioSessionTiming(),
    this.clock = DateTime.now,
  });

  final BleTransport _transport;
  final CbioDiscovery discovery;

  /// Where the session resolves the vendor material its link needs.
  ///
  /// The default reads `--dart-define` values and fails closed when the build
  /// did not carry them; see `cbio_credentials.dart`.
  final CbioCredentialSource credentials;

  final CbioSessionTiming timing;
  final DateTime Function() clock;

  /// Whether this driver can open its authenticated link at all.
  ///
  /// A registry that would otherwise surface a sensor it cannot read can ask
  /// this before registering the driver.
  bool get canAuthenticate => credentials.isConfigured;

  static const CgmCapabilities capabilities = CbioGlucoseSession.capabilities;

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) async* {
    final seen = <String, DiscoveredSensor>{};

    Stream<DiscoveredSensor> pass(List<String>? withServices) async* {
      await for (final result in _transport.scan(
        timeout: timeout,
        allowDuplicates: allowDuplicates,
        withServices: withServices,
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

    // The FF30-filtered pass is the cheapest discovery path and stays first.
    // This sensor's advertisement does not always carry the service UUID on
    // the layer Android filters, so a filtered pass can finish with no
    // candidate even while the sensor is advertising a few centimetres away.
    // One unfiltered retry keeps discovery working without widening what the
    // driver accepts: results are still classified by the same FF30 mapping,
    // so a foreign advertiser is never surfaced as a Cbio sensor.
    var surfaced = false;
    await for (final candidate in pass(CbioDiscovery.scanServiceUuids)) {
      surfaced = true;
      yield candidate;
    }
    if (surfaced) {
      return;
    }
    yield* pass(null);
  }

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async {
    final session = CbioGlucoseSession(
      sensor: sensor,
      transport: _transport,
      credentials: credentials,
      timing: timing,
      clock: clock,
    );
    unawaited(session.initialize());
    return session;
  }
}

enum CbioProtocolFailure {
  missingNotifyCharacteristic,
  notifyUnavailable,
  missingWriteCharacteristic,
}

/// A closed, identifier-free failure from the read-only Cbio session.
final class CbioProtocolException implements Exception {
  const CbioProtocolException(this.failure);

  final CbioProtocolFailure failure;

  String get diagnosticCode => 'cgm.cbio.live.${failure.name}';

  @override
  String toString() => 'CbioProtocolException(${failure.name})';
}
