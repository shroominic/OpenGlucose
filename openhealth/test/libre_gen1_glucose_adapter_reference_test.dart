// SPDX-License-Identifier: GPL-3.0-only
// Synthetic integration test for the separately GPL-covered decoder.
// Reference formula/vectors/notices: packages/cgm_libre2_glucose.
import 'dart:async';

import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_glucose_adapter.dart';
import 'package:openglucose/src/libre_gen1_secure_store.dart';

import '../../packages/cgm_libre2_glucose/test/support/synthetic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synthetic/calibrated_decoder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bootstrap = LibreGen1StreamingBootstrap(
    bootstrapId: 'synthetic_receiver_1234',
    deviceId: 'AA:BB:CC:DD:EE:FF',
    uid: LibreGen1Uid.algorithmOrder(syntheticUid),
    initialPatchInfo: LibreGen1PatchInfo(syntheticPatch),
    streamingBase: 1,
    lifecycle: LibreGen1LifecycleState.active,
  );
  final store = LibreGen1SecureStore(channel: channel, supported: true);
  final provider = PrivateLibreGlucoseDecoderProvider(
    readEvidence: store.readCalibrationEvidence,
  );
  final calls = <MethodCall>[];
  Map<String, Object?> evidence([List<int>? fram]) => {
    'bootstrapId': bootstrap.bootstrapId,
    'uid': syntheticUid,
    'receiverInitialPatchInfo': syntheticPatch,
    'calibrationPatchInfo': syntheticPatch,
    'encryptedFram': encryptedFram(
      fram ?? clearFram(index: 1, offset: 20, scale: 501, reference: 10004),
    ),
  };
  void respond(Object? response) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'protected same-receiver evidence reaches real factory conversion',
    () async {
      respond(evidence());
      final decoder = await provider.prepare(bootstrap);
      expect(decoder, isNotNull);
      expect(calls.map((c) => c.method), ['readLibreGen1CalibrationEvidence']);
      expect(calls.single.arguments, {'bootstrapId': bootstrap.bootstrapId});
      final result = decoder!.decode(
        encryptedPacket: encryptedBle(
          clearBle(raw: 1001, temperature: 6004, adjustment: 4),
        ),
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      // Row 1 of the checked-in, independently executed Swift oracle.
      expect(result.glucoseMgdl, 2123.0);
      expect(result.sensorAgeMinutes, 120);
      expect(result.sampleAgeMinutes, 120);
      expect(result.expectedLifetimeMinutes, 20160);
      expect(result.rejection, isNull);
      expect(result.toString(), isNot(contains('2123')));
      expect(result.historySamples, hasLength(9));
      expect(
        result.historySamples.map((entry) => entry.sampleAgeMinutes),
        [118, 116, 114, 113, 108, 105, 105, 90, 75],
      );
      expect(
        result.historySamples.take(6).map((entry) => entry.kind),
        everyElement(LibreGen1BleHistoryKind.trend),
      );
      expect(
        result.historySamples.skip(6).map((entry) => entry.kind),
        everyElement(LibreGen1BleHistoryKind.history),
      );
      expect(
        result.historySamples.map((entry) => entry.glucoseMgdl),
        everyElement(2123.0),
      );
      expect(
        result.historySamples.map((entry) => entry.rejection),
        everyElement(isNull),
      );
      expect(result.historySamples.clear, throwsUnsupportedError);
    },
  );

  test(
    'older BLE slots retain independent rejection and do not replace current',
    () async {
      respond(evidence(clearFram(age: 0, state: 2)));
      final decoder = (await provider.prepare(bootstrap))!;
      final packet = clearBle(age: 64);
      putBits(packet, 4, 0, 14, 0); // Older trend: sensor error.
      putBits(packet, 8, 14, 12, 0); // Older trend: invalid temperature.
      final result = decoder.decode(
        encryptedPacket: encryptedBle(packet),
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      expect(result.sampleAgeMinutes, 64);
      expect(result.glucoseMgdl, isNotNull);
      expect(result.rejection, isNull);
      expect(
        result.historySamples.map((entry) => entry.sampleAgeMinutes),
        [62, 60, 58, 57, 52, 49, 60, 45, 30],
      );
      expect(
        result.historySamples.map((entry) => entry.rejection),
        [
          LibreGen1GlucoseRejection.noCurrentSample,
          LibreGen1GlucoseRejection.invalidData,
          for (var i = 0; i < 4; i++) LibreGen1GlucoseRejection.warmingUp,
          null,
          LibreGen1GlucoseRejection.warmingUp,
          LibreGen1GlucoseRejection.warmingUp,
        ],
      );
      for (final sample in result.historySamples) {
        expect(sample.glucoseMgdl == null, sample.rejection != null);
      }
    },
  );

  test('rejected current does not hide valid older slots', () async {
    respond(evidence());
    final decoder = (await provider.prepare(bootstrap))!;
    final packet = clearBle();
    putBits(packet, 0, 0, 14, 0);
    final result = decoder.decode(
      encryptedPacket: encryptedBle(packet),
      receivedAt: DateTime.utc(2026, 1, 1),
    );
    expect(result.glucoseMgdl, isNull);
    expect(result.rejection, LibreGen1GlucoseRejection.noCurrentSample);
    expect(result.historySamples, hasLength(9));
    expect(
      result.historySamples.map((entry) => entry.glucoseMgdl),
      everyElement(isNotNull),
    );
  });

  test(
    'before-start and expired slots remain present without glucose',
    () async {
      respond(evidence(clearFram(age: 0, state: 2)));
      final decoder = (await provider.prepare(bootstrap))!;
      final beforeStart = decoder.decode(
        encryptedPacket: encryptedBle(clearBle(age: 0)),
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      expect(beforeStart.historySamples, hasLength(9));
      expect(
        beforeStart.historySamples.map((entry) => entry.sampleAgeMinutes),
        [-2, -4, -6, -7, -12, -15, 0, -15, -30],
      );
      expect(
        beforeStart.historySamples.map((entry) => entry.glucoseMgdl),
        everyElement(isNull),
      );
      expect(
        beforeStart.historySamples.first.rejection,
        LibreGen1GlucoseRejection.invalidData,
      );
      final expired = decoder.decode(
        encryptedPacket: encryptedBle(clearBle(age: 20160)),
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      expect(expired.historySamples, hasLength(9));
      expect(
        expired.historySamples.map((entry) => entry.rejection),
        everyElement(LibreGen1GlucoseRejection.invalidData),
      );
      expect(
        expired.historySamples.map((entry) => entry.glucoseMgdl),
        everyElement(isNull),
      );
    },
  );

  test(
    'different receiver/UID/patch and extra fields never create a decoder',
    () async {
      for (final map in [
        {...evidence(), 'bootstrapId': 'synthetic_other_receiver'},
        {
          ...evidence(),
          'uid': [1, ...syntheticUid.skip(1)],
        },
        {
          ...evidence(),
          'receiverInitialPatchInfo': [...syntheticPatch.take(5), 0x13],
        },
        {...evidence(), 'unexpected': true},
        {...evidence(), 'encryptedFram': List.filled(343, 0)},
      ]) {
        respond(map);
        expect(await provider.prepare(bootstrap), isNull);
      }
    },
  );

  test(
    'current NFC seed decodes FRAM without replacing the BLE credential',
    () async {
      final currentPatch = [...syntheticPatch.take(4), 0x78, 0x56];
      final rotated = {
        ...evidence(),
        'calibrationPatchInfo': currentPatch,
        'encryptedFram': encryptedFram(
          clearFram(index: 1, offset: 20, scale: 501, reference: 10004),
          patchInfo: currentPatch,
        ),
      };
      respond(rotated);
      final decoder = await provider.prepare(bootstrap);
      expect(decoder, isNotNull);
      final result = decoder!.decode(
        encryptedPacket: encryptedBle(
          clearBle(raw: 1001, temperature: 6004, adjustment: 4),
        ),
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      expect(result.glucoseMgdl, 2123.0);
      expect(bootstrap.initialPatchInfo.value.bytes, syntheticPatch);
      expect(calls.map((call) => call.method), [
        'readLibreGen1CalibrationEvidence',
      ]);

      // Matching shape and receiver alone cannot authenticate the wrong FRAM seed.
      respond({...rotated, 'calibrationPatchInfo': syntheticPatch});
      expect(await provider.prepare(bootstrap), isNull);
      respond({...evidence(), 'calibrationPatchInfo': currentPatch});
      expect(await provider.prepare(bootstrap), isNull);
    },
  );

  test(
    'valid shape but bad CRC, calibration or lifecycle is rejected',
    () async {
      final corrupt = encryptedFram(clearFram())..[330] ^= 1;
      for (final map in [
        {...evidence(), 'encryptedFram': corrupt},
        evidence(clearFram(index: 0)),
        evidence(clearFram(state: 1)),
        evidence(clearFram(state: 6)),
      ]) {
        respond(map);
        expect(await provider.prepare(bootstrap), isNull);
      }
    },
  );

  test('warmup and raw-zero error map to closed no-glucose reasons', () async {
    respond(evidence(clearFram(age: 0, state: 2)));
    final decoder = (await provider.prepare(bootstrap))!;
    final now = DateTime.utc(2026, 1, 1);
    final warmup = decoder.decode(
      encryptedPacket: encryptedBle(clearBle(age: 59)),
      receivedAt: now,
    );
    expect(warmup.glucoseMgdl, isNull);
    expect(warmup.rejection, LibreGen1GlucoseRejection.warmingUp);
    final error = decoder.decode(
      encryptedPacket: encryptedBle(
        clearBle(age: 120, raw: 0, temperature: 0xfff << 2),
      ),
      receivedAt: now,
    );
    expect(error.glucoseMgdl, isNull);
    expect(error.rejection, LibreGen1GlucoseRejection.noCurrentSample);
    final invalid = decoder.decode(
      encryptedPacket: encryptedBle(clearBle(age: 120, temperature: 0)),
      receivedAt: now,
    );
    expect(invalid.glucoseMgdl, isNull);
    expect(invalid.rejection, LibreGen1GlucoseRejection.invalidData);
  });

  testWidgets('late native calibration cannot create a decoder after timeout', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    LibreGen1GlucoseDecoder? result;
    var completed = false;
    final attempt = provider.prepare(bootstrap).then((value) {
      result = value;
      completed = true;
    });
    await tester.pump(const Duration(seconds: 16));
    await attempt;
    expect(completed, isTrue);
    expect(result, isNull);
    pending.complete(evidence());
    await tester.pump();
    expect(result, isNull);
  });
}
