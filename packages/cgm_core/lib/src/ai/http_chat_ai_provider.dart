import 'dart:convert';

import 'ai_provider.dart';

/// A BYO-key provider for an OpenAI-compatible chat-completions endpoint.
///
/// The injected transport keeps this class pure Dart and unit-testable. It is
/// the only shipped provider that can move data off-device, and it does so
/// only after the host obtains explicit user consent.
class HttpChatAiProvider implements AiProvider, AiCapabilityDescribingProvider {
  const HttpChatAiProvider({required this.config, required this.transport});

  final AiProviderConfig config;
  final AiTransport transport;

  @override
  bool get isEnabled => config.isReady;

  @override
  String? get modelId => config.model;

  @override
  AiProviderCapability get capability => config.capability();

  @override
  Future<String> generate(AiRequest request) async {
    if (!isEnabled) {
      throw const AiGenerationException(
        'The OpenAI-compatible AI provider is not configured.',
      );
    }
    final requestError = request.validationError(limits: config.resourceLimits);
    if (requestError != null) throw AiGenerationException(requestError);
    try {
      final text = await transport(request, config);
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        throw const AiGenerationException(
          'Provider returned an empty response.',
        );
      }
      return trimmed;
    } on AiGenerationException {
      rethrow;
    } catch (_) {
      // Transport errors can contain a provider response or endpoint details.
      // Keep the public exception stable and non-sensitive.
      throw const AiGenerationException('AI request failed.');
    }
  }

  /// Builds the canonical OpenAI-compatible request body.
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
      if (request.requiresStructuredOutput)
        'response_format': const <String, Object?>{'type': 'json_object'},
    };
  }

  /// Parses text from the OpenAI-compatible response shape only.
  ///
  /// Native Anthropic Messages is not implemented and is not claimed.
  static String parseResponseBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const AiGenerationException('Malformed provider response.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const AiGenerationException('Unexpected provider response shape.');
    }

    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map && message['content'] is String) {
          return message['content'] as String;
        }
        if (first['text'] is String) return first['text'] as String;
      }
    }

    final error = decoded['error'];
    if (error is Map && error['message'] is String) {
      throw const AiGenerationException('Provider returned an error response.');
    }
    throw const AiGenerationException(
      'Could not find a completion in the provider response.',
    );
  }
}
