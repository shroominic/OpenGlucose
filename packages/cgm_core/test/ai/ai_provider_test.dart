import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:test/test.dart';

void main() {
  group('NullAiProvider', () {
    test('is disabled and never generates', () async {
      const provider = NullAiProvider();
      expect(provider.isEnabled, isFalse);
      expect(provider.modelId, isNull);
      expect(
        () => provider.generate(
          const AiRequest(messages: <AiMessage>[AiMessage.user('hi')]),
        ),
        throwsA(isA<AiGenerationException>()),
      );
    });
  });

  group('AiProviderConfig', () {
    test('hasKey requires both key and base URL', () {
      expect(const AiProviderConfig(baseUrl: '', apiKey: '').hasKey, isFalse);
      expect(
        const AiProviderConfig(baseUrl: 'https://x', apiKey: '  ').hasKey,
        isFalse,
      );
      expect(
        const AiProviderConfig(baseUrl: 'https://x', apiKey: 'sk-1').hasKey,
        isTrue,
      );
    });

    test('rejects invalid remote endpoint configuration', () {
      const config = AiProviderConfig(
        baseUrl: 'http://api.example.com/v1',
        apiKey: 'sk-1',
      );
      expect(config.isReady, isFalse);
      expect(config.validationError, contains('absolute HTTPS URL'));
      expect(
        config.capability().availabilityReason,
        AiAvailabilityReason.invalidConfiguration,
      );
    });
  });

  group('HttpChatAiProvider', () {
    AiProviderConfig config() => const AiProviderConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );

    test('reports enabled and model from config', () {
      final provider = HttpChatAiProvider(
        config: config(),
        transport: (_, _) async => 'ok',
      );
      expect(provider.isEnabled, isTrue);
      expect(provider.modelId, 'test-model');
      expect(provider.capability.kind, AiProviderKind.openAiCompatibleRemote);
      expect(provider.capability.supportsStructuredOutput, isTrue);
    });

    test('returns trimmed transport text', () async {
      final provider = HttpChatAiProvider(
        config: config(),
        transport: (request, cfg) async {
          expect(cfg.apiKey, 'sk-test');
          expect(request.messages, isNotEmpty);
          return '  hello world  ';
        },
      );
      expect(await provider.generate(_req()), 'hello world');
    });

    test('throws when disabled (no key)', () async {
      final provider = HttpChatAiProvider(
        config: const AiProviderConfig(baseUrl: '', apiKey: ''),
        transport: (_, _) async => 'never',
      );
      expect(provider.isEnabled, isFalse);
      await expectLater(
        provider.generate(_req()),
        throwsA(isA<AiGenerationException>()),
      );
    });

    test(
      'wraps transport failure in AiGenerationException (no crash)',
      () async {
        final provider = HttpChatAiProvider(
          config: config(),
          transport: (_, _) async => throw Exception('network down'),
        );
        await expectLater(
          provider.generate(_req()),
          throwsA(
            isA<AiGenerationException>().having(
              (e) => e.cause.toString(),
              'cause',
              contains('network down'),
            ),
          ),
        );
      },
    );

    test('empty response is an error', () async {
      final provider = HttpChatAiProvider(
        config: config(),
        transport: (_, _) async => '   ',
      );
      await expectLater(
        provider.generate(_req()),
        throwsA(isA<AiGenerationException>()),
      );
    });

    test('buildRequestBody serializes OpenAI-compatible shape', () {
      final body = HttpChatAiProvider.buildRequestBody(_req(), config());
      expect(body['model'], 'gpt-4o-mini');
      expect(body['max_tokens'], isA<int>());
      expect(body['response_format'], <String, Object?>{'type': 'json_object'});
      final messages = body['messages'] as List;
      expect(messages.first, containsPair('role', 'system'));
      expect(messages.last, containsPair('role', 'user'));
    });

    test('parseResponseBody reads OpenAI choices shape', () {
      final body = jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'from openai'},
          },
        ],
      });
      expect(HttpChatAiProvider.parseResponseBody(body), 'from openai');
    });

    test('parseResponseBody rejects native Anthropic response shape', () {
      final body = jsonEncode({
        'content': [
          {'type': 'text', 'text': 'from anthropic'},
        ],
      });
      expect(
        () => HttpChatAiProvider.parseResponseBody(body),
        throwsA(isA<AiGenerationException>()),
      );
    });

    test('parseResponseBody redacts provider error details', () {
      final body = jsonEncode({
        'error': {'message': 'invalid key'},
      });
      expect(
        () => HttpChatAiProvider.parseResponseBody(body),
        throwsA(
          isA<AiGenerationException>().having(
            (e) => e.message,
            'message',
            'Provider returned an error response.',
          ),
        ),
      );
    });

    test('parseResponseBody rejects malformed JSON', () {
      expect(
        () => HttpChatAiProvider.parseResponseBody('not json'),
        throwsA(isA<AiGenerationException>()),
      );
    });
  });
}

AiRequest _req() => const AiRequest(
  messages: <AiMessage>[AiMessage.system('sys'), AiMessage.user('hello')],
  structuredOutputVersion: aiObservationContractVersion,
);
