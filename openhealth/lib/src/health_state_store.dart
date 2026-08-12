import 'package:shared_preferences/shared_preferences.dart';

/// Minimal key/value store for restricted sensor identity and glucose history.
abstract interface class HealthStateStore {
  Future<void> initialize();

  String? getString(String key);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);
}

/// Preference-backed implementation for web and deterministic tests.
///
/// Native production builds use the backup-excluded file implementation from
/// [createHealthStateStore].
class PreferencesHealthStateStore implements HealthStateStore {
  PreferencesHealthStateStore(this._preferences);

  final SharedPreferences _preferences;

  @override
  Future<void> initialize() async {}

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    final stored = await _preferences.setString(key, value);
    if (!stored) {
      throw StateError('Could not persist restricted health state.');
    }
  }

  @override
  Future<void> remove(String key) async {
    final removed = await _preferences.remove(key);
    if (!removed && _preferences.containsKey(key)) {
      throw StateError('Could not remove restricted health state.');
    }
  }
}
