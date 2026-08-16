import 'package:shared_preferences/shared_preferences.dart';

/// Minimal key/value store for restricted sensor identity and glucose history.
///
/// Implementations may store different key families independently. Callers
/// must therefore treat a completed mutation as the durability boundary and
/// must not depend on unrelated keys being rewritten in the same transaction.
abstract interface class HealthStateStore {
  Future<void> initialize();

  String? getString(String key);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);
}

/// Preference-backed implementation for web and deterministic tests.
///
/// Native production builds use the platform-local, per-history-blob file
/// implementation selected by `createHealthStateStore`. Supported mobile
/// builds also apply their platform backup-exclusion controls.
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
