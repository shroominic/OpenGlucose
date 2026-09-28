/// CT5 GATT service used by the target-unverified Anytime family.
const yuwellCt5ServiceUuid = '00001000-1212-efde-1523-785feabcd123';

/// CT5 notification/read characteristic.
const yuwellCt5NotifyCharacteristicUuid =
    '00001001-1212-efde-1523-785feabcd123';

/// CT5 write characteristic.
const yuwellCt5WriteCharacteristicUuid = '00001002-1212-efde-1523-785feabcd123';

/// Model metadata for Anytime 5P. It is not live-device evidence.
abstract final class YuwellAnytime5PMetadata {
  static const warmup = Duration(minutes: 45);
  static const wearPeriod = Duration(days: 16);
  static const sampleInterval = Duration(minutes: 3);
  static const totalSessionDuration = Duration(days: 16, minutes: 45);
  static const warmupSlots = 15;
  static const totalSlots = 7695;

  /// Derived from [wearPeriod] and [sampleInterval].
  static const expectedWearSamples = 16 * 24 * 60 ~/ 3;
}
