import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../display_preferences.dart';

/// Persists first-run onboarding state in [SharedPreferences].
///
/// Self-contained: it owns its own preference keys and does not touch
/// `DisplayPreferences` or any dashboard state. The chosen target glucose
/// range is stored in mg/dL (canonical) so it is unit-agnostic; callers
/// convert for display via [GlucoseUnit.convertFromMgdl].
class OnboardingStore {
  const OnboardingStore(this._preferences);

  final SharedPreferences _preferences;

  static const _completedKey = 'openHealth.onboarding.completed';
  static const _targetLowKey = 'openHealth.onboarding.targetLowMgdl';
  static const _targetHighKey = 'openHealth.onboarding.targetHighMgdl';
  static const _displayPreferencesKey = 'openHealth.displayPreferences';

  /// Default in-range band, matching the dashboard chart band (70–180 mg/dL).
  static const double defaultTargetLowMgdl = 70;
  static const double defaultTargetHighMgdl = 180;

  /// Whether the user has already seen (completed or skipped) onboarding.
  bool get isCompleted => _preferences.getBool(_completedKey) ?? false;

  double get targetLowMgdl =>
      _loadDisplayPreferences()?.targetLowMgdl ??
      _preferences.getDouble(_targetLowKey) ??
      defaultTargetLowMgdl;

  double get targetHighMgdl =>
      _loadDisplayPreferences()?.targetHighMgdl ??
      _preferences.getDouble(_targetHighKey) ??
      defaultTargetHighMgdl;

  /// Marks onboarding as done. Optionally records the chosen target range
  /// (in mg/dL); when omitted the existing/default range is left intact.
  Future<void> complete({double? targetLowMgdl, double? targetHighMgdl}) async {
    if (targetLowMgdl != null || targetHighMgdl != null) {
      final current = _loadDisplayPreferences() ?? const DisplayPreferences();
      final low = targetLowMgdl ?? current.targetLowMgdl;
      final high = targetHighMgdl ?? current.targetHighMgdl;
      if (!low.isFinite || !high.isFinite || low <= 0 || high <= low) {
        throw ArgumentError('Target range must be finite and increasing.');
      }
      await _preferences.setString(
        _displayPreferencesKey,
        jsonEncode(
          current.copyWith(targetLowMgdl: low, targetHighMgdl: high).toJson(),
        ),
      );
      // Remove the legacy duplicate keys after migrating them into the single
      // display-preferences source of truth.
      await _preferences.remove(_targetLowKey);
      await _preferences.remove(_targetHighKey);
    }
    await _preferences.setBool(_completedKey, true);
  }

  /// Test/debug helper: clears persisted onboarding state.
  Future<void> reset() async {
    await _preferences.remove(_completedKey);
    await _preferences.remove(_targetLowKey);
    await _preferences.remove(_targetHighKey);
  }

  DisplayPreferences? _loadDisplayPreferences() {
    final raw = _preferences.getString(_displayPreferencesKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return DisplayPreferences.fromJson(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}
