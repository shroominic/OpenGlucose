import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openglucose/l10n/generated/app_localizations.dart';
import 'package:openglucose/src/ai/ai_controller.dart';
import 'package:openglucose/src/ai/ai_settings.dart';
import 'package:openglucose/src/ai/ai_settings_pane.dart';
import 'package:openglucose/src/ai/ai_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _localizedApp(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

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
        baseUrl: 'https://api.anthropic.com/v1',
        model: 'claude-3-5-haiku-latest',
        authScheme: AiAuthScheme.xApiKey,
      );
      final restored = AiSettings.decode(settings.encode());
      expect(restored.enabled, isTrue);
      expect(restored.model, 'claude-3-5-haiku-latest');
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
        _localizedApp(
          const Scaffold(body: AiSettingsPane(recentReadings: <CgmReading>[])),
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

    testWidgets('testing first saves the unsaved cloud draft', (tester) async {
      await tester.pumpWidget(
        _localizedApp(
          const Scaffold(body: AiSettingsPane(recentReadings: <CgmReading>[])),
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
      await tester.ensureVisible(find.text('Test with aggregates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test with aggregates'));
      await tester.pumpAndSettle();

      final store = await newStore();
      expect(store.loadSettings().enabled, isTrue);
      expect(await store.hasApiKey(), isTrue);
      expect(secureBox.values, contains('sk-unsaved'));
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
      final result = await controller.generateRecentInsight(
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

    testWidgets('renders cloud AI privacy controls in Simplified Chinese', (
      tester,
    ) async {
      await tester.pumpWidget(
        _localizedApp(
          const Scaffold(body: AiSettingsPane(recentReadings: <CgmReading>[])),
          locale: const Locale('zh'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('AI 洞察'), findsOneWidget);
      expect(find.text('设备端模型'), findsOneWidget);
      expect(find.text('自定义云端服务'), findsOneWidget);

      await tester.tap(find.text('自定义云端服务'));
      await tester.pumpAndSettle();
      expect(find.text('启用云端 AI'), findsOneWidget);
      expect(find.text('API 密钥（安全存储）'), findsOneWidget);
    });
  });
}
