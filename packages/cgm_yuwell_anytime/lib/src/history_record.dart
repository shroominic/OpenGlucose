import 'byte_utils.dart';
import 'errors.dart';

enum YuwellHistoryRecordLayout { compact11, voltage15, alert17 }

/// A strict, already transformed CT5 history record.
final class YuwellHistoryRecord {
  YuwellHistoryRecord._({
    required this.layout,
    required List<int> rawBytes,
    required this.currentARaw,
    required this.currentBRaw,
    required this.temperatureIntegerRaw,
    required this.temperatureFractionRaw,
    required this.glucoseMgDl,
    required this.trendCode,
    required this.errorCode,
    required List<int> unknownBytes,
    required List<int> electrodeRaw,
    required List<int> electrodeScaled,
    required this.batteryRaw,
    required this.hypoglycemiaWarningMinutes,
    required this.calibrationStatus,
    required this.hyperglycemiaWarningMinutes,
    required this.warningCode,
  }) : rawBytes = List<int>.unmodifiable(rawBytes),
       unknownBytes = List<int>.unmodifiable(unknownBytes),
       electrodeRaw = List<int>.unmodifiable(electrodeRaw),
       electrodeScaled = List<int>.unmodifiable(electrodeScaled);

  factory YuwellHistoryRecord.parse(Iterable<int> input) {
    final bytes = checkedProtocolBytes(input, field: 'history record');
    final layout = switch (bytes.length) {
      11 => YuwellHistoryRecordLayout.compact11,
      15 => YuwellHistoryRecordLayout.voltage15,
      17 => YuwellHistoryRecordLayout.alert17,
      _ => throw const YuwellProtocolFormatException(
        'history record must contain 11, 15, or 17 bytes',
      ),
    };
    if (_isSentinel(bytes, 0xfc) || _isSentinel(bytes, 0xff)) {
      throw const YuwellProtocolFormatException(
        'history record is a no-data sentinel',
      );
    }

    final electrodeRaw = layout == YuwellHistoryRecordLayout.compact11
        ? const <int>[]
        : bytes.sublist(9, 13);
    final electrodeScale = switch (layout) {
      YuwellHistoryRecordLayout.compact11 => 0,
      YuwellHistoryRecordLayout.voltage15 => 6,
      YuwellHistoryRecordLayout.alert17 => 8,
    };
    final firstAlert = layout == YuwellHistoryRecordLayout.alert17
        ? bytes[15]
        : null;
    final secondAlert = layout == YuwellHistoryRecordLayout.alert17
        ? bytes[16]
        : null;

    return YuwellHistoryRecord._(
      layout: layout,
      rawBytes: bytes,
      currentARaw: readUint16BigEndian(bytes, 0),
      currentBRaw: readUint16BigEndian(bytes, 2),
      temperatureIntegerRaw: bytes[4],
      temperatureFractionRaw: bytes[5],
      trendCode: bytes[6] >> 4,
      glucoseMgDl: ((bytes[6] & 0x0f) << 8) | bytes[7],
      errorCode: bytes[8],
      unknownBytes: layout == YuwellHistoryRecordLayout.compact11
          ? bytes.sublist(9, 11)
          : const <int>[],
      electrodeRaw: electrodeRaw,
      electrodeScaled: electrodeRaw
          .map((value) => value * electrodeScale)
          .toList(growable: false),
      batteryRaw: layout == YuwellHistoryRecordLayout.compact11
          ? null
          : readUint16BigEndian(bytes, 13),
      hypoglycemiaWarningMinutes: firstAlert == null
          ? null
          : (firstAlert >> 3) & 0x1f,
      calibrationStatus: firstAlert == null ? null : firstAlert & 0x07,
      hyperglycemiaWarningMinutes: secondAlert == null
          ? null
          : (secondAlert >> 3) & 0x1f,
      warningCode: secondAlert == null ? null : secondAlert & 0x07,
    );
  }

  final YuwellHistoryRecordLayout layout;
  final List<int> rawBytes;
  final int currentARaw;
  final int currentBRaw;
  final int temperatureIntegerRaw;
  final int temperatureFractionRaw;
  final int glucoseMgDl;
  final int trendCode;
  final int errorCode;
  final List<int> unknownBytes;
  final List<int> electrodeRaw;
  final List<int> electrodeScaled;
  final int? batteryRaw;
  final int? hypoglycemiaWarningMinutes;
  final int? calibrationStatus;
  final int? hyperglycemiaWarningMinutes;
  final int? warningCode;

  double get currentA => currentARaw * 0.01;
  double get currentB => currentBRaw * 0.01;
  double get temperatureCelsius =>
      temperatureIntegerRaw - 40 + temperatureFractionRaw * 0.01;

  @override
  String toString() =>
      'YuwellHistoryRecord(layout: $layout, bytes: <redacted>)';
}

bool _isSentinel(List<int> bytes, int value) =>
    bytes.every((byte) => byte == value);
