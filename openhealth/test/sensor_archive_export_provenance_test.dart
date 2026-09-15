import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/libre_nfc_history.dart';
import 'package:openglucose/src/sensor_archive.dart';
import 'package:openglucose/src/sensor_archive_export.dart';
import 'package:openglucose/src/sensor_archive_export_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final format in ArchivedSensorExportFormat.values) {
    test('legacy ${format.name} stays byte-compatible and has no evidence', () {
      final readings = [
        const CgmReading(
          valueMgdl: 110,
          source: CgmRecordSource.raw,
          rawValue: 900,
          qualifier: 7,
          isDisplayProvisional: true,
        ),
        CgmReading(
          valueMgdl: 90,
          source: CgmRecordSource.vendor,
          sensorMinute: 98,
          recordedAt: _at,
        ),
      ];
      final session = _session(2, driver: 'aidex');
      final data = ArchivedSensorExportData.legacy(
        session: session,
        readings: readings,
      );
      expect(data.hasAcquisitionEvidence, isFalse);
      expect(data.acquisitionEntries, isNull);
      final expected = buildArchivedSensorExport(
        format: format,
        session: session,
        readings: readings,
      );
      expect(_export(data, format), expected);
      readings.clear();
      expect(data.readings, hasLength(2));
      expect(_export(data, format), expected);
      final contents = _contents(expected, format);
      expect(contents, isNot(contains('export_schema_version')));
      if (format == ArchivedSensorExportFormat.xlsx) {
        expect(contents, contains('<autoFilter ref="A1:M3"/>'));
        expect(contents, isNot(contains('<col min="14"')));
      } else {
        final separator = format == ArchivedSensorExportFormat.csv ? ',' : '\t';
        expect(contents.split('\r\n').first.split(separator), hasLength(13));
      }
    });
  }

  test(
    'v2 CSV keeps source and all acquisition evidence paired after sort',
    () {
      final data = _mixedData();
      final rows = _csvRows(data);
      expect(rows.first, archivedSensorAcquisitionCsvColumns);
      expect(rows.every((row) => row.length == 17), isTrue);
      expect(rows.skip(1).map((row) => row[6]), ['80', '100', '110', '120']);
      expect(rows.skip(1).map((row) => row[13]), everyElement('2'));
      expect(rows[1].sublist(14), ['legacyUnknown', '', 'legacyUnknown']);
      expect(rows[1].sublist(8, 13), ['raw', '73', '834', '7', 'true']);
      expect(rows[2].sublist(14), [
        'nfcHistory',
        '2026-09-10T07:00:00.123456Z',
        'sensorRelative',
      ]);
      expect(rows[2][5], '2026-09-10T06:35:00.123456Z');
      expect(rows[2][8], 'vendor');
      expect(rows[3].sublist(14), [
        'bleLive',
        '2026-09-10T06:58:00.123456Z',
        'phoneReceipt',
      ]);
      expect(rows[3][5], rows[3][15]);
      expect(rows[4].sublist(14), [
        'nfcTrend',
        '2026-09-10T07:00:00.123456Z',
        'sensorRelative',
      ]);
      expect(rows[4][5], '2026-09-10T06:59:00.123456Z');
      expect(rows.skip(1).map((row) => row[12]), everyElement('true'));
    },
  );

  test('TXT has the same 17 fields and ordering as CSV', () {
    final data = _mixedData();
    final textRows = utf8
        .decode(_export(data, ArchivedSensorExportFormat.txt))
        .split('\r\n')
        .where((line) => line.isNotEmpty)
        .map((line) => line.split('\t'))
        .toList();
    expect(textRows, _csvRows(data));
  });

  test(
    'XLSX extends widths and filter, preserving typed values and blanks',
    () {
      final bytes = _export(_mixedData(), ArchivedSensorExportFormat.xlsx);
      final sheet = _contents(bytes, ArchivedSensorExportFormat.xlsx);
      expect(sheet, contains('<dimension ref="A1:Q5"/>'));
      expect(sheet, contains('<autoFilter ref="A1:Q5"/>'));
      expect(sheet, contains('<col min="14" max="14" width="24.0"'));
      expect(sheet, contains('<col min="17" max="17" width="20.0"'));
      expect(sheet, contains('<c r="N2" s="2"><v>2</v></c>'));
      expect(sheet, contains('<c r="G2" s="3"><v>80</v></c>'));
      expect(sheet, contains('<c r="H2" s="4"><v>4.444</v></c>'));
      expect(sheet, isNot(contains('<c r="P2"')));
      expect(sheet, contains('<c r="O2" t="inlineStr">'));
      expect(sheet, contains('<t xml:space="preserve">legacyUnknown</t>'));
      expect(sheet, contains('<c r="P3" t="inlineStr">'));
      expect(sheet, contains('2026-09-10T07:00:00.123456Z'));
      expect(sheet, isNot(contains('<f')));
    },
  );

  test('equal timestamps preserve original row and evidence order', () {
    final entries = [
      _entry(
        LibreHistoryOrigin.nfcHistory,
        minute: 90,
        receipt: _at.add(const Duration(minutes: 10)),
      ),
      _entry(LibreHistoryOrigin.nfcTrend, minute: 100),
      _entry(LibreHistoryOrigin.bleLive, minute: 101),
    ];
    final data = ArchivedSensorExportData.libreHistory(
      session: _session(3),
      entries: entries,
    );
    final rows = _csvRows(data);
    expect(rows.skip(1).map((row) => row[9]), ['90', '100', '101']);
    expect(rows.skip(1).map((row) => row[14]), [
      'nfcHistory',
      'nfcTrend',
      'bleLive',
    ]);
  });

  test('unknown legacy time and receipt remain blank, with no inference', () {
    const entry = LibreHistoryEntry(
      reading: CgmReading(valueMgdl: 90, source: CgmRecordSource.broadcast),
      origin: LibreHistoryOrigin.legacyUnknown,
      firstReceivedAt: null,
      timestampBasis: LibreHistoryTimestampBasis.legacyUnknown,
    );
    final data = ArchivedSensorExportData.libreHistory(
      session: _session(1),
      entries: [entry],
    );
    final row = _csvRows(data)[1];
    expect(row[5], isEmpty);
    expect(row[9], isEmpty);
    expect(row.sublist(14), ['legacyUnknown', '', 'legacyUnknown']);
  });

  for (final format in ArchivedSensorExportFormat.values) {
    test('empty v2 ${format.name} has a versioned metadata-only row', () {
      final data = ArchivedSensorExportData.libreHistory(
        session: _session(0),
        entries: [],
      );
      final contents = _contents(_export(data, format), format);
      if (format == ArchivedSensorExportFormat.xlsx) {
        expect(contents, contains('<autoFilter ref="A1:Q2"/>'));
        expect(contents, contains('<c r="N2" s="2"><v>2</v></c>'));
        expect(contents, isNot(contains('<c r="O2"')));
      } else {
        final separator = format == ArchivedSensorExportFormat.csv ? ',' : '\t';
        final rows = contents.split('\r\n');
        expect(rows, hasLength(3));
        final row = rows[1].split(separator);
        expect(row, hasLength(17));
        expect(row[4], '0');
        expect(row.sublist(13), ['2', '', '', '']);
      }
    });

    test(
      'v2 ${format.name} is deterministic and omits all sensor identity',
      () {
        final data = _mixedData();
        final first = _export(data, format);
        expect(_export(data, format), first);
        final contents = _contents(first, format);
        for (final identity in [
          data.session.id,
          data.session.historyKey,
          data.session.storageKey,
          data.session.driverId,
          data.session.deviceId,
          data.session.displayName,
          data.session.serial,
          data.session.model,
          data.session.firmware,
        ]) {
          expect(contents, isNot(contains(identity)));
        }
      },
    );
  }

  test(
    'snapshot copies input containers and reading objects before export',
    () {
      final mutable = _MutableReading();
      final entries = [
        LibreHistoryEntry(
          reading: mutable,
          origin: LibreHistoryOrigin.bleLive,
          firstReceivedAt: _at,
          timestampBasis: LibreHistoryTimestampBasis.phoneReceipt,
        ),
      ];
      final data = ArchivedSensorExportData.libreHistory(
        session: _session(1),
        entries: entries,
      );
      final before = _export(data, ArchivedSensorExportFormat.csv);
      mutable.value = 200;
      entries.clear();
      expect(data.readings.single.valueMgdl, 100);
      expect(
        data.readings.single,
        same(data.acquisitionEntries!.single.reading),
      );
      expect(data.readings.clear, throwsUnsupportedError);
      expect(() => data.acquisitionEntries!.clear(), throwsUnsupportedError);
      expect(_export(data, ArchivedSensorExportFormat.csv), before);
      expect(data.toString(), 'ArchivedSensorExportData(data: <redacted>)');
    },
  );

  test(
    'complete snapshot passes through a compute isolate unchanged',
    () async {
      final data = _mixedData();
      for (final format in ArchivedSensorExportFormat.values) {
        final bytes = await compute(_buildInIsolate, (
          format: format,
          data: data,
        ));
        expect(bytes, _export(data, format));
      }
    },
  );

  test('accumulated archive is not limited to one 48-sample NFC scan', () {
    final entries = [
      for (var minute = 1; minute <= 60; minute++)
        _entry(LibreHistoryOrigin.nfcTrend, minute: minute),
    ];
    final data = ArchivedSensorExportData.libreHistory(
      session: _session(60),
      entries: entries,
    );
    expect(_csvRows(data), hasLength(61));
  });

  test(
    'v2 rejects mismatched driver, counts, and duplicate observation identity',
    () {
      final entry = _entry(LibreHistoryOrigin.bleLive);
      for (final session in [_session(2), _session(1, driver: 'aidex')]) {
        expect(
          () => ArchivedSensorExportData.libreHistory(
            session: session,
            entries: [entry],
          ),
          _closedError,
        );
      }
      expect(
        () => ArchivedSensorExportData.libreHistory(
          session: _session(2),
          entries: [entry, _entry(LibreHistoryOrigin.nfcTrend)],
        ),
        _closedError,
      );
    },
  );

  final valid = _entry(LibreHistoryOrigin.nfcTrend);
  final invalid = <String, LibreHistoryEntry>{
    'legacy receipt': _replace(
      valid,
      origin: LibreHistoryOrigin.legacyUnknown,
      basis: LibreHistoryTimestampBasis.legacyUnknown,
    ),
    'legacy basis': LibreHistoryEntry(
      reading: valid.reading,
      origin: LibreHistoryOrigin.legacyUnknown,
      firstReceivedAt: null,
      timestampBasis: LibreHistoryTimestampBasis.phoneReceipt,
    ),
    'BLE basis': _replace(valid, origin: LibreHistoryOrigin.bleLive),
    'BLE missing receipt': LibreHistoryEntry(
      reading: valid.reading,
      origin: LibreHistoryOrigin.bleLive,
      firstReceivedAt: null,
      timestampBasis: LibreHistoryTimestampBasis.phoneReceipt,
    ),
    'BLE unequal receipt': _replace(
      valid,
      origin: LibreHistoryOrigin.bleLive,
      basis: LibreHistoryTimestampBasis.phoneReceipt,
      receipt: _at.add(const Duration(microseconds: 1)),
    ),
    'NFC basis': _replace(
      valid,
      basis: LibreHistoryTimestampBasis.phoneReceipt,
    ),
    'NFC missing receipt': LibreHistoryEntry(
      reading: valid.reading,
      origin: valid.origin,
      firstReceivedAt: null,
      timestampBasis: valid.timestampBasis,
    ),
    'NFC future reading': _replace(
      valid,
      reading: valid.reading.copyWith(
        recordedAt: _at.add(const Duration(microseconds: 1)),
      ),
    ),
    'NFC fractional offset': _replace(
      valid,
      receipt: _at.add(const Duration(microseconds: 1)),
    ),
    'NFC derived age overflow': _replace(
      valid,
      reading: valid.reading.copyWith(sensorMinute: 0xffff),
      receipt: _at.add(const Duration(minutes: 1)),
    ),
    'NFC stable output': _replace(
      valid,
      reading: valid.reading.copyWith(isDisplayProvisional: false),
    ),
    'NFC wrong source': _replace(
      valid,
      reading: valid.reading.copyWith(source: CgmRecordSource.raw),
    ),
    'negative minute': _replace(
      valid,
      reading: valid.reading.copyWith(sensorMinute: -1),
    ),
    'minute overflow': _replace(
      valid,
      reading: valid.reading.copyWith(sensorMinute: 0x10000),
    ),
    'zero glucose': _replace(
      valid,
      reading: valid.reading.copyWith(valueMgdl: 0),
    ),
    'negative glucose': _replace(
      valid,
      reading: valid.reading.copyWith(valueMgdl: -1),
    ),
    'NaN glucose': _replace(
      valid,
      reading: valid.reading.copyWith(valueMgdl: double.nan),
    ),
    'infinite glucose': _replace(
      valid,
      reading: valid.reading.copyWith(valueMgdl: double.infinity),
    ),
    for (final origin in [
      LibreHistoryOrigin.bleLive,
      LibreHistoryOrigin.nfcTrend,
    ])
      '${origin.name} missing timestamp and minute': LibreHistoryEntry(
        reading: const CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.vendor,
          isDisplayProvisional: true,
        ),
        origin: origin,
        firstReceivedAt: _at,
        timestampBasis: origin == LibreHistoryOrigin.bleLive
            ? LibreHistoryTimestampBasis.phoneReceipt
            : LibreHistoryTimestampBasis.sensorRelative,
      ),
  };
  for (final entry in invalid.entries) {
    test('contradictory acquisition evidence is closed: ${entry.key}', () {
      expect(
        () => ArchivedSensorExportData.libreHistory(
          session: _session(1),
          entries: [entry.value],
        ),
        _closedError,
      );
    });
  }
}

final DateTime _at = DateTime.parse('2026-09-10T14:00:00.123456+07:00');
final Matcher _closedError = throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'redacted message',
    'Archived sensor acquisition evidence is unavailable.',
  ),
);

ArchivedSensorSession _session(int count, {String driver = 'libre2-gen1'}) =>
    ArchivedSensorSession(
      id: 'synthetic-archive-id',
      historyKey: 'synthetic-history-key',
      storageKey: 'synthetic-storage-key',
      driverId: driver,
      deviceId: 'synthetic-device-id',
      displayName: 'synthetic-display-name',
      serial: 'synthetic-serial',
      model: 'synthetic-model',
      firmware: 'synthetic-firmware',
      reason: SensorArchiveReason.disconnected,
      readingCount: count,
      endedAt: _at.add(const Duration(minutes: 1)),
      lastReadingAt: _at,
    );

LibreHistoryEntry _entry(
  LibreHistoryOrigin origin, {
  int minute = 100,
  DateTime? recordedAt,
  DateTime? receipt,
  double value = 100,
}) => LibreHistoryEntry(
  reading: CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.vendor,
    recordedAt: recordedAt ?? _at,
    sensorMinute: minute,
    isDisplayProvisional: true,
  ),
  origin: origin,
  firstReceivedAt: origin == LibreHistoryOrigin.legacyUnknown
      ? null
      : receipt ?? _at,
  timestampBasis: switch (origin) {
    LibreHistoryOrigin.legacyUnknown =>
      LibreHistoryTimestampBasis.legacyUnknown,
    LibreHistoryOrigin.bleLive => LibreHistoryTimestampBasis.phoneReceipt,
    _ => LibreHistoryTimestampBasis.sensorRelative,
  },
);

LibreHistoryEntry _replace(
  LibreHistoryEntry entry, {
  CgmReading? reading,
  LibreHistoryOrigin? origin,
  LibreHistoryTimestampBasis? basis,
  DateTime? receipt,
}) => LibreHistoryEntry(
  reading: reading ?? entry.reading,
  origin: origin ?? entry.origin,
  timestampBasis: basis ?? entry.timestampBasis,
  firstReceivedAt: receipt ?? entry.firstReceivedAt,
);

ArchivedSensorExportData _mixedData() => ArchivedSensorExportData.libreHistory(
  session: _session(4),
  entries: [
    _entry(
      LibreHistoryOrigin.bleLive,
      minute: 98,
      value: 110,
      recordedAt: _at.subtract(const Duration(minutes: 2)),
      receipt: _at.subtract(const Duration(minutes: 2)),
    ),
    _entry(
      LibreHistoryOrigin.nfcTrend,
      minute: 99,
      value: 120,
      recordedAt: _at.subtract(const Duration(minutes: 1)),
    ),
    LibreHistoryEntry(
      reading: CgmReading(
        valueMgdl: 80,
        source: CgmRecordSource.raw,
        recordedAt: _at.subtract(const Duration(minutes: 27)),
        sensorMinute: 73,
        rawValue: 834,
        qualifier: 7,
        isDisplayProvisional: true,
      ),
      origin: LibreHistoryOrigin.legacyUnknown,
      firstReceivedAt: null,
      timestampBasis: LibreHistoryTimestampBasis.legacyUnknown,
    ),
    _entry(
      LibreHistoryOrigin.nfcHistory,
      minute: 75,
      value: 100,
      recordedAt: _at.subtract(const Duration(minutes: 25)),
    ),
  ],
);

Uint8List _export(
  ArchivedSensorExportData data,
  ArchivedSensorExportFormat format,
) => buildArchivedSensorExportFromData(format: format, data: data);

List<List<String>> _csvRows(ArchivedSensorExportData data) => utf8
    .decode(_export(data, ArchivedSensorExportFormat.csv))
    .split('\r\n')
    .where((line) => line.isNotEmpty)
    .map((line) => line.split(','))
    .toList();

String _contents(Uint8List bytes, ArchivedSensorExportFormat format) =>
    format == ArchivedSensorExportFormat.xlsx
    ? utf8.decode(
        ZipDecoder()
            .decodeBytes(bytes)
            .findFile('xl/worksheets/sheet1.xml')!
            .content,
      )
    : utf8.decode(bytes);

Uint8List _buildInIsolate(
  ({ArchivedSensorExportFormat format, ArchivedSensorExportData data}) request,
) => _export(request.data, request.format);

class _MutableReading extends CgmReading {
  _MutableReading()
    : super(
        valueMgdl: 100,
        source: CgmRecordSource.vendor,
        sensorMinute: 100,
        recordedAt: _at,
        isDisplayProvisional: true,
      );
  double value = 100;
  @override
  double get valueMgdl => value;
}
