import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final _legacySensorExportFileName = RegExp(
  '^openhealth_[A-Za-z0-9_-]+_[0-9]{8}-[0-9]{4}'
  r'(?:-(?:[2-9]|[1-9][0-9]+))?\.csv$',
);

/// Writes one native share payload into its own temporary directory.
///
/// The caller must invoke [disposeArchivedSensorShareFile] after the platform
/// share sheet completes so private glucose history does not linger in cache.
Future<String?> prepareArchivedSensorShareFile({
  required String filename,
  required String contents,
  String? temporaryDirectoryPath,
}) => prepareArchivedSensorShareFileBytes(
  filename: filename,
  bytes: utf8.encode(contents),
  temporaryDirectoryPath: temporaryDirectoryPath,
);

/// Writes one binary native share payload into its own temporary directory.
///
/// This is used for XLSX as well as the UTF-8 CSV and text formats so every
/// export reaches the platform as one real file with the requested extension.
Future<String?> prepareArchivedSensorShareFileBytes({
  required String filename,
  required List<int> bytes,
  String? temporaryDirectoryPath,
}) async {
  final temporaryDirectory = temporaryDirectoryPath == null
      ? await getTemporaryDirectory()
      : Directory(temporaryDirectoryPath);
  final exportDirectory = await temporaryDirectory.createTemp(
    'openglucose-export-',
  );
  final file = File(path.join(exportDirectory.path, filename));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Best-effort cleanup of the scoped directory created for one share action.
Future<void> disposeArchivedSensorShareFile(String? filePath) async {
  if (filePath == null) {
    return;
  }
  final file = File(filePath);
  try {
    await file.delete();
  } on FileSystemException {
    // The share target or OS may already have removed the temporary payload.
  }
  final directory = file.parent;
  if (!path.basename(directory.path).startsWith('openglucose-export-')) {
    return;
  }
  try {
    await directory.delete();
  } on FileSystemException {
    // Cleanup is best effort; never hide a successfully completed export.
  }
}

/// Removes stale OpenGlucose and share_plus payloads left in temporary storage.
///
/// Android's native share intent needs its private FileProvider copy after the
/// chooser returns, so that copy cannot safely be deleted immediately. The
/// next app launch is the earliest reliable cleanup boundary. The exact legacy
/// `openhealth_<sensor-id>_<timestamp>.csv` shape is also removed because old
/// app versions wrote identifier-bearing exports directly into this directory.
Future<void> clearStaleArchivedSensorShareFiles({
  String? temporaryDirectoryPath,
}) async {
  final temporaryDirectory = temporaryDirectoryPath == null
      ? await getTemporaryDirectory()
      : Directory(temporaryDirectoryPath);
  List<FileSystemEntity> entries;
  try {
    entries = await temporaryDirectory.list().toList();
  } on FileSystemException {
    return;
  }
  for (final entry in entries) {
    final name = path.basename(entry.path);
    final isKnownDirectory =
        entry is Directory &&
        (name == 'share_plus' || name.startsWith('openglucose-export-'));
    final isLegacySensorExport =
        entry is File && _legacySensorExportFileName.hasMatch(name);
    if (!isKnownDirectory && !isLegacySensorExport) {
      continue;
    }
    try {
      await entry.delete(recursive: true);
    } on FileSystemException {
      // Cleanup is best effort and scoped to known share payload directories.
    }
  }
}
