// SPDX-License-Identifier: GPL-3.0-only
// Factory conversion and FRAM coefficients adapted from xdripswift contributors.
// BLE layout follows the separately MIT-licensed DiaBLE reference. See notices.
import 'dart:math' as math;

import 'package:cgm_libre2/cgm_libre2.dart';

import 'factory_tables.dart';

/// Static reasons for rejecting a context or complete packet.
enum Libre2Gen1GlucoseErrorKind {
  unsupportedSensor,
  unusableLifecycle,
  invalidCalibration,
  invalidSensorLifetime,
  packetPredatesCalibration,
}

/// Redacted error. Crypto shape/CRC failures remain [LibreProtocolError].
final class Libre2Gen1GlucoseError implements Exception {
  const Libre2Gen1GlucoseError(this.kind);
  final Libre2Gen1GlucoseErrorKind kind;
  @override
  String toString() => 'Libre2Gen1GlucoseError(${kind.name})';
}

/// A rejected sample never contains a glucose value.
enum Libre2Gen1GlucoseRejection {
  sensorError,
  beforeStart,
  warmingUp,
  outsideSensorLifetime,
  invalidTemperature,
  invalidGlucose,
}

/// One reference-derived estimate, not a clinically validated measurement.
final class Libre2Gen1GlucoseSample {
  const Libre2Gen1GlucoseSample._({
    required this.sensorMinute,
    required this.isHistory,
    required this.glucoseMgDl,
    required this.rejection,
    required this.qualityCode,
    required this.qualityFlags,
  });

  final int sensorMinute;
  final bool isHistory;
  final int? glucoseMgDl;
  final Libre2Gen1GlucoseRejection? rejection;

  /// BLE: the full 12-bit temperature/error field when raw glucose is zero.
  /// NFC: the nine-bit FRAM quality code, even when raw glucose is nonzero.
  /// Unknown bits are retained, not treated as an OK sample.
  final int qualityCode;

  /// The two encoded quality flags from the corresponding BLE or NFC layout.
  final int qualityFlags;

  @override
  String toString() =>
      'Libre2Gen1GlucoseSample(data: <redacted>, '
      'rejection: ${rejection?.name ?? 'none'})';
}

/// Seven sparse trend and three history samples, in packet order.
///
/// Age is the sensor counter, not wall-clock time or current lifecycle proof.
final class Libre2Gen1GlucosePacket {
  Libre2Gen1GlucosePacket._(
    this.sensorAgeMinutes,
    Iterable<Libre2Gen1GlucoseSample> samples,
  ) : samples = List.unmodifiable(samples);
  final int sensorAgeMinutes;
  final List<Libre2Gen1GlucoseSample> samples;
  Libre2Gen1GlucoseSample get current => samples.first;
  @override
  String toString() => 'Libre2Gen1GlucosePacket(data: <redacted>)';
}

/// Factory estimates from the trend/history rings of one verified NFC read.
///
/// Both lists are immutable, newest-first, and retain rejected slots without
/// substituting glucose. Age/minute are counters, not dates. This pure value
/// does not prove when the read occurred or that it belongs to a live receiver.
final class Libre2Gen1GlucoseNfcScan {
  Libre2Gen1GlucoseNfcScan._({
    required this.sensorAgeMinutes,
    required this.maxLifeMinutes,
    required this.lifecycleAtScan,
    required Iterable<Libre2Gen1GlucoseSample> trend,
    required Iterable<Libre2Gen1GlucoseSample> history,
  }) : trend = List.unmodifiable(trend),
       history = List.unmodifiable(history);

  final int sensorAgeMinutes;
  final int maxLifeMinutes;
  final LibreGen1LifecycleState lifecycleAtScan;
  final List<Libre2Gen1GlucoseSample> trend;
  final List<Libre2Gen1GlucoseSample> history;

  @override
  String toString() => 'Libre2Gen1GlucoseNfcScan(data: <redacted>)';
}

/// Decode one encrypted NFC snapshot with its own factory evidence.
///
/// The caller must bind UID/current patch/FRAM to the same fresh exact-target
/// NFC read. This function cannot prove freshness, authenticity, or a receiver
/// binding. In particular, cached FRAM must not be relabelled as a new scan.
/// There is no existing decoder/calibration argument: ring values, lifecycle,
/// lifetime, age, and factory coefficients all come from this one CRC-verified
/// snapshot using its current patch seed, not the frozen BLE login patch.
Libre2Gen1GlucoseNfcScan decodeLibre2Gen1EncryptedNfcFram({
  required Iterable<int> uid,
  required Iterable<int> currentPatchInfo,
  required Iterable<int> encryptedFram,
}) {
  final (core, verified) = _decryptFactoryFram(
    uid: uid,
    patchInfo: currentPatchInfo,
    encryptedFram: encryptedFram,
  );
  final decoder = Libre2Gen1GlucoseDecoder._fromVerifiedFram(core, verified);
  final rings = parseLibreGen1FramHistory(verified);
  Libre2Gen1GlucoseSample convert(LibreGen1FramRawSample sample) {
    var (glucose, rejection) = decoder._decodeSample(
      age: rings.sensorAgeMinutes,
      minute: sample.sensorMinute,
      raw: sample.rawValue,
      temperature: sample.rawTemperature,
      adjustment: sample.temperatureAdjustment,
      sensorError:
          sample.rawValue == 0 ||
          sample.hasError ||
          sample.qualityCode != 0 ||
          sample.qualityFlags != 0,
    );
    // Unlike cached BLE calibration evidence, this is the sensor's current
    // lifecycle. A contradictory age must not override fresh warm-up state.
    if (decoder.lifecycleAtFram == LibreGen1LifecycleState.warmingUp &&
        glucose != null) {
      glucose = null;
      rejection = Libre2Gen1GlucoseRejection.warmingUp;
    }
    return Libre2Gen1GlucoseSample._(
      sensorMinute: sample.sensorMinute,
      isHistory: sample.kind == LibreGen1FramSampleKind.history,
      glucoseMgDl: glucose,
      rejection: rejection,
      qualityCode: sample.qualityCode,
      qualityFlags: sample.qualityFlags,
    );
  }

  return Libre2Gen1GlucoseNfcScan._(
    sensorAgeMinutes: rings.sensorAgeMinutes,
    maxLifeMinutes: decoder.maxLifeMinutes,
    lifecycleAtScan: decoder.lifecycleAtFram,
    trend: rings.trend.map(convert),
    history: rings.history.map(convert),
  );
}

(LibreGen1OfflineCore, LibreGen1DecryptedFram) _decryptFactoryFram({
  required Iterable<int> uid,
  required Iterable<int> patchInfo,
  required Iterable<int> encryptedFram,
}) {
  final identity = LibreGen1Uid.algorithmOrder(uid);
  final patch = LibreGen1PatchInfo(patchInfo);
  if (identity.value.bytes[6] != 0x07 ||
      identity.value.bytes[7] != 0xe0 ||
      patch.model != LibreGen1Model.libre2) {
    throw const Libre2Gen1GlucoseError(
      Libre2Gen1GlucoseErrorKind.unsupportedSensor,
    );
  }
  final core = LibreGen1OfflineCore(uid: identity, patchInfo: patch);
  return (core, core.decryptFram(encryptedFram));
}

/// A pure decoder bound to one UID and its initial patch information/FRAM.
///
/// The caller must prove that all three inputs came from the SAME protected
/// receiver bootstrap. CRC checks are integrity checks, not authentication.
/// The decoder does not deduplicate packets or establish a current lifecycle.
/// A warming-up FRAM snapshot remains historical even after the age reaches 60.
/// No sensor control, native storage, clock, network or mutable state is used.
final class Libre2Gen1GlucoseDecoder {
  factory Libre2Gen1GlucoseDecoder.fromEncryptedFram({
    required Iterable<int> uid,
    required Iterable<int> initialPatchInfo,
    required Iterable<int> encryptedFram,
  }) {
    final (core, verified) = _decryptFactoryFram(
      uid: uid,
      patchInfo: initialPatchInfo,
      encryptedFram: encryptedFram,
    );
    return Libre2Gen1GlucoseDecoder._fromVerifiedFram(core, verified);
  }

  factory Libre2Gen1GlucoseDecoder._fromVerifiedFram(
    LibreGen1OfflineCore core,
    LibreGen1DecryptedFram verified,
  ) {
    final lifecycle = parseLibreGen1Lifecycle(verified).state;
    if (lifecycle != LibreGen1LifecycleState.warmingUp &&
        lifecycle != LibreGen1LifecycleState.active) {
      throw const Libre2Gen1GlucoseError(
        Libre2Gen1GlucoseErrorKind.unusableLifecycle,
      );
    }
    final fram = verified.value.bytes;
    final age = _bits(fram, 316, 0, 16);
    final maxLife = _bits(fram, 326, 0, 16);
    if (maxLife <= 0 || age > maxLife) {
      throw const Libre2Gen1GlucoseError(
        Libre2Gen1GlucoseErrorKind.invalidSensorLifetime,
      );
    }
    final index = _bits(fram, 2, 3, 10);
    var offset = _bits(fram, 0x150, 0, 8);
    if (_bits(fram, 0x150, 0x21, 1) != 0) offset = -offset;
    final scale = _bits(fram, 0x150, 8, 14);
    final temperatureReference = _bits(fram, 0x150, 0x34, 12) << 2;
    if (index == 0 ||
        index > factoryT1.length ||
        index > factoryT2.length ||
        scale <= offset ||
        temperatureReference == 0) {
      throw const Libre2Gen1GlucoseError(
        Libre2Gen1GlucoseErrorKind.invalidCalibration,
      );
    }
    return Libre2Gen1GlucoseDecoder._(
      core,
      age,
      maxLife,
      lifecycle,
      index - 1,
      offset,
      scale,
      temperatureReference,
    );
  }

  const Libre2Gen1GlucoseDecoder._(
    this._core,
    this.framAgeMinutes,
    this.maxLifeMinutes,
    this.lifecycleAtFram,
    this._tableIndex,
    this._offset,
    this._scale,
    this._temperatureReference,
  );

  final LibreGen1OfflineCore _core;
  final int _tableIndex;
  final int _offset;
  final int _scale;
  final int _temperatureReference;
  final int framAgeMinutes;
  final int maxLifeMinutes;
  final LibreGen1LifecycleState lifecycleAtFram;

  /// Decrypt, check the packet CRC, parse, and apply the factory reference.
  ///
  /// Raw zero is an error record. Samples from the first 60 minutes and outside
  /// the declared sensor lifetime do not yield glucose. No default slope,
  /// placeholder, smoothing, clinical clipping, or ADC/10 conversion exists.
  Libre2Gen1GlucosePacket decodeEncryptedBle(Iterable<int> encryptedPacket) {
    final data = _core.decryptBle(encryptedPacket).value.bytes;
    final age = _bits(data, 40, 0, 16);
    if (age < framAgeMinutes) {
      throw const Libre2Gen1GlucoseError(
        Libre2Gen1GlucoseErrorKind.packetPredatesCalibration,
      );
    }
    const offsets = <int>[0, 2, 4, 6, 7, 12, 15];
    final samples = <Libre2Gen1GlucoseSample>[];
    for (var i = 0; i < 10; i++) {
      final minute = i < 7
          ? age - offsets[i]
          : ((age - 2) ~/ 15) * 15 - 15 * (i - 7);
      final raw = _bits(data, i * 4, 0, 14);
      final encodedTemperature = _bits(data, i * 4, 14, 12);
      final temperature = encodedTemperature << 2;
      var adjustment = _bits(data, i * 4, 26, 5) << 2;
      if (_bits(data, i * 4, 31, 1) != 0) adjustment = -adjustment;
      final (glucose, rejection) = _decodeSample(
        age: age,
        minute: minute,
        raw: raw,
        temperature: temperature,
        adjustment: adjustment,
        sensorError: raw == 0,
      );
      samples.add(
        Libre2Gen1GlucoseSample._(
          sensorMinute: minute,
          isHistory: i >= 7,
          glucoseMgDl: glucose,
          rejection: rejection,
          qualityCode: raw == 0 ? encodedTemperature : 0,
          qualityFlags: raw == 0 ? (encodedTemperature & 0x600) >> 9 : 0,
        ),
      );
    }
    return Libre2Gen1GlucosePacket._(age, samples);
  }

  (int?, Libre2Gen1GlucoseRejection?) _decodeSample({
    required int age,
    required int minute,
    required int raw,
    required int temperature,
    required int adjustment,
    required bool sensorError,
  }) {
    if (sensorError) return (null, Libre2Gen1GlucoseRejection.sensorError);
    if (minute < 0) return (null, Libre2Gen1GlucoseRejection.beforeStart);
    if (minute < 60) return (null, Libre2Gen1GlucoseRejection.warmingUp);
    if (age >= maxLifeMinutes || minute >= maxLifeMinutes) {
      return (null, Libre2Gen1GlucoseRejection.outsideSensorLifetime);
    }
    return _convert(raw, temperature, adjustment);
  }

  (int?, Libre2Gen1GlucoseRejection?) _convert(
    int raw,
    int rawTemperature,
    int adjustment,
  ) {
    // GPL factory algorithm: exact coefficients/operation order from the pinned
    // xdripswift method. Additional checks reject invalid mathematical domains.
    final denominator = adjustment + _temperatureReference;
    final resistance = rawTemperature * 72500.0 / denominator - 1000.0;
    if (denominator <= 0 || resistance <= 0 || !resistance.isFinite) {
      return (null, Libre2Gen1GlucoseRejection.invalidTemperature);
    }
    final logR = math.log(resistance);
    final d =
        math.pow(logR, 3) * 0.00000005283566 +
        math.pow(logR, 2) * 0.0000007061775 +
        logR * 0.0001964561 +
        0.0009180023;
    if (!d.isFinite || d <= 0) {
      return (null, Libre2Gen1GlucoseRejection.invalidTemperature);
    }
    final temperature = 1 / d - 273.15;
    final g1 = 65.0 * (raw - _offset) / (_scale - _offset);
    final g2 = math.pow(1.045, 32.5 - temperature);
    final value = (g1 * g2 - factoryT1[_tableIndex]) / factoryT2[_tableIndex];
    // This is a representation/domain check, not a clinical range threshold.
    if (!value.isFinite ||
        value <= 0 ||
        value > 0x7fffffff ||
        value.round() <= 0) {
      return (null, Libre2Gen1GlucoseRejection.invalidGlucose);
    }
    return (value.round(), null);
  }

  @override
  String toString() => 'Libre2Gen1GlucoseDecoder(data: <redacted>)';
}

int _bits(List<int> bytes, int byteOffset, int bitOffset, int count) {
  var value = 0;
  for (var i = 0; i < count; i++) {
    final bit = byteOffset * 8 + bitOffset + i;
    value |= ((bytes[bit ~/ 8] >> (bit % 8)) & 1) << i;
  }
  return value;
}
