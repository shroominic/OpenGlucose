import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openglucose/src/ai/ai_controller.dart';
import 'package:openglucose/src/ai/ai_settings.dart';
import 'package:openglucose/src/ai/ai_settings_pane.dart';
import 'package:openglucose/src/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<CgmReading> _generationReadings() {
  final latest = DateTime.now().subtract(const Duration(minutes: 5));
  return List<CgmReading>.generate(145, (index) {
    return CgmReading(
      valueMgdl: 100 + (index % 8) * 3,
      source: CgmRecordSource.vendor,
      recordedAt: latest.subtract(Duration(minutes: (144 - index) * 5)),
    );
  });
}

Future<HealthRepository> _openMemoryRepository() async {
  final repository = InMemoryHealthRepository();
  await repository.init();
  return repository;
}

const String _validObservationResponse =
    '{"formatVersion":2,"kind":"observation","statements":['
    '{"template":"recordedEvidence",'
    '"evidenceIds":["journal.meal_count"],"numericClaims":['
    '{"evidenceId":"journal.meal_count","value":0,"unit":"events"}]}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiSettings serialization', () {
    test('defaults are AI-off', () {
      const settings = AiSettings();
      expect(settings.enabled, isFalse);
      expect(settings.baseUrl, contains('openai'));
    });

    test('round-trips through encode/decode and never holds a key', () {
      const settings = AiSettings(
        enabled: true,
        baseUrl: 'https://compat.example/v1',
        model: 'compatible-model',
        authScheme: AiAuthScheme.xApiKey,
      );
      final restored = AiSettings.decode(settings.encode());
      expect(restored.enabled, isTrue);
      expect(restored.model, 'compatible-model');
      expect(restored.authScheme, AiAuthScheme.xApiKey);
      // No secret leaks into the serialized form.
      expect(settings.encode(), isNot(contains('apiKey')));
    });

    test('decode falls back to defaults on corrupt input', () {
      expect(AiSettings.decode('not json').enabled, isFalse);
      expect(AiSettings.decode(null).enabled, isFalse);
    });
  });

  group('AiSettingsStore + AiController', () {
    // Mock the flutter_secure_storage method channel with an in-memory map so
    // these tests need no Keychain/Keystore.
    final secureBox = <String, String>{};

    setUp(() {
      secureBox.clear();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args =
                  (call.arguments as Map?) ?? const <Object?, Object?>{};
              final key = args['key'] as String?;
              switch (call.method) {
                case 'write':
                  final value = args['value'];
                  if (key != null && value is String) {
                    secureBox[key] = value;
                  }
                  return null;
                case 'read':
                  return secureBox[key];
                case 'delete':
                  secureBox.remove(key);
                  return null;
                case 'containsKey':
                  return secureBox.containsKey(key);
                case 'readAll':
                  return Map<String, String>.from(secureBox);
                case 'deleteAll':
                  secureBox.clear();
                  return null;
                default:
                  return null;
              }
            },
          );
    });

    Future<AiSettingsStore> newStore() async {
      final prefs = await SharedPreferences.getInstance();
      return AiSettingsStore(preferences: prefs);
    }

    test('stores key in secure storage, not in preferences', () async {
      final store = await newStore();
      await store.saveSettings(const AiSettings(enabled: true));
      await store.writeApiKey('sk-secret');

      expect(await store.hasApiKey(), isTrue);
      expect(secureBox.values, contains('sk-secret'));

      final prefs = await SharedPreferences.getInstance();
      // The key must never appear in plain SharedPreferences.
      final dumped = prefs.getKeys().map(prefs.get).join();
      expect(dumped, isNot(contains('sk-secret')));
    });

    test('iOS keys stay on this device and never synchronize', () {
      final options = AiSettingsStore.secureIOSOptions.toMap();

      expect(
        options['accessibility'],
        KeychainAccessibility.unlocked_this_device.name,
      );
      expect(options['synchronizable'], 'false');
    });

    test('empty key write deletes the stored key', () async {
      final store = await newStore();
      await store.writeApiKey('sk-secret');
      expect(await store.hasApiKey(), isTrue);
      await store.writeApiKey('   ');
      expect(await store.hasApiKey(), isFalse);
    });

    testWidgets('cloud controls stay hidden until Advanced is expanded', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiSettingsPane(
              recentReadings: _generationReadings(),
              repositoryOpener: _openMemoryRepository,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Custom cloud provider'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey<String>('comingSoonStatus')),
            )
            .label,
        contains('On-device model status: coming soon'),
      );
      semantics.dispose();
      expect(find.text('API base URL'), findsNothing);
      expect(find.text('Auth scheme'), findsNothing);
      expect(find.text('API key (stored securely)'), findsNothing);

      await tester.tap(find.text('Custom cloud provider'));
      await tester.pumpAndSettle();

      expect(find.text('API base URL'), findsOneWidget);
      expect(find.text('Auth scheme'), findsOneWidget);
      expect(find.text('API key (stored securely)'), findsOneWidget);
    });

    testWidgets('saving persists the unsaved cloud draft', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AiSettingsPane(recentReadings: <CgmReading>[])),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom cloud provider'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enable cloud AI'));
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'API key (stored securely)',
        ),
        'sk-unsaved',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save provider'));
      await tester.pumpAndSettle();

      final store = await newStore();
      expect(store.loadSettings().enabled, isTrue);
      expect(await store.hasApiKey(), isTrue);
      expect(secureBox.values, contains('sk-unsaved'));
    });

    testWidgets('real generation shows a recipient and data preview first', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiSettingsPane(
              recentReadings: _generationReadings(),
              repositoryOpener: _openMemoryRepository,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom cloud provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable cloud AI'));
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'API key (stored securely)',
        ),
        'sk-preview',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Generate aggregate insight'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate aggregate insight'));
      await tester.pumpAndSettle();

      expect(find.text('Send aggregates to api.openai.com?'), findsOneWidget);
      expect(
        find.textContaining('https://api.openai.com/v1/chat/completions'),
        findsOneWidget,
      );
      expect(
        find.textContaining('aggregate glucose statistics'),
        findsOneWidget,
      );
      expect(find.textContaining('journal event counts'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      final disclosureLabel = tester
          .getSemantics(
            find.byKey(const ValueKey<String>('aiRemoteGenerationDisclosure')),
          )
          .label;
      expect(disclosureLabel, contains('never sends raw readings'));
      expect(
        disclosureLabel,
        contains('https://api.openai.com/v1/chat/completions'),
      );
      expect(disclosureLabel, contains('aggregate glucose statistics'));
      expect(disclosureLabel, contains('journal event counts'));
      semantics.dispose();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Send aggregates to api.openai.com?'), findsNothing);
    });

    testWidgets('captures a redacted remote-generation disclosure dialog', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiSettingsPane(
              recentReadings: _generationReadings(),
              repositoryOpener: _openMemoryRepository,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom cloud provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable cloud AI'));
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'API key (stored securely)',
        ),
        'sk-preview',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Generate aggregate insight'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate aggregate insight'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AlertDialog),
        matchesGoldenFile(
          '../../../docs/architecture/adr/'
          'ai-remote-generation-disclosure-redacted.png',
        ),
      );
    });

    test('AiController builds NullAiProvider when disabled', () async {
      final store = await newStore();
      await store.saveSettings(const AiSettings(enabled: false));
      await store.writeApiKey('sk-secret');
      final controller = AiController(
        store: store,
        repository: InMemoryHealthRepository(),
      );
      final provider = await controller.buildProvider();
      expect(provider, isA<NullAiProvider>());
      expect(provider.isEnabled, isFalse);
    });

    test(
      'AiController builds NullAiProvider when enabled but no key',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        final controller = AiController(
          store: store,
          repository: InMemoryHealthRepository(),
        );
        final provider = await controller.buildProvider();
        expect(provider, isA<NullAiProvider>());
      },
    );

    test(
      'AiController builds an enabled HttpChatAiProvider with key',
      () async {
        final store = await newStore();
        await store.saveSettings(
          const AiSettings(enabled: true, model: 'm-test'),
        );
        await store.writeApiKey('sk-secret');
        final controller = AiController(
          store: store,
          repository: InMemoryHealthRepository(),
        );
        final provider = await controller.buildProvider();
        expect(provider, isA<HttpChatAiProvider>());
        expect(provider.isEnabled, isTrue);
        expect(provider.modelId, 'm-test');
      },
    );

    test('disabled controller generates nothing (no I/O)', () async {
      final store = await newStore();
      final repo = InMemoryHealthRepository();
      await repo.init();
      final controller = AiController(store: store, repository: repo);
      final result = await controller.prepareRecentInsightGeneration(
        readings: <CgmReading>[
          CgmReading(
            valueMgdl: 120,
            source: CgmRecordSource.vendor,
            recordedAt: DateTime.now(),
          ),
        ],
      );
      expect(result, isNull);
      expect(await repo.queryInsights(), isEmpty);
    });

    test(
      'disabled controller does not send a connection-test request',
      () async {
        final store = await newStore();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: InMemoryHealthRepository(),
          transport: (request, config) async {
            requests.add(request);
            return 'unexpected';
          },
        );

        await expectLater(
          controller.testRemoteConnection(),
          throwsA(isA<AiGenerationException>()),
        );

        expect(requests, isEmpty);
      },
    );

    test(
      'connection test sends a synthetic request and persists nothing',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repo = InMemoryHealthRepository();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: repo,
          transport: (request, config) async {
            requests.add(request);
            expect(config.endpointHostname, 'api.openai.com');
            return 'connected';
          },
        );

        final result = await controller.testRemoteConnection();

        expect(result.responseReceived, isTrue);
        expect(requests, hasLength(1));
        expect(requests.single.purpose, AiRequestPurpose.connectionTest);
        expect(requests.single.requiresStructuredOutput, isFalse);
        expect(requests.single.model, 'gpt-4o-mini');
        expect(
          requests.single.messages.map((message) => message.content).join(' '),
          isNot(contains('Average glucose')),
        );
        expect(await repo.queryInsights(), isEmpty);
      },
    );

    test(
      'real generation disclosure names recipient and outgoing categories',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repository = await _openMemoryRepository();
        final controller = AiController(
          store: store,
          repository: repository,
        );

        final preparation = await controller.prepareRecentInsightGeneration(
          readings: _generationReadings(),
        );
        final disclosure = preparation?.disclosure;

        expect(disclosure, isNotNull);
        expect(disclosure!.endpointHostname, 'api.openai.com');
        expect(
          disclosure.endpoint,
          'https://api.openai.com/v1/chat/completions',
        );
        expect(
          disclosure.dataCategories,
          contains('aggregate glucose statistics'),
        );
        expect(disclosure.dataCategories, contains('journal event counts'));
        final disclosedCategories = List<String>.from(
          disclosure.dataCategories,
        );
        expect(
          () => disclosure.dataCategories.add('raw readings'),
          throwsUnsupportedError,
        );
        expect(disclosure.dataCategories, orderedEquals(disclosedCategories));
        await repository.close();
      },
    );

    test(
      'a public disclosure mutation cannot change consent-bound categories',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repository = await _openMemoryRepository();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: repository,
          transport: (request, _) async {
            requests.add(request);
            return _validObservationResponse;
          },
        );

        final preparation = await controller.prepareRecentInsightGeneration(
          readings: _generationReadings(),
        );
        expect(preparation, isNotNull);
        final originalCategories = List<String>.from(
          preparation!.disclosure.dataCategories,
        );
        expect(
          () => preparation.disclosure.dataCategories.add('raw readings'),
          throwsUnsupportedError,
        );
        expect(
          preparation.disclosure.dataCategories,
          orderedEquals(originalCategories),
        );

        final receipt = controller.confirmRemoteGeneration(preparation);
        await controller.generateRecentInsight(
          preparation: preparation,
          consentReceipt: receipt,
        );

        expect(requests, hasLength(1));
        expect(
          preparation.disclosure.dataCategories,
          orderedEquals(originalCategories),
        );
        await repository.close();
      },
    );

    test(
      'requires one exact consent receipt before a real provider call',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repository = await _openMemoryRepository();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: repository,
          transport: (request, _) async {
            requests.add(request);
            return _validObservationResponse;
          },
        );

        final preparation = await controller.prepareRecentInsightGeneration(
          readings: _generationReadings(),
        );
        expect(preparation, isNotNull);
        expect(requests, isEmpty, reason: 'preparation is local-only');

        final receipt = controller.confirmRemoteGeneration(preparation!);
        final insight = await controller.generateRecentInsight(
          preparation: preparation,
          consentReceipt: receipt,
        );

        expect(insight, isNotNull);
        expect(requests, hasLength(1));
        await expectLater(
          controller.generateRecentInsight(
            preparation: preparation,
            consentReceipt: receipt,
          ),
          throwsA(isA<AiGenerationException>()),
        );
        expect(requests, hasLength(1), reason: 'a consumed receipt is inert');
        await repository.close();
      },
    );

    test(
      'rejects a receipt if its configured endpoint changes',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repository = await _openMemoryRepository();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: repository,
          transport: (request, _) async {
            requests.add(request);
            return _validObservationResponse;
          },
        );
        final preparation = await controller.prepareRecentInsightGeneration(
          readings: _generationReadings(),
        );
        final receipt = controller.confirmRemoteGeneration(preparation!);
        await store.saveSettings(
          const AiSettings(
            enabled: true,
            baseUrl: 'https://other-provider.example/v1',
          ),
        );

        await expectLater(
          controller.generateRecentInsight(
            preparation: preparation,
            consentReceipt: receipt,
          ),
          throwsA(isA<AiGenerationException>()),
        );
        expect(requests, isEmpty);
        await repository.close();
      },
    );

    test(
      'rejects a receipt for a different prepared aggregate snapshot',
      () async {
        final store = await newStore();
        await store.saveSettings(const AiSettings(enabled: true));
        await store.writeApiKey('sk-secret');
        final repository = await _openMemoryRepository();
        final requests = <AiRequest>[];
        final controller = AiController(
          store: store,
          repository: repository,
          transport: (request, _) async {
            requests.add(request);
            return _validObservationResponse;
          },
        );
        final first = await controller.prepareRecentInsightGeneration(
          readings: _generationReadings(),
        );
        final secondReadings = _generationReadings()
            .map(
              (reading) => CgmReading(
                valueMgdl: reading.valueMgdl + 20,
                source: reading.source,
                recordedAt: reading.recordedAt,
              ),
            )
            .toList(growable: false);
        final second = await controller.prepareRecentInsightGeneration(
          readings: secondReadings,
        );
        final receipt = controller.confirmRemoteGeneration(first!);

        await expectLater(
          controller.generateRecentInsight(
            preparation: second!,
            consentReceipt: receipt,
          ),
          throwsA(isA<AiGenerationException>()),
        );
        expect(requests, isEmpty);
        await repository.close();
      },
    );
  });
}
