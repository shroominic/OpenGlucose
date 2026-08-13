import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export.dart';
import 'package:openglucose/src/sensor_archive_share_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final session = ArchivedSensorSession(
    id: 'session/42',
    historyKey: 'history,private',
    storageKey: 'aidex:07A12',
    driverId: 'aidex',
    deviceId: '07A12',
    displayName: 'AiDEX "Demo"\n07A12',
    serial: 'SER-42',
    model: 'G7, test',
    firmware: '1.2.3',
    reason: SensorArchiveReason.expired,
    readingCount: 2,
    startedAt: DateTime.utc(2026, 8, 1, 1, 2, 3),
    endedAt: DateTime.utc(2026, 8, 16, 1, 2, 3),
    lastReadingAt: DateTime.utc(2026, 8, 16, 0, 57),
  );

  test('exports minimized session context and readings as RFC 4180 CSV', () {
    final csv = buildArchivedSensorCsv(
      session: session,
      readings: <CgmReading>[
        CgmReading(
          valueMgdl: 103.5,
          source: CgmRecordSource.raw,
          sensorMinute: 22,
          recordedAt: DateTime.parse('2026-08-01T09:02:03+07:00'),
          rawValue: 982,
          qualifier: 7,
          isDisplayProvisional: true,
        ),
        CgmReading(
          valueMgdl: 90,
          source: CgmRecordSource.vendor,
          sensorMinute: 17,
          recordedAt: DateTime.utc(2026, 8, 1, 1, 57),
        ),
      ],
    );

    expect(csv, endsWith('\r\n'));
    expect(csv.split('\r\n'), hasLength(4));
    final lines = csv.split('\r\n');
    expect(lines.first, archivedSensorCsvColumns.join(','));
    expect(lines[1], contains('2026-08-01T01:57:00.000Z,90,5.000,vendor,17'));
    expect(
      lines[2],
      contains('2026-08-01T02:02:03.000Z,103.5,5.750,raw,22,982,7,true'),
    );
    expect(lines[1], startsWith('expired,'));
    expect(lines[1], isNot(contains(session.id)));
    expect(lines[1], isNot(contains(session.serial)));
    expect(lines[1], isNot(contains(session.deviceId)));
    expect(lines[1], endsWith('vendor,17,,,false'));
  });

  test('keeps untimestamped raw readings and blank nullable fields', () {
    final csv = buildArchivedSensorCsv(
      session: session,
      readings: const <CgmReading>[
        CgmReading(
          valueMgdl: 72,
          source: CgmRecordSource.broadcast,
          rawValue: 700,
        ),
      ],
    );

    final dataRow = csv.split('\r\n')[1];
    expect(dataRow, contains(',2,,72,4.000,broadcast,,700,,false'));
  });

  test('metadata-only archives still produce a data row', () {
    final csv = buildArchivedSensorCsv(session: session, readings: const []);

    final lines = csv.split('\r\n');
    expect(lines, hasLength(3));
    expect(lines[1], startsWith('expired,'));
    expect(lines[1], endsWith(',2,,,,,,,,'));
  });

  test('filename is neutral and deterministic', () {
    expect(archivedSensorCsvFilename(), 'openglucose-glucose-data.csv');
  });

  test('does not export sensor identity metadata', () {
    final csv = buildArchivedSensorCsv(
      session: session,
      readings: const <CgmReading>[
        CgmReading(valueMgdl: 103, source: CgmRecordSource.vendor),
      ],
    );

    expect(csv, isNot(contains(session.id)));
    expect(csv, isNot(contains(session.historyKey)));
    expect(csv, isNot(contains(session.storageKey)));
    expect(csv, isNot(contains(session.driverId)));
    expect(csv, isNot(contains(session.deviceId)));
    expect(csv, isNot(contains(session.displayName)));
    expect(csv, isNot(contains(session.serial)));
    expect(csv, isNot(contains(session.model)));
    expect(csv, isNot(contains(session.firmware)));
  });

  test('native share payload is scoped and removed after sharing', () async {
    final root = await Directory.systemTemp.createTemp(
      'openglucose-share-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final filePath = await prepareArchivedSensorShareFile(
      filename: archivedSensorCsvFilename(),
      contents: 'private glucose history',
      temporaryDirectoryPath: root.path,
    );
    expect(filePath, isNotNull);
    final file = File(filePath!);
    final directory = file.parent;
    expect(await file.readAsString(), 'private glucose history');

    await disposeArchivedSensorShareFile(filePath);

    // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
    expect(await file.exists(), isFalse);
    // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
    expect(await directory.exists(), isFalse);
  });

  test(
    'startup cleanup removes only known share payload directories',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'openglucose-share-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final pluginCache = Directory('${root.path}/share_plus')
        ..createSync(recursive: true);
      File('${pluginCache.path}/glucose.csv').writeAsStringSync('private');
      final ownCache = Directory('${root.path}/openglucose-export-stale')
        ..createSync(recursive: true);
      File('${ownCache.path}/glucose.csv').writeAsStringSync('private');
      final unrelated = Directory('${root.path}/unrelated-cache')
        ..createSync(recursive: true);
      File('${unrelated.path}/keep.txt').writeAsStringSync('keep');

      await clearStaleArchivedSensorShareFiles(
        temporaryDirectoryPath: root.path,
      );

      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await pluginCache.exists(), isFalse);
      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await ownCache.exists(), isFalse);
      // ignore: avoid_slow_async_io, proving cleanup remains tightly scoped.
      expect(await unrelated.exists(), isTrue);
    },
  );
}
