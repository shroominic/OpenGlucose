import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/onboarding/onboarding_flow.dart';
import 'package:openglucose/src/onboarding/onboarding_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<OnboardingStore> _store([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  return OnboardingStore(await SharedPreferences.getInstance());
}

void main() {
  group('OnboardingStore', () {
    test('defaults to not completed with the default 70-180 range', () async {
      final store = await _store();
      expect(store.isCompleted, isFalse);
      expect(store.targetLowMgdl, 70);
      expect(store.targetHighMgdl, 180);
    });

    test('persists completion and chosen range', () async {
      final store = await _store();
      await store.complete(targetLowMgdl: 80, targetHighMgdl: 160);
      expect(store.isCompleted, isTrue);
      expect(store.targetLowMgdl, 80);
      expect(store.targetHighMgdl, 160);

      // A fresh store over the same backing prefs sees the persisted state.
      final reloaded = OnboardingStore(await SharedPreferences.getInstance());
      expect(reloaded.isCompleted, isTrue);
      expect(reloaded.targetLowMgdl, 80);
    });

    test('reads back true when already completed', () async {
      final store = await _store(<String, Object>{
        'openHealth.onboarding.completed': true,
      });
      expect(store.isCompleted, isTrue);
    });
  });

  group('OnboardingFlow', () {
    testWidgets('flows through all screens, picks a range, and finishes', (
      tester,
    ) async {
      final store = await _store();
      var finished = false;

      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingFlow(
            store: store,
            unit: GlucoseUnit.mgdl,
            onFinished: () => finished = true,
          ),
        ),
      );

      // Welcome -> How it works -> Target range -> Connect.
      expect(find.text('Welcome to OpenGlucose'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onboardingPrimaryButton')));
      await tester.pumpAndSettle();
      expect(find.text('How it works'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('onboardingPrimaryButton')));
      await tester.pumpAndSettle();
      expect(find.text('Set your target range'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboardingRangeSlider')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('onboardingPrimaryButton')));
      await tester.pumpAndSettle();
      expect(find.text("You're all set"), findsOneWidget);

      // Final step persists completion and hands off. The button shows an
      // (infinite) spinner while finishing, so pump a fixed amount rather than
      // pumpAndSettle.
      await tester.tap(find.byKey(const ValueKey('onboardingPrimaryButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(finished, isTrue);
      expect(store.isCompleted, isTrue);
    });

    testWidgets('Skip persists completion without forcing the range', (
      tester,
    ) async {
      final store = await _store();
      var finished = false;

      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingFlow(store: store, onFinished: () => finished = true),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('onboardingSkipButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(finished, isTrue);
      expect(store.isCompleted, isTrue);
      // Skipped without touching the slider -> default range retained.
      expect(store.targetLowMgdl, 70);
      expect(store.targetHighMgdl, 180);
    });
  });
}
