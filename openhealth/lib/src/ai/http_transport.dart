import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';

/// A concrete [AiTransport] for [HttpChatAiProvider], built on `dart:io`'s
/// [HttpClient] so the app needs no extra HTTP dependency.
///
/// This is the single place in the app that makes the outbound, user-opted-in
/// BYO-key request. It POSTs an OpenAI/Anthropic-compatible chat-completions
/// body and returns the parsed assistant text. All failures surface as
/// [AiGenerationException] so callers never crash.
class HttpAiTransport {
  HttpAiTransport({Duration? timeout})
    : _timeout = timeout ?? const Duration(seconds: 30);

  final Duration _timeout;

  /// The injectable transport function passed to [HttpChatAiProvider].
  AiTransport get call => _send;

  Future<String> _send(AiRequest request, AiProviderConfig config) async {
    final uri = _resolveEndpoint(config.baseUrl);
    final body = HttpChatAiProvider.buildRequestBody(request, config);

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final httpRequest = await client
          .postUrl(uri)
          .timeout(_timeout);
      httpRequest.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json',
      );
      switch (config.authScheme) {
        case AiAuthScheme.bearer:
          httpRequest.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${config.apiKey}',
          );
        case AiAuthScheme.xApiKey:
          httpRequest.headers.set('x-api-key', config.apiKey);
          httpRequest.headers.set('anthropic-version', '2023-06-01');
      }
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final response = await httpRequest.close().timeout(_timeout);
      final responseBody =
          await response.transform(utf8.decoder).join().timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Try to surface the provider's error message, else the status.
        try {
          return HttpChatAiProvider.parseResponseBody(responseBody);
        } catch (_) {
          throw AiGenerationException(
            'Provider returned HTTP ${response.statusCode}.',
          );
        }
      }
      return HttpChatAiProvider.parseResponseBody(responseBody);
    } on AiGenerationException {
      rethrow;
    } on TimeoutException catch (error) {
      throw AiGenerationException('AI request timed out.', cause: error);
    } catch (error) {
      throw AiGenerationException('AI request failed.', cause: error);
    } finally {
      client.close(force: true);
    }
  }

  static Uri _resolveEndpoint(String baseUrl) {
    var normalized = baseUrl.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    // Allow callers to pass either a base (…/v1) or the full path.
    final path = normalized.endsWith('/chat/completions')
        ? normalized
        : '$normalized/chat/completions';
    return Uri.parse(path);
  }
}
