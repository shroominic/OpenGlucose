// SPDX-License-Identifier: GPL-3.0-only
//
// The private bench reads its inputs only through the audited Darwin descriptor
// path, so every host without that path must refuse the run before it parses or
// prints anything. `private_bench_test.dart` holds the Darwin-side assertions;
// this file holds the contract the other hosts get.
@TestOn('!mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/analyze_private_bench.dart';

void main() {
  late Directory temp;
  late File calibration;
  late File trace;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('libre-private-bench-host-');
    calibration = File('${temp.path}/calibration.json')
      ..writeAsStringSync('{}');
    trace = File('${temp.path}/ble.jsonl')..writeAsStringSync('');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('analysis fails closed without the audited descriptor path', () async {
    final result = await runPrivateBenchAnalysis([
      '--calibration',
      calibration.absolute.path,
      '--ble',
      trace.absolute.path,
    ]);

    expect(result.$1, 66);
    expect(jsonDecode(result.$2), <String, Object?>{
      'analyzed': false,
      'error': 'unsupported_platform',
    });
  });

  test('the CLI stays to one redacted JSON line and an empty stderr', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/analyze_private_bench.dart',
      '--calibration',
      calibration.absolute.path,
      '--ble',
      trace.absolute.path,
    ]);

    expect(result.exitCode, 66, reason: result.stderr as String);
    expect(result.stderr, isEmpty);
    expect(const LineSplitter().convert(result.stdout as String), hasLength(1));
    expect(jsonDecode(result.stdout as String), <String, Object?>{
      'analyzed': false,
      'error': 'unsupported_platform',
    });
  });
}
