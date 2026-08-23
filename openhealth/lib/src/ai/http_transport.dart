import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cgm_core/cgm_core.dart';

/// A concrete [AiTransport] for [HttpChatAiProvider], built on `dart:io`'s
/// [HttpClient] so the app needs no extra HTTP dependency.
///
/// This is the single place in the app that makes the outbound, user-opted-in
/// BYO-key request. It POSTs an OpenAI-compatible chat-completions
/// body and returns the parsed assistant text. All failures surface as
/// [AiGenerationException] so callers never crash.
class HttpAiTransport {
  HttpAiTransport({Duration? timeout}) : _timeoutOverride = timeout;

  final Duration? _timeoutOverride;

  /// The injectable transport function passed to [HttpChatAiProvider].
  AiTransport get call => _send;

  Future<String> _send(AiRequest request, AiProviderConfig config) async {
    final uri = config.endpoint;
    if (uri == null) {
      throw AiGenerationException(
        config.validationError ?? 'AI provider configuration is invalid.',
      );
    }
    final timeout = _timeoutOverride ?? config.resourceLimits.timeout;
    final body = HttpChatAiProvider.buildRequestBody(request, config);

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final httpRequest = await client.postUrl(uri).timeout(timeout);
      // A redirect could forward the API key and health summary to a different
      // origin. Provider endpoints are therefore required to answer directly.
      httpRequest.followRedirects = false;
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
      }
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final response = await httpRequest.close().timeout(timeout);
      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiGenerationException(_providerErrorMessage(response.statusCode));
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

  static String _providerErrorMessage(int statusCode) =>
      'Provider returned HTTP $statusCode.';
}
