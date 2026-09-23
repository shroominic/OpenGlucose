// SPDX-License-Identifier: GPL-3.0-only
/// Reads a captured GS1 harness log back into plaintext frames and identity.
///
/// The device harness prints one line per FF31 notification with the masked
/// bytes and the unmasked plaintext. Only the plaintext is retained: the masked
/// form carries the vendor stream key and a captured address, so this parser
/// deliberately drops it. That makes a replayed decode reproducible from a log
/// without the radio and without spreading credential-shaped bytes.
library;

import 'dart:convert';

/// One captured harness log.
final class CbioCapturedLog {
  const CbioCapturedLog({
    required this.plaintextFrames,
    required this.harness,
    required this.harnessRevision,
    required this.appPackage,
  });

  /// Plaintext frames in arrival order, oldest first.
  final List<List<int>> plaintextFrames;

  /// Repository-relative harness path from the evidence line.
  final String harness;

  /// Harness revision from the evidence line, or `unknown`.
  final String harnessRevision;

  /// App package from the evidence line, or `unknown`.
  final String appPackage;
}

final RegExp _plaintextPattern = RegExp(r'plaintext=((?:[0-9a-f]{2} ?)+)');
final RegExp _evidencePattern = RegExp(r'CBIO-EVIDENCE (\{.*\})\s*$');
final RegExp _identityValue = RegExp(r'"[a-zA-Z]+"\s*:\s*"([^"]*)"');

/// Parses one captured harness log. Missing identity fields stay `unknown`.
CbioCapturedLog parseCbioHarnessLog(String contents) {
  final frames = <List<int>>[];
  var harness = 'unknown';
  var revision = 'unknown';
  var appPackage = 'unknown';
  for (final line in const LineSplitter().convert(contents)) {
    final plaintext = _plaintextPattern.firstMatch(line);
    if (plaintext != null) {
      frames.add([
        for (final byte in plaintext.group(1)!.trim().split(' '))
          int.parse(byte, radix: 16),
      ]);
    }
    final evidence = _evidencePattern.firstMatch(line);
    if (evidence == null) continue;
    final fields = _identityValue.allMatches(evidence.group(1)!);
    for (final field in fields) {
      final key = field.group(0)!;
      final value = field.group(1)!;
      if (key.contains('harness') && !key.contains('Revision')) {
        harness = value;
      } else if (key.contains('harnessRevision')) {
        revision = value;
      } else if (key.contains('appPackage')) {
        appPackage = value;
      }
    }
  }
  return CbioCapturedLog(
    plaintextFrames: frames,
    harness: harness,
    harnessRevision: revision,
    appPackage: appPackage,
  );
}
