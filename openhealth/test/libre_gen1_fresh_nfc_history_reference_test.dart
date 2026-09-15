// SPDX-License-Identifier: GPL-3.0-only
// Synthetic integration of the separately licensed factory decoder.
import 'package:cgm_core/cgm_core.dart';
import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:cgm_libre2_glucose/cgm_libre2_glucose.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_gen1_fresh_nfc_history.dart';
import 'package:openglucose/src/libre_gen1_glucose_adapter.dart';
import 'package:openglucose/src/libre_nfc_history.dart';

import '../../packages/cgm_libre2_glucose/test/support/synthetic.dart';

const _attempt = 'synthetic_fresh_nfc_attempt';
final _receipt = DateTime.utc(2026, 11, 1, 0, 2, 3, 123, 456);

void main() {
  final bootstrap = LibreGen1StreamingBootstrap(
    bootstrapId: 'synthetic_receiver_1234',
    deviceId: '02:00:00:00:00:01',
    uid: LibreGen1Uid.algorithmOrder(syntheticUid),
    initialPatchInfo: LibreGen1PatchInfo(syntheticPatch),
    streamingBase: 1,
    lifecycle: LibreGen1LifecycleState.active,
  );
  var calibrationReads = 0;
  final provider = PrivateLibreGlucoseDecoderProvider(
    readEvidence: (_) async {
      calibrationReads++;
      throw StateError('Fresh history cannot read cached BLE calibration');
    },
  );
  final calls = <String>[];

  Future<LibreGen1DecodedNfcHistory> read(
    List<int> fram, {
    List<int> patch = syntheticPatch,
    List<int>? encrypted,
    DateTime? receipt,
  }) => LibreGen1FreshNfcHistoryReader(
    supported: true,
    invokeMethod: (method, args) async {
      calls.add(method);
      expect(args, {
        'attemptId': _attempt,
        'bootstrapId': bootstrap.bootstrapId,
      });
      return {
        'attemptId': _attempt,
        'bootstrapId': bootstrap.bootstrapId,
        'uid': syntheticUid,
        'receiverInitialPatchInfo': syntheticPatch,
        'currentPatchInfo': patch,
        'encryptedFram': encrypted ?? encryptedFram(fram, patchInfo: patch),
        'observedAtUtc': (receipt ?? _receipt).toIso8601String(),
      };
    },
  ).readDecoded(bootstrap: bootstrap, attemptId: _attempt, decoder: provider);

  setUp(() {
    calibrationReads = 0;
    calls.clear();
  });
  tearDown(() {
    expect(calibrationReads, 0);
    expect(
      calls.every((m) => m == LibreGen1FreshNfcHistoryReader.methodName),
      isTrue,
    );
  });

  test(
    'fresh rings use real factory conversion, source and historical offsets',
    () async {
      final result = await read(_fram());
      expect(result.scanMinute, 600);
      expect(result.receivedAt, _receipt);
      expect(result.samples, hasLength(47));
      expect(result.samples.map((s) => s.reading.sensorMinute), [
        ...List.generate(16, (i) => 600 - i),
        ...List.generate(31, (i) => 570 - i * 15),
      ]);
      for (final sample in result.samples) {
        // Independently executed pinned Swift row 1.
        expect(sample.reading.valueMgdl, 2123.0);
        expect(sample.reading.source, CgmRecordSource.vendor);
        expect(sample.reading.isDisplayProvisional, isTrue);
        expect(sample.reading.rawValue, isNull);
        expect(sample.reading.qualifier, isNull);
        expect(sample.firstReceivedAt, _receipt);
        expect(
          sample.reading.recordedAt,
          _receipt.subtract(
            Duration(minutes: 600 - sample.reading.sensorMinute!),
          ),
        );
        expect(sample.reading.recordedAt!.isUtc, isTrue);
      }
      expect(
        result.samples
            .take(16)
            .every((s) => s.origin == LibreHistoryOrigin.nfcTrend),
        isTrue,
      );
      expect(
        result.samples
            .skip(16)
            .every((s) => s.origin == LibreHistoryOrigin.nfcHistory),
        isTrue,
      );
      expect(result.samples.last.reading.recordedAt!.day, 31);
      expect(result.samples.clear, throwsUnsupportedError);
    },
  );

  test('trend wins overlap without duplicate minute/source input', () async {
    final fram = _fram();
    // At age600 the oldest trend and newest history both represent minute585.
    putBits(fram, 28 + 3 * 6, 0, 14, 1100);
    putBits(fram, 124 + 6 * 6, 0, 14, 1400);
    final expected = decodeLibre2Gen1EncryptedNfcFram(
      uid: syntheticUid,
      currentPatchInfo: syntheticPatch,
      encryptedFram: encryptedFram(fram),
    );
    expect(
      expected.trend.last.glucoseMgDl,
      isNot(expected.history.first.glucoseMgDl),
    );
    final result = await read(fram);
    final overlap = result.samples
        .where((s) => s.reading.sensorMinute == 585)
        .single;
    expect(overlap.origin, LibreHistoryOrigin.nfcTrend);
    expect(
      overlap.reading.valueMgdl,
      expected.trend.last.glucoseMgDl!.toDouble(),
    );
    expect(
      result.samples.map((s) => s.reading.sensorMinute).toSet(),
      hasLength(47),
    );
  });

  test(
    'rotated current seed and new coefficients are never replaced by frozen evidence',
    () async {
      final currentPatch = [...syntheticPatch.take(4), 0x78, 0x56];
      final old = await read(_fram(index: 1));
      final freshFram = _fram(index: 1023);
      final fresh = await read(freshFram, patch: currentPatch);
      expect(
        fresh.samples.first.reading.valueMgdl,
        isNot(old.samples.first.reading.valueMgdl),
      );
      expect(bootstrap.initialPatchInfo.value.bytes, syntheticPatch);
      await expectLater(
        read(
          freshFram,
          encrypted: encryptedFram(freshFram, patchInfo: currentPatch),
        ),
        throwsA(isA<LibreGen1FreshNfcHistoryException>()),
      );
    },
  );

  test(
    'quality/error and invalid temperature slots contribute no glucose',
    () async {
      final fram = _fram();
      final rejectedMinutes = <int>{};
      for (var i = 0; i < 4; i++) {
        final slot = (2 - i) % 16;
        final offset = 28 + slot * 6;
        switch (i) {
          case 0:
            putBits(fram, offset, 14, 9, 1);
          case 1:
            putBits(fram, offset, 23, 2, 1);
          case 2:
            putBits(fram, offset, 25, 1, 1);
          case 3:
            putBits(fram, offset, 26, 12, 0);
        }
        rejectedMinutes.add(600 - i);
      }
      final result = await read(fram);
      expect(result.samples, hasLength(43));
      expect(
        result.samples.any(
          (s) => rejectedMinutes.contains(s.reading.sensorMinute),
        ),
        isFalse,
      );
      expect(result.samples.first.reading.sensorMinute, 596);
    },
  );

  test(
    'warm-up yields no sample; lifetime and corrupt evidence stay closed',
    () async {
      expect((await read(_fram(age: 59, state: 2))).samples, isEmpty);
      expect((await read(_fram(age: 60, state: 2))).samples, isEmpty);
      expect((await read(_fram(age: 600, state: 2))).samples, isEmpty);
      expect(
        (await read(_fram(age: 60))).samples.single.reading.sensorMinute,
        60,
      );
      expect(
        (await read(_fram(age: 63))).samples.map((s) => s.reading.sensorMinute),
        [63, 62, 61, 60],
      );
      expect((await read(_fram(age: 20160))).samples, isEmpty);
      final badCrc = encryptedFram(_fram())..[330] ^= 1;
      for (final call in [
        () => read(_fram(state: 1)),
        () => read(_fram(state: 4)),
        () => read(_fram(index: 0)),
        () => read(_fram(age: 20161)),
        () => read(_fram(), encrypted: badCrc),
        () => read(_fram()..[27] = 31),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<LibreGen1FreshNfcHistoryException>().having(
              (e) => e.kind,
              'kind',
              LibreGen1FreshNfcFailure.invalidDecodedHistory,
            ),
          ),
        );
      }
    },
  );

  test(
    'each scan anchors only historical offsets; no phone-now substitution',
    () async {
      final oldReceipt = DateTime.utc(2020, 2, 29, 0, 0, 1);
      final result = await read(_fram(), receipt: oldReceipt);
      expect(result.receivedAt, oldReceipt);
      expect(result.samples.first.reading.recordedAt, oldReceipt);
      expect(
        result.samples.last.reading.recordedAt,
        oldReceipt.subtract(const Duration(minutes: 480)),
      );
      // Freshness admission belongs to native/repository, not pure conversion.
      expect(
        result.samples.every((s) => s.firstReceivedAt == oldReceipt),
        isTrue,
      );
      expect(result.toString(), isNot(contains('2123')));
    },
  );
}

List<int> _fram({int age = 600, int state = 3, int index = 1}) {
  final bytes = clearFram(
    index: index,
    offset: 20,
    scale: 501,
    reference: 10004,
    age: age,
    state: state,
  );
  bytes[26] = 3;
  bytes[27] = age < 3 ? 0 : ((age - 3) ~/ 15) % 32;
  for (var i = 0; i < 48; i++) {
    final offset = 28 + i * 6;
    putBits(bytes, offset, 0, 14, 1001);
    putBits(bytes, offset, 26, 12, 6004 >> 2);
    putBits(bytes, offset, 38, 9, 4 >> 2);
  }
  return bytes;
}
