import 'byte_utils.dart';
import 'checksum.dart';
import 'errors.dart';
import 'transform.dart';

/// Pure CT5 command encoders. This class performs no Bluetooth I/O.
abstract final class YuwellCt5Commands {
  static const versionCommand = 0x01;
  static const selfCheckCommand = 0x05;
  static const setDateCommand = 0x03;
  static const checkIdCommand = 0x31;
  static const initializeCommand = 0x06;
  static const lowPowerCommand = 0x0f;
  static const bindingStatusCommand = 0x11;
  static const setParametersCommand = 0x38;
  static const querySensorCodeCommand = 0x3f;
  static const historyCommand = 0x37;
  static const alternateHistoryCommand = 0x47;
  static const liveCommand = 0x35;
  static const alternateLiveCommand = 0x45;

  /// Returns the one-byte version query.
  static List<int> readVersion() => const <int>[versionCommand];

  static List<int> selfCheck() =>
      appendYuwellSum8(const <int>[selfCheckCommand, 0x55, 0xaa]);

  /// Encodes a reconnect-safe check-ID query with exactly four challenge bytes.
  static List<int> checkId(Iterable<int> challenge) {
    final bytes = checkedArgumentBytes(challenge, field: 'challenge');
    if (bytes.length != 4) {
      throw ArgumentError.value(
        bytes.length,
        'challenge',
        'must contain exactly four bytes',
      );
    }
    return appendYuwellSum8(<int>[checkIdCommand, ...bytes]);
  }

  /// Encodes the literal calendar fields in [localDateTime].
  ///
  /// No timezone conversion is done. The CT5 year field is `year - 1900`.
  static List<int> setDate(DateTime localDateTime) {
    final year = localDateTime.year - 1900;
    if (year < 0 || year > 0xff) {
      throw RangeError.range(
        localDateTime.year,
        1900,
        2155,
        'localDateTime.year',
      );
    }
    return appendYuwellSum8(<int>[
      setDateCommand,
      year,
      localDateTime.month,
      localDateTime.day,
      localDateTime.hour,
      localDateTime.minute,
      localDateTime.second,
    ]);
  }

  /// Encodes a target-unverified CT5 history query.
  static List<int> readHistory({required int startIndex, int recordCount = 1}) {
    return readHistoryVariant(
      startIndex: startIndex,
      recordCount: recordCount,
      transmitterComputed: false,
    );
  }

  /// Encodes a CT5 history query for the selected record family.
  static List<int> readHistoryVariant({
    required int startIndex,
    int recordCount = 1,
    required bool transmitterComputed,
  }) {
    RangeError.checkValueInInterval(startIndex, 0, 0xffff, 'startIndex');
    RangeError.checkValueInInterval(recordCount, 1, 0xff, 'recordCount');
    return appendYuwellSum8(<int>[
      transmitterComputed ? alternateHistoryCommand : historyCommand,
      startIndex & 0xff,
      (startIndex >> 8) & 0xff,
      recordCount,
    ]);
  }

  static List<int> querySensorCode() =>
      appendYuwellSum8(const <int>[querySensorCodeCommand, 0x55, 0xaa]);

  static List<int> enterLowPower() =>
      appendYuwellSum8(const <int>[lowPowerCommand, 0x55, 0xaa]);

  /// Read-only binding/reset status query. This does not reset the sensor.
  static List<int> readBindingStatus() =>
      appendYuwellSum8(const <int>[bindingStatusCommand, 0x55, 0xaa]);

  /// Encodes the reference initialization branch.
  ///
  /// [transmitterComputed] selects the reference path that asks the
  /// transmitter to provide a display value. The 5P reference initialization
  /// index is 15; callers can override it only after target evidence review.
  static List<int> initialize({
    required bool transmitterComputed,
    int initializationIndex = 15,
  }) {
    RangeError.checkValueInInterval(
      initializationIndex,
      0,
      0xff,
      'initializationIndex',
    );
    if (!transmitterComputed) {
      return appendYuwellSum8(const <int>[initializeCommand, 0x55, 0xaa]);
    }
    return appendYuwellSum8(<int>[
      initializeCommand,
      initializationIndex,
      0x01,
    ]);
  }

  /// Encodes the authenticated CT5 setup payload.
  ///
  /// The four-character [idPrefix] is transformed together with the setup
  /// fields. No sensor identifier is accepted here.
  static List<int> setParameters({
    required double k,
    required double r,
    required int cipher,
    required String idPrefix,
  }) {
    RangeError.checkValueInInterval(cipher, 0, 0xff, 'cipher');
    if (k < 0 || k >= 256 || r < 0 || r >= 256) {
      throw const YuwellProtocolFormatException(
        'setup coefficients must be in the supported byte range',
      );
    }
    if (!RegExp(r'^\d{4}$').hasMatch(idPrefix)) {
      throw const YuwellProtocolFormatException(
        'setup ID must contain exactly four decimal digits',
      );
    }
    final kInteger = k.floor();
    final rInteger = r.floor();
    final kFraction = ((k * 100).round() - kInteger * 100) & 0xff;
    // The reference wire field rounds R to one decimal place, then stores
    // hundredths. Keep that behavior explicit instead of relying on locale.
    final rRoundedTenths = (r * 10).round() / 10;
    final rFraction = ((rRoundedTenths * 100).round() - rInteger * 100) & 0xff;
    final clear = <int>[
      kInteger,
      kFraction,
      rInteger,
      rFraction,
      0x03,
      0x10,
      0x55,
      0x00,
      ...idPrefix.codeUnits,
    ];
    final wire = YuwellCt5ByteTransform.encode(clear, key: cipher);
    return appendYuwellSum8(<int>[setParametersCommand, ...wire]);
  }

  static List<int> acknowledgeLive({required bool alternate}) =>
      appendYuwellSum8(<int>[
        alternate ? alternateLiveCommand : liveCommand,
        0x55,
        0xaa,
      ]);
}
