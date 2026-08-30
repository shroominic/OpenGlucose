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

  testWidgets(
    'enables and reaches qualified Context controls at 320px with 2x text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.utc(2026, 8, 24, 12);
      final fixture = await _DashboardFixture.create(
        clock: () => now,
        driver: _UniformQualifiedRiseDriver(now),
        repository: _SavingContextRepository(),
      );
      var fixtureDisposed = false;
      addTearDown(() async {
        if (!fixtureDisposed) await fixture.dispose();
      });

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: fixture.app(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('OpenGlucose'), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('OpenGlucose'))).scale(
          14,
        ),
        28,
      );

      // Use the shipped dashboard and Settings navigation. Do not mutate the
      // settings controller directly: this confirms that the user-visible
      // controls enable the bridge and its explicit non-clinical policy.
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      final contextDestination = find.ancestor(
        of: find.text('Context view'),
        matching: find.byType(ListTile),
      );
      expect(contextDestination, findsOneWidget);
      await tester.ensureVisible(contextDestination);
      await tester.pumpAndSettle();
      await tester.tap(contextDestination);
      await tester.pumpAndSettle();
      expect(find.byType(ContextViewSettingsPane), findsOneWidget);

      final showContext = find.byKey(
        const ValueKey<String>('showContextViewSetting'),
      );
      await tester.scrollUntilVisible(
        showContext,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(showContext);
      await tester.pumpAndSettle();
      await tester.tap(showContext);
      await tester.pumpAndSettle();

      final threshold = find.byKey(
        const ValueKey<String>('observedRiseThresholdSetting'),
      );
      await tester.scrollUntilVisible(
        threshold,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(threshold);
      await tester.pumpAndSettle();
      await tester.tap(threshold);
      await tester.enterText(threshold, '20');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final suggest = find.byKey(
        const ValueKey<String>('suggestRecentRiseSetting'),
      );
      await tester.scrollUntilVisible(
        suggest,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(suggest);
      await tester.pumpAndSettle();
      await tester.tap(suggest);
      await tester.pumpAndSettle();

      expect(fixture.settings.showContextView, isTrue);
      expect(fixture.settings.observedRiseThresholdMgdl, 20);
      expect(fixture.settings.suggestRecentRise, isTrue);
      // Drain the settings-triggered cache tail while the real route is still
      // mounted. This does not change the user-selected settings.
      await fixture.bridge.reload();
      await tester.pump();

      // Return through the actual settings route, then let the started bridge
      // publish the qualified rapid-rise cache created by those settings.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        fixture.bridge.snapshot.suggestionAvailability,
        ContextBridgeSuggestionAvailability.available,
      );
      expect(fixture.bridge.snapshot.attachmentSuggestion, isNotNull);

      // Slivers below the large-text hero are built lazily. Scroll the actual
      // dashboard rather than navigating directly to prove the real action is
      // reachable at this viewport and scale.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('openContextView')),
        240,
      );
      expect(
        find.byKey(const ValueKey<String>('dashboardHistorySection')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('openContextView')),
      );
      await tester.pumpAndSettle();
      final contextAction = find.byKey(
        const ValueKey<String>('openContextView'),
      );
      expect(tester.getCenter(contextAction).dy, inInclusiveRange(0, 800));
      expect(tester.widget<TextButton>(contextAction).onPressed, isNotNull);
      await tester.tap(contextAction);
      await tester.pump();
      expect(Navigator.of(tester.element(contextAction)).canPop(), isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.byType(ContextViewScreen), findsOneWidget);
      expect(find.text('Glucose with context'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('contextViewTimeline')),
        240,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey<String>('contextViewScroll')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('contextViewTimeline')),
        findsOneWidget,
      );

      // The actual dashboard quick-add is present only for the qualified,
      // bounded opportunity. Reopen the dashboard before exercising it.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('addContextToRecentRise')),
        240,
      );
      final addContext = find.byKey(
        const ValueKey<String>('addContextToRecentRise'),
      );
      await tester.ensureVisible(addContext);
      await tester.pumpAndSettle();
      expect(tester.getCenter(addContext).dy, inInclusiveRange(0, 800));
      expect(tester.widget<OutlinedButton>(addContext).onPressed, isNotNull);
      await tester.tap(addContext);
      await tester.pumpAndSettle();

      final attachmentSheet = find.byKey(
        const ValueKey<String>('contextAttachmentScroll'),
      );
      expect(attachmentSheet, findsOneWidget);
      expect(
        find.descendant(
          of: attachmentSheet,
          matching: find.text('Add context to recent rise'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Allowed local time range:')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('contextAttachmentKind-meal')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('contextAttachmentKind-activity')),
        findsOneWidget,
      );
      // Manual sleep remains available from Diary, not this recent-rise
      // quick-add, where the two bounded options keep the choice focused.
      expect(
        find.byKey(const ValueKey<String>('contextAttachmentKind-sleep')),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.text('Save context'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('contextAttachmentScroll'),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final saveContext = find.widgetWithText(FilledButton, 'Save context');
      await tester.ensureVisible(saveContext);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(saveContext).onPressed, isNotNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await fixture.dispose();
      fixtureDisposed = true;
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
                  prepareContextAttachmentSave: (_) async =>
                      const ContextBridgeAttachmentPreparation.unavailable(),
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
      find.byKey(const ValueKey<String>('contextAttachmentKind-meal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('contextAttachmentKind-activity')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('contextAttachmentKind-note')),
      findsNothing,
    );
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
                    prepareContextAttachmentSave: (expected) async =>
                        ContextBridgeAttachmentPreparation.ready(
                          suggestion: expected,
                          save: (draft) =>
                              ContextAttachmentController(
                                writer: repository,
                              ).save(
                                draft: draft,
                                suggestion: expected,
                              ),
                        ),
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

      // Let the modal route finish its teardown. The sheet has no retained
      // repository lifecycle after the completed save.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('fails closed when a bounded context candidate becomes stale', (
    tester,
  ) async {
    Future<bool>? result;
    var refreshCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                result = showContextAttachmentSheet(
                  context: context,
                  suggestion: _suggestion(),
                  prepareContextAttachmentSave: (_) async =>
                      const ContextBridgeAttachmentPreparation.staleOrSuperseded(),
                  refreshContext: () async {
                    refreshCalls++;
                  },
                );
              },
              child: const Text('Open stale bounded context add'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open stale bounded context add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save context'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This recent observation is no longer current. No diary entry was saved.',
      ),
      findsOneWidget,
    );
    expect(refreshCalls, 1);

    Navigator.of(tester.element(find.text('Add context to recent rise'))).pop();
    await tester.pumpAndSettle();
    expect(await result!, isFalse);
  });

  testWidgets('closes a claimed sheet after it refreshes the local truth', (
    tester,
  ) async {
    Future<bool>? result;
    var refreshCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                result = showContextAttachmentSheet(
                  context: context,
                  suggestion: _suggestion(),
                  prepareContextAttachmentSave: (_) async =>
                      const ContextBridgeAttachmentPreparation.alreadyClaimed(),
                  refreshContext: () async {
                    refreshCalls++;
                  },
                );
              },
              child: const Text('Open claimed bounded context add'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open claimed bounded context add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save context'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(refreshCalls, 1);
    expect(find.text('Add context to recent rise'), findsNothing);
    expect(await result!, isFalse);
  });

  testWidgets(
    'keeps the bounded attachment sheet usable at 320px with 2x text',
    (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    await showContextAttachmentSheet(
                      context: context,
                      suggestion: _suggestion(),
                      prepareContextAttachmentSave: (_) async =>
                          const ContextBridgeAttachmentPreparation.unavailable(),
                      refreshContext: () async {},
                    );
                  },
                  child: const Text('Open large bounded context add'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open large bounded context add'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save context'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey<String>('contextAttachmentScroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      expect(find.text('Add context to recent rise'), findsOneWidget);
      expect(find.text('Save context'), findsOneWidget);
      expect(tester.takeException(), isNull);
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

  static Future<_DashboardFixture> create({
    bool startBridge = true,
    MockScenario scenario = MockScenario.activeNormal,
    DateTime Function()? clock,
    CgmDriver? driver,
    HealthRepository? repository,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'openHealth.onboarding.completed': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final effectiveClock = clock ?? DateTime.now;
    final effectiveDriver =
        driver ??
        DemoCgmDriver(initialScenario: scenario, clock: effectiveClock);
    final controller = CgmAppController(
      preferences: preferences,
      driver: effectiveDriver,
    );
    await controller.initialize();
    await controller.connect(MockScenarioCatalog.sensor);

    final repositoryOpenCounter = _RepositoryOpenCounter();
    final lifecycle = AppHealthRepositoryLifecycle(() async {
      repositoryOpenCounter.value++;
      return repository ?? InMemoryHealthRepository();
    });
    final settings = ContextViewSettings(preferences);
    final bridge = ContextBridge(
      controller: controller,
      repositoryLifecycle: lifecycle,
      contextSettingsSignal: settings,
      isContextViewEnabled: () => settings.showContextView,
      suggestionPolicyProvider: () => settings.suggestionPolicy,
      clock: effectiveClock,
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

/// Keeps the qualified-rise fixture deterministic while assigning one
/// displayed CGM source to every reading. The production rapid-rise demo
/// intentionally mixes its final broadcast value with vendor history, which
/// the bridge correctly rejects for a candidate; this test-only session uses
/// one eligible, completed local sequence instead.
class _UniformQualifiedRiseDriver extends DemoCgmDriver {
  _UniformQualifiedRiseDriver(DateTime now)
    : _session = _FixedCgmSession(_uniformQualifiedRiseSnapshot(now)),
      super(initialScenario: MockScenario.activeNormal, clock: () => now);

  final _FixedCgmSession _session;

  @override
  Future<CgmSession> connect(DiscoveredSensor sensor) async => _session;
}

class _FixedCgmSession implements CgmSession {
  const _FixedCgmSession(this._snapshot);

  final CgmSessionSnapshot _snapshot;

  @override
  CgmSessionSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<CgmLogEntry> get logs => const Stream<CgmLogEntry>.empty();

  @override
  DiscoveredSensor get sensor => _snapshot.sensor;

  @override
  Stream<CgmSessionSnapshot> get snapshots =>
      const Stream<CgmSessionSnapshot>.empty();

  @override
  CgmUnsafeAdmin? get unsafeAdmin => null;

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<CgmCalibrationEntry>> fetchCalibrations() async =>
      const <CgmCalibrationEntry>[];

  @override
  Future<void> refresh() async {}

  @override
  Future<List<CgmDiagnosticItem>> refreshDiagnostics() async =>
      const <CgmDiagnosticItem>[];

  @override
  Future<void> refreshLiveData() async {}

  @override
  Future<void> submitCalibration({
    required int glucoseMgdl,
    int? sensorMinute,
    DateTime? recordedAt,
  }) async {}

  @override
  Future<void> syncHistory({
    bool includeRawHistory = false,
    int? requestedStartOffset,
  }) async {}
}

CgmSessionSnapshot _uniformQualifiedRiseSnapshot(DateTime now) {
  final sourceSnapshot = MockScenarioCatalog(
    clock: () => now,
  ).buildSnapshot(MockScenario.activeNormal);
  final sessionStart = sourceSnapshot.sessionInfo.sessionStart!;
  final values = <double>[120, 100, 110, 125, 130, 128, 126, 124];
  final history = List<CgmReading>.generate(values.length, (index) {
    final recordedAt = now.subtract(
      Duration(minutes: (values.length - 1 - index) * 5),
    );
    return CgmReading(
      valueMgdl: values[index],
      source: CgmRecordSource.vendor,
      sensorMinute: recordedAt.difference(sessionStart).inMinutes,
      recordedAt: recordedAt,
      qualifier: 1,
    );
  });
  return sourceSnapshot.copyWith(
    history: history,
    latestReading: history.last,
  );
}

class _SavingContextRepository extends InMemoryHealthRepository
    with ContextAttachmentWriter
    implements FastJournalStore, ContextAttachmentFactStore {
  int saveCalls = 0;

  @override
  Future<List<FastJournalEntry>> queryFastJournalEntries({
    TimeWindow window = TimeWindow.all,
    required int limit,
  }) async => const <FastJournalEntry>[];

  @override
  Future<bool> isFastJournalRiseClaimed({
    required DateTime riseStartedAt,
  }) async => false;

  @override
  Future<FastJournalEntry> saveFastJournalEntry({
    required FastJournalEntry entry,
    FastJournalRiseReference? requestedRise,
  }) async => requestedRise == null
      ? entry
      : entry.copyWith(riseReference: requestedRise);

  @override
  Future<ContextAttachmentFact?> claimContextAttachmentFact(
    ContextAttachmentFact fact,
  ) async => fact;

  @override
  Future<List<ContextAttachmentFact>> queryContextAttachmentFacts({
    TimeWindow window = TimeWindow.all,
    ContextBridgeEpisodeKey? episodeKey,
  }) async => const <ContextAttachmentFact>[];

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
