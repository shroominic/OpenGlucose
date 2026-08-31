import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export.dart';
import 'package:openglucose/src/sensor_archive_share_file.dart';
import 'package:share_plus/share_plus.dart';

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
    expect(
      archivedSensorExportFilename(ArchivedSensorExportFormat.csv),
      'openglucose-glucose-data.csv',
    );
    expect(
      archivedSensorExportFilename(ArchivedSensorExportFormat.txt),
      'openglucose-glucose-data.txt',
    );
    expect(
      archivedSensorExportFilename(ArchivedSensorExportFormat.xlsx),
      'openglucose-glucose-data.xlsx',
    );
  });

  test('formats expose UI-ready labels, extensions, and MIME types', () {
    expect(ArchivedSensorExportFormat.csv.label, 'CSV');
    expect(ArchivedSensorExportFormat.csv.extension, 'csv');
    expect(ArchivedSensorExportFormat.csv.mimeType, 'text/csv');
    expect(ArchivedSensorExportFormat.txt.label, 'Plain text');
    expect(ArchivedSensorExportFormat.txt.extension, 'txt');
    expect(ArchivedSensorExportFormat.txt.mimeType, 'text/plain');
    expect(ArchivedSensorExportFormat.xlsx.label, 'Excel workbook');
    expect(ArchivedSensorExportFormat.xlsx.extension, 'xlsx');
    expect(
      ArchivedSensorExportFormat.xlsx.mimeType,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  });

  test('share request contains one file and no separate text save item', () {
    final file = XFile.fromData(
      Uint8List.fromList(<int>[0x50, 0x4b]),
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    const filename = 'openglucose-glucose-data.xlsx';
    const localizedTitle = '导出已归档传感器数据';
    const origin = Rect.fromLTWH(10, 20, 30, 40);

    final params = buildArchivedSensorShareParams(
      file: file,
      filename: filename,
      localizedTitle: localizedTitle,
      sharePositionOrigin: origin,
    );

    expect(params.title, localizedTitle);
    expect(params.subject, localizedTitle);
    expect(params.files, <XFile>[file]);
    expect(params.files, hasLength(1));
    expect(params.fileNameOverrides, <String>[filename]);
    expect(params.fileNameOverrides, hasLength(1));
    expect(params.text, isNull);
    expect(params.uri, isNull);
    expect(params.previewThumbnail, isNull);
    expect(params.mailToFallbackEnabled, isFalse);
    expect(params.sharePositionOrigin, origin);
  });

  test('plain text is usable UTF-8 tab-delimited data', () {
    final text = buildArchivedSensorText(
      session: session,
      readings: <CgmReading>[
        CgmReading(
          valueMgdl: 103.5,
          source: CgmRecordSource.raw,
          recordedAt: DateTime.parse('2026-08-01T09:02:03+07:00'),
          rawValue: 982,
          qualifier: 7,
          isDisplayProvisional: true,
        ),
      ],
    );

    final lines = text.split('\r\n');
    expect(lines.first, archivedSensorCsvColumns.join('\t'));
    expect(lines[1], contains('2026-08-01T02:02:03.000Z\t103.5\t5.750\traw'));
    expect(lines[1].split('\t'), hasLength(archivedSensorCsvColumns.length));
    expect(text, isNot(contains(session.id)));
    expect(text, isNot(contains(session.serial)));
    expect(utf8.decode(utf8.encode(text)), text);
  });

  test('format-neutral builder returns the selected file bytes', () {
    final csvBytes = buildArchivedSensorExport(
      format: ArchivedSensorExportFormat.csv,
      session: session,
      readings: const <CgmReading>[],
    );
    final textBytes = buildArchivedSensorExport(
      format: ArchivedSensorExportFormat.txt,
      session: session,
      readings: const <CgmReading>[],
    );

    expect(
      utf8.decode(csvBytes),
      buildArchivedSensorCsv(session: session, readings: const []),
    );
    expect(
      utf8.decode(textBytes),
      buildArchivedSensorText(session: session, readings: const []),
    );
  });

  test(
    'XLSX package is structurally complete and artifact-tool compatible',
    () {
      final readings = <CgmReading>[
        CgmReading(
          valueMgdl: 103.5,
          source: CgmRecordSource.raw,
          sensorMinute: 22,
          recordedAt: DateTime.utc(2026, 8, 1, 2, 2, 3),
          rawValue: 982,
          qualifier: 7,
          isDisplayProvisional: true,
        ),
        CgmReading(
          valueMgdl: 110,
          source: CgmRecordSource.vendor,
          sensorMinute: 27,
          recordedAt: DateTime.utc(2026, 8, 1, 2, 7, 3),
        ),
      ];
      final bytes = buildArchivedSensorExport(
        format: ArchivedSensorExportFormat.xlsx,
        session: session,
        readings: readings,
      );

      expect(bytes.take(2), <int>[0x50, 0x4b]);
      final workbook = ZipDecoder().decodeBytes(bytes);
      expect(
        workbook.map((file) => file.name),
        containsAll(<String>[
          '[Content_Types].xml',
          '_rels/.rels',
          'xl/workbook.xml',
          'xl/_rels/workbook.xml.rels',
          'xl/styles.xml',
          'xl/worksheets/sheet1.xml',
        ]),
      );
      final contentTypes = _archiveText(workbook, '[Content_Types].xml');
      final relationships = _archiveText(
        workbook,
        'xl/_rels/workbook.xml.rels',
      );
      final workbookXml = _archiveText(workbook, 'xl/workbook.xml');
      expect(contentTypes, contains('spreadsheetml.sheet.main+xml'));
      expect(contentTypes, contains('spreadsheetml.worksheet+xml'));
      expect(contentTypes, contains('spreadsheetml.styles+xml'));
      expect(relationships, contains('Target="worksheets/sheet1.xml"'));
      expect(relationships, contains('Target="styles.xml"'));
      expect(workbookXml, contains('name="Glucose data"'));
      expect(workbookXml, contains('r:id="rId1"'));
    },
  );

  test('XLSX has styled headers, usable widths, and a frozen filter row', () {
    final bytes = buildArchivedSensorXlsx(
      session: session,
      readings: const <CgmReading>[
        CgmReading(valueMgdl: 103, source: CgmRecordSource.vendor),
      ],
    );
    final workbook = ZipDecoder().decodeBytes(bytes);
    final sheet = _archiveText(workbook, 'xl/worksheets/sheet1.xml');
    final styles = _archiveText(workbook, 'xl/styles.xml');

    expect(sheet, contains('<pane ySplit="1" topLeftCell="A2"'));
    expect(sheet, contains('state="frozen"'));
    expect(sheet, contains('<autoFilter ref="A1:M2"/>'));
    expect(sheet, contains('<row r="1" ht="32" customHeight="1">'));
    expect(sheet, contains('<c r="A1" s="1" t="inlineStr">'));
    expect(sheet, contains('<col min="1" max="1" width="18.0"'));
    expect(sheet, contains('<col min="6" max="6" width="25.0"'));
    expect(styles, contains('<fonts count="2">'));
    expect(styles, contains('<fgColor rgb="FF0B6E69"/>'));
    expect(styles, contains('<cellXfs count="5">'));
    expect(styles, contains('formatCode="0.000"'));
  });

  test('XLSX uses typed numbers, blank nullable cells, and no formulas', () {
    final bytes = buildArchivedSensorXlsx(
      session: session,
      readings: <CgmReading>[
        CgmReading(
          valueMgdl: 103.5,
          source: CgmRecordSource.raw,
          sensorMinute: 22,
          recordedAt: DateTime.utc(2026, 8, 1, 2, 2, 3),
          rawValue: 982,
          qualifier: 7,
          isDisplayProvisional: true,
        ),
        CgmReading(
          valueMgdl: 110,
          source: CgmRecordSource.vendor,
          sensorMinute: 27,
          recordedAt: DateTime.utc(2026, 8, 1, 2, 7, 3),
        ),
      ],
    );
    final workbook = ZipDecoder().decodeBytes(bytes);
    final sheet = _archiveText(workbook, 'xl/worksheets/sheet1.xml');

    expect(sheet, contains('<c r="G2" s="3"><v>103.5</v></c>'));
    expect(sheet, contains('<c r="H2" s="4"><v>5.750</v></c>'));
    expect(sheet, contains('<c r="J2" s="2"><v>22</v></c>'));
    expect(sheet, contains('<c r="K2" s="2"><v>982</v></c>'));
    expect(sheet, contains('<c r="L2" s="2"><v>7</v></c>'));
    expect(sheet, isNot(contains('<c r="K3"')));
    expect(sheet, isNot(contains('<c r="L3"')));
    expect(sheet, isNot(contains('<f')));
    expect(sheet, isNot(contains(session.id)));
    expect(sheet, isNot(contains(session.serial)));
    expect(sheet, isNot(contains(session.deviceId)));
  });

  test('XLSX bytes are deterministic and do not expose export time', () {
    final first = buildArchivedSensorXlsx(
      session: session,
      readings: const <CgmReading>[
        CgmReading(valueMgdl: 103, source: CgmRecordSource.vendor),
      ],
    );
    final second = buildArchivedSensorXlsx(
      session: session,
      readings: const <CgmReading>[
        CgmReading(valueMgdl: 103, source: CgmRecordSource.vendor),
      ],
    );

    expect(second, first);
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
    'startup cleanup removes only known payloads and exact legacy CSV files',
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
      final legacyCsv = File(
        '${root.path}/openhealth_SENSOR_42-A_20260609-0858.csv',
      )..writeAsStringSync('identifier-bearing private export');
      final legacyCollisionCsv = File(
        '${root.path}/openhealth_SENSOR_42-A_20260609-0858-2.csv',
      )..writeAsStringSync('identifier-bearing private export');
      final legacyXlsx = File(
        '${root.path}/openhealth_SENSOR_42-A_20260609-0858.xlsx',
      )..writeAsStringSync('not in the scoped CSV migration');
      final malformedTimestamp = File(
        '${root.path}/openhealth_SENSOR_42-A_recent.csv',
      )..writeAsStringSync('unrelated near-match');
      final impossibleLegacyCollision = File(
        '${root.path}/openhealth_SENSOR_42-A_20260609-0858-1.csv',
      )..writeAsStringSync('unrelated near-match');
      final similarlyNamedDirectory = Directory(
        '${root.path}/openhealth_DIRECTORY_20260609-0858.csv',
      )..createSync();

      await clearStaleArchivedSensorShareFiles(
        temporaryDirectoryPath: root.path,
      );

      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await pluginCache.exists(), isFalse);
      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await ownCache.exists(), isFalse);
      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await legacyCsv.exists(), isFalse);
      // ignore: avoid_slow_async_io, verifying privacy cleanup is the behavior.
      expect(await legacyCollisionCsv.exists(), isFalse);
      // ignore: avoid_slow_async_io, proving non-CSV files remain untouched.
      expect(await legacyXlsx.exists(), isTrue);
      // ignore: avoid_slow_async_io, proving near-matches remain untouched.
      expect(await malformedTimestamp.exists(), isTrue);
      // ignore: avoid_slow_async_io, old collision numbering began at two.
      expect(await impossibleLegacyCollision.exists(), isTrue);
      // ignore: avoid_slow_async_io, proving only regular files are removed.
      expect(await similarlyNamedDirectory.exists(), isTrue);
      // ignore: avoid_slow_async_io, proving cleanup remains tightly scoped.
      expect(await unrelated.exists(), isTrue);
    },
  );
}

String _archiveText(Archive archive, String path) {
  final file = archive.findFile(path);
  expect(file, isNotNull, reason: '$path must exist in XLSX package');
  return utf8.decode(file!.content);
}
