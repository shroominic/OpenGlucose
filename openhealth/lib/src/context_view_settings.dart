import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'context_bridge/context_bridge.dart';

/// Persisted, local controls for the optional context reader surface.
///
/// The default state is deliberately quiet: no context view and no observed
/// rise suggestion. A caller must set a positive, visible local observation
/// threshold before [suggestionPolicy] can enable a suggestion.
class ContextViewSettings extends ChangeNotifier {
  ContextViewSettings(SharedPreferences preferences)
    : _preferences = preferences,
      _showContextView = preferences.getBool(_showContextViewKey) ?? false,
      _suggestRecentRise = preferences.getBool(_suggestRecentRiseKey) ?? false,
      _observedRiseThresholdMgdl = preferences.getDouble(
        _observedRiseThresholdMgdlKey,
      );

  static const String _showContextViewKey =
      'openGlucose.contextView.showContextView';
  static const String _suggestRecentRiseKey =
      'openGlucose.contextView.suggestRecentRise';
  static const String _observedRiseThresholdMgdlKey =
      'openGlucose.contextView.observedRiseThresholdMgdl';

  static const String nonClinicalDisclosure =
      'A recent observed glucose rise does not identify its cause and is not medical advice.';

  final SharedPreferences _preferences;

  bool _showContextView;
  bool _suggestRecentRise;
  double? _observedRiseThresholdMgdl;
  Future<void> _writeTail = Future<void>.value();

  bool get showContextView => _showContextView;
  bool get suggestRecentRise => _suggestRecentRise;
  double? get observedRiseThresholdMgdl => _observedRiseThresholdMgdl;

  /// A threshold is valid only when it is explicit, finite, and positive.
  ///
  /// This is not a clinical range, a treatment target, or an interpretation.
  bool get hasValidObservedRiseThreshold {
    final value = _observedRiseThresholdMgdl;
    return value != null && value.isFinite && value > 0;
  }

  /// The only policy supplied to the local bridge.
  ///
  /// An invalid/missing threshold fails closed even if an old preferences value
  /// had the suggestion switch enabled.
  ContextBridgeSuggestionPolicy get suggestionPolicy {
    final threshold = _observedRiseThresholdMgdl;
    if (!_suggestRecentRise ||
        threshold == null ||
        !threshold.isFinite ||
        threshold <= 0) {
      return const ContextBridgeSuggestionPolicy.disabled();
    }
    return ContextBridgeSuggestionPolicy.nonClinicalObservedRise(
      recentRisePolicy: RecentObservedRisePolicy(minimumRiseMgdl: threshold),
      disclosure: nonClinicalDisclosure,
    );
  }

  Future<void> setShowContextView({required bool value}) {
    if (_showContextView == value) return Future<void>.value();
    _showContextView = value;
    notifyListeners();
    return _enqueueWrite(
      () => _preferences.setBool(_showContextViewKey, value),
    );
  }

  /// Returns false and leaves the setting off if there is no explicit local
  /// observation threshold. This prevents an accidental hidden default.
  Future<bool> setSuggestRecentRise({required bool value}) async {
    if (value && !hasValidObservedRiseThreshold) return false;
    if (_suggestRecentRise == value) return true;
    _suggestRecentRise = value;
    notifyListeners();
    await _enqueueWrite(
      () => _preferences.setBool(_suggestRecentRiseKey, value),
    );
    return true;
  }

  /// Saves a user-entered threshold. Blank, invalid, and non-positive input
  /// clears the value and also turns suggestions off.
  Future<void> setObservedRiseThresholdText(String value) {
    final normalized = value.trim().replaceAll(',', '.');
    final parsed = double.tryParse(normalized);
    final next = parsed != null && parsed.isFinite && parsed > 0
        ? parsed
        : null;
    final thresholdChanged = _observedRiseThresholdMgdl != next;
    final disableSuggestions = next == null && _suggestRecentRise;
    if (!thresholdChanged && !disableSuggestions) return Future<void>.value();
    _observedRiseThresholdMgdl = next;
    if (disableSuggestions) _suggestRecentRise = false;
    notifyListeners();
    return _enqueueWrite(() async {
      if (next == null) {
        await _preferences.remove(_observedRiseThresholdMgdlKey);
      } else {
        await _preferences.setDouble(_observedRiseThresholdMgdlKey, next);
      }
      if (disableSuggestions) {
        await _preferences.setBool(_suggestRecentRiseKey, false);
      }
    });
  }

  Future<void> _enqueueWrite(FutureOr<void> Function() operation) {
    final scheduled = _writeTail.then((_) async {
      await operation();
    });
    _writeTail = scheduled.catchError((Object _) {});
    return scheduled;
  }
}

/// Exposes [ContextViewSettings] without giving presentation widgets direct
/// access to SharedPreferences.
class ContextViewSettingsScope extends InheritedNotifier<ContextViewSettings> {
  const ContextViewSettingsScope({
    super.key,
    required ContextViewSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static ContextViewSettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ContextViewSettingsScope>()
      ?.notifier;
}
