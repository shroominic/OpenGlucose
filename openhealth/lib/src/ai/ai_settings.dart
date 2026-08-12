import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';

/// Non-secret AI configuration persisted in SharedPreferences.
///
/// The API key is deliberately NOT part of this model — it lives only in
/// secure storage. This object is safe to serialize to
/// plain preferences because it contains no secret.
class AiSettings {
  const AiSettings({
    this.enabled = false,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.authScheme = AiAuthScheme.bearer,
  });

  /// Whether the user opted into AI insights (BYO-key). Off by default.
  final bool enabled;

  /// OpenAI/Anthropic-compatible base URL.
  final String baseUrl;

  /// Model identifier.
  final String model;

  /// How the key is attached to requests.
  final AiAuthScheme authScheme;

  AiSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? model,
    AiAuthScheme? authScheme,
  }) {
    return AiSettings(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      authScheme: authScheme ?? this.authScheme,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'baseUrl': baseUrl,
    'model': model,
    'authScheme': authScheme.name,
  };

  String encode() => jsonEncode(toJson());

  factory AiSettings.fromJson(Map<String, Object?> json) {
    final scheme = AiAuthScheme.values.firstWhere(
      (value) => value.name == json['authScheme'],
      orElse: () => AiAuthScheme.bearer,
    );
    return AiSettings(
      enabled: json['enabled'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String? ?? 'https://api.openai.com/v1',
      model: json['model'] as String? ?? 'gpt-4o-mini',
      authScheme: scheme,
    );
  }

  factory AiSettings.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const AiSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return AiSettings.fromJson(decoded);
    } catch (_) {
      // Fall through to defaults on any corruption.
    }
    return const AiSettings();
  }
}
