import 'dart:typed_data';

import 'package:cgm_aidex/cgm_aidex.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  test('specific ops CRC matches confirmed vectors', () {
    expect(hexOf(buildSpecificOpsRequest(0x1A)), '1a8b52');
    expect(hexOf(buildSpecificOpsRequest(0x02)), '02b2c1');
  });

  test('session start payload matches confirmed example', () {
    final date = DateTime.parse('2026-04-02T04:28:10+08:00');
    expect(
      hexOf(
        buildAidexSessionStartPayload(
          date,
          timeZoneOffset: const Duration(hours: 8),
        ),
      ),
      'ea070402041c0a20005721',
    );
  });

  test('advertisement parsing uses big-endian sfloat triplet', () {
    final advertisement = parseAidexManufacturerData(
      Uint8List.fromList(<int>[
        0x59,
        0x00,
        0x01,
        0x00,
        0x08,
        0x02,
        0x00,
        0x55,
        0x88,
        0x00,
        0x56,
        0x80,
        0x00,
        0x57,
        0x84,
      ]),
    );

    expect(advertisement.counter, 1);
    expect(advertisement.phaseHex, '0802');
    expect(advertisement.glucoseTriplet, <int>[0x0055, 0x0056, 0x0057]);
    expect(advertisement.qualifiers, <int>[0x88, 0x80, 0x84]);
    expect(advertisement.displayValueMgdl, 85);
  });

  test('advertisement parsing skips unusable samples before displaying', () {
    final advertisement = parseAidexManufacturerData(
      Uint8List.fromList(<int>[
        0x59,
        0x00,
        0x01,
        0x00,
        0x08,
        0x02,
        0xDC,
        0x78,
        0x88,
        0x00,
        0x56,
        0x88,
        0x00,
        0x57,
        0x84,
      ]),
    );

    expect(advertisement.displayValueMgdl, 86);
  });

  test('cgm status parses structured fields and crc', () {
    final payload = <int>[0x34, 0x12, 0xAA, 0xBB, 0xCC];
    final crc = crc16CcittFalse(payload);
    final status = parseCgmStatus(<int>[
      ...payload,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);

    expect(status?.timeOffsetMinutes, 0x1234);
    expect(status?.sessionFlags, 0xAA);
    expect(status?.calibrationTemperatureState, 0xBB);
    expect(status?.warningFlags, 0xCC);
    expect(status?.crcValid, isTrue);
  });

  test('vendor history range parses confirmed example', () {
    final range = parseVendorRangePayload(bytesFromHex('01010001005700'));

    expect(range?.status, 0x01);
    expect(range?.lowIndex, 0x0001);
    expect(range?.highIndex, 0x0001);
    expect(range?.count, 0x0057);
  });

  test('vendor range parser accepts short calibration-range payloads', () {
    final range = parseVendorRangePayload(bytesFromHex('0101005700'));

    expect(range?.status, 0x01);
    expect(range?.lowIndex, 0x0001);
    expect(range?.highIndex, 0x0057);
    expect(range?.count, 0x0057);
  });

  test(
    'vendor broadcast parsing exposes current glucose and minute offset',
    () {
      final broadcast = parseVendorBroadcastData(
        bytesFromHex('011e000000008c80abcd'),
      );

      expect(broadcast.status, 0x01);
      expect(broadcast.timeOffsetMinutes, 30);
      expect(broadcast.currentGlucoseRawByte, 140);
      expect(broadcast.currentQualifier, 0x80);
      expect(broadcast.currentGlucoseMgdl, 140);
      expect(broadcast.isUsableGlucose, isTrue);
      expect(broadcast.tailHex, 'abcd');
    },
  );

  test('vendor start time parsing exposes absolute start', () {
    final response = parseVendorStartTimeResponse(
      bytesFromHex('01ea070402041c0a2000'),
    );

    expect(response?.status, 0x01);
    expect(response?.startTime, DateTime.parse('2026-04-01T20:28:10Z'));
  });

  test('Aidex date-time parsing applies the DST byte when present', () {
    final parsed = parseAidexDateTime(bytesFromHex('ea070402041c0a2004'));

    expect(parsed, DateTime.parse('2026-04-01T19:28:10Z'));
  });

  test('standard measurement parsing decodes multiple records', () {
    final records = parseStandardMeasurementNotification(<int>[
      0x07,
      0x00,
      0x8C,
      0x00,
      0x1E,
      0x00,
      0x80,
      0x07,
      0x00,
      0x90,
      0x00,
      0x1F,
      0x00,
      0x84,
    ]);

    expect(records, hasLength(2));
    expect(records.first.source, CgmRecordSource.standard);
    expect(records.first.sensorMinute, 30);
    expect(records.first.valueMgdl, 140);
    expect(records.first.qualifier, 0x80);
    expect(records.last.sensorMinute, 31);
    expect(records.last.valueMgdl, 144);
    expect(records.last.qualifier, 0x84);
  });

  test('vendor history page parses byte pairs into readings', () {
    final page = parseVendorHistoryPagePayload(<int>[
      0x01,
      0x01,
      0x00,
      0x55,
      0x80,
      0x56,
      0x84,
      0x10,
      0x07,
    ], source: CgmRecordSource.vendor);

    expect(page, isNotNull);
    expect(page!.indexEcho, 1);
    expect(page.rawPairs.length, 3);
    expect(page.records.length, 2);
    expect(page.records[0].sensorMinute, 1);
    expect(page.records[0].valueMgdl, 85);
    expect(page.records[1].sensorMinute, 2);
    expect(page.records[1].valueMgdl, 86);
  });

  test('vendor history page filters unusable qualifiers and ranges', () {
    final page = parseVendorHistoryPagePayload(<int>[
      0x01,
      0x01,
      0x00,
      0x10,
      0x80,
      0x55,
      0x80,
      0x56,
      0x88,
      0x57,
      0x84,
    ], source: CgmRecordSource.vendor);

    expect(page, isNotNull);
    expect(page!.rawPairs.length, 4);
    expect(page.records.map((reading) => reading.valueMgdl).toList(), <double>[
      85,
      87,
    ]);
  });

  test('vendor history sync plan handles partial cache', () {
    const range = AidexVendorRangeResponse(
      status: 0x01,
      lowIndex: 1,
      highIndex: 1,
      count: 6486,
    );
    final plan = planVendorHistorySync(
      range: range,
      storedCount: 6296,
      latestStoredOffset: 6299,
      requestedStartOffset: 6300,
    );

    expect(plan.startIndex, 6300);
    expect(plan.targetIndex, 6486);
    expect(plan.totalAvailable, 6486);
    expect(plan.shouldResetCache, isFalse);
    expect(plan.isAlreadyCurrent, isFalse);
  });

  test('vendor pair response round-trips synthetic fixture', () {
    final crypto = deriveAidexCrypto('2222293Q2E');
    final rawNotification = Uint8List.fromList(
      List<int>.generate(16, (index) => index + 16),
    );
    final expectedSessionKey = Uint8List.fromList(
      List<int>.generate(16, (index) => index),
    );
    final plaintext = Uint8List.fromList(<int>[
      ...expectedSessionKey,
      vendorCrc8(expectedSessionKey),
    ]);

    final encrypted = aesCfb128Encrypt(plaintext, rawNotification, crypto.iv);
    final result = processVendorPairResponse(
      encrypted,
      rawNotification,
      crypto.iv,
    );

    expect(result, isNotNull);
    expect(result!.sessionKey, expectedSessionKey);
  });

  group('BMS sensor transfer feature', () {
    test('prefers requesting-device LE deletion when advertised', () {
      final plan = parseAidexBondTransferFeature(const <int>[0x10]);

      expect(plan.scope, CgmBondTransferScope.requestingDeviceLe);
      expect(plan.removesAllLeBonds, isFalse);
      expect(aidexBondTransferOpcode(plan), 0x03);
    });

    test('uses all-LE deletion only when it is advertised without a code', () {
      final plan = parseAidexBondTransferFeature(const <int>[0x00, 0x04]);

      expect(plan.scope, CgmBondTransferScope.allLe);
      expect(plan.removesAllLeBonds, isTrue);
      expect(aidexBondTransferOpcode(plan), 0x06);
    });

    test('rejects authorization-code-only procedures', () {
      for (final feature in const <List<int>>[
        <int>[0x20],
        <int>[0x00, 0x08],
      ]) {
        expect(
          () => parseAidexBondTransferFeature(feature),
          throwsA(
            isA<CgmBondTransferException>().having(
              (failure) => failure.kind,
              'kind',
              CgmBondTransferFailureKind.authorizationCodeRequired,
            ),
          ),
        );
      }
    });

    test('rejects contradictory, empty, and unsupported values', () {
      final cases = <(List<int>, CgmBondTransferFailureKind)>[
        (const <int>[0x30], CgmBondTransferFailureKind.featureMalformed),
        (const <int>[0x00, 0x0c], CgmBondTransferFailureKind.featureMalformed),
        (const <int>[], CgmBondTransferFailureKind.featureUnavailable),
        (const <int>[0x00], CgmBondTransferFailureKind.procedureUnsupported),
      ];

      for (final testCase in cases) {
        expect(
          () => parseAidexBondTransferFeature(testCase.$1),
          throwsA(
            isA<CgmBondTransferException>().having(
              (failure) => failure.kind,
              'kind',
              testCase.$2,
            ),
          ),
        );
      }
    });
  });
}
