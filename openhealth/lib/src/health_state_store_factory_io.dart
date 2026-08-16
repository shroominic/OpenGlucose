import 'package:shared_preferences/shared_preferences.dart';

import 'health_state_store.dart';
import 'health_state_store_io.dart';
import 'local_state_directory.dart';

HealthStateStore createHealthStateStore(SharedPreferences legacyPreferences) {
  return FileHealthStateStore(
    legacyPreferences: legacyPreferences,
    directoryProvider: resolveLocalStateBaseDirectory,
  );
}
