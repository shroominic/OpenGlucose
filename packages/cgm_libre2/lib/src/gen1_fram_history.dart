import 'gen1_security.dart';

// Raw layout: pinned MIT DiaBLE Libre.swift:122-181, revision
// e6a909c88faeada49f461d30834174cd95db4042. Timing: MIT LibreTools
// SensorData.swift:170-187, revision d54b0883959420e5941ed293ec6b9ef2474b7ed3.
// Required notices are in THIRD_PARTY_NOTICES.md. No factory conversion from
// either reference is included here.

enum LibreGen1FramSampleKind { trend, history }

enum LibreGen1FramHistoryErrorKind {
  invalidTrendIndex,
  invalidHistoryIndex,
  inconsistentHistoryTiming,
}

/// Closed failure without source bytes, sensor identity or counter values.
final class LibreGen1FramHistoryError implements Exception {
  const LibreGen1FramHistoryError(this.kind);

  final LibreGen1FramHistoryErrorKind kind;

  @override
  String toString() =>
      'LibreGen1FramHistoryError(kind: ${kind.name}, data: <redacted>)';
}

/// One six-byte FRAM record, expressed as raw fields, not glucose.
///
/// The sample minute is sensor-relative, never a UTC timestamp. Nonzero
/// quality/error fields and zero raw values are retained, not declared valid.
/// A separately licensed decoder owns conversion and sample acceptance.
final class LibreGen1FramRawSample {
  const LibreGen1FramRawSample._({
    required this.kind,
    required this.sensorMinute,
    required this.rawValue,
    required this.qualityCode,
    required this.qualityFlags,
    required this.hasError,
    required this.rawTemperature,
    required this.temperatureAdjustment,
  });

  final LibreGen1FramSampleKind kind;
  final int sensorMinute;
  final int rawValue;
  final int qualityCode;
  final int qualityFlags;
  final bool hasError;

  /// The encoded twelve-bit field multiplied by four, as in the reference.
  final int rawTemperature;

  /// Signed nine-bit magnitude multiplied by four; negative zero is zero.
  final int temperatureAdjustment;

  @override
  String toString() => 'LibreGen1FramRawSample(data: <redacted>)';
}

/// Bounded, newest-first raw trend/history from one verified Gen1 FRAM image.
///
/// This does not prove a fresh read, a particular sensor/model binding, current
/// lifecycle, or a successful history import. A saved FRAM remains historical.
/// No UTC activation, glucose value, calibration or sensor command is derived.
final class LibreGen1FramHistory {
  LibreGen1FramHistory._({
    required this.sensorAgeMinutes,
    required Iterable<LibreGen1FramRawSample> trend,
    required Iterable<LibreGen1FramRawSample> history,
  }) : trend = List.unmodifiable(trend),
       history = List.unmodifiable(history);

  final int sensorAgeMinutes;
  final List<LibreGen1FramRawSample> trend;
  final List<LibreGen1FramRawSample> history;

  @override
  String toString() => 'LibreGen1FramHistory(data: <redacted>)';
}

/// Parses only an all-three-CRC-verified FRAM value.
///
/// Ring indices identify the next slot to be written. Trend holds up to sixteen
/// one-minute records. History holds up to thirty-two fifteen-minute records;
/// the first historical minute is fifteen, available at sensor age eighteen.
/// Unfilled/pre-start slots are omitted even if their bytes are nonzero.
///
/// The references adjust dates when the history index advances before the age
/// counter, but do not adjust sample identity consistently. Reject that state
/// rather than silently moving a record by fifteen minutes. A caller may ask
/// for another separately owned read; this pure parser never retries.
LibreGen1FramHistory parseLibreGen1FramHistory(LibreGen1DecryptedFram fram) {
  final bytes = fram.value.bytes;
  final age = bytes[316] | (bytes[317] << 8);
  final trendIndex = bytes[26];
  final historyIndex = bytes[27];
  if (trendIndex >= 16) {
    throw const LibreGen1FramHistoryError(
      LibreGen1FramHistoryErrorKind.invalidTrendIndex,
    );
  }
  if (historyIndex >= 32) {
    throw const LibreGen1FramHistoryError(
      LibreGen1FramHistoryErrorKind.invalidHistoryIndex,
    );
  }
  // Avoid host-language negative division/remainder differences at ages 0..2.
  // No historical record has been produced before minute 15 arrives at age 18.
  final historyIntervals = age < 3 ? 0 : (age - 3) ~/ 15;
  if (historyIndex != historyIntervals % 32) {
    throw const LibreGen1FramHistoryError(
      LibreGen1FramHistoryErrorKind.inconsistentHistoryTiming,
    );
  }
  final trendCount = age < 15 ? age + 1 : 16;
  final historyCount = historyIntervals < 32 ? historyIntervals : 32;
  return LibreGen1FramHistory._(
    sensorAgeMinutes: age,
    trend: [
      for (var i = 0; i < trendCount; i += 1)
        _sample(
          bytes,
          28 + ((trendIndex - 1 - i) % 16) * 6,
          LibreGen1FramSampleKind.trend,
          age - i,
        ),
    ],
    history: [
      for (var i = 0; i < historyCount; i += 1)
        _sample(
          bytes,
          124 + ((historyIndex - 1 - i) % 32) * 6,
          LibreGen1FramSampleKind.history,
          (historyIntervals - i) * 15,
        ),
    ],
  );
}

LibreGen1FramRawSample _sample(
  List<int> bytes,
  int offset,
  LibreGen1FramSampleKind kind,
  int minute,
) {
  final magnitude = _bits(bytes, offset, 38, 9) << 2;
  return LibreGen1FramRawSample._(
    kind: kind,
    sensorMinute: minute,
    rawValue: _bits(bytes, offset, 0, 14),
    qualityCode: _bits(bytes, offset, 14, 9),
    qualityFlags: _bits(bytes, offset, 23, 2),
    hasError: _bits(bytes, offset, 25, 1) != 0,
    rawTemperature: _bits(bytes, offset, 26, 12) << 2,
    temperatureAdjustment: _bits(bytes, offset, 47, 1) == 0
        ? magnitude
        : -magnitude,
  );
}

int _bits(List<int> bytes, int offset, int start, int length) {
  var value = 0;
  for (var bit = 0; bit < length; bit += 1) {
    final position = start + bit;
    value |= ((bytes[offset + position ~/ 8] >> (position % 8)) & 1) << bit;
  }
  return value;
}
