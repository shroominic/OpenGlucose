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
    test(
      'BLE historical ${format.name} keeps v2 shape and paired evidence',
      () {
        final entries = [
          _entry(LibreHistoryOrigin.bleTrend, minute: 600, value: 123.25),
          _entry(LibreHistoryOrigin.bleHistory, minute: 585, value: 98.5),
        ];
        final data = _data(entries);
        final bytes = _export(data, format);
        expect(_export(data, format), bytes);
        final contents = _contents(bytes, format);
        if (format == ArchivedSensorExportFormat.xlsx) {
          expect(contents, contains('<dimension ref="A1:Q3"/>'));
          expect(contents, contains('<autoFilter ref="A1:Q3"/>'));
          expect(contents, contains('<c r="N2" s="2"><v>2</v></c>'));
          expect(contents, contains('<c r="N3" s="2"><v>2</v></c>'));
          expect(_cell(contents, 'O2'), contains('bleHistory'));
          expect(_cell(contents, 'O3'), contains('bleTrend'));
          expect(
            _cell(contents, 'F2'),
            contains('2026-09-10T06:43:00.123456Z'),
          );
          expect(
            _cell(contents, 'F3'),
            contains('2026-09-10T06:58:00.123456Z'),
          );
          for (final row in [2, 3]) {
            expect(
              _cell(contents, 'P$row'),
              contains('2026-09-10T07:00:00.123456Z'),
            );
            expect(_cell(contents, 'Q$row'), contains('sensorRelative'));
            expect(_cell(contents, 'I$row'), contains('vendor'));
            expect(_cell(contents, 'M$row'), contains('true'));
          }
        } else {
          final separator = format == ArchivedSensorExportFormat.csv
              ? ','
              : '\t';
          final rows = contents
              .split('\r\n')
              .where((row) => row.isNotEmpty)
              .map((row) => row.split(separator))
              .toList();
          expect(rows.first, archivedSensorAcquisitionCsvColumns);
          expect(rows.every((row) => row.length == 17), isTrue);
          expect(rows.skip(1).map((row) => row[6]), ['98.5', '123.25']);
          expect(rows.skip(1).map((row) => row[9]), ['585', '600']);
          expect(rows.skip(1).map((row) => row[5]), [
            '2026-09-10T06:43:00.123456Z',
            '2026-09-10T06:58:00.123456Z',
          ]);
          expect(rows[1].sublist(13), [
            '2',
            'bleHistory',
            '2026-09-10T07:00:00.123456Z',
            'sensorRelative',
          ]);
          expect(rows[2].sublist(13), [
            '2',
            'bleTrend',
            '2026-09-10T07:00:00.123456Z',
            'sensorRelative',
          ]);
          expect(rows.skip(1).map((row) => row[8]), everyElement('vendor'));
          expect(rows.skip(1).map((row) => row[12]), everyElement('true'));
        }
        expect(contents, isNot(contains('synthetic-private-')));
        expect(
          data.readings.first.recordedAt,
          entries.first.reading.recordedAt,
        );
        expect(data.acquisitionEntries!.first.firstReceivedAt, _receipt);
      },
    );
  }

  test('every sparse slot is valid across all packet-minute remainders', () {
    for (var age = 600; age < 615; age++) {
      for (final offset in [2, 4, 6, 7, 12, 15]) {
        expect(
          _data([
            _entry(
              LibreHistoryOrigin.bleTrend,
              minute: age - offset,
              packetMinute: age,
            ),
          ]).readings,
          hasLength(1),
        );
      }
      final newest = ((age - 2) ~/ 15) * 15;
      for (final offset in [0, 15, 30]) {
        expect(
          _data([
            _entry(
              LibreHistoryOrigin.bleHistory,
              minute: newest - offset,
              packetMinute: age,
            ),
          ]).readings,
          hasLength(1),
        );
      }
    }
  });

  test('BLE two-minute history delay is not the NFC three-minute delay', () {
    expect(
      _data([
        _entry(LibreHistoryOrigin.bleHistory, minute: 600, packetMinute: 602),
      ]).readings,
      hasLength(1),
    );
    expect(
      () => _data([
        _entry(LibreHistoryOrigin.bleHistory, minute: 600, packetMinute: 601),
      ]),
      _closedError,
    );
  });

  test(
    'warmup boundary and full wire age are checked without invented lifetime',
    () {
      expect(
        _data([
          _entry(LibreHistoryOrigin.bleTrend, minute: 60, packetMinute: 62),
        ]).readings,
        hasLength(1),
      );
      expect(
        _data([
          _entry(LibreHistoryOrigin.bleHistory, minute: 60, packetMinute: 62),
        ]).readings,
        hasLength(1),
      );
      expect(
        _data([
          _entry(
            LibreHistoryOrigin.bleTrend,
            minute: 65533,
            packetMinute: 65535,
          ),
        ]).readings,
        hasLength(1),
      );
      expect(
        _data([
          _entry(
            LibreHistoryOrigin.bleHistory,
            minute: 65520,
            packetMinute: 65535,
          ),
        ]).readings,
        hasLength(1),
      );
    },
  );

  for (final origin in [
    LibreHistoryOrigin.bleTrend,
    LibreHistoryOrigin.bleHistory,
  ]) {
    final valid = _entry(
      origin,
      minute: origin == LibreHistoryOrigin.bleTrend ? 600 : 585,
    );
    final invalid = <String, LibreHistoryEntry>{
      'missing receipt': LibreHistoryEntry(
        reading: valid.reading,
        origin: origin,
        firstReceivedAt: null,
        timestampBasis: valid.timestampBasis,
      ),
      'wrong basis': _replace(
        valid,
        basis: LibreHistoryTimestampBasis.phoneReceipt,
      ),
      'future sample': _replace(
        valid,
        reading: valid.reading.copyWith(
          recordedAt: _receipt.add(const Duration(microseconds: 1)),
        ),
      ),
      'fractional receipt': _replace(
        valid,
        receipt: _receipt.add(const Duration(microseconds: 1)),
      ),
      'raw source': _replace(
        valid,
        reading: valid.reading.copyWith(source: CgmRecordSource.raw),
      ),
      'not provisional': _replace(
        valid,
        reading: valid.reading.copyWith(isDisplayProvisional: false),
      ),
      'no minute or time': LibreHistoryEntry(
        reading: const CgmReading(
          valueMgdl: 100,
          source: CgmRecordSource.vendor,
          isDisplayProvisional: true,
        ),
        origin: origin,
        firstReceivedAt: _receipt,
        timestampBasis: valid.timestampBasis,
      ),
      'zero offset': _replace(
        valid,
        reading: valid.reading.copyWith(recordedAt: _receipt),
      ),
      'before warmup': _entry(
        origin,
        minute: origin == LibreHistoryOrigin.bleTrend ? 59 : 45,
        packetMinute: 61,
      ),
      'wire age overflow': _entry(
        origin,
        minute: origin == LibreHistoryOrigin.bleTrend ? 65534 : 65520,
        packetMinute: 65536,
      ),
      'zero glucose': _replace(
        valid,
        reading: valid.reading.copyWith(valueMgdl: 0),
      ),
      'nonfinite glucose': _replace(
        valid,
        reading: valid.reading.copyWith(valueMgdl: double.infinity),
      ),
    };
    for (final entry in invalid.entries) {
      test('${origin.name} rejects ${entry.key}', () {
        expect(() => _data([entry.value]), _closedError);
      });
    }
  }

  test('non-slot trend offset and fourth history slot are rejected', () {
    expect(
      () => _data([_entry(LibreHistoryOrigin.bleTrend, minute: 599)]),
      _closedError,
    );
    expect(
      () => _data([_entry(LibreHistoryOrigin.bleHistory, minute: 555)]),
      _closedError,
    );
    expect(
      () => _data([_entry(LibreHistoryOrigin.bleHistory, minute: 586)]),
      _closedError,
    );
  });

  test('new origins survive immutable compute transfer', () async {
    final data = _data([
      _entry(LibreHistoryOrigin.bleTrend, minute: 600),
      _entry(LibreHistoryOrigin.bleHistory, minute: 585),
    ]);
    expect(() => data.acquisitionEntries!.clear(), throwsUnsupportedError);
    for (final format in ArchivedSensorExportFormat.values) {
      expect(
        await compute(_inIsolate, (data: data, format: format)),
        _export(data, format),
      );
    }
  });
}

final DateTime _receipt = DateTime.parse('2026-09-10T14:00:00.123456+07:00');
final Matcher _closedError = throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'redacted error',
    'Archived sensor acquisition evidence is unavailable.',
  ),
);

LibreHistoryEntry _entry(
  LibreHistoryOrigin origin, {
  required int minute,
  int packetMinute = 602,
  double value = 100,
}) => LibreHistoryEntry(
  reading: CgmReading(
    valueMgdl: value,
    source: CgmRecordSource.vendor,
    sensorMinute: minute,
    recordedAt: _receipt.subtract(Duration(minutes: packetMinute - minute)),
    isDisplayProvisional: true,
  ),
  origin: origin,
  firstReceivedAt: _receipt,
  timestampBasis: LibreHistoryTimestampBasis.sensorRelative,
);

LibreHistoryEntry _replace(
  LibreHistoryEntry entry, {
  CgmReading? reading,
  DateTime? receipt,
  LibreHistoryTimestampBasis? basis,
}) => LibreHistoryEntry(
  reading: reading ?? entry.reading,
  origin: entry.origin,
  firstReceivedAt: receipt ?? entry.firstReceivedAt,
  timestampBasis: basis ?? entry.timestampBasis,
);

ArchivedSensorExportData _data(List<LibreHistoryEntry> entries) =>
    ArchivedSensorExportData.libreHistory(
      session: ArchivedSensorSession(
        id: 'synthetic-private-id',
        historyKey: 'synthetic-private-history',
        storageKey: 'synthetic-private-bootstrap',
        driverId: 'libre2-gen1',
        deviceId: 'synthetic-private-device',
        displayName: 'synthetic-private-name',
        reason: SensorArchiveReason.disconnected,
        readingCount: entries.length,
      ),
      entries: entries,
    );

Uint8List _export(
  ArchivedSensorExportData data,
  ArchivedSensorExportFormat format,
) => buildArchivedSensorExportFromData(format: format, data: data);
Uint8List _inIsolate(
  ({ArchivedSensorExportData data, ArchivedSensorExportFormat format}) request,
) => _export(request.data, request.format);
String _contents(Uint8List bytes, ArchivedSensorExportFormat format) =>
    format == ArchivedSensorExportFormat.xlsx
    ? utf8.decode(
        ZipDecoder()
            .decodeBytes(bytes)
            .findFile('xl/worksheets/sheet1.xml')!
            .content,
      )
    : utf8.decode(bytes);
String _cell(String sheet, String address) =>
    RegExp('<c r="$address"[^>]*>.*?</c>').firstMatch(sheet)!.group(0)!;
