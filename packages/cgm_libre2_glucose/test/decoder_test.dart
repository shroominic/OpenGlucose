// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_libre2_glucose/cgm_libre2_glucose.dart';
import 'package:test/test.dart';

import 'support/synthetic.dart';

Libre2Gen1GlucoseDecoder decoder([List<int>? clear]) =>
    Libre2Gen1GlucoseDecoder.fromEncryptedFram(
      uid: syntheticUid,
      initialPatchInfo: syntheticPatch,
      encryptedFram: encryptedFram(clear ?? clearFram()),
    );

Matcher kind(Libre2Gen1GlucoseErrorKind expected) => throwsA(
  isA<Libre2Gen1GlucoseError>().having((e) => e.kind, 'kind', expected),
);

void main() {
  test(
    'every calibration table index agrees with pinned Swift synthetic oracle',
    () {
      final rows =
          jsonDecode(
                File('test/reference/factory_vectors.json').readAsStringSync(),
              )
              as List;
      expect(rows, hasLength(1023));
      for (var i = 0; i < rows.length; i++) {
        final row = (rows[i] as List).cast<int>();
        expect(row[0], i + 1);
        final d = decoder(
          clearFram(
            index: row[0],
            offset: row[1],
            scale: row[2],
            reference: row[3],
          ),
        );
        final packet = d.decodeEncryptedBle(
          encryptedBle(
            clearBle(raw: row[4], temperature: row[5], adjustment: row[6]),
          ),
        );
        expect(
          packet.current.glucoseMgDl,
          row[7],
          reason: 'synthetic index ${i + 1}',
        );
        expect(packet.current.rejection, isNull);
      }
    },
  );

  test(
    'sparse trend/history timing is exact, immutable, and does not invent dates',
    () {
      final packet = decoder().decodeEncryptedBle(
        encryptedBle(clearBle(age: 121)),
      );
      expect(packet.sensorAgeMinutes, 121);
      expect(packet.samples.map((s) => s.sensorMinute), [
        121,
        119,
        117,
        115,
        114,
        109,
        106,
        105,
        90,
        75,
      ]);
      expect(packet.samples.map((s) => s.isHistory), [
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
      ]);
      expect(() => packet.samples.clear(), throwsUnsupportedError);
    },
  );

  test('snapshot and diagnostics disclose no input bytes or glucose', () {
    final fram = encryptedFram(clearFram());
    final uid = List<int>.of(syntheticUid);
    final patch = List<int>.of(syntheticPatch);
    final d = Libre2Gen1GlucoseDecoder.fromEncryptedFram(
      uid: uid,
      initialPatchInfo: patch,
      encryptedFram: fram,
    );
    uid.fillRange(0, 8, 0);
    patch.fillRange(0, 6, 0);
    fram.fillRange(0, 344, 0);
    final packet = d.decodeEncryptedBle(encryptedBle(clearBle()));
    expect(packet.current.glucoseMgDl, isNotNull);
    for (final text in [
      d.toString(),
      packet.toString(),
      packet.current.toString(),
    ]) {
      expect(text, contains('<redacted>'));
      expect(text, isNot(contains('001122')));
      expect(text, isNot(contains(packet.current.glucoseMgDl.toString())));
    }
  });

  test('requires exact inputs and immutable CRC-validated data boundary', () {
    for (final uid in [
      syntheticUid.sublist(1),
      [...syntheticUid, 0],
      [...syntheticUid.take(7), 256],
    ]) {
      expect(
        () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
          uid: uid,
          initialPatchInfo: syntheticPatch,
          encryptedFram: encryptedFram(clearFram()),
        ),
        throwsA(isA<LibreProtocolError>()),
      );
    }
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: syntheticUid,
        initialPatchInfo: syntheticPatch.take(5),
        encryptedFram: encryptedFram(clearFram()),
      ),
      throwsA(isA<LibreProtocolError>()),
    );
    for (final length in [343, 345]) {
      expect(
        () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
          uid: syntheticUid,
          initialPatchInfo: syntheticPatch,
          encryptedFram: List.filled(length, 0),
        ),
        throwsA(isA<LibreProtocolError>()),
      );
    }
    for (final length in [45, 47]) {
      expect(
        () => decoder().decodeEncryptedBle(List.filled(length, 0)),
        throwsA(isA<LibreProtocolError>()),
      );
    }
  });

  test('rejects other manufacturer/model/security and wrong UID/patch', () {
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: [...syntheticUid.take(6), 0, 0],
        initialPatchInfo: syntheticPatch,
        encryptedFram: encryptedFram(clearFram()),
      ),
      kind(Libre2Gen1GlucoseErrorKind.unsupportedSensor),
    );
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: syntheticUid,
        initialPatchInfo: [0xc6, 9, 0x31, 1, 0, 0],
        encryptedFram: encryptedFram(clearFram()),
      ),
      kind(Libre2Gen1GlucoseErrorKind.unsupportedSensor),
    );
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: syntheticUid,
        initialPatchInfo: [0x2b, 0x0a, 0x39, 1, 0, 0],
        encryptedFram: encryptedFram(clearFram()),
      ),
      throwsA(isA<LibreProtocolError>()),
    );
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: [1, ...syntheticUid.skip(1)],
        initialPatchInfo: syntheticPatch,
        encryptedFram: encryptedFram(clearFram()),
      ),
      throwsA(isA<LibreProtocolError>()),
    );
    expect(
      () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
        uid: syntheticUid,
        initialPatchInfo: [...syntheticPatch.take(5), 0x13],
        encryptedFram: encryptedFram(clearFram()),
      ),
      throwsA(isA<LibreProtocolError>()),
    );
  });

  for (final offset in [10, 100, 330]) {
    test('rejects FRAM CRC corruption at synthetic offset $offset', () {
      final fram = encryptedFram(clearFram())..[offset] ^= 1;
      expect(
        () => Libre2Gen1GlucoseDecoder.fromEncryptedFram(
          uid: syntheticUid,
          initialPatchInfo: syntheticPatch,
          encryptedFram: fram,
        ),
        throwsA(isA<LibreProtocolError>()),
      );
    });
  }
  test('rejects corrupted BLE CRC with no sample output', () {
    final packet = encryptedBle(clearBle())..[20] ^= 1;
    expect(
      () => decoder().decodeEncryptedBle(packet),
      throwsA(isA<LibreProtocolError>()),
    );
  });

  test(
    'lifecycle is historical and inactive/unknown/failure snapshots fail closed',
    () {
      expect(
        decoder(clearFram(state: 2)).lifecycleAtFram,
        LibreGen1LifecycleState.warmingUp,
      );
      expect(
        decoder(clearFram(state: 3)).lifecycleAtFram,
        LibreGen1LifecycleState.active,
      );
      for (final state in [0, 1, 4, 5, 6, 255]) {
        expect(
          () => decoder(clearFram(state: state)),
          kind(Libre2Gen1GlucoseErrorKind.unusableLifecycle),
        );
      }
      final d = decoder(clearFram(state: 2, age: 10));
      expect(
        d
            .decodeEncryptedBle(encryptedBle(clearBle(age: 61)))
            .current
            .glucoseMgDl,
        isNotNull,
      );
      expect(d.lifecycleAtFram, LibreGen1LifecycleState.warmingUp);
    },
  );

  test(
    'invalid coefficient index, scale and temperature reference fail closed',
    () {
      for (final fram in [
        clearFram(index: 0),
        clearFram(scale: 20),
        clearFram(scale: 19),
        clearFram(reference: 0),
      ]) {
        expect(
          () => decoder(fram),
          kind(Libre2Gen1GlucoseErrorKind.invalidCalibration),
        );
      }
      expect(decoder(clearFram(index: 1023)), isA<Libre2Gen1GlucoseDecoder>());
    },
  );

  test(
    'zero lifetime, already-outside lifetime and older packet fail closed',
    () {
      expect(
        () => decoder(clearFram(maxLife: 0)),
        kind(Libre2Gen1GlucoseErrorKind.invalidSensorLifetime),
      );
      expect(
        () => decoder(clearFram(age: 101, maxLife: 100)),
        kind(Libre2Gen1GlucoseErrorKind.invalidSensorLifetime),
      );
      expect(
        () => decoder().decodeEncryptedBle(encryptedBle(clearBle(age: 59))),
        kind(Libre2Gen1GlucoseErrorKind.packetPredatesCalibration),
      );
      final packet = decoder(
        clearFram(maxLife: 120),
      ).decodeEncryptedBle(encryptedBle(clearBle(age: 120)));
      expect(packet.samples.every((s) => s.glucoseMgDl == null), isTrue);
      expect(
        packet.current.rejection,
        Libre2Gen1GlucoseRejection.outsideSensorLifetime,
      );
    },
  );

  test('warmup and pre-start records never return glucose', () {
    final d = decoder(clearFram(age: 0, state: 2));
    final early = d.decodeEncryptedBle(encryptedBle(clearBle(age: 1)));
    expect(early.current.rejection, Libre2Gen1GlucoseRejection.warmingUp);
    expect(early.samples[1].rejection, Libre2Gen1GlucoseRejection.beforeStart);
    expect(early.samples.every((s) => s.glucoseMgDl == null), isTrue);
    final boundary = d.decodeEncryptedBle(encryptedBle(clearBle(age: 60)));
    expect(boundary.current.glucoseMgDl, isNotNull);
    expect(
      boundary.samples.skip(1).every((s) => s.glucoseMgDl == null),
      isTrue,
    );
  });

  test(
    'zero raw reports every unknown quality bit without inventing a value',
    () {
      for (final code in [0, 1, 0x20, 0x100, 0x600, 0x800, 0xfff]) {
        final packet = decoder().decodeEncryptedBle(
          encryptedBle(clearBle(raw: 0, temperature: code << 2)),
        );
        expect(packet.current.glucoseMgDl, isNull);
        expect(
          packet.current.rejection,
          Libre2Gen1GlucoseRejection.sensorError,
        );
        expect(packet.current.qualityCode, code);
        expect(packet.current.qualityFlags, (code & 0x600) >> 9);
      }
    },
  );

  test(
    'invalid temperature mathematical domains never become zero/default glucose',
    () {
      final d = decoder();
      expect(
        d
            .decodeEncryptedBle(encryptedBle(clearBle(temperature: 0)))
            .current
            .rejection,
        Libre2Gen1GlucoseRejection.invalidTemperature,
      );
      final smallRef = decoder(clearFram(reference: 4));
      expect(
        smallRef
            .decodeEncryptedBle(encryptedBle(clearBle(adjustment: -4)))
            .current
            .rejection,
        Libre2Gen1GlucoseRejection.invalidTemperature,
      );
      expect(
        smallRef
            .decodeEncryptedBle(encryptedBle(clearBle(adjustment: -8)))
            .current
            .glucoseMgDl,
        isNull,
      );
    },
  );

  test(
    'negative/nonpositive conversion is rejected, not clamped or ADC divided',
    () {
      final packet = decoder(
        clearFram(offset: 255),
      ).decodeEncryptedBle(encryptedBle(clearBle(raw: 10)));
      expect(
        packet.current.rejection,
        Libre2Gen1GlucoseRejection.invalidGlucose,
      );
      expect(packet.current.glucoseMgDl, isNull);
    },
  );
}
