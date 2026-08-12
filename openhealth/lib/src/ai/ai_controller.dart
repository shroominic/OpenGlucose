import 'package:cgm_core/cgm_core.dart';

import 'ai_settings.dart';
import 'ai_settings_store.dart';
import 'http_transport.dart';

/// Wires persisted [AiSettings] + the secure BYO API key into a concrete
/// [AiProvider] and a ready-to-use [InsightService].
///
/// This is the app-side glue between the privacy-first `cgm_core` AI foundation
/// and the on-device data: it keeps the key in memory only for the duration of
/// building a provider, and returns a [NullAiProvider] whenever AI is disabled
/// or no key is set — so the disabled path provably performs no network I/O.
class AiController {
  AiController({
    required AiSettingsStore store,
    required HealthRepository repository,
    HttpAiTransport? transport,
  }) : _store = store,
       _repository = repository,
       _transport = transport ?? HttpAiTransport();

  final AiSettingsStore _store;
  final HealthRepository _repository;
  final HttpAiTransport _transport;

  AiSettings get settings => _store.loadSettings();

  Future<bool> hasApiKey() => _store.hasApiKey();

  /// Builds the active provider from current settings + secure key.
  ///
  /// Returns a [NullAiProvider] when AI is disabled or no key is present.
  Future<AiProvider> buildProvider() async {
    final settings = _store.loadSettings();
    if (!settings.enabled) return const NullAiProvider();
    final key = await _store.readApiKey();
    if (key == null || key.trim().isEmpty) return const NullAiProvider();

    return HttpChatAiProvider(
      config: AiProviderConfig(
        baseUrl: settings.baseUrl,
        apiKey: key,
        model: settings.model,
        authScheme: settings.authScheme,
      ),
      transport: _transport.call,
    );
  }

  /// Builds an [InsightService] bound to the active provider and the local
  /// repository.
  Future<InsightService> buildInsightService() async {
    final provider = await buildProvider();
    return InsightService(repository: _repository, provider: provider);
  }

  /// Generates an insight over the last [window] of [readings], returning the
  /// persisted [AiInsight] (or `null` when AI is disabled). Throws
  /// [AiGenerationException] on failure — callers should catch and surface it.
  Future<AiInsight?> generateRecentInsight({
    required List<CgmReading> readings,
    Duration window = const Duration(hours: 24),
    GlucoseUnit unit = GlucoseUnit.mgdl,
    DateTime? now,
  }) async {
    final service = await buildInsightService();
    final end = now ?? DateTime.now();
    return service.generateSummaryInsight(
      readings: readings,
      windowStart: end.subtract(window),
      windowEnd: end,
      unit: unit,
    );
  }
}
