import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_settings.dart';

/// Persists AI settings: non-secret config in [SharedPreferences], and the
/// BYO API key in the platform secure store (Keychain / Keystore) via
/// [FlutterSecureStorage].
///
/// The key is NEVER written to SharedPreferences or logged. The UI shows only
/// whether a key is set, not the key itself.
class AiSettingsStore {
  AiSettingsStore({
    required SharedPreferences preferences,
    FlutterSecureStorage? secureStorage,
  }) : _preferences = preferences,
       _secure = secureStorage ?? const FlutterSecureStorage();

  static const _settingsKey = 'openHealth.ai.settings';
  static const _apiKeyKey = 'openHealth.ai.apiKey';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secure;

  /// Loads the non-secret settings (defaults if absent/corrupt).
  AiSettings loadSettings() =>
      AiSettings.decode(_preferences.getString(_settingsKey));

  /// Persists the non-secret settings.
  Future<void> saveSettings(AiSettings settings) =>
      _preferences.setString(_settingsKey, settings.encode());

  /// Reads the stored API key from secure storage, or `null` if unset.
  Future<String?> readApiKey() => _secure.read(key: _apiKeyKey);

  /// Whether a non-empty API key is present, without exposing it.
  Future<bool> hasApiKey() async {
    final key = await readApiKey();
    return key != null && key.trim().isNotEmpty;
  }

  /// Stores (or, when [key] is empty, deletes) the API key in secure storage.
  Future<void> writeApiKey(String key) async {
    if (key.trim().isEmpty) {
      await _secure.delete(key: _apiKeyKey);
    } else {
      await _secure.write(key: _apiKeyKey, value: key.trim());
    }
  }

  /// Removes the stored API key.
  Future<void> deleteApiKey() => _secure.delete(key: _apiKeyKey);
}
