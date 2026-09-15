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

/// Historical slot type within the existing ten-sample BLE packet.
enum LibreGen1BleHistoryKind { trend, history }

/// One older BLE slot, including rejection. Never a current-reading claim.
final class LibreGen1GlucoseHistorySample {
  const LibreGen1GlucoseHistorySample({
    required this.sampleAgeMinutes,
    required this.kind,
    this.glucoseMgdl,
    this.rejection,
  });

  final int sampleAgeMinutes;
  final LibreGen1BleHistoryKind kind;
  final double? glucoseMgdl;
  final LibreGen1GlucoseRejection? rejection;

  @override
  String toString() => 'LibreGen1GlucoseHistorySample(data: <redacted>)';
}

/// Current sample and separate older slots. Ages are sensor-relative minutes,
/// not wall-clock timestamps. Historical values never establish freshness.
final class LibreGen1GlucoseResult {
  const LibreGen1GlucoseResult({
    required this.sensorAgeMinutes,
    this.sampleAgeMinutes,
    this.glucoseMgdl,
    this.rejection,
    this.expectedLifetimeMinutes,
    this.historySamples = const [],
  });
  final int sensorAgeMinutes;
  final int? sampleAgeMinutes;
  final double? glucoseMgdl;
  final LibreGen1GlucoseRejection? rejection;
  final int? expectedLifetimeMinutes;
  final List<LibreGen1GlucoseHistorySample> historySamples;
  @override
  String toString() => 'LibreGen1GlucoseResult(data: <redacted>)';
}
