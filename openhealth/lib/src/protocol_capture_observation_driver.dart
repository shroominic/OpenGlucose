import 'package:cgm_core/cgm_core.dart';

/// Fail-closed app surface for a physical protocol-capture build.
///
/// The separately configured capture transport owns passive observation.
/// This driver uses a distinct identity so stored production selections are
/// not restored, exposes no logical discoveries, and cannot connect.
final class ProtocolCaptureObservationDriver implements CgmDriver {
  const ProtocolCaptureObservationDriver();

  @override
  String get driverId => 'protocol_capture_observation';

  @override
  Stream<DiscoveredSensor> scan({
    Duration? timeout,
    bool allowDuplicates = true,
  }) => const Stream<DiscoveredSensor>.empty();

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) =>
      Future<CgmSession>.error(
        UnsupportedCapabilityException(
          'Protocol capture does not authorize a sensor connection.',
        ),
      );
}
