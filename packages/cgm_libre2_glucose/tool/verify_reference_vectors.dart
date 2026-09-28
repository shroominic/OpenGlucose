// SPDX-License-Identifier: GPL-3.0-only
// Re-execute the pinned, preserved Swift factory method and exact tables.
// This is a host-only test oracle; the production decoder does not run Swift.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final source = File(
    'test/reference/LibreMeasurement.swift',
  ).readAsStringSync();
  final method = RegExp(
    r'func glucoseValueFromRaw\(libreCalibrationInfo: LibreCalibrationInfo\) -> Double \{[\s\S]*?\n    \}',
  ).firstMatch(source)!.group(0)!;
  final tables = source.substring(source.indexOf('fileprivate let t1 = ['));
  final swift =
      '''
import Foundation
struct LibreCalibrationInfo { let i2: Int; let i3: Double; let i4: Double; let i6: Double }
struct Reference {
 let rawGlucose: Int; let rawTemperature: Int; let rawTemperatureAdjustment: Int
 $method
}
$tables
var rows = [[Int]]()
for i in 1...1023 {
 let raw = 1000 + i % 700
 let temp = 6000 + (i % 100) * 4
 let adjustment = (i % 31) * 4 * (i % 2 == 0 ? -1 : 1)
 let offset = i % 2 == 0 ? -20 : 20
 let scale = 500 + i % 1000
 let reference = 10000 + (i % 1000) * 4
 let c = LibreCalibrationInfo(i2: i, i3: Double(offset), i4: Double(scale), i6: Double(reference))
 let m = Reference(rawGlucose: raw, rawTemperature: temp, rawTemperatureAdjustment: adjustment)
 let result = m.glucoseValueFromRaw(libreCalibrationInfo: c)
 rows.append([i, offset, scale, reference, raw, temp, adjustment, Int(round(result))])
}
let data = try JSONSerialization.data(withJSONObject: rows)
print(String(data:data, encoding:.utf8)!)
''';
  final process = await Process.start('swift', ['-']);
  process.stdin.write(swift);
  await process.stdin.close();
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  if (await process.exitCode != 0) {
    stderr.write(await errors);
    exitCode = 1;
    return;
  }
  final value = jsonDecode(await output);
  if (args.contains('--print')) {
    stdout.writeln(jsonEncode(value));
    return;
  }
  final expected = jsonDecode(
    File('test/reference/factory_vectors.json').readAsStringSync(),
  );
  if (jsonEncode(value) != jsonEncode(expected)) {
    stderr.writeln('Pinned Swift oracle differs from synthetic vectors.');
    exitCode = 1;
    return;
  }
  stdout.writeln('All 1023 synthetic factory vectors match pinned Swift.');
}
