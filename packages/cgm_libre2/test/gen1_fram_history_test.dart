import 'package:cgm_libre2/cgm_libre2.dart';
import 'package:test/test.dart';

import 'support/gen1_fram_history_fixtures.dart';

void main() {
  LibreGen1FramHistory parse({
    required int age,
    int trendIndex = 0,
    int? historyIndex,
    void Function(List<int>)? edit,
  }) => parseLibreGen1FramHistory(
    syntheticFramHistoryCore().decryptFram(
      syntheticEncryptedFramHistory(
        age: age,
        trendIndex: trendIndex,
        historyIndex: historyIndex,
        edit: edit,
      ),
    ),
  );

  for (final values in <(int, int, int?)>[
    (0, 1, null),
    (1, 2, null),
    (2, 3, null),
    (3, 4, null),
    (14, 15, null),
    (15, 16, null),
    (17, 16, null),
    (18, 16, 15),
    (19, 16, 15),
    (32, 16, 15),
    (33, 16, 30),
    (47, 16, 30),
    (48, 16, 45),
    (482, 16, 465),
    (483, 16, 480),
    (484, 16, 480),
    (0xffff, 16, 65520),
  ]) {
    test('maps age ${values.$1} without pre-start or delayed future slots', () {
      final result = parse(
        age: values.$1,
        // Even nonzero unused bytes must not become invented pre-start data.
        edit: (bytes) => bytes.fillRange(28, 316, 0xff),
      );
      expect(result.sensorAgeMinutes, values.$1);
      expect(result.trend.length, values.$2);
      expect(result.trend.map((sample) => sample.sensorMinute), [
        for (var i = 0; i < values.$2; i += 1) values.$1 - i,
      ]);
      final newest = values.$3;
      if (newest == null) {
        expect(result.history, isEmpty);
      } else {
        final count = newest ~/ 15 < 32 ? newest ~/ 15 : 32;
        expect(result.history.map((sample) => sample.sensorMinute), [
          for (var i = 0; i < count; i += 1) newest - i * 15,
        ]);
        expect(
          result.history.first.sensorMinute,
          lessThanOrEqualTo(values.$1 - 3),
        );
        expect(
          result.history.every((sample) => sample.sensorMinute >= 15),
          isTrue,
        );
      }
      expect(
        result.trend.every(
          (sample) => sample.kind == LibreGen1FramSampleKind.trend,
        ),
        isTrue,
      );
      expect(
        result.history.every(
          (sample) => sample.kind == LibreGen1FramSampleKind.history,
        ),
        isTrue,
      );
    });
  }

  for (var next = 0; next < 16; next += 1) {
    test('trend wraps from next slot $next in newest-first order', () {
      final result = parse(
        age: 1000,
        trendIndex: next,
        edit: (bytes) {
          for (var slot = 0; slot < 16; slot += 1) {
            writeSyntheticFramField(bytes, 28 + slot * 6, 0, 14, 1000 + slot);
          }
        },
      );
      expect(result.trend.map((sample) => sample.rawValue), [
        for (var i = 0; i < 16; i += 1) 1000 + (next - 1 - i) % 16,
      ]);
    });
  }

  for (var next = 0; next < 32; next += 1) {
    test('history wraps from next slot $next in newest-first order', () {
      final result = parse(
        age: 483 + next * 15,
        edit: (bytes) {
          for (var slot = 0; slot < 32; slot += 1) {
            writeSyntheticFramField(bytes, 124 + slot * 6, 0, 14, 2000 + slot);
          }
        },
      );
      expect(result.history.length, 32);
      expect(result.history.map((sample) => sample.rawValue), [
        for (var i = 0; i < 32; i += 1) 2000 + (next - 1 - i) % 32,
      ]);
      expect(
        result.history.first.sensorMinute - result.history.last.sensorMinute,
        465,
      );
    });
  }

  test('every raw bit is separate from quality, error and temperature', () {
    for (var bit = 0; bit < 48; bit += 1) {
      final result = parse(
        age: 483,
        trendIndex: 1,
        edit: (bytes) {
          writeSyntheticFramField(bytes, 28, bit, 1, 1);
          writeSyntheticFramField(bytes, 124 + 31 * 6, bit, 1, 1);
        },
      );
      for (final sample in [result.trend.first, result.history.first]) {
        expect(sample.rawValue, bit < 14 ? 1 << bit : 0, reason: 'bit $bit');
        expect(
          sample.qualityCode,
          bit >= 14 && bit < 23 ? 1 << (bit - 14) : 0,
          reason: 'bit $bit',
        );
        expect(
          sample.qualityFlags,
          bit >= 23 && bit < 25 ? 1 << (bit - 23) : 0,
          reason: 'bit $bit',
        );
        expect(sample.hasError, bit == 25, reason: 'bit $bit');
        expect(
          sample.rawTemperature,
          bit >= 26 && bit < 38 ? (1 << (bit - 26)) * 4 : 0,
          reason: 'bit $bit',
        );
        expect(
          sample.temperatureAdjustment,
          bit >= 38 && bit < 47 ? (1 << (bit - 38)) * 4 : 0,
          reason: 'bit $bit',
        );
      }
    }
  });

  test(
    'preserves maxima and signed adjustment without glucose interpretation',
    () {
      final result = parse(
        age: 483,
        edit: (bytes) => bytes.fillRange(28, 316, 0xff),
      );
      for (final sample in [result.trend.first, result.history.first]) {
        expect(sample.rawValue, 0x3fff);
        expect(sample.qualityCode, 0x1ff);
        expect(sample.qualityFlags, 3);
        expect(sample.hasError, isTrue);
        expect(sample.rawTemperature, 0x3ffc);
        expect(sample.temperatureAdjustment, -0x7fc);
      }
      final zero = parse(age: 483);
      expect(zero.trend.first.rawValue, 0);
      expect(zero.history.first.rawValue, 0);
    },
  );

  for (final invalid in [16, 17, 255]) {
    test('rejects invalid trend index $invalid with closed error', () {
      expect(
        () => parse(age: 483, trendIndex: invalid),
        _fails(LibreGen1FramHistoryErrorKind.invalidTrendIndex),
      );
    });
  }
  for (final invalid in [32, 33, 255]) {
    test('rejects invalid history index $invalid with closed error', () {
      expect(
        () => parse(age: 483, historyIndex: invalid),
        _fails(LibreGen1FramHistoryErrorKind.invalidHistoryIndex),
      );
    });
  }
  for (final age in [0, 2, 3, 17, 18, 32, 33, 482, 483, 484, 65535]) {
    test(
      'rejects early/late history index at age $age without shifting identity',
      () {
        final expected = age < 3 ? 0 : ((age - 3) ~/ 15) % 32;
        for (final index in [(expected + 1) % 32, (expected - 1) % 32]) {
          expect(
            () => parse(age: age, historyIndex: index),
            _fails(LibreGen1FramHistoryErrorKind.inconsistentHistoryTiming),
          );
        }
      },
    );
  }

  for (final changedByte in [4, 28, 326]) {
    test(
      'CRC failure in region containing $changedByte never reaches parser',
      () {
        final encrypted = syntheticEncryptedFramHistory(age: 483)
          ..[changedByte] ^= 1;
        expect(
          () => parseLibreGen1FramHistory(
            syntheticFramHistoryCore().decryptFram(encrypted),
          ),
          throwsA(isA<LibreProtocolError>()),
        );
      },
    );
  }

  test('result lists are immutable and all diagnostics redact raw values', () {
    final result = parse(
      age: 483,
      edit: (bytes) => bytes.fillRange(28, 316, 0xff),
    );
    expect(() => result.trend.clear(), throwsUnsupportedError);
    expect(
      () => result.history.add(result.history.first),
      throwsUnsupportedError,
    );
    expect(result.toString(), 'LibreGen1FramHistory(data: <redacted>)');
    expect(
      result.trend.first.toString(),
      'LibreGen1FramRawSample(data: <redacted>)',
    );
    expect(
      result.history.first.toString(),
      'LibreGen1FramRawSample(data: <redacted>)',
    );
    expect(
      const LibreGen1FramHistoryError(
        LibreGen1FramHistoryErrorKind.inconsistentHistoryTiming,
      ).toString(),
      'LibreGen1FramHistoryError(kind: inconsistentHistoryTiming, data: <redacted>)',
    );
  });
}

Matcher _fails(LibreGen1FramHistoryErrorKind kind) => throwsA(
  isA<LibreGen1FramHistoryError>().having((error) => error.kind, 'kind', kind),
);
