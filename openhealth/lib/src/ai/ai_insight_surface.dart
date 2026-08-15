import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

/// The lifecycle of the optional Today AI surface.
enum AiInsightSurfaceStatus { disabled, empty, loading, ready, error }

/// Immutable state used by [AiInsightSurface] and easy to assert in tests.
class AiInsightSurfaceState {
  const AiInsightSurfaceState({
    required this.status,
    this.insight,
    this.observations = const <MetabolicObservation>[],
    this.errorMessage,
  });

  final AiInsightSurfaceStatus status;
  final AiInsight? insight;
  final List<MetabolicObservation> observations;
  final String? errorMessage;

  bool get hasEvidence =>
      observations.any((observation) => observation.isEvidenceBacked);
}

/// Presentation/controller seam for the opt-in AI product layer.
///
/// This controller never creates a provider and never starts network work on
/// its own. The optional [generate] callback is invoked only after the user
/// taps an explicit generate/retry action. The callback should be wired to the
/// app's existing AI controller when cloud AI is enabled; leaving it null is
/// a safe, local-only configuration.
class AiInsightSurfaceController extends ChangeNotifier {
  AiInsightSurfaceController({
    bool enabled = false,
    List<MetabolicObservation> observations = const <MetabolicObservation>[],
    AiInsight? insight,
    Future<AiInsight?> Function()? generate,
  }) : _enabled = enabled,
       _observations = List<MetabolicObservation>.unmodifiable(observations),
       _insight = insight,
       _generate = generate,
       _state = _initialState(
         enabled: enabled,
         observations: observations,
         insight: insight,
       );

  bool _enabled;
  List<MetabolicObservation> _observations;
  AiInsight? _insight;
  Future<AiInsight?> Function()? _generate;
  AiInsightSurfaceState _state;

  AiInsightSurfaceState get state => _state;
  bool get enabled => _enabled;

  /// Replaces the explicit generator seam without invoking it.
  // ignore: use_setters_to_change_properties
  void setGenerator(Future<AiInsight?> Function()? generate) {
    _generate = generate;
  }

  /// Updates the opt-in gate. AI is disabled by default and disabling it clears
  /// any transient error/loading state while retaining local observations.
  set enabled(bool enabled) {
    if (_enabled == enabled &&
        (_state.status != AiInsightSurfaceStatus.loading || enabled)) {
      return;
    }
    _enabled = enabled;
    _state = enabled
        ? _stateForEnabled()
        : AiInsightSurfaceState(
            status: AiInsightSurfaceStatus.disabled,
            observations: _observations,
          );
    notifyListeners();
  }

  /// Supplies fresh deterministic observations from the local engine.
  void setObservations(Iterable<MetabolicObservation> observations) {
    _observations = List<MetabolicObservation>.unmodifiable(observations);
    _state = _enabled
        ? _stateForEnabled()
        : AiInsightSurfaceState(
            status: AiInsightSurfaceStatus.disabled,
            observations: _observations,
          );
    notifyListeners();
  }

  /// Restores a locally persisted insight without triggering generation.
  void setInsight(AiInsight? insight) {
    _insight = insight;
    _state = _enabled
        ? _stateForEnabled()
        : AiInsightSurfaceState(
            status: AiInsightSurfaceStatus.disabled,
            observations: _observations,
          );
    notifyListeners();
  }

  /// Runs the explicitly supplied generation callback.
  ///
  /// A missing callback is treated as an unavailable feature rather than a
  /// crash. Errors are intentionally reduced to user-safe text; no exception
  /// or provider response is logged by this presentation layer.
  Future<void> generate() async {
    if (!_enabled) {
      _state = AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.disabled,
        observations: _observations,
      );
      notifyListeners();
      return;
    }
    final generator = _generate;
    if (generator == null) {
      _state = AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.error,
        observations: _observations,
        errorMessage: 'AI generation is not configured yet.',
      );
      notifyListeners();
      return;
    }

    _state = AiInsightSurfaceState(
      status: AiInsightSurfaceStatus.loading,
      insight: _insight,
      observations: _observations,
    );
    notifyListeners();

    try {
      final insight = await generator();
      _insight = insight;
      _state = insight == null
          ? _stateForEnabled()
          : AiInsightSurfaceState(
              status: AiInsightSurfaceStatus.ready,
              insight: insight,
              observations: _observations,
            );
    } on AiGenerationException catch (error) {
      _state = AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.error,
        insight: _insight,
        observations: _observations,
        errorMessage: _safeError(error.message),
      );
    } catch (_) {
      _state = AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.error,
        insight: _insight,
        observations: _observations,
        errorMessage: 'Could not create the insight. Try again later.',
      );
    }
    notifyListeners();
  }

  AiInsightSurfaceState _stateForEnabled() {
    if (_insight != null) {
      return AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.ready,
        insight: _insight,
        observations: _observations,
      );
    }
    return AiInsightSurfaceState(
      status: AiInsightSurfaceStatus.empty,
      observations: _observations,
    );
  }

  static AiInsightSurfaceState _initialState({
    required bool enabled,
    required List<MetabolicObservation> observations,
    required AiInsight? insight,
  }) {
    if (!enabled) {
      return AiInsightSurfaceState(
        status: AiInsightSurfaceStatus.disabled,
        observations: List<MetabolicObservation>.unmodifiable(observations),
      );
    }
    return insight == null
        ? AiInsightSurfaceState(
            status: AiInsightSurfaceStatus.empty,
            observations: List<MetabolicObservation>.unmodifiable(observations),
          )
        : AiInsightSurfaceState(
            status: AiInsightSurfaceStatus.ready,
            insight: insight,
            observations: List<MetabolicObservation>.unmodifiable(observations),
          );
  }
}

/// Compact Today-facing rendering of an optional AI insight.
///
/// The card only renders bounded evidence labels and sanitized model text. It
/// never displays journal/note bodies, API keys, or turns a model response
/// into an alert, diagnosis, or dosing instruction.
class AiInsightSurface extends StatelessWidget {
  const AiInsightSurface({
    super.key,
    required this.controller,
    this.onEnable,
    this.onGenerate,
  });

  final AiInsightSurfaceController controller;
  final VoidCallback? onEnable;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildState(context, controller.state),
    );
  }

  Widget _buildState(BuildContext context, AiInsightSurfaceState state) {
    return Card(
      key: const ValueKey<String>('aiInsightSurface'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: switch (state.status) {
          AiInsightSurfaceStatus.disabled => _DisabledState(onEnable: onEnable),
          AiInsightSurfaceStatus.empty => _EmptyState(
            hasEvidence: state.hasEvidence,
            onGenerate: onGenerate,
          ),
          AiInsightSurfaceStatus.loading => const _LoadingState(),
          AiInsightSurfaceStatus.error => _ErrorState(
            message: state.errorMessage ?? 'Could not create the insight.',
            onGenerate: onGenerate,
          ),
          AiInsightSurfaceStatus.ready => _ReadyState(
            insight: state.insight!,
            observations: state.observations,
          ),
        },
      ),
    );
  }
}

class _DisabledState extends StatelessWidget {
  const _DisabledState({this.onEnable});

  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.auto_awesome_outlined, color: Color(0xFF0B6E69)),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'AI insights are off',
                style: TextStyle(
                  color: Color(0xFF183C3B),
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Turn them on in Settings to explore evidence-backed patterns. '
                'Nothing leaves this device while they are off.',
                style: TextStyle(color: Color(0xFF49615D), height: 1.3),
              ),
            ],
          ),
        ),
        if (onEnable != null)
          TextButton(
            key: const ValueKey<String>('aiInsightEnableButton'),
            onPressed: onEnable,
            child: const Text('Enable'),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasEvidence, this.onGenerate});

  final bool hasEvidence;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.auto_awesome_outlined, color: Color(0xFF0B6E69)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            hasEvidence
                ? 'Your local evidence is ready for an optional insight.'
                : 'AI insights need a little more data',
            style: const TextStyle(color: Color(0xFF49615D), height: 1.3),
          ),
        ),
        if (onGenerate != null)
          TextButton(
            key: const ValueKey<String>('aiInsightGenerateButton'),
            onPressed: onGenerate,
            child: const Text('Explore'),
          ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        SizedBox(
          key: ValueKey<String>('aiInsightLoadingIndicator'),
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Preparing an evidence-backed insight…',
            style: TextStyle(color: Color(0xFF49615D)),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, this.onGenerate});

  final String message;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.info_outline_rounded, color: Color(0xFF9A4D00)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            key: const ValueKey<String>('aiInsightErrorMessage'),
            style: const TextStyle(color: Color(0xFF6B5542), height: 1.3),
          ),
        ),
        if (onGenerate != null)
          TextButton(
            key: const ValueKey<String>('aiInsightRetryButton'),
            onPressed: onGenerate,
            child: const Text('Retry'),
          ),
      ],
    );
  }
}

class _ReadyState extends StatelessWidget {
  const _ReadyState({required this.insight, required this.observations});

  final AiInsight insight;
  final List<MetabolicObservation> observations;

  @override
  Widget build(BuildContext context) {
    final evidence = insight.evidence.isNotEmpty
        ? insight.evidence
        : observations
              .expand((observation) => observation.evidence)
              .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.auto_awesome_rounded, color: Color(0xFF0B6E69)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'A pattern to explore',
                style: TextStyle(
                  color: Color(0xFF183C3B),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            if (insight.model != null)
              const Text(
                'AI',
                style: TextStyle(
                  color: Color(0xFF5B6E6A),
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _redactSensitiveText(insight.title),
          key: const ValueKey<String>('aiInsightTitle'),
          style: const TextStyle(
            color: Color(0xFF183C3B),
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          _redactSensitiveText(insight.body),
          key: const ValueKey<String>('aiInsightBody'),
          style: const TextStyle(color: Color(0xFF49615D), height: 1.35),
        ),
        if (evidence.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: evidence
                .take(3)
                .map(
                  (item) => Chip(
                    label: Text(_evidenceLabel(item)),
                    visualDensity: VisualDensity.compact,
                  ),
                )
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: 10),
        const Text(
          'Wellness only—not medical advice, diagnosis, alerts, or dosing.',
          key: ValueKey<String>('aiInsightSafetyBoundary'),
          style: TextStyle(color: Color(0xFF49615D), fontSize: 12, height: 1.3),
        ),
      ],
    );
  }

  String _evidenceLabel(ObservationEvidence evidence) {
    final value = evidence.value == null
        ? 'n/a'
        : evidence.value!.toStringAsFixed(evidence.unit == '%' ? 1 : 0);
    final unit = evidence.unit == null ? '' : ' ${evidence.unit}';
    return '${_redactSensitiveText(evidence.label)} · $value$unit';
  }
}

String _safeError(String message) {
  final cleaned = _redactSensitiveText(message).trim();
  return cleaned.isEmpty
      ? 'Could not create the insight. Try again later.'
      : cleaned;
}

/// Removes likely journal lines and common secret-shaped strings before model
/// output reaches the UI. Raw note bodies are never part of the prompt, but
/// this defense-in-depth boundary also protects against an over-sharing model.
String _redactSensitiveText(String text) {
  var sanitized = text;
  sanitized = sanitized.replaceAll(
    RegExp(
      r'^\s*(?:note|journal|memo|comment|text)\s*[:\-].*$',
      multiLine: true,
      caseSensitive: false,
    ),
    '[Journal text hidden]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\b(?:sk|rk)-[A-Za-z0-9_-]{8,}\b'),
    '[secret hidden]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{8,}\b', caseSensitive: false),
    'Bearer [secret hidden]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', caseSensitive: false),
    '[email hidden]',
  );
  return sanitized;
}
