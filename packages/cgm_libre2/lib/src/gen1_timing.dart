import 'gen1_lifecycle.dart';
import 'gen1_security.dart';

/// Sensor-relative age reported by one CRC-validated Gen1 BLE payload.
///
/// CRC proves integrity, not authenticity or freshness. This observation has no
/// wall-clock activation time, current lifecycle, or glucose interpretation.
final class LibreGen1BleTiming {
  const LibreGen1BleTiming._(this.elapsedMinutes);

  final int elapsedMinutes;

  @override
  String toString() => 'LibreGen1BleTiming(data: <redacted>)';
}

/// Timing and lifecycle observed in one all-three-CRC-validated FRAM read.
///
/// A stored calibration FRAM is historical, not current lifecycle evidence.
/// Callers must bind a fresh read to their exact target before using it as a
/// current observation. No field authorizes an operation or establishes UTC.
final class LibreGen1FramTiming {
  const LibreGen1FramTiming._({
    required this.elapsedMinutes,
    required this.expectedLifetimeMinutes,
    required this.lifecycle,
  });

  final int elapsedMinutes;

  /// The sensor's reported lifetime; zero is unknown, not a default lifetime.
  final int? expectedLifetimeMinutes;
  final LibreGen1LifecycleState lifecycle;

  @override
  String toString() => 'LibreGen1FramTiming(data: <redacted>)';
}

LibreGen1BleTiming parseLibreGen1BleTiming(
  LibreGen1DecryptedBlePayload payload,
) => LibreGen1BleTiming._(_uint16(payload.value.bytes, 40));

LibreGen1FramTiming parseLibreGen1FramTiming(LibreGen1DecryptedFram fram) {
  final lifetime = _uint16(fram.value.bytes, 326);
  return LibreGen1FramTiming._(
    elapsedMinutes: _uint16(fram.value.bytes, 316),
    expectedLifetimeMinutes: lifetime == 0 ? null : lifetime,
    lifecycle: parseLibreGen1Lifecycle(fram).state,
  );
}

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);
