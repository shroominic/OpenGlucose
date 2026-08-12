import 'package:shared_preferences/shared_preferences.dart';

import 'health_state_store.dart';

HealthStateStore createHealthStateStore(SharedPreferences legacyPreferences) {
  return PreferencesHealthStateStore(legacyPreferences);
}
