import 'errors.dart';

/// The fixed-width CT5 calibration-code layout selected by the reference app.
enum YuwellCt5CalibrationCodeFormat {
  /// The older 17-character layout, with two K digits.
  legacy17,

  /// The older 18-character layout, with three K digits.
  legacy18,

  /// The 21-character layout with explicit market and lifetime codes.
  extendedMarket,

  /// The 21-character layout whose first two characters are both zero.
  extendedZeroPrefix,
}

/// Calibration metadata decoded from a CT5 SSN response.
///
/// This is a clean-room, fixed-position decoder. It does not retain the source
/// code and [toString] does not expose decoded identifiers.
final class YuwellCt5CalibrationCode {
  const YuwellCt5CalibrationCode._({
    required this.format,
    required this.marketNumber,
    required this.lifeTimeCode,
    required this.electrodeType,
    required this.yearCode,
    required this.serialNumber,
    required this.unitOrder,
    required this.sensorNumber,
    required this.calibrationCode,
    required this.k,
    required this.r,
    required this.electrodeTechnologyCode,
    required this.enzymeTechnologyCode,
    required this.membraneTechnologyCode,
  });

  static final RegExp _legacyPattern = RegExp(
    r'^[A-Z0-9][0-9](0[1-9]|[1-9][0-9]|[A-Z][1-9A-Z])'
    r'(00[1-9]|0[1-9][0-9]|[1-9][0-9][0-9]){2}'
    r'[0-9]{4,5}[0-9A-Z]{3}$',
  );

  static final RegExp _extendedMarketPattern = RegExp(
    r'^[1-9A-HJ-NP-Za-hj-np-z][1-9][A-Z0-9][0-9]'
    r'(0[1-9]|[1-9][0-9]|[A-Z][1-9A-Z])'
    r'(00[1-9]|0[1-9][0-9]|[1-9][0-9][0-9]){2}'
    r'[0-9]{6}[0-9A-Z]{3}$',
  );

  static final RegExp _extendedZeroPrefixPattern = RegExp(
    r'^00[A-Z0-9][0-9]'
    r'(0[1-9]|[1-9][0-9]|[A-Z][1-9A-Z])'
    r'(00[1-9]|0[1-9][0-9]|[1-9][0-9][0-9]){2}'
    r'[0-9]{6}[0-9A-Z]{3}$',
  );

  /// Parses a decrypted CT5 SSN/calibration code.
  ///
  /// Throws [YuwellProtocolFormatException] for every unsupported layout. The
  /// exception deliberately does not include [code].
  factory YuwellCt5CalibrationCode.parse(String code) {
    if (_legacyPattern.hasMatch(code)) {
      return _parseLegacy(code);
    }
    if (_extendedMarketPattern.hasMatch(code)) {
      return _parseExtended(
        code,
        format: YuwellCt5CalibrationCodeFormat.extendedMarket,
      );
    }
    if (_extendedZeroPrefixPattern.hasMatch(code)) {
      return _parseExtended(
        code,
        format: YuwellCt5CalibrationCodeFormat.extendedZeroPrefix,
      );
    }
    throw const YuwellProtocolFormatException(
      'Unsupported CT5 calibration-code layout',
    );
  }

  /// Returns a decoded value, or `null` for an unsupported layout.
  static YuwellCt5CalibrationCode? tryParse(String code) {
    try {
      return YuwellCt5CalibrationCode.parse(code);
    } on YuwellProtocolFormatException {
      return null;
    }
  }

  static YuwellCt5CalibrationCode _parseLegacy(String code) {
    final hasThreeDigitK = code.length == 18;
    final rStart = hasThreeDigitK ? 13 : 12;
    final technologyStart = rStart + 2;
    return YuwellCt5CalibrationCode._(
      format: hasThreeDigitK
          ? YuwellCt5CalibrationCodeFormat.legacy18
          : YuwellCt5CalibrationCodeFormat.legacy17,
      marketNumber: null,
      lifeTimeCode: null,
      electrodeType: code.substring(0, 1),
      yearCode: _digitAt(code, 1),
      serialNumber: code.substring(2, 4),
      unitOrder: int.parse(code.substring(4, 7)),
      sensorNumber: code.substring(7, 10),
      calibrationCode: null,
      k: int.parse(code.substring(10, rStart)) / (hasThreeDigitK ? 100 : 10),
      r: int.parse(code.substring(rStart, technologyStart)) / 10,
      electrodeTechnologyCode: code.substring(
        technologyStart,
        technologyStart + 1,
      ),
      enzymeTechnologyCode: code.substring(
        technologyStart + 1,
        technologyStart + 2,
      ),
      membraneTechnologyCode: code.substring(
        technologyStart + 2,
        technologyStart + 3,
      ),
    );
  }

  static YuwellCt5CalibrationCode _parseExtended(
    String code, {
    required YuwellCt5CalibrationCodeFormat format,
  }) {
    return YuwellCt5CalibrationCode._(
      format: format,
      marketNumber: code.substring(0, 1),
      lifeTimeCode: _digitAt(code, 1),
      electrodeType: code.substring(2, 3),
      yearCode: _digitAt(code, 3),
      serialNumber: code.substring(4, 6),
      unitOrder: int.parse(code.substring(6, 9)),
      sensorNumber: code.substring(9, 12),
      calibrationCode: _digitAt(code, 12),
      k: int.parse(code.substring(13, 16)) / 100,
      r: int.parse(code.substring(16, 18)) / 10,
      electrodeTechnologyCode: code.substring(18, 19),
      enzymeTechnologyCode: code.substring(19, 20),
      membraneTechnologyCode: code.substring(20, 21),
    );
  }

  static int _digitAt(String value, int index) =>
      value.codeUnitAt(index) - 0x30;

  final YuwellCt5CalibrationCodeFormat format;

  /// The one-character market code, when the selected layout carries it.
  final String? marketNumber;

  /// The one-digit lifetime code, when the selected layout carries it.
  final int? lifeTimeCode;

  final String electrodeType;

  /// A one-digit production-year code, not a full calendar year.
  final int yearCode;

  final String serialNumber;
  final int unitOrder;
  final String sensorNumber;

  /// The one-digit calibration selector in extended layouts.
  final int? calibrationCode;

  /// The per-sensor K calibration coefficient.
  final double k;

  /// The per-sensor R calibration coefficient.
  final double r;

  final String electrodeTechnologyCode;
  final String enzymeTechnologyCode;
  final String membraneTechnologyCode;

  @override
  String toString() => 'YuwellCt5CalibrationCode(format: $format, <redacted>)';
}
