import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_view_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'context settings are off by default and require an explicit threshold',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final settings = ContextViewSettings(preferences);

      expect(settings.showContextView, isFalse);
      expect(settings.suggestRecentRise, isFalse);
      expect(settings.observedRiseThresholdMgdl, isNull);
      expect(settings.suggestionPolicy.isEnabled, isFalse);

      expect(await settings.setSuggestRecentRise(value: true), isFalse);
      expect(settings.suggestRecentRise, isFalse);
      expect(settings.suggestionPolicy.isEnabled, isFalse);

      await settings.setObservedRiseThresholdText('24');
      expect(settings.hasValidObservedRiseThreshold, isTrue);
      expect(await settings.setSuggestRecentRise(value: true), isTrue);
      expect(settings.suggestionPolicy.isEnabled, isTrue);
      expect(
        settings.suggestionPolicy.recentRisePolicy?.minimumRiseMgdl,
        24,
      );
      expect(
        settings.suggestionPolicy.disclosure,
        contains('does not identify its cause'),
      );
    },
  );

  test(
    'invalid threshold clears the policy and persisted suggestion state',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final settings = ContextViewSettings(preferences);

      await settings.setShowContextView(value: true);
      await settings.setObservedRiseThresholdText('20');
      await settings.setSuggestRecentRise(value: true);
      await settings.setObservedRiseThresholdText('not a number');

      expect(settings.showContextView, isTrue);
      expect(settings.observedRiseThresholdMgdl, isNull);
      expect(settings.suggestRecentRise, isFalse);
      expect(settings.suggestionPolicy.isEnabled, isFalse);

      final relaunched = ContextViewSettings(preferences);
      expect(relaunched.showContextView, isTrue);
      expect(relaunched.observedRiseThresholdMgdl, isNull);
      expect(relaunched.suggestRecentRise, isFalse);
    },
  );
}
