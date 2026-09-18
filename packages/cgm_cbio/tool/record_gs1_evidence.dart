// SPDX-License-Identifier: GPL-3.0-only
// Turns one device-run log into a durable, redacted GS1 evidence artifact.
//
// The assertion-bearing harnesses print a single `CBIO-EVIDENCE <json>` line
// per run. This tool extracts that line, validates it against the schema and
// the redaction rules, and writes it to the evidence directory. It never reads
// a sensor, never talks to a device, and never writes a field the model does not
// already carry.
//
//   dart run tool/record_gs1_evidence.dart --log <file> --out <dir> \
//     [--source "<command that produced the log>"]
import 'dart:convert';
import 'dart:io';

import 'package:cgm_cbio/cgm_cbio.dart';

const String _evidencePrefix = 'CBIO-EVIDENCE ';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final logPath = options['log'];
  final outputDirectory = options['out'];
  if (logPath == null || outputDirectory == null) {
    stderr.writeln(
      'usage: record_gs1_evidence --log <file> --out <directory> '
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

  final payloads = <String>[
    for (final line in const LineSplitter().convert(log.readAsStringSync()))
      if (line.startsWith(_evidencePrefix))
        line.substring(_evidencePrefix.length),
  ];
  if (payloads.isEmpty) {
    stderr.writeln(
      'error: no $_evidencePrefix line in $logPath; the harness did not '
      'reach a verdict',
    );
    exitCode = 2;
    return;
  }
  if (payloads.length > 1) {
    stderr.writeln(
      'note: ${payloads.length} evidence lines found; recording the last one',
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(payloads.last);
  } on FormatException catch (error) {
    stderr.writeln('error: evidence line is not JSON: ${error.message}');
    exitCode = 3;
    return;
  }

  final violations = cbioSessionEvidenceArtifactViolations(decoded);
  if (violations.isNotEmpty) {
    stderr.writeln('error: evidence artifact rejected:');
    for (final violation in violations) {
      stderr.writeln('  - $violation');
    }
    exitCode = 4;
    return;
  }

  final directory = Directory(outputDirectory)..createSync(recursive: true);
  final artifact = decoded! as Map<String, Object?>;
  final identity = artifact['identity']! as Map;
  final harness = '${identity['harness']}';
  final slug = harness
      .split('/')
      .last
      .replaceAll(RegExp(r'\.dart$'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '-');
  final capturedAt = DateTime.now().toUtc();
  final stamp = capturedAt
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .split('.')
      .first;
  final file = _uniqueFile(directory, 'gs1-session-$stamp-$slug');
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(artifact)}\n',
  );

  final records = artifact['records']! as Map;
  final writes = artifact['writes']! as Map;
  final errors = artifact['errors']! as Map;
  final index = File('${directory.path}/INDEX.md');
  final header = index.existsSync()
      ? ''
      : '# GS1 device evidence\n\n'
            'Artifacts written by `make cbio-gs1-evidence`. Each file records one\n'
            'assertion-bearing device session: outcome, write counts, record\n'
            'counts and ranges, timing, closed error taxonomy, and app/harness\n'
            'identity. Units stay unverified; no artifact carries a sensor\n'
            'address or credential material.\n\n'
            '| captured (UTC) | harness | outcome | records | errors | file |\n'
            '|---|---|---|---|---|---|\n';
  index.writeAsStringSync(
    '$header'
    '| ${capturedAt.toIso8601String()} | `$harness` | '
    '`${artifact['outcome']}` | glucose ${(records['glucose']! as Map)['count']}, '
    'raw ${(records['raw']! as Map)['count']} | '
    '${errors.isEmpty ? 'none' : errors.keys.join(', ')} | '
    '`${file.uri.pathSegments.last}` |\n',
    mode: FileMode.append,
  );

  stdout.writeln('wrote ${file.path}');
  stdout.writeln(
    'outcome=${artifact['outcome']} writes=${writes.values.fold<int>(0, (a, b) => a + (b as int))} '
    'notifications=${artifact['notifications']} '
    'glucose=${(records['glucose']! as Map)['count']} '
    'raw=${(records['raw']! as Map)['count']} '
    'errors=${errors.isEmpty ? 'none' : errors.keys.join(',')} '
    'unit=${artifact['unitStatus']}',
  );
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
    } else {
      options[name] = null;
    }
  }
  return options;
}

/// Two sessions can finish inside the same second; never overwrite evidence.
File _uniqueFile(Directory directory, String stem) {
  var candidate = File('${directory.path}/$stem.json');
  var suffix = 1;
  while (candidate.existsSync()) {
    candidate = File('${directory.path}/$stem-$suffix.json');
    suffix += 1;
  }
  return candidate;
}
