/// Privacy-first provider contracts for OpenGlucose AI features.
///
/// This library does not perform network I/O. Hosts must opt in to a provider
/// explicitly and disclose remote data movement before calling it.
library;

/// A single message in a chat-style exchange with an AI provider.
class AiMessage {
  const AiMessage({required this.role, required this.content});

  const AiMessage.system(this.content) : role = AiRole.system;
  const AiMessage.user(this.content) : role = AiRole.user;
  const AiMessage.assistant(this.content) : role = AiRole.assistant;

  final String role;
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

/// Why an AI request is being made.
enum AiRequestPurpose {
  /// A synthetic configuration test. It must not contain health data.
  connectionTest,

  /// A structured, evidence-bound wellness observation.
  observation,
}

/// Configuration for a chat-completion request, independent of transport.
class AiRequest {
  const AiRequest({
    required this.messages,
    this.model = 'gpt-4o-mini',
    this.temperature = 0.3,
    this.maxTokens = 512,
    this.purpose = AiRequestPurpose.observation,
    this.structuredOutputVersion,
  });

  final List<AiMessage> messages;
  final String model;
  final double temperature;
  final int maxTokens;
  final AiRequestPurpose purpose;

  /// Required contract version for a structured observation response.
  ///
  /// Connection tests intentionally leave this null, because they exchange a
  /// fixed synthetic message and never parse/store an observation.
  final int? structuredOutputVersion;

  bool get requiresStructuredOutput => purpose == AiRequestPurpose.observation;

  /// Returns a safe, configuration-level validation error, if any.
  String? validationError({AiResourceLimits? limits}) {
    if (messages.isEmpty) return 'An AI request needs at least one message.';
    if (messages.any((message) => message.content.trim().isEmpty)) {
      return 'AI request messages cannot be empty.';
    }
    if (model.trim().isEmpty) return 'An AI model identifier is required.';
    if (temperature < 0 || temperature > 1) {
      return 'AI temperature must be between 0 and 1.';
    }
    if (maxTokens < 1) return 'AI max tokens must be positive.';
    if (requiresStructuredOutput && structuredOutputVersion == null) {
      return 'Structured observations require an output contract version.';
    }
    if (limits != null && maxTokens > limits.maxOutputTokens) {
      return 'AI request exceeds the configured output-token limit.';
    }
    final contextLength = messages.fold<int>(
      0,
      (length, message) => length + message.content.length,
    );
    if (limits != null && contextLength > limits.maxContextCharacters) {
      return 'AI request exceeds the configured context limit.';
    }
    return null;
  }
}

/// A function that performs the network round-trip for a provider.
///
/// It is injected so cgm_core remains dependency-free and all provider
/// contracts are unit-testable without a network.
typedef AiTransport =
    Future<String> Function(AiRequest request, AiProviderConfig config);

/// The provider family. Native Anthropic Messages is deliberately not listed:
/// OpenGlucose currently ships only an OpenAI-compatible chat serializer.
enum AiProviderKind { disabled, onDevice, openAiCompatibleRemote }

/// Where a provider evaluates a request.
enum AiExecutionLocation { none, local, remote }

/// A reason why a provider cannot currently generate.
enum AiAvailabilityReason {
  available,
  disabledByUser,
  missingApiKey,
  invalidConfiguration,
  unsupportedProtocol,
  localRuntimeUnavailable,
  resourceLimit,
}

/// Boundaries that stop an AI request from becoming an unbounded data export.
class AiResourceLimits {
  const AiResourceLimits({
    this.maxContextCharacters = 8000,
    this.maxOutputTokens = 512,
    this.maxResponseBytes = 64 * 1024,
    this.timeout = const Duration(seconds: 30),
  });

  final int maxContextCharacters;
  final int maxOutputTokens;
  final int maxResponseBytes;
  final Duration timeout;

  String? get validationError {
    if (maxContextCharacters < 256 || maxContextCharacters > 32000) {
      return 'AI context limit must be between 256 and 32000 characters.';
    }
    if (maxOutputTokens < 32 || maxOutputTokens > 2048) {
      return 'AI output limit must be between 32 and 2048 tokens.';
    }
    if (maxResponseBytes < 1024 || maxResponseBytes > 512 * 1024) {
      return 'AI response limit must be between 1024 and 524288 bytes.';
    }
    if (timeout < const Duration(seconds: 1) ||
        timeout > const Duration(minutes: 2)) {
      return 'AI timeout must be between 1 second and 2 minutes.';
    }
    return null;
  }

  bool get isValid => validationError == null;
}

/// Explicit capability metadata for a configured provider.
///
/// The host can render this without claiming that an unavailable local model
/// exists or that a remote endpoint supports a protocol it does not implement.
class AiProviderCapability {
  const AiProviderCapability({
    required this.kind,
    required this.executionLocation,
    required this.availabilityReason,
    required this.supportsStructuredOutput,
    required this.locale,
    required this.resourceLimits,
    this.availabilityDetail,
    this.model,
    this.modelVersion,
    this.runtimeVersion = 'host-runtime-unspecified',
  });

  final AiProviderKind kind;
  final AiExecutionLocation executionLocation;
  final AiAvailabilityReason availabilityReason;
  final bool supportsStructuredOutput;
  final String locale;
  final AiResourceLimits resourceLimits;
  final String? availabilityDetail;
  final String? model;
  final String? modelVersion;

  /// Exact host runtime/OS version when the host supplies it.
  ///
  /// cgm_core cannot inspect platform state itself. A missing host value stays
  /// explicit rather than being invented.
  final String runtimeVersion;

  bool get isAvailable => availabilityReason == AiAvailabilityReason.available;

  static const AiProviderCapability disabled = AiProviderCapability(
    kind: AiProviderKind.disabled,
    executionLocation: AiExecutionLocation.none,
    availabilityReason: AiAvailabilityReason.disabledByUser,
    supportsStructuredOutput: false,
    locale: 'und',
    resourceLimits: AiResourceLimits(),
  );
}

/// Optional extension point for providers that expose capability metadata.
///
/// It is deliberately separate from [AiProvider] to keep existing provider
/// implementations source-compatible while new production providers must
/// expose truthful metadata.
abstract interface class AiCapabilityDescribingProvider {
  AiProviderCapability get capability;
}

/// Connection settings for an OpenAI-compatible BYO-key chat endpoint.
///
/// The API key must be sourced from platform secure storage by the host. It
/// must never be logged, serialized to normal preferences, or included in a
/// disclosure receipt.
class AiProviderConfig {
  const AiProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    this.model = 'gpt-4o-mini',
    this.authScheme = AiAuthScheme.bearer,
    this.locale = 'en',
    this.modelVersion,
    this.runtimeVersion = 'host-runtime-unspecified',
    this.resourceLimits = const AiResourceLimits(),
  });

  /// Base URL of an OpenAI-compatible chat endpoint, for example
  /// https://api.openai.com/v1. The transport appends /chat/completions.
  final String baseUrl;

  final String apiKey;
  final String model;

  /// Auth header used by an OpenAI-compatible gateway.
  ///
  /// x-api-key does not make this a native Anthropic Messages integration.
  final AiAuthScheme authScheme;
  final String locale;
  final String? modelVersion;
  final String runtimeVersion;
  final AiResourceLimits resourceLimits;

  bool get hasKey => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// A non-secret configuration error. It never includes the API key.
  String? get validationError {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return 'AI base URL must be an absolute HTTPS URL without credentials, '
          'query parameters, or a fragment.';
    }
    if (model.trim().isEmpty) return 'AI model identifier is required.';
    if (locale.trim().isEmpty) return 'AI locale is required.';
    return resourceLimits.validationError;
  }

  bool get isValid => validationError == null;
  bool get isReady => hasKey && isValid;

  /// The direct, no-redirect endpoint for the OpenAI-compatible serializer.
  Uri? get endpoint {
    if (!isValid) return null;
    final uri = Uri.parse(baseUrl.trim());
    var normalizedPath = uri.path;
    while (normalizedPath.endsWith('/')) {
      normalizedPath = normalizedPath.substring(0, normalizedPath.length - 1);
    }
    final endpointPath = normalizedPath.endsWith('/chat/completions')
        ? normalizedPath
        : '$normalizedPath/chat/completions';
    return uri.replace(path: endpointPath, query: null, fragment: null);
  }

  String? get endpointHostname => endpoint?.host;

  AiProviderCapability capability({
    AiAvailabilityReason? availabilityReason,
    String? availabilityDetail,
  }) {
    final reason =
        availabilityReason ??
        (isReady
            ? AiAvailabilityReason.available
            : hasKey
            ? AiAvailabilityReason.invalidConfiguration
            : AiAvailabilityReason.missingApiKey);
    return AiProviderCapability(
      kind: AiProviderKind.openAiCompatibleRemote,
      executionLocation: AiExecutionLocation.remote,
      availabilityReason: reason,
      availabilityDetail: availabilityDetail ?? validationError,
      supportsStructuredOutput: true,
      locale: locale,
      resourceLimits: resourceLimits,
      model: model,
      modelVersion: modelVersion ?? model,
      runtimeVersion: runtimeVersion,
    );
  }
}

/// The information a host must show before it sends an observation remotely.
class AiRemoteGenerationDisclosure {
  const AiRemoteGenerationDisclosure({
    required this.endpointHostname,
    required this.endpoint,
    required this.dataCategories,
  });

  final String endpointHostname;
  final String endpoint;
  final List<String> dataCategories;
}

/// How the API key is attached to an OpenAI-compatible request.
enum AiAuthScheme {
  /// Authorization: Bearer &lt;key&gt;.
  bearer,

  /// x-api-key: &lt;key&gt;, for compatible gateways that require it.
  xApiKey,
}

/// Thrown when an [AiProvider] cannot produce a completion.
class AiGenerationException implements Exception {
  const AiGenerationException(this.message);

  final String message;

  @override
  String toString() => 'AiGenerationException: $message';
}

/// The core abstraction every AI backend implements.
abstract interface class AiProvider {
  bool get isEnabled;
  String? get modelId;
  Future<String> generate(AiRequest request);
}
