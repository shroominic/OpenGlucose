import 'gen1_live_driver.dart';

/// Optional, separately reviewed conversion. Package defaults supply none.
/// Preparation must bind calibration evidence to this exact saved bootstrap;
/// it must not change the sensor, connect, or reserve a login counter.
abstract interface class LibreGen1GlucoseDecoderProvider {
  Future<LibreGen1GlucoseDecoder?> prepare(
    LibreGen1StreamingBootstrap bootstrap,
  );
}

abstract interface class LibreGen1GlucoseDecoder {
  /// Called only after the transport validates the composite's CRC. Inputs
  /// remain restricted device data and must not be logged or retained remotely.
  LibreGen1GlucoseResult decode({
    required List<int> encryptedPacket,
    required DateTime receivedAt,
  });
}

enum LibreGen1GlucoseRejection {
  warmingUp,
  noCurrentSample,
  invalidData,
  unsupported,
}

/// Current sample only. Sensor age and sample age use sensor-relative minutes,
/// not wall-clock timestamps. A value alone does not establish freshness.
final class LibreGen1GlucoseResult {
  const LibreGen1GlucoseResult({
    required this.sensorAgeMinutes,
    this.sampleAgeMinutes,
    this.glucoseMgdl,
    this.rejection,
    this.expectedLifetimeMinutes,
  });
  final int sensorAgeMinutes;
  final int? sampleAgeMinutes;
  final double? glucoseMgdl;
  final LibreGen1GlucoseRejection? rejection;
  final int? expectedLifetimeMinutes;
  @override
  String toString() => 'LibreGen1GlucoseResult(data: <redacted>)';
}
