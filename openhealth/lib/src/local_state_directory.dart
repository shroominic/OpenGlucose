import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef LocalStateDirectoryProvider = Future<Directory> Function();

/// Resolves persistent local application state without using Windows roaming
/// AppData for restricted sensor and health records.
///
/// `path_provider` maps its Windows application-support directory to roaming
/// AppData. Its cache-directory provider maps to the application's stable
/// LocalAppData directory. OpenGlucose uses that location as persistent state,
/// creates dedicated non-cache subdirectories below it, and never includes
/// those subdirectories in cache cleanup.
Future<Directory> resolveLocalStateBaseDirectory({
  bool? isWindows,
  LocalStateDirectoryProvider? localAppDataProvider,
  LocalStateDirectoryProvider? applicationSupportProvider,
}) {
  final useLocalAppData = isWindows ?? Platform.isWindows;
  if (useLocalAppData) {
    return (localAppDataProvider ?? getApplicationCacheDirectory)();
  }
  return (applicationSupportProvider ?? getApplicationSupportDirectory)();
}
