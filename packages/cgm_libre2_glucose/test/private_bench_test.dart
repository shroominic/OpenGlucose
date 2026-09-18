// SPDX-License-Identifier: GPL-3.0-only
//
// The private bench reads its inputs only through the audited Darwin
// descriptor path in `tool/analyze_private_bench.dart`. Every assertion below
// describes that path's result, so the suite is scoped to macOS; the
// fail-closed contract that every other host gets instead is asserted in
// `private_bench_host_scope_test.dart`.
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/analyze_private_bench.dart';
import 'support/synthetic.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Map<String, Object?> calibration() => {
  'schemaVersion': 2,
  'nativeCaptureSessionId': 'synthetic_native_1234',
  'processSessionId': 'synthetic_process_1234',
  'captureSessionId': null,
  'versionCode': 1,
  'lastUpdateTime': 1,
  'targetUidSha256': sha256.convert(syntheticUid).toString(),
  'iso15693ManufacturerPrefix': 'e007',
  'patchInfoSha256': sha256.convert(syntheticPatch).toString(),
  'model': 'libre2',
  'securityGeneration': 'gen1',
  'algorithmOrderUidHex': hex(syntheticUid),
  'patchInfoHex': hex(syntheticPatch),
  'encryptedFramHex': hex(encryptedFram(clearFram())),
  'observedAtUtc': '2026-01-01T00:00:00Z',
  'observedAtMonotonicElapsedNanos': 1,
  'sourceKind': 'explicitLibre2Lifecycle',
  'explicitAttemptId': 'synthetic_attempt',
};
List<Map<String, Object?>> trace({int raw = 1400, int temperature = 6400}) {
  final bytes = encryptedBle(clearBle(raw: raw, temperature: temperature));
  return [
    for (var i = 0; i < 3; i++)
      {
        'schema_version': 1,
        'sequence': i + 1,
        'correlation_id': 'synthetic_notify',
        'recorded_at_utc': '2026-01-01T00:00:0${i + 1}Z',
        'monotonic_elapsed_microseconds': (i + 1) * 1000000,
        'event_type': 'notificationData',
        'operation': 'notifications',
        'data': {
          'device_id': 'AA:BB:CC:DD:EE:FF',
          'service_uuid': 'fde3',
          'characteristic_uuid': 'f002',
          'properties': {
            'read': false,
            'write': false,
            'write_without_response': false,
            'notify': true,
            'indicate': false,
          },
          'bytes': bytes.sublist(const [0, 20, 38][i], const [20, 38, 46][i]),
        },
      },
  ];
}

void main() {
  late Directory temp;
  late File fram, ble;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('libre-private-bench-test-');
    fram = File('${temp.path}/calibration.json');
    ble = File('${temp.path}/ble.jsonl');
  });
  tearDown(() => temp.deleteSync(recursive: true));
  void write({
    Map<String, Object?>? frame,
    List<Map<String, Object?>>? events,
    String? source,
  }) {
    for (final file in [fram, ble]) {
      if (file.existsSync()) Process.runSync('/bin/chmod', ['600', file.path]);
    }
    fram.writeAsStringSync(jsonEncode(frame ?? calibration()));
    ble.writeAsStringSync(
      source ?? (events ?? trace()).map(jsonEncode).join('\n'),
    );
    for (final file in [fram, ble]) {
      expect(Process.runSync('/bin/chmod', ['600', file.path]).exitCode, 0);
    }
  }

  Future<(int, String)> run() => runPrivateBenchAnalysis([
    '--calibration',
    fram.absolute.path,
    '--ble',
    ble.absolute.path,
  ]);
  Map<String, Object?> summary((int, String) result) =>
      jsonDecode(result.$2) as Map<String, Object?>;
  void closed((int, String) result) {
    for (final secret in [
      fram.path,
      ble.path,
      'AA:BB',
      '001122',
      '9d0830',
      '1400',
      '6400',
      'StackTrace',
    ]) {
      expect(result.$2, isNot(contains(secret)));
    }
  }

  test(
    'owner600 native-v2 source yields counts only, with no mutation',
    () async {
      write();
      final before = [fram.readAsBytesSync(), ble.readAsBytesSync()];
      final result = await run();
      expect(result.$1, 0, reason: result.$2);
      expect(summary(result), {
        'analyzed': true,
        'notifications': 3,
        'completeComposites': 1,
        'incompleteComposites': 0,
        'acceptedCurrentSamples': 1,
        'integrityRejected': 0,
        'currentRejections': {},
        'sampleRejections': {},
        'packetRejections': {},
      });
      expect(fram.readAsBytesSync(), before[0]);
      expect(ble.readAsBytesSync(), before[1]);
      closed(result);
    },
  );
  test(
    'raw-zero and invalid temperature are distinct closed reasons',
    () async {
      write(events: trace(raw: 0));
      var result = await run();
      expect(summary(result)['currentRejections'], {'sensorError': 1});
      expect(summary(result)['sampleRejections'], {'sensorError': 10});
      closed(result);
      write(events: trace(temperature: 0));
      result = await run();
      expect(summary(result)['currentRejections'], {'invalidTemperature': 1});
      expect(summary(result)['acceptedCurrentSamples'], 0);
    },
  );
  test('CRC rejection prints no packet content', () async {
    final rows = trace();
    ((rows[1]['data'] as Map)['bytes'] as List)[0] ^= 1;
    write(events: rows);
    final result = await run();
    expect(summary(result)['integrityRejected'], 1);
    expect(summary(result)['acceptedCurrentSamples'], 0);
    closed(result);
  });
  test('single explicit host-v1 artifact is also accepted', () async {
    final frame = calibration()
      ..['schemaVersion'] = 1
      ..['captureSessionId'] = 'session-20260101T000000Z-synthetic'
      ..remove('sourceKind')
      ..remove('explicitAttemptId');
    write(frame: frame);
    expect((await run()).$1, 0);
  });
  test('invalid binding and schema do not parse as calibration', () async {
    for (final frame in [
      {...calibration(), 'targetUidSha256': '0' * 64},
      {...calibration(), 'patchInfoSha256': '0' * 64},
      {...calibration(), 'captureSessionId': 'unexpected-host-binding'},
      {...calibration(), 'extra': true},
      {...calibration(), 'model': 'libre2Plus'},
      {...calibration(), 'observedAtUtc': '2026-13-01T00:00:00Z'},
    ]) {
      write(frame: frame);
      final result = await run();
      expect(result.$1, 65);
      closed(result);
    }
  });
  test('all input permissions must be exactly600, not644 or400', () async {
    for (final mode in ['644', '400', '700']) {
      write();
      Process.runSync('/bin/chmod', [mode, ble.path]);
      final result = await run();
      expect(result.$1, 66);
      closed(result);
    }
  });
  test(
    'final symlink, directory and oversize inputs fail before parse',
    () async {
      write();
      final link = Link('${temp.path}/link')..createSync(ble.path);
      expect(
        (await runPrivateBenchAnalysis([
          '--calibration',
          fram.path,
          '--ble',
          link.path,
        ])).$1,
        66,
      );
      expect(
        (await runPrivateBenchAnalysis([
          '--calibration',
          fram.path,
          '--ble',
          temp.path,
        ])).$1,
        66,
      );
      fram.writeAsBytesSync(List.filled(16385, 32));
      expect((await run()).$1, 66);
    },
  );
  test('explicit arguments and absolute paths only', () async {
    for (final args in [
      <String>[],
      ['--ble', '/not-used', '--calibration', '/not-used'],
      ['--calibration', 'relative', '--ble', '/not-used'],
    ]) {
      final result = await runPrivateBenchAnalysis(args);
      expect(result.$1, isNot(0));
      closed(result);
    }
  });
  test(
    'multiple matching devices and mixed subscription fragments are rejected',
    () async {
      for (final mutation in ['device', 'correlation', 'timeout']) {
        final rows = trace();
        if (mutation == 'device') {
          (rows[1]['data'] as Map)['device_id'] = '00:11:22:33:44:55';
        }
        if (mutation == 'correlation') rows[1]['correlation_id'] = 'other';
        if (mutation == 'timeout') {
          rows[2]['monotonic_elapsed_microseconds'] = 12000001;
          rows[2]['recorded_at_utc'] = '2026-01-01T00:00:12Z';
        }
        write(events: rows);
        final result = await run();
        expect(result.$1, 65);
        closed(result);
      }
    },
  );
  test('out-of-order fragments and nonmonotonic trace are rejected', () async {
    final malformed = trace();
    (malformed[1]['data'] as Map)['bytes'] = List.filled(8, 0);
    write(events: malformed);
    expect((await run()).$1, 65);
    final unordered = trace()..[1]['sequence'] = 1;
    write(events: unordered);
    expect((await run()).$1, 65);
  });
  test(
    'trace schema uses integer versions and valid elapsed clock ranges',
    () async {
      for (final mutation in ['version', 'sequenceZero', 'clockNegative']) {
        final rows = trace();
        if (mutation == 'version') rows[0]['schema_version'] = 1.0;
        if (mutation == 'sequenceZero') rows[0]['sequence'] = 0;
        if (mutation == 'clockNegative') {
          rows[0]['monotonic_elapsed_microseconds'] = -1;
        }
        write(events: rows);
        final result = await run();
        expect(result.$1, 65, reason: mutation);
        expect(summary(result)['error'], 'traceSchema');
        closed(result);
      }
      final firstAtZero = trace();
      firstAtZero[0]['monotonic_elapsed_microseconds'] = 0;
      write(events: firstAtZero);
      expect((await run()).$1, 0);
    },
  );
  test(
    'terminal boundaries cannot join old fragments to a new packet',
    () async {
      for (final type in [
        'connectionState',
        'streamCompleted',
        'streamCancelled',
        'streamCancellationFailed',
        'streamFailed',
      ]) {
        final old = trace().take(2).toList();
        final next = trace();
        for (var i = 0; i < next.length; i++) {
          next[i]['sequence'] = i + 4;
          next[i]['monotonic_elapsed_microseconds'] = (i + 4) * 1000000;
          next[i]['recorded_at_utc'] = '2026-01-01T00:00:0${i + 4}Z';
          next[i]['correlation_id'] = 'synthetic_next_subscription';
        }
        write(
          events: [
            ...old,
            {
              ...trace()[2],
              'event_type': type,
              'operation': type == 'connectionState'
                  ? 'connectionState'
                  : 'notifications',
              'data': <String, Object?>{},
            },
            ...next,
          ],
        );
        final result = await run();
        expect(result.$1, 0, reason: type);
        expect(summary(result)['incompleteComposites'], 1);
        expect(summary(result)['completeComposites'], 1);
        expect(summary(result)['acceptedCurrentSamples'], 1);
        closed(result);
      }
    },
  );
  test('escaped duplicate calibration keys cannot replace a binding', () async {
    write();
    final encoded = fram.readAsStringSync();
    fram.writeAsStringSync('{"\\u0073chemaVersion":2,${encoded.substring(1)}');
    final result = await run();
    expect(result.$1, 65);
    closed(result);
  });
  test('trailing partial composite is counted and never decoded', () async {
    write(events: trace().take(2).toList());
    final result = await run();
    expect(result.$1, 0);
    expect(summary(result)['incompleteComposites'], 1);
    expect(summary(result)['completeComposites'], 0);
  });
  test(
    'duplicate nested JSON keys are rejected despite jsonDecode overwrite',
    () async {
      final source = trace()
          .map(jsonEncode)
          .join('\n')
          .replaceFirst(
            '"device_id":',
            '"device_id":"PRIVATE-DUPLICATE","device_id":',
          );
      write(source: source);
      final result = await run();
      expect(result.$1, 65);
      closed(result);
      expect(result.$2, isNot(contains('PRIVATE-DUPLICATE')));
    },
  );
  test(
    'permission change after secure open fails descriptor-bound recheck',
    () async {
      write();
      final result = await runPrivateBenchAnalysis(
        ['--calibration', fram.path, '--ble', ble.path],
        afterSecureOpenForTest: () =>
            Process.runSync('/bin/chmod', ['644', fram.path]),
      );
      expect(result.$1, 66);
      closed(result);
    },
  );
  test('CLI emits one redacted JSON line and empty stderr', () async {
    write(events: trace(raw: 0));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/analyze_private_bench.dart',
      '--calibration',
      fram.path,
      '--ble',
      ble.path,
    ]);
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stderr, isEmpty);
    expect(const LineSplitter().convert(result.stdout as String), hasLength(1));
    closed((result.exitCode, result.stdout as String));
  });
}
