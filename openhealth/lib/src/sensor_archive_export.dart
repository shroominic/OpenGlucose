// OOXML fragments intentionally join at element boundaries without spaces.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cgm_core/cgm_core.dart';

import 'sensor_archive.dart';

/// Column names for the stable archived-sensor CSV interchange format.
///
/// Session timing is deliberately repeated on every reading row. A CSV can be
/// filtered or concatenated without exposing stable sensor/device identifiers.
const archivedSensorCsvColumns = <String>[
  'archive_reason',
  'session_started_at_utc',
  'session_ended_at_utc',
  'last_reading_at_utc',
  'archived_reading_count',
  'recorded_at_utc',
  'glucose_mg_dl',
  'glucose_mmol_l',
  'source',
  'sensor_minute',
  'raw_value',
  'qualifier',
  'provisional',
];

/// Supported, local-only archive export formats.
enum ArchivedSensorExportFormat {
  csv(label: 'CSV', extension: 'csv', mimeType: 'text/csv'),
  txt(label: 'Plain text', extension: 'txt', mimeType: 'text/plain'),
  xlsx(
    label: 'Excel workbook',
    extension: 'xlsx',
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  )
  ;

  const ArchivedSensorExportFormat({
    required this.label,
    required this.extension,
    required this.mimeType,
  });

  final String label;
  final String extension;
  final String mimeType;
}

/// Builds one of the supported export formats without performing any I/O.
Uint8List buildArchivedSensorExport({
  required ArchivedSensorExportFormat format,
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) {
  return switch (format) {
    ArchivedSensorExportFormat.csv => Uint8List.fromList(
      utf8.encode(buildArchivedSensorCsv(session: session, readings: readings)),
    ),
    ArchivedSensorExportFormat.txt => Uint8List.fromList(
      utf8.encode(
        buildArchivedSensorText(session: session, readings: readings),
      ),
    ),
    ArchivedSensorExportFormat.xlsx => buildArchivedSensorXlsx(
      session: session,
      readings: readings,
    ),
  };
}

/// Builds an RFC 4180 CSV containing one archived sensor session.
///
/// Readings are exported in chronological order. Untimestamped readings are
/// placed last in their original order so no raw sensor record is discarded.
/// An archive with no readings still emits one metadata-only row.
String buildArchivedSensorCsv({
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) {
  final rows = _exportRows(session, readings);
  return '${rows.map(_encodeCsvRow).join('\r\n')}\r\n';
}

/// Builds a UTF-8, tab-delimited plain-text export.
///
/// Text cells are spreadsheet-neutralized in case the file is later imported
/// as tab-separated data.
String buildArchivedSensorText({
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) {
  final rows = _exportRows(session, readings);
  return '${rows.map((row) => row.map(_encodeTextField).join('\t')).join('\r\n')}'
      '\r\n';
}

/// Builds a genuine Office Open XML workbook containing one worksheet.
///
/// Text cells use inline strings rather than formulas, which prevents values
/// that begin with `=`, `+`, `-`, or `@` from executing when opened in
/// spreadsheet software. Measurements use typed numeric cells when finite;
/// nullable fields are represented by absent cells rather than empty strings.
Uint8List buildArchivedSensorXlsx({
  required ArchivedSensorSession session,
  required List<CgmReading> readings,
}) {
  final rows = _exportRows(session, readings);
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', _xlsxContentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', _xlsxRootRelationships))
    ..addFile(ArchiveFile.string('xl/workbook.xml', _xlsxWorkbook))
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        _xlsxWorkbookRelationships,
      ),
    )
    ..addFile(ArchiveFile.string('xl/styles.xml', _xlsxStyles))
    ..addFile(
      ArchiveFile.string('xl/worksheets/sheet1.xml', _buildWorksheetXml(rows)),
    );
  return ZipEncoder().encodeBytes(
    archive,
    // A fixed ZIP timestamp makes identical exports byte-for-byte stable and
    // avoids leaking when the user created or shared the workbook.
    modified: DateTime.utc(1980),
  );
}

/// Returns a neutral filename that reveals no sensor identity or timestamps.
String archivedSensorCsvFilename() =>
    archivedSensorExportFilename(ArchivedSensorExportFormat.csv);

/// Returns a neutral filename for [format].
String archivedSensorExportFilename(ArchivedSensorExportFormat format) =>
    'openglucose-glucose-data.${format.extension}';

List<List<String>> _exportRows(
  ArchivedSensorSession session,
  List<CgmReading> readings,
) {
  final indexedReadings = readings.indexed.toList(growable: false)
    ..sort((left, right) {
      final leftAt = left.$2.recordedAt;
      final rightAt = right.$2.recordedAt;
      if (leftAt == null && rightAt != null) {
        return 1;
      }
      if (leftAt != null && rightAt == null) {
        return -1;
      }
      if (leftAt != null && rightAt != null) {
        final timestampOrder = leftAt.compareTo(rightAt);
        if (timestampOrder != 0) {
          return timestampOrder;
        }
      }
      return left.$1.compareTo(right.$1);
    });

  return <List<String>>[
    archivedSensorCsvColumns,
    if (indexedReadings.isEmpty) _rowFor(session, null),
    for (final indexedReading in indexedReadings)
      _rowFor(session, indexedReading.$2),
  ];
}

List<String> _rowFor(ArchivedSensorSession session, CgmReading? reading) =>
    <String>[
      _safeText(session.reason.name),
      _utcTimestamp(session.startedAt),
      _utcTimestamp(session.endedAt),
      _utcTimestamp(session.lastReadingAt),
      session.readingCount.toString(),
      _utcTimestamp(reading?.recordedAt),
      if (reading == null) '' else _decimal(reading.valueMgdl),
      if (reading == null) '' else (reading.valueMgdl / 18).toStringAsFixed(3),
      _safeText(reading?.source.name ?? ''),
      reading?.sensorMinute?.toString() ?? '',
      reading?.rawValue?.toString() ?? '',
      reading?.qualifier?.toString() ?? '',
      reading?.isDisplayProvisional.toString() ?? '',
    ];

/// Stops spreadsheet applications from evaluating exported labels as formulas.
/// Numeric measurement columns remain numeric.
String _safeText(String value) {
  if (!RegExp(r'^[\x00-\x20]*[=+\-@]').hasMatch(value)) {
    return value;
  }
  return "'$value";
}

String _utcTimestamp(DateTime? value) => value?.toUtc().toIso8601String() ?? '';

String _decimal(double value) {
  if (!value.isFinite) {
    return value.toString();
  }
  return value == value.truncateToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}

String _encodeCsvRow(List<String> fields) => fields.map(_escapeCsv).join(',');

String _escapeCsv(String value) {
  if (!value.contains(RegExp(r'[,"\r\n]'))) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

String _encodeTextField(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\t', r'\t')
    .replaceAll('\r', r'\r')
    .replaceAll('\n', r'\n');

const _numericColumns = <int>{4, 6, 7, 9, 10, 11};

const _xlsxColumnWidths = <double>[
  18,
  25,
  25,
  25,
  22,
  25,
  16,
  18,
  14,
  16,
  14,
  12,
  14,
];

String _buildWorksheetXml(List<List<String>> rows) {
  final lastColumn = _xlsxColumnName(archivedSensorCsvColumns.length - 1);
  final buffer = StringBuffer(
    '<worksheet xmlns="http://schemas.openxmlformats.org/'
    'spreadsheetml/2006/main">'
    '<dimension ref="A1:$lastColumn${rows.length}"/>'
    '<sheetViews><sheetView workbookViewId="0" showGridLines="0">'
    '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" '
    'state="frozen"/>'
    '<selection pane="bottomLeft" activeCell="A2" sqref="A2"/>'
    '</sheetView></sheetViews>'
    '<sheetFormatPr defaultRowHeight="20"/>'
    '<cols>',
  );
  for (var index = 0; index < _xlsxColumnWidths.length; index += 1) {
    final number = index + 1;
    buffer.write(
      '<col min="$number" max="$number" '
      'width="${_xlsxColumnWidths[index]}" customWidth="1"/>',
    );
  }
  buffer.write('</cols><sheetData>');
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
    final rowNumber = rowIndex + 1;
    final isHeader = rowIndex == 0;
    buffer.write(
      isHeader
          ? '<row r="$rowNumber" ht="32" customHeight="1">'
          : '<row r="$rowNumber">',
    );
    final row = rows[rowIndex];
    for (var columnIndex = 0; columnIndex < row.length; columnIndex += 1) {
      final value = row[columnIndex];
      if (!isHeader && value.isEmpty) {
        continue;
      }
      final reference = '${_xlsxColumnName(columnIndex)}$rowNumber';
      final number = !isHeader && _numericColumns.contains(columnIndex)
          ? double.tryParse(value)
          : null;
      if (number?.isFinite ?? false) {
        buffer.write(
          '<c r="$reference" s="${_xlsxNumericStyle(columnIndex)}">'
          '<v>${_xmlEscape(value)}</v></c>',
        );
      } else {
        final style = isHeader ? ' s="1"' : '';
        buffer.write(
          '<c r="$reference"$style t="inlineStr"><is>'
          '<t xml:space="preserve">${_xmlEscape(_safeText(value))}</t>'
          '</is></c>',
        );
      }
    }
    buffer.write('</row>');
  }
  buffer
    ..write('</sheetData>')
    ..write('<autoFilter ref="A1:$lastColumn${rows.length}"/>')
    ..write(
      '<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" '
      'header="0.3" footer="0.3"/>',
    )
    ..write('</worksheet>');
  return buffer.toString();
}

int _xlsxNumericStyle(int columnIndex) => switch (columnIndex) {
  6 => 3,
  7 => 4,
  _ => 2,
};

String _xlsxColumnName(int zeroBasedIndex) {
  var remaining = zeroBasedIndex + 1;
  final characters = <int>[];
  while (remaining > 0) {
    remaining -= 1;
    characters.add(65 + remaining % 26);
    remaining ~/= 26;
  }
  return String.fromCharCodes(characters.reversed);
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

const _xlsxContentTypes =
    '<Types xmlns="http://schemas.openxmlformats.org/'
    'package/2006/content-types"><Default Extension="rels" '
    'ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.'
    'openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/'
    'vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.'
    'openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>';

const _xlsxRootRelationships =
    '<Relationships xmlns="http://schemas.'
    'openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" '
    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'officeDocument" Target="xl/workbook.xml"/></Relationships>';

const _xlsxWorkbook =
    '<workbook xmlns="http://schemas.openxmlformats.org/'
    'spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/'
    'officeDocument/2006/relationships"><workbookPr date1904="0"/>'
    '<bookViews><workbookView activeTab="0"/></bookViews><sheets>'
    '<sheet name="Glucose data" sheetId="1" r:id="rId1"/></sheets>'
    '</workbook>';

const _xlsxWorkbookRelationships =
    '<Relationships xmlns="http://schemas.'
    'openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" '
    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" '
    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
    'styles" Target="styles.xml"/></Relationships>';

const _xlsxStyles =
    '<styleSheet xmlns="http://schemas.openxmlformats.org/'
    'spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" '
    'formatCode="0.0##"/><numFmt numFmtId="165" formatCode="0.000"/>'
    '</numFmts><fonts count="2"><font><sz val="11"/><color rgb="FF1F2927"/>'
    '<name val="Aptos"/><family val="2"/></font><font><b/><sz val="11"/>'
    '<color rgb="FFFFFFFF"/><name val="Aptos"/><family val="2"/></font>'
    '</fonts><fills count="3"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill><fill><patternFill '
    'patternType="solid"><fgColor rgb="FF0B6E69"/><bgColor indexed="64"/>'
    '</patternFill></fill></fills><borders count="2"><border><left/><right/>'
    '<top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom '
    'style="thin"><color rgb="FF084C49"/></bottom><diagonal/></border>'
    '</borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" '
    'fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf '
    'numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf '
    'numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" '
    'applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">'
    '<alignment horizontal="center" vertical="center" wrapText="1"/></xf>'
    '<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" '
    'applyNumberFormat="1" applyAlignment="1"><alignment horizontal="right"/>'
    '</xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" '
    'applyNumberFormat="1" applyAlignment="1"><alignment horizontal="right"/>'
    '</xf><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" '
    'applyNumberFormat="1" applyAlignment="1"><alignment horizontal="right"/>'
    '</xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" '
    'builtinId="0"/></cellStyles><dxfs count="0"/><tableStyles count="0" '
    'defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>'
    '</styleSheet>';
