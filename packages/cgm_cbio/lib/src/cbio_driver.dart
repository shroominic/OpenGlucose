import 'package:cgm_ble/cgm_ble.dart';
import 'package:cgm_core/cgm_core.dart';

/// UUID candidates recovered from both SiSensing GS1 and GS3 Java payloads.
/// Shared UUIDs do not establish a sensor model or protocol compatibility.
abstract final class CbioUuids {
  static const String service = '0000ff30-0000-1000-8000-00805f9b34fb';
  static const String receive = '0000ff31-0000-1000-8000-00805f9b34fb';
  static const String command = '0000ff32-0000-1000-8000-00805f9b34fb';
}

/// Pure candidate mapping; performs no Bluetooth operations.
final class CbioDiscovery {
  const CbioDiscovery();

  static const List<String> scanServiceUuids = <String>[CbioUuids.service];

  DiscoveredSensor? mapScanResult(BleScanResult result) {
    final matches = result.serviceUuids.any((uuid) {
      final normalized = uuid.trim().toLowerCase();
      return normalized == CbioUuids.service ||
          normalized == 'ff30' ||
          normalized == '0000ff30';
    });
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

/// A reserved driver contract for offline work, with no transport access.
///
/// This scaffold deliberately accepts no [BleTransport]. Neither direct calls
/// nor restored sensor metadata can start radio operations. Registration in a
/// physical scan registry still needs a separate live implementation and
/// target verification. Discovery candidates cannot enable a live session.
final class CbioSensorDriver implements CgmDriver {
  const CbioSensorDriver();

  static const CgmCapabilities capabilities = CgmCapabilities();

  @override
  String get driverId => 'cbio';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) =>
      Stream<DiscoveredSensor>.error(const CbioProtocolUnavailableException());

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) =>
      Future<CgmSession>.error(const CbioProtocolUnavailableException());
}

/// An identifier-free failure, distinct from an empty successful scan.
final class CbioProtocolUnavailableException implements Exception {
  const CbioProtocolUnavailableException();

  String get diagnosticCode => 'cgm.cbio.protocol-unavailable';

  @override
  String toString() =>
      'CbioProtocolUnavailableException: Cbio GS1 live protocol is unavailable.';
}
