import 'ai_provider.dart';

/// A no-op [AiProvider] used when AI insights are disabled.
///
/// It never performs any I/O and never sends data anywhere — it simply reports
/// [isEnabled] as `false` and throws if asked to generate. This is the safe
/// default: with AI off, the user's data provably cannot leave the device.
class NullAiProvider implements AiProvider, AiCapabilityDescribingProvider {
  const NullAiProvider({
    this.reason = AiAvailabilityReason.disabledByUser,
    this.detail,
  });

  final AiAvailabilityReason reason;
  final String? detail;

  @override
  bool get isEnabled => false;

  @override
  String? get modelId => null;

  @override
  AiProviderCapability get capability => AiProviderCapability(
    kind: AiProviderKind.disabled,
    executionLocation: AiExecutionLocation.none,
    availabilityReason: reason,
    availabilityDetail: detail,
    supportsStructuredOutput: false,
    locale: 'und',
    resourceLimits: const AiResourceLimits(),
  );

  @override
  Future<String> generate(AiRequest request) {
    throw const AiGenerationException(
      'AI insights are disabled. Enable them and add an API key in Settings.',
    );
  }
}
