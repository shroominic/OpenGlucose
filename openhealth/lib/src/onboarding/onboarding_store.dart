import 'package:cgm_core/cgm_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Default in-range band, matching the dashboard chart band (70–180 mg/dL).
  static const double defaultTargetLowMgdl = 70;
  static const double defaultTargetHighMgdl = 180;

  /// Whether the user has already seen (completed or skipped) onboarding.
  bool get isCompleted => _preferences.getBool(_completedKey) ?? false;

  double get targetLowMgdl =>
      _preferences.getDouble(_targetLowKey) ?? defaultTargetLowMgdl;

  double get targetHighMgdl =>
      _preferences.getDouble(_targetHighKey) ?? defaultTargetHighMgdl;

  /// Marks onboarding as done. Optionally records the chosen target range
  /// (in mg/dL); when omitted the existing/default range is left intact.
  Future<void> complete({
    double? targetLowMgdl,
    double? targetHighMgdl,
  }) async {
    if (targetLowMgdl != null) {
      await _preferences.setDouble(_targetLowKey, targetLowMgdl);
    }
    if (targetHighMgdl != null) {
      await _preferences.setDouble(_targetHighKey, targetHighMgdl);
    }
    await _preferences.setBool(_completedKey, true);
  }

  /// Test/debug helper: clears persisted onboarding state.
  Future<void> reset() async {
    await _preferences.remove(_completedKey);
    await _preferences.remove(_targetLowKey);
    await _preferences.remove(_targetHighKey);
  }
}
