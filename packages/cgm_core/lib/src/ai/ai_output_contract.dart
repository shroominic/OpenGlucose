import 'ai_disclaimer.dart';
import 'ai_provider.dart';

/// Validates model text before it becomes a persisted wellness artifact.
///
/// Providers return free-form text for compatibility with local and remote
/// models. This boundary keeps that text from silently becoming medical
/// guidance: the service rejects explicit advice/diagnosis language and
/// always attaches the typed local evidence plus [AiDisclaimer.short] to the
/// persisted insight.
abstract final class AiOutputContract {
  /// The short contract included in every user prompt.
  static const String promptContract =
      'Output contract: write 2-4 concise observations only. Ground every '
      'statement in the evidence labels supplied below; do not invent '
      'measurements or causal explanations. Use tentative language such as '
      '"you might notice" or "one pattern to explore". Do not give medical '
      'advice, diagnosis, treatment, emergency guidance, or glucose/insulin/'
      'medication dosing.';

  /// Trims and validates provider text. Throws when the output is empty or
  /// contains an explicit unsafe instruction/claim.
  static String validate(String output) {
    final text = output.trim();
    if (text.isEmpty) {
      throw const AiGenerationException('AI returned an empty response.');
    }
    final normalized = text.toLowerCase();
    for (final pattern in _unsafePatterns) {
      if (normalized.contains(pattern)) {
        throw const AiGenerationException(
          'AI response did not meet the wellness safety contract.',
        );
      }
    }
    return text;
  }

  static const List<String> _unsafePatterns = <String>[
    'you have diabetes',
    'you have hypoglycemia',
    'you have hyperglycemia',
    'you are diabetic',
    'diagnose you',
    'your diagnosis',
    'take insulin',
    'increase insulin',
    'decrease insulin',
    'adjust your insulin',
    'change your insulin',
    'take more medication',
    'take less medication',
    'change your medication',
    'call 911',
    'go to the emergency room',
  ];
}
