import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/main.dart';
import 'package:openglucose/src/app_controller.dart';
import 'package:openglucose/src/context_bridge/context_attachment_fact.dart';
import 'package:openglucose/src/context_bridge/context_attachment_writer.dart';
import 'package:openglucose/src/context_bridge/context_bridge.dart';
import 'package:openglucose/src/context_bridge/context_bridge_models.dart';
import 'package:openglucose/src/context_view_screen.dart';
import 'package:openglucose/src/context_view_settings.dart';
import 'package:openglucose/src/demo_driver.dart';
import 'package:openglucose/src/healthkit_export.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';
import 'package:openglucose/src/mock_scenarios.dart';
import 'package:openglucose/src/persistence/health_repository_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'keeps the default reader unchanged and avoids a local context query',
    (tester) async {
      final fixture = await _DashboardFixture.create();
      addTearDown(fixture.dispose);

      expect(fixture.repositoryOpenCalls, 0);
      expect(fixture.bridge.snapshot.loadState, ContextBridgeLoadState.idle);

      await tester.pumpWidget(fixture.app());
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('dashboardHistorySection')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('openContextView')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('addContextToRecentRise')),
        findsNothing,
      );
      expect(fixture.repositoryOpenCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'opens the opt-in full context route with an accessible History action',
    (tester) async {
      // The route consumes the already-published bridge snapshot. Keeping this
      // bridge idle verifies that navigation itself starts no repository work
      // and that its teardown settles without a cache refresh race.
      final fixture = await _DashboardFixture.create(startBridge: false);
      addTearDown(fixture.dispose);
      await fixture.settings.setShowContextView(value: true);

      await tester.pumpWidget(fixture.app());
      await tester.pump();

      expect(fixture.repositoryOpenCalls, 0);
      final semanticsHandle = tester.ensureSemantics();
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey<String>('openContextView')),
        ),
        isSemantics(
          label: 'Open context view from History',
          isButton: true,
          hasTapAction: true,
        ),
      );
      semanticsHandle.dispose();
      await tester.tap(find.byKey(const ValueKey<String>('openContextView')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('Glucose with context'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('contextViewTimeline')),
        findsOneWidget,
      );
      expect(find.text('Heart rate'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keeps Context settings and the History action usable with narrow large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final settings = ContextViewSettings(preferences);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp(
            home: Scaffold(
              body: ContextViewSettingsPane(settings: settings),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('showContextViewSetting')),
        240,
      );
      expect(
        find.byKey(const ValueKey<String>('showContextViewSetting')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('suggestRecentRiseSetting')),
        240,
      );
      expect(
        find.byKey(const ValueKey<String>('suggestRecentRiseSetting')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('bounded context add cancels and fails closed on a local error', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    Future<bool>? result;
    var refreshCalls = 0;
    final suggestion = _suggestion();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                result = showContextAttachmentSheet(
                  context: context,
                  suggestion: suggestion,
                  repositoryLifecycle: null,
                  refreshContext: () async {
                    refreshCalls++;
                  },
                );
              },
              child: const Text('Open bounded context add'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open bounded context add'));
    await tester.pumpAndSettle();
    expect(find.text('Add context to recent rise'), findsOneWidget);
    expect(find.textContaining('Allowed time:'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('^Allowed local time range:')),
      findsOneWidget,
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(await result!, isFalse);

    await tester.tap(find.text('Open bounded context add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save context'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This local context could not be saved. Your diary was not changed.',
      ),
      findsOneWidget,
    );
    expect(refreshCalls, 0);
  });

  testWidgets(
    'keeps a completed local save successful when cache refresh is unavailable',
    (tester) async {
      final repository = _SavingContextRepository();
      final lifecycle = AppHealthRepositoryLifecycle(() async => repository);
      Future<bool>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () {
                  result = showContextAttachmentSheet(
                    context: context,
                    suggestion: _suggestion(),
                    repositoryLifecycle: lifecycle,
                    refreshContext: () async {
                      throw StateError('refresh unavailable');
                    },
                  );
                },
                child: const Text('Open successful bounded context add'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open successful bounded context add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save context'));
      await tester.pumpAndSettle();

      expect(await result!, isTrue);
      expect(repository.saveCalls, 1);
      expect(
        find.text(
          'This local context could not be saved. Your diary was not changed.',
        ),
        findsNothing,
      );

      // Let the modal route finish its teardown before disposing the
      // app-owned repository. This mirrors app shutdown order and ensures a
      // completed local write cannot retain an async widget route.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await lifecycle.dispose();
    },
  );
}

class _DashboardFixture {
  _DashboardFixture({
    required this.preferences,
    required this.controller,
    required this.settings,
    required this.bridge,
    required this.lifecycle,
    required this.repositoryOpenCounter,
  });

  final SharedPreferences preferences;
  final CgmAppController controller;
  final ContextViewSettings settings;
  final ContextBridge bridge;
  final AppHealthRepositoryLifecycle lifecycle;
  final _RepositoryOpenCounter repositoryOpenCounter;

  int get repositoryOpenCalls => repositoryOpenCounter.value;

  static Future<_DashboardFixture> create({bool startBridge = true}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final driver = DemoCgmDriver();
    final controller = CgmAppController(
      preferences: preferences,
      driver: driver,
    );
    await controller.initialize();
    await controller.connect(MockScenarioCatalog.sensor);

    final repositoryOpenCounter = _RepositoryOpenCounter();
    final lifecycle = AppHealthRepositoryLifecycle(() async {
      repositoryOpenCounter.value++;
      return InMemoryHealthRepository();
    });
    final settings = ContextViewSettings(preferences);
    final bridge = ContextBridge(
      controller: controller,
      repositoryLifecycle: lifecycle,
      contextSettingsSignal: settings,
      isContextViewEnabled: () => settings.showContextView,
      suggestionPolicyProvider: () => settings.suggestionPolicy,
    );
    if (startBridge) {
      await bridge.start();
    }
    return _DashboardFixture(
      preferences: preferences,
      controller: controller,
      settings: settings,
      bridge: bridge,
      lifecycle: lifecycle,
      repositoryOpenCounter: repositoryOpenCounter,
    );
  }

  OpenGlucoseApp app() => OpenGlucoseApp(
    controller: controller,
    healthExport: HealthExportController(
      preferences: preferences,
      writesAllowed: false,
    )..initialize(),
    contextBridge: bridge,
    contextViewSettings: settings,
    healthRepositoryLifecycle: lifecycle,
    preferences: preferences,
  );

  Future<void> dispose() async {
    bridge.dispose();
    controller.dispose();
    await lifecycle.dispose();
  }
}

class _RepositoryOpenCounter {
  int value = 0;
}

class _SavingContextRepository extends InMemoryHealthRepository
    with ContextAttachmentWriter {
  int saveCalls = 0;

  @override
  Future<ContextAttachmentSaveResult> saveContextAttachment({
    required FastJournalEntry entry,
    required ContextAttachmentFact fact,
  }) async {
    saveCalls++;
    return ContextAttachmentSaveResult.saved(entry);
  }
}

ContextBridgeAttachmentSuggestion _suggestion() {
  final start = DateTime.utc(2026, 8, 24, 11);
  return ContextBridgeAttachmentSuggestion(
    candidateId: ContextBridgeCandidateId(
      'ctx-candidate-0123456789abcdef01234567',
    ),
    episodeKey: ContextBridgeEpisodeKey('ctx-episode-fedcba9876543210fedcba98'),
    calculationVersion: 'recent-observed-rise-v1',
    episodeStart: start,
    peakAt: start.add(const Duration(minutes: 20)),
    attachmentWindowStart: start.subtract(const Duration(minutes: 20)),
    attachmentWindowEnd: start.add(const Duration(minutes: 40)),
    safetyBoundary:
        'A recent observed glucose rise does not identify its cause and is not medical advice.',
  );
}
