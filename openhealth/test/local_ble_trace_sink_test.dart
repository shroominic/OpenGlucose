import 'dart:convert';
import 'dart:io';

import 'package:cgm_ble/cgm_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/local_ble_trace_sink.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'openglucose-ble-trace-test-',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'writes ordered sensitive JSON into the supplied private directory',
    () async {
      final sink = LocalBleTraceSink(
        directoryProvider: () async => temporaryDirectory,
        sessionToken: 'test-session',
      );

      await Future.wait(<Future<void>>[
        sink.append(_event(sequence: 1, bytes: const <int>[1, 2, 3])),
        sink.append(_event(sequence: 2, bytes: const <int>[4, 5, 6])),
      ]);

      final files = temporaryDirectory.listSync().whereType<File>().toList(
        growable: false,
      );
      expect(files, hasLength(1));
      expect(files.single.path, endsWith('ble-test-session-00.jsonl'));

      final lines = await files.single.readAsLines();
      expect(lines, hasLength(2));
      final first = jsonDecode(lines[0]) as Map<String, Object?>;
      final second = jsonDecode(lines[1]) as Map<String, Object?>;
      expect(first['schema_version'], bleTraceSchemaVersion);
      expect(first['sequence'], 1);
      expect(second['sequence'], 2);
      expect((first['data']! as Map<String, Object?>)['bytes'], <Object?>[
        1,
        2,
        3,
      ]);
    },
  );

  test('rotates and stops at the configured capture bound', () async {
    final firstEvent = _event(sequence: 1);
    final secondEvent = _event(sequence: 2);
    final segmentBytes = <BleTraceEvent>[firstEvent, secondEvent]
        .map(
          (event) =>
              utf8.encode('${jsonEncode(event.toSensitiveJson())}\n').length,
        )
        .reduce((left, right) => left > right ? left : right);
    final sink = LocalBleTraceSink(
      directoryProvider: () async => temporaryDirectory,
      sessionToken: 'bounded',
      maxSegmentBytes: segmentBytes,
      maxSegmentCount: 2,
    );

    await sink.append(firstEvent);
    await sink.append(secondEvent);
    await sink.append(_event(sequence: 3));

    final files = temporaryDirectory.listSync().whereType<File>().toList(
      growable: false,
    )..sort((left, right) => left.path.compareTo(right.path));
    expect(files, hasLength(2));
    expect(files[0].path, endsWith('ble-bounded-00.jsonl'));
    expect(files[1].path, endsWith('ble-bounded-01.jsonl'));
    expect(await files[0].readAsLines(), hasLength(1));
    expect(await files[1].readAsLines(), hasLength(1));
    expect(sink.health.state, LocalBleTraceSinkState.capacityReached);
    expect(sink.health.capacityReached, isTrue);
    expect(sink.health.lastCommittedSequence, 2);
  });

  test(
    'an oversized event latches capacity without creating a segment',
    () async {
      final sink = LocalBleTraceSink(
        directoryProvider: () async => temporaryDirectory,
        sessionToken: 'oversized',
        maxSegmentBytes: 1,
      );

      await sink.append(_event(sequence: 1, bytes: const <int>[1, 2, 3]));

      expect(temporaryDirectory.listSync(), isEmpty);
      expect(sink.health.state, LocalBleTraceSinkState.capacityReached);
      expect(sink.health.errorCode, 'event_exceeds_segment_capacity');
      expect(sink.health.lastCommittedSequence, isNull);
    },
  );

  test('a write failure is terminal for the capture session', () async {
    final blockingFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}not-a-directory',
    );
    await blockingFile.writeAsString('blocked');
    final sink = LocalBleTraceSink(
      directoryProvider: () async => Directory(blockingFile.path),
      sessionToken: 'write-failure',
    );

    await expectLater(
      sink.append(_event(sequence: 1)),
      throwsA(isA<FileSystemException>()),
    );
    expect(sink.health.state, LocalBleTraceSinkState.writeError);
    expect(sink.health.errorCode, 'write_failed');

    await blockingFile.delete();
    await expectLater(sink.append(_event(sequence: 2)), throwsStateError);
    expect(sink.health.state, LocalBleTraceSinkState.writeError);
    expect(sink.health.lastCommittedSequence, isNull);
  });

  test('retains only the configured number of BLE trace sessions', () async {
    final oldest = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}ble-oldest-00.jsonl',
    );
    final newest = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}ble-newest-00.jsonl',
    );
    await oldest.writeAsString('{}\n');
    await newest.writeAsString('{}\n');
    await oldest.setLastModified(DateTime.utc(2026, 1, 1));
    await newest.setLastModified(DateTime.utc(2026, 1, 2));
    final sink = LocalBleTraceSink(
      directoryProvider: () async => temporaryDirectory,
      sessionToken: 'current',
      maxRetainedSessionCount: 2,
    );

    await sink.append(_event(sequence: 1));

    expect(oldest.existsSync(), isFalse);
    expect(newest.existsSync(), isTrue);
    expect(
      File(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'ble-current-00.jsonl',
      ).existsSync(),
      isTrue,
    );
  });

  test('rejects unsafe file tokens', () {
    expect(
      () => LocalBleTraceSink(
        directoryProvider: () async => temporaryDirectory,
        sessionToken: '../escape',
      ),
      throwsArgumentError,
    );
  });
}

BleTraceEvent _event({required int sequence, List<int> bytes = const <int>[]}) {
  return BleTraceEvent(
    sequence: sequence,
    correlationId: 'c$sequence',
    recordedAtUtc: DateTime.utc(2026, 8, 31, 1, 2, sequence),
    monotonicElapsed: Duration(milliseconds: sequence),
    type: BleTraceEventType.notificationData,
    operation: BleTraceOperation.notifications,
    data: <String, Object?>{'bytes': bytes},
  );
}
