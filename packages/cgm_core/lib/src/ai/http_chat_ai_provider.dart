import 'dart:convert';

import 'ai_provider.dart';

/// A BYO-key [AiProvider] that talks to any OpenAI/Anthropic-compatible
/// `/chat/completions` endpoint.
///
/// The actual bytes-on-the-wire are delegated to an injected [AiTransport], so
/// this class stays pure Dart and fully unit-testable: tests pass a fake
/// transport, the app passes a real `HttpClient`-backed one. This is the *only*
/// provider that can cause data to leave the device, and only with a key the
/// user explicitly supplied.
///
/// [defaultTransport] is a self-contained transport built on `dart:io`'s
/// `HttpClient`; it is exposed so the app can use it without adding an HTTP
/// dependency, while tests stay on a fake. It is referenced lazily so this
/// library still imports cleanly on platforms without `dart:io` (callers on
/// such platforms must inject their own transport).
class HttpChatAiProvider implements AiProvider {
  const HttpChatAiProvider({required this.config, required this.transport});

  final AiProviderConfig config;
  final AiTransport transport;

  @override
  bool get isEnabled => config.hasKey;

  @override
  String? get modelId => config.model;

  @override
  Future<String> generate(AiRequest request) async {
    if (!isEnabled) {
      throw const AiGenerationException(
        'No API key/base URL configured for the AI provider.',
      );
    }
    try {
      final text = await transport(request, config);
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        throw const AiGenerationException('Provider returned an empty response.');
      }
      return trimmed;
    } on AiGenerationException {
      rethrow;
    } catch (error) {
      throw AiGenerationException('AI request failed.', cause: error);
    }
  }

  /// Builds the JSON request body for an OpenAI-compatible chat endpoint.
  ///
  /// Exposed (static) so transports and tests can share one canonical
  /// serialization rather than re-deriving the schema.
  static Map<String, Object?> buildRequestBody(
    AiRequest request,
    AiProviderConfig config,
  ) {
    return <String, Object?>{
      'model': request.model.isNotEmpty ? request.model : config.model,
      'temperature': request.temperature,
      'max_tokens': request.maxTokens,
      'messages': request.messages
          .map((message) => message.toJson())
          .toList(growable: false),
    };
  }

  /// Parses the assistant text out of an OpenAI-compatible chat response.
  ///
  /// Tolerant of both OpenAI (`choices[0].message.content`) and Anthropic
  /// (`content[0].text`) response shapes so one provider class spans both.
  /// Throws [AiGenerationException] when no text can be found.
  static String parseResponseBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (error) {
      throw AiGenerationException('Malformed provider response.', cause: error);
    }
    if (decoded is! Map<String, Object?>) {
      throw const AiGenerationException('Unexpected provider response shape.');
    }

    // OpenAI-style: { choices: [ { message: { content } } ] }
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map && message['content'] is String) {
          return message['content'] as String;
        }
        if (first['text'] is String) {
          return first['text'] as String;
        }
      }
    }

    // Anthropic-style: { content: [ { type: text, text } ] }
    final content = decoded['content'];
    if (content is List && content.isNotEmpty) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          buffer.write(part['text']);
        }
      }
      if (buffer.isNotEmpty) return buffer.toString();
    }

    // Surface a provider-reported error if present.
    final error = decoded['error'];
    if (error is Map && error['message'] is String) {
      throw AiGenerationException(
        'Provider error: ${error['message']}',
      );
    }

    throw const AiGenerationException(
      'Could not find a completion in the provider response.',
    );
  }
}
