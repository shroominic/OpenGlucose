// SPDX-License-Identifier: GPL-3.0-only
// Turns one captured device-run log into a durable side-by-side decode.
//
// The log already holds every plaintext frame the sensor pushed during the
// session, so the comparison below is a replay of the *same* window both paths
// saw: the payload word the app's live path renders, and the processed field the
// evidence path used to report. Nothing here reads a sensor or writes a frame.
//
//   dart run tool/replay_gs1_decode.dart --log <file> --out <dir> \
//     [--source "<command that produced the log>"]
import 'dart:convert';
import 'dart:io';

import 'package:cgm_cbio/cgm_cbio.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final logPath = options['log'];
  final outputDirectory = options['out'];
  if (logPath == null || outputDirectory == null) {
    stderr.writeln(
      'usage: replay_gs1_decode --log <file> --out <directory> '
      '[--source <description>]',
    );
    exitCode = 64;
    return;
  }
  final log = File(logPath);
  if (!log.existsSync()) {
    stderr.writeln('error: log not found: $logPath');
    exitCode = 2;
    return;
  }

  final captured = parseCbioHarnessLog(log.readAsStringSync());
  if (captured.plaintextFrames.isEmpty) {
    stderr.writeln('error: no plaintext frame in $logPath');
    exitCode = 2;
    return;
  }
  final comparison = compareCbioDecode(captured.plaintextFrames);
  final appPath = CbioHistoryArchive();
  captured.plaintextFrames.forEach(appPath.ingest);
  final agreement = compareCbioWithArchive(comparison, appPath.records);
  final artifact = <String, Object?>{
    ...comparison.toJson(),
    'source': <String, Object?>{
      'harness': captured.harness,
      'harnessRevision': captured.harnessRevision,
      'appPackage': captured.appPackage,
      'plaintextFrames': captured.plaintextFrames.length,
      'reproducedBy':
          options['source'] ?? 'dart run tool/replay_gs1_decode.dart',
    },
    'arithmetic': _arithmetic(comparison),
    'hourlyShape': _hourlyShape(comparison),
    'appPathComparison': <String, Object?>{
      'decoder': 'CbioHistoryArchive',
      'field': 'payload',
      ...agreement.toJson(),
    },
  };

  final directory = Directory(outputDirectory)..createSync(recursive: true);
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .split('.')
      .first;
  final file = File('${directory.path}/gs1-decode-comparison-$stamp.json');
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(artifact)}\n',
  );

  stdout.writeln('wrote ${file.path}');
  stdout.writeln(
    'records=${comparison.recordCount} '
    'payload=${comparison.payloadMinimum}..${comparison.payloadMaximum} '
    'nonZero=${comparison.payloadNonZero} '
    'processed=${comparison.processedMinimum}..${comparison.processedMaximum} '
    'nonZero=${comparison.processedNonZero} fieldsAgree=${comparison.agrees}',
  );
  stdout.writeln(
    'appPath agreeing=${agreement.agreeing}/${agreement.compared} '
    'missing=${agreement.missing} disagreeing=${agreement.disagreeing} '
    'agrees=${agreement.agrees}',
  );
}

/// The byte arithmetic for the first decoded record, as printed evidence.
Map<String, Object?> _arithmetic(CbioDecodeComparison comparison) {
  if (comparison.records.isEmpty) return <String, Object?>{};
  final record = comparison.records.first;
  final payload = record.payloadRaw;
  final processed = record.processedRaw;
  return <String, Object?>{
    'recordIndex': record.index,
    'payloadSpan': record.payloadSpan,
    'payloadRaw': payload,
    'payloadRule': 'LE16(payloadSpan)',
    'processedSpan': record.processedSpan,
    'processedRaw': processed,
    'processedRule': '(processedRaw >> 6) & 0x3ff',
    'processedPacked': record.processedPacked,
    'temperatureRaw': record.temperatureRaw,
    'note':
        'a zero packed field is zero bytes, not a shifted offset: the '
        'record stride is confirmed by the temperature word',
  };
}

/// Median/min/max of the payload word per captured hour.
///
/// The session wrote the sensor clock once, so the bucket label is the captured
/// raw time read as UTC; it is a shape check, not a timestamp claim.
List<Map<String, Object?>> _hourlyShape(CbioDecodeComparison comparison) {
  final buckets = <int, List<CbioDecodeComparisonRecord>>{};
  for (final record in comparison.records) {
    buckets.putIfAbsent(record.rawTime ~/ 3600, () => []).add(record);
  }
  final starts = buckets.keys.toList()..sort();
  return [for (final start in starts) _bucket(start, buckets[start]!)];
}

Map<String, Object?> _bucket(
  int hourStart,
  List<CbioDecodeComparisonRecord> records,
) {
  final values = [for (final record in records) record.payloadRaw]..sort();
  return <String, Object?>{
    'rawHour': hourStart,
    'startsAtUtc': DateTime.fromMillisecondsSinceEpoch(
      hourStart * 3600 * 1000,
      isUtc: true,
    ).toIso8601String(),
    'count': values.length,
    'payloadMinimum': values.first,
    'payloadMedian': values[values.length ~/ 2],
    'payloadMaximum': values.last,
    'payloadTenthsUnverified': values[values.length ~/ 2] / 10,
  };
}

Map<String, String?> _parseArguments(List<String> arguments) {
  final options = <String, String?>{};
  for (var index = 0; index < arguments.length; index += 1) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) continue;
    final name = argument.substring(2);
    if (index + 1 < arguments.length &&
        !arguments[index + 1].startsWith('--')) {
      options[name] = arguments[index + 1];
      index += 1;
    }
  }
  return options;
}
