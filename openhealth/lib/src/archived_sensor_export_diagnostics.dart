import 'package:flutter/services.dart';

/// Privacy-safe stages for one archived-sensor export attempt.
enum ArchivedSensorExportStage {
  preparing('P01'),
  storing('P02'),
  sharing('P03'),
  cleanup('P04')
  ;

  const ArchivedSensorExportStage(this.phase);

  final String phase;
}

/// Returns an identifier-free code suitable for UI and diagnostic logs.
///
/// Exception messages are deliberately excluded because file-system and
/// platform errors can contain private cache paths or attachment names.
String archivedSensorExportSupportCode({
  required ArchivedSensorExportStage stage,
  required Object error,
}) {
  final kind = switch (error) {
    PlatformException() => 'platform',
    ArgumentError() => 'invalidrequest',
    StateError() => 'state',
    _ => _safeDiagnosticToken(error.runtimeType.toString()),
  };
  final code = switch (error) {
    PlatformException(:final code) => _safePlatformCode(code),
    ArgumentError() => 'argument',
    StateError() => 'state',
    _ => 'unexpected',
  };
  return 'OGEXP1 phase=${stage.phase} op=export kind=$kind code=$code';
}

String _safePlatformCode(String value) {
  final token = _safeDiagnosticToken(value);
  return switch (token) {
    'export_share_failed' || 'channel-error' => token,
    _ => 'unexpected',
  };
}

String _safeDiagnosticToken(String value) {
  final normalized = value
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.isEmpty) {
    return 'unknown';
  }
  return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
}
