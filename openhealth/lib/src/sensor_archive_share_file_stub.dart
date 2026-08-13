/// Web keeps generated CSV bytes in memory and lets the browser share or
/// download them without creating an app-owned temporary file.
Future<String?> prepareArchivedSensorShareFile({
  required String filename,
  required String contents,
  String? temporaryDirectoryPath,
}) => Future<String?>.value();

Future<void> disposeArchivedSensorShareFile(String? path) =>
    Future<void>.value();

Future<void> clearStaleArchivedSensorShareFiles({
  String? temporaryDirectoryPath,
}) => Future<void>.value();
