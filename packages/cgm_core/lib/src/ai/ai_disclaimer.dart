/// Wellness/self-experimentation disclaimers attached to every AI artifact.
///
/// OpenGlucose is a wellness and self-experimentation tool, **not** an
/// FDA-cleared / CE-marked medical device. AI output describes patterns and
/// observations only — it must never read as medical advice, diagnosis, or
/// dosing guidance. These constants are the single source of truth used by the
/// prompt (to constrain the model) and by the persisted insight (so the
/// disclaimer travels with the data and shows in the UI).
abstract final class AiDisclaimer {
  /// Short tag stored on every generated [AiInsight] and shown in the UI.
  static const String short =
      'Wellness & self-experimentation only — not medical advice. '
      'Patterns/observations, not diagnosis or dosing.';

  /// System-prompt guardrail injected ahead of every generation so the model
  /// stays within wellness framing and never emits medical claims.
  static const String systemGuardrail =
      'You are a wellness and self-experimentation assistant for an '
      'open-source, local-first glucose-monitoring app. You describe patterns '
      'and observations in the user\'s own data to support self-experimentation. '
      'You are NOT a doctor. NEVER give medical advice, diagnoses, treatment, '
      'or insulin/medication dosing. Do not mention specific diseases as '
      'conclusions. Use cautious, non-prescriptive language ("you might '
      'notice", "one pattern is"). If asked for medical or dosing guidance, '
      'decline and suggest consulting a healthcare professional. Keep responses '
      'concise and grounded only in the summary statistics provided.';

  /// Tag value used in [AiInsight.tags] to mark wellness-framed insights, so
  /// the UI can assert the disclaimer is present before rendering.
  static const String tag = 'wellness-disclaimer';
}
