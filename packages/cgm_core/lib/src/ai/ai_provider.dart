/// Privacy-first LLM provider abstraction for OpenGlucose.
///
/// The provider layer is intentionally transport-agnostic and pure Dart: it
/// describes *what* an AI request and response look like, not *how* the bytes
/// travel. The concrete network call is supplied by the host (the Flutter app)
/// as an injected [AiTransport], which keeps `cgm_core` dependency-free and
/// makes every provider trivially unit-testable with a fake transport.
///
/// ## Privacy model
/// Nothing in this library performs any network I/O on its own. The *only*
/// time the user's data leaves the device is when a [HttpChatAiProvider] is
/// configured with the user's own API key and explicitly invoked. That is a
/// deliberate, opt-in "bring your own key" (BYO-key) action. The [NullAiProvider]
/// performs no I/O at all and is the safe default when AI is disabled.
library;

/// A single message in a chat-style exchange with an LLM.
///
/// Mirrors the OpenAI/Anthropic-compatible chat schema (`role` + `content`).
class AiMessage {
  const AiMessage({required this.role, required this.content});

  /// Convenience constructor for a `system` instruction message.
  const AiMessage.system(this.content) : role = AiRole.system;

  /// Convenience constructor for a `user` message.
  const AiMessage.user(this.content) : role = AiRole.user;

  /// Convenience constructor for an `assistant` message.
  const AiMessage.assistant(this.content) : role = AiRole.assistant;

  /// One of `system`, `user`, or `assistant`.
  final String role;

  /// The message text.
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role,
    'content': content,
  };
}

/// Stable role string constants for chat messages.
abstract final class AiRole {
  static const String system = 'system';
  static const String user = 'user';
  static const String assistant = 'assistant';
}

/// Configuration for a chat-completion request, independent of transport.
class AiRequest {
  const AiRequest({
    required this.messages,
    this.model = 'gpt-4o-mini',
    this.temperature = 0.3,
    this.maxTokens = 512,
  });

  /// The ordered conversation to send to the model.
  final List<AiMessage> messages;

  /// Model identifier (e.g. `gpt-4o-mini`, `claude-3-5-haiku-latest`).
  final String model;

  /// Sampling temperature; lower is more deterministic.
  final double temperature;

  /// Upper bound on response length.
  final int maxTokens;
}

/// A function that actually performs the network round-trip for a provider.
///
/// Injecting the transport keeps `cgm_core` free of any HTTP dependency and
/// lets tests substitute a deterministic fake. Implementations should throw
/// (or complete with an error) on any failure — providers translate that into
/// an [AiGenerationException].
typedef AiTransport =
    Future<String> Function(AiRequest request, AiProviderConfig config);

/// Connection settings for a BYO-key chat provider.
///
/// The [apiKey] is supplied by the user and must be sourced from secure
/// storage by the host app — never hard-coded or logged.
class AiProviderConfig {
  const AiProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    this.model = 'gpt-4o-mini',
    this.authScheme = AiAuthScheme.bearer,
  });

  /// Base URL of an OpenAI/Anthropic-compatible chat endpoint, e.g.
  /// `https://api.openai.com/v1`. The provider appends `/chat/completions`.
  final String baseUrl;

  /// The user's own API key (BYO-key). Held only in memory for the call.
  final String apiKey;

  /// Default model used when an [AiRequest] does not override it.
  final String model;

  /// How the [apiKey] is presented to the endpoint.
  final AiAuthScheme authScheme;

  bool get hasKey => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}

/// How the API key is attached to outbound requests.
enum AiAuthScheme {
  /// `Authorization: Bearer <key>` (OpenAI-compatible).
  bearer,

  /// `x-api-key: <key>` (Anthropic-compatible).
  xApiKey,
}

/// Thrown when an [AiProvider] cannot produce a completion.
///
/// Wraps the underlying cause so callers (e.g. the insight service) can fail
/// gracefully — log it, surface a message, and crucially *not crash*.
class AiGenerationException implements Exception {
  const AiGenerationException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'AiGenerationException: $message'
      : 'AiGenerationException: $message (cause: $cause)';
}

/// The core abstraction every AI backend implements.
///
/// Deliberately tiny: given a request, return text (or throw
/// [AiGenerationException]). [isEnabled] lets callers cheaply branch on whether
/// AI is configured without attempting a doomed call.
abstract interface class AiProvider {
  /// Whether this provider is configured and able to generate.
  bool get isEnabled;

  /// A human/log-friendly identifier of the active model, if any.
  String? get modelId;

  /// Generates a completion for [request], or throws [AiGenerationException].
  Future<String> generate(AiRequest request);
}
