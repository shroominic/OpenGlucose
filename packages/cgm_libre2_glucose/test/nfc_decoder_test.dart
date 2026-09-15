// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_libre2_glucose/cgm_libre2_glucose.dart';
import 'package:test/test.dart';

import 'support/synthetic.dart';

void main() {
  test('NFC trend and history agree with all pinned Swift factory vectors', () {
    final rows =
        jsonDecode(
              File('test/reference/factory_vectors.json').readAsStringSync(),
            )
            as List;
    expect(rows, hasLength(1023));
    for (final value in rows) {
      final row = (value as List).cast<int>();
      final scan = decode(
        _fram(
          index: row[0],
          offset: row[1],
          scale: row[2],
          reference: row[3],
          raw: row[4],
          temperature: row[5],
          adjustment: row[6],
        ),
      );
      for (final sample in [scan.trend.first, scan.history.first]) {
        expect(sample.glucoseMgDl, row[7], reason: 'synthetic index ${row[0]}');
        expect(sample.rejection, isNull);
      }
    }
  });

  test('ring origin and minutes remain immutable without invented dates', () {
    final scan = decode(_fram(age: 511, trendIndex: 0));
    expect(scan.sensorAgeMinutes, 511);
    expect(scan.maxLifeMinutes, 20160);
    expect(scan.lifecycleAtScan, LibreGen1LifecycleState.active);
    expect(
      scan.trend.map((s) => s.sensorMinute),
      List.generate(16, (i) => 511 - i),
    );
    expect(
      scan.history.map((s) => s.sensorMinute),
      List.generate(32, (i) => 495 - 15 * i),
    );
    expect(scan.trend.every((s) => !s.isHistory), isTrue);
    expect(scan.history.every((s) => s.isHistory), isTrue);
    expect(() => scan.trend.clear(), throwsUnsupportedError);
    expect(() => scan.history.clear(), throwsUnsupportedError);
  });

  test(
    'each NFC call uses its current patch and same-snapshot coefficients',
    () {
      final old = _fram(index: 1);
      final fresh = _fram(index: 1023);
      final oldScan = decode(old);
      final currentPatch = [...syntheticPatch.take(4), 0x78, 0x56];
      final encrypted = encryptedFram(fresh, patchInfo: currentPatch);
      final scan = decodeLibre2Gen1EncryptedNfcFram(
        uid: syntheticUid,
        currentPatchInfo: currentPatch,
        encryptedFram: encrypted,
      );
      final expected =
          Libre2Gen1GlucoseDecoder.fromEncryptedFram(
                uid: syntheticUid,
                initialPatchInfo: currentPatch,
                encryptedFram: encrypted,
              )
              .decodeEncryptedBle(encryptedBle(clearBle(age: 600)))
              .current
              .glucoseMgDl;
      expect(scan.trend.first.glucoseMgDl, expected);
      expect(scan.history.first.glucoseMgDl, expected);
      expect(
        scan.trend.first.glucoseMgDl,
        isNot(oldScan.trend.first.glucoseMgDl),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: syntheticUid,
          currentPatchInfo: syntheticPatch,
          encryptedFram: encrypted,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
      // Decoding a cached snapshot again is deterministic, not a newer scan.
      expect(decode(old).sensorAgeMinutes, oldScan.sensorAgeMinutes);
      expect(
        decode(old).trend.first.glucoseMgDl,
        oldScan.trend.first.glucoseMgDl,
      );
    },
  );

  test('unknown NFC quality bits flags and error bit suppress nonzero raw', () {
    for (final quality in [1, 2, 0x20, 0x100, 0x1ff]) {
      final scan = decode(_fram(quality: quality));
      for (final sample in [...scan.trend, ...scan.history]) {
        expect(sample.glucoseMgDl, isNull);
        expect(sample.rejection, Libre2Gen1GlucoseRejection.sensorError);
        expect(sample.qualityCode, quality);
      }
    }
    for (final flags in [1, 2, 3]) {
      final scan = decode(_fram(flags: flags));
      expect(scan.trend.first.qualityFlags, flags);
      expect(scan.history.first.qualityFlags, flags);
      expect(
        [...scan.trend, ...scan.history].every((s) => s.glucoseMgDl == null),
        isTrue,
      );
    }
    for (final clear in [_fram(error: true), _fram(raw: 0)]) {
      final scan = decode(clear);
      expect(
        [...scan.trend, ...scan.history].every(
          (s) =>
              s.glucoseMgDl == null &&
              s.rejection == Libre2Gen1GlucoseRejection.sensorError,
        ),
        isTrue,
      );
    }
  });

  test(
    'one rejected NFC slot cannot remove or replace neighboring readings',
    () {
      final clear = _fram();
      final newestTrend = 28 + 2 * 6;
      putBits(clear, newestTrend, 25, 1, 1);
      final scan = decode(clear);
      expect(scan.trend.first.glucoseMgDl, isNull);
      expect(
        scan.trend.first.rejection,
        Libre2Gen1GlucoseRejection.sensorError,
      );
      expect(scan.trend.skip(1).every((s) => s.glucoseMgDl != null), isTrue);
      expect(scan.history.every((s) => s.glucoseMgDl != null), isTrue);
      expect(scan.trend, hasLength(16));
    },
  );

  test('warmup pre-start and initial history slots do not yield glucose', () {
    for (final age in [0, 1, 2, 17, 18, 59]) {
      final scan = decode(_fram(age: age, state: 2));
      expect(scan.trend.length, age < 15 ? age + 1 : 16);
      expect(scan.history.length, age < 18 ? 0 : (age - 3) ~/ 15);
      expect(
        [...scan.trend, ...scan.history].every((s) => s.glucoseMgDl == null),
        isTrue,
      );
      expect(
        [...scan.trend, ...scan.history].every((s) => s.sensorMinute >= 0),
        isTrue,
      );
    }
    final boundary = decode(_fram(age: 60));
    expect(boundary.trend.first.glucoseMgDl, isNotNull);
    expect(
      boundary.trend
          .skip(1)
          .every((s) => s.rejection == Libre2Gen1GlucoseRejection.warmingUp),
      isTrue,
    );
    expect(boundary.history.every((s) => s.glucoseMgDl == null), isTrue);
    final historyBoundary = decode(_fram(age: 63));
    expect(historyBoundary.history.first.sensorMinute, 60);
    expect(historyBoundary.history.first.glucoseMgDl, isNotNull);
  });

  test('fresh warmup lifecycle suppresses glucose even after minute 60', () {
    for (final age in [60, 600]) {
      final fram = _fram(age: age, state: 2);
      final scan = decode(fram);
      expect(
        [...scan.trend, ...scan.history].every((s) => s.glucoseMgDl == null),
        isTrue,
      );
      expect(scan.trend.first.rejection, Libre2Gen1GlucoseRejection.warmingUp);
      // Historical factory evidence remains usable for later valid BLE data.
      final ble = Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: syntheticUid,
        initialPatchInfo: syntheticPatch,
        encryptedFram: encryptedFram(fram),
      ).decodeEncryptedBle(encryptedBle(clearBle(age: 600)));
      expect(ble.current.glucoseMgDl, isNotNull);
    }
  });

  test('fresh snapshot lifecycle and lifetime never widen BLE gates', () {
    for (final state in [0, 1, 4, 5, 6, 255]) {
      expect(
        () => decode(_fram(state: state)),
        _kind(Libre2Gen1GlucoseErrorKind.unusableLifecycle),
      );
    }
    for (final frame in [_fram(maxLife: 0), _fram(age: 101, maxLife: 100)]) {
      expect(
        () => decode(frame),
        _kind(Libre2Gen1GlucoseErrorKind.invalidSensorLifetime),
      );
    }
    final atEnd = decode(_fram(age: 600, maxLife: 600));
    expect(
      [...atEnd.trend, ...atEnd.history].every((s) => s.glucoseMgDl == null),
      isTrue,
    );
    expect(
      atEnd.trend.first.rejection,
      Libre2Gen1GlucoseRejection.outsideSensorLifetime,
    );
  });

  test('NFC math rejects invalid temperature and nonpositive glucose', () {
    for (final frame in [
      _fram(temperature: 0),
      _fram(reference: 4, adjustment: -4),
      _fram(reference: 4, adjustment: -8),
    ]) {
      final scan = decode(frame);
      expect(
        [...scan.trend, ...scan.history].every(
          (s) =>
              s.glucoseMgDl == null &&
              s.rejection == Libre2Gen1GlucoseRejection.invalidTemperature,
        ),
        isTrue,
      );
    }
    final low = decode(_fram(offset: 255, raw: 10));
    expect(
      [...low.trend, ...low.history].every(
        (s) =>
            s.glucoseMgDl == null &&
            s.rejection == Libre2Gen1GlucoseRejection.invalidGlucose,
      ),
      isTrue,
    );
  });

  test('NFC preserves the wider temperature adjustment field and sign', () {
    final positive = decode(_fram(adjustment: 2044));
    final negative = decode(_fram(adjustment: -2044));
    expect(positive.trend.first.glucoseMgDl, isNotNull);
    expect(negative.trend.first.glucoseMgDl, isNotNull);
    expect(
      positive.trend.first.glucoseMgDl,
      isNot(negative.trend.first.glucoseMgDl),
    );
    expect(
      positive.trend.first.glucoseMgDl,
      positive.history.first.glucoseMgDl,
    );
    expect(
      negative.trend.first.glucoseMgDl,
      negative.history.first.glucoseMgDl,
    );
  });

  test(
    'NFC rejects all CRC regions malformed inputs and unsupported identity',
    () {
      final good = encryptedFram(_fram());
      for (final offset in [10, 100, 330]) {
        final corrupt = [...good]..[offset] ^= 1;
        expect(
          () => decodeLibre2Gen1EncryptedNfcFram(
            uid: syntheticUid,
            currentPatchInfo: syntheticPatch,
            encryptedFram: corrupt,
          ),
          throwsA(isA<LibreProtocolError>()),
        );
      }
      for (final length in [343, 345]) {
        expect(
          () => decodeLibre2Gen1EncryptedNfcFram(
            uid: syntheticUid,
            currentPatchInfo: syntheticPatch,
            encryptedFram: List.filled(length, 0),
          ),
          throwsA(isA<LibreProtocolError>()),
        );
      }
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: [1, ...syntheticUid.skip(1)],
          currentPatchInfo: syntheticPatch,
          encryptedFram: good,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: syntheticUid.take(7),
          currentPatchInfo: syntheticPatch,
          encryptedFram: good,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: syntheticUid,
          currentPatchInfo: syntheticPatch.take(5),
          encryptedFram: good,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: [...syntheticUid.take(6), 0, 0],
          currentPatchInfo: syntheticPatch,
          encryptedFram: good,
        ),
        _kind(Libre2Gen1GlucoseErrorKind.unsupportedSensor),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: syntheticUid,
          currentPatchInfo: [0xc6, 9, 0x31, 1, 0, 0],
          encryptedFram: good,
        ),
        _kind(Libre2Gen1GlucoseErrorKind.unsupportedSensor),
      );
      expect(
        () => decodeLibre2Gen1EncryptedNfcFram(
          uid: syntheticUid,
          currentPatchInfo: [0x2b, 0x0a, 0x39, 1, 0, 0],
          encryptedFram: good,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
    },
  );

  test('NFC rejects invalid factory evidence and ambiguous ring timing', () {
    for (final frame in [
      _fram(index: 0),
      _fram(scale: 20),
      _fram(reference: 0),
    ]) {
      expect(
        () => decode(frame),
        _kind(Libre2Gen1GlucoseErrorKind.invalidCalibration),
      );
    }
    for (final frame in [
      _fram()..[26] = 16,
      _fram()..[27] = 32,
      _fram()..[27] ^= 1,
    ]) {
      expect(() => decode(frame), throwsA(isA<LibreGen1FramHistoryError>()));
    }
  });

  test('NFC output is input-independent immutable and redacted', () {
    final uid = [...syntheticUid],
        patch = [...syntheticPatch],
        encrypted = encryptedFram(_fram());
    final scan = decodeLibre2Gen1EncryptedNfcFram(
      uid: uid,
      currentPatchInfo: patch,
      encryptedFram: encrypted,
    );
    final value = scan.trend.first.glucoseMgDl;
    uid.fillRange(0, uid.length, 0);
    patch.fillRange(0, patch.length, 0);
    encrypted.fillRange(0, encrypted.length, 0);
    expect(scan.trend.first.glucoseMgDl, value);
    for (final text in [
      scan.toString(),
      scan.trend.first.toString(),
      scan.history.first.toString(),
    ]) {
      expect(text, contains('<redacted>'));
      expect(text, isNot(contains(value.toString())));
      expect(text, isNot(contains('001122')));
    }
  });
}

Matcher _kind(Libre2Gen1GlucoseErrorKind kind) =>
    throwsA(isA<Libre2Gen1GlucoseError>().having((e) => e.kind, 'kind', kind));

Libre2Gen1GlucoseNfcScan decode(List<int> clear) =>
    decodeLibre2Gen1EncryptedNfcFram(
      uid: syntheticUid,
      currentPatchInfo: syntheticPatch,
      encryptedFram: encryptedFram(clear),
    );

List<int> _fram({
  int age = 600,
  int state = 3,
  int maxLife = 20160,
  int index = 300,
  int offset = 20,
  int scale = 500,
  int reference = 12000,
  int raw = 1400,
  int temperature = 6400,
  int adjustment = 24,
  int quality = 0,
  int flags = 0,
  bool error = false,
  int trendIndex = 3,
}) {
  final bytes = clearFram(
    index: index,
    offset: offset,
    scale: scale,
    reference: reference,
    state: state,
    age: age,
    maxLife: maxLife,
  );
  bytes[26] = trendIndex;
  bytes[27] = age < 3 ? 0 : ((age - 3) ~/ 15) % 32;
  for (var slot = 0; slot < 48; slot++) {
    final at = 28 + slot * 6;
    putBits(bytes, at, 0, 14, raw);
    putBits(bytes, at, 14, 9, quality);
    putBits(bytes, at, 23, 2, flags);
    putBits(bytes, at, 25, 1, error ? 1 : 0);
    putBits(bytes, at, 26, 12, temperature >> 2);
    putBits(bytes, at, 38, 9, adjustment.abs() >> 2);
    putBits(bytes, at, 47, 1, adjustment < 0 ? 1 : 0);
  }
  return bytes;
}
