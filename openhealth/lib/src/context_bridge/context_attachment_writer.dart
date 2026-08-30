import '../journal/fast_journal_controller.dart';
import '../journal/fast_journal_store.dart';
import 'context_attachment_fact.dart';
import 'context_bridge_models.dart';

/// Result of one transactional local context attachment attempt.
enum ContextAttachmentSaveStatus { saved, alreadyClaimed }

class ContextAttachmentSaveResult {
  const ContextAttachmentSaveResult.saved(this.entry)
    : status = ContextAttachmentSaveStatus.saved;

  const ContextAttachmentSaveResult.alreadyClaimed()
    : status = ContextAttachmentSaveStatus.alreadyClaimed,
      entry = null;

  final ContextAttachmentSaveStatus status;
  final FastJournalEntry? entry;
}

/// Repository capability for atomically writing one diary entry and one
/// bounded observation link.
///
/// It is deliberately separate from the general diary store. A context action
/// fails closed if the local repository cannot guarantee that the entry and
/// the one-time episode claim agree.
mixin ContextAttachmentWriter {
  Future<ContextAttachmentSaveResult> saveContextAttachment({
    required FastJournalEntry entry,
    required ContextAttachmentFact fact,
  });
}

/// Deterministic local coordinator for the bounded context quick-add sheet.
///
/// It owns no analytics: the bridge already qualified the supplied suggestion.
/// It validates only the explicit user-selected timing range and writes no raw
/// glucose values, source IDs, sensor identity, or causal conclusion.
class ContextAttachmentController {
  ContextAttachmentController({
    required ContextAttachmentWriter writer,
    ContextAttachmentIdFactory? entryIdFactory,
    ContextAttachmentIdFactory? factIdFactory,
  }) : _writer = writer,
       _entryIdFactory = entryIdFactory ?? _newContextAttachmentId,
       _factIdFactory = factIdFactory ?? _newContextAttachmentId;

  final ContextAttachmentWriter _writer;
  final ContextAttachmentIdFactory _entryIdFactory;
  final ContextAttachmentIdFactory _factIdFactory;

  Future<ContextAttachmentSaveResult> save({
    required FastJournalDraft draft,
    required ContextBridgeAttachmentSuggestion suggestion,
  }) {
    final occurredAt = draft.startedAt.toUtc();
    if (!suggestion.canAttachAt(occurredAt)) {
      throw FormatException(
        'The selected time is outside the allowed context range.',
      );
    }
    final entry = draft.toEntry(id: _requiredId(_entryIdFactory()));
    final fact = ContextAttachmentFact(
      id: _requiredId(_factIdFactory()),
      journalEntryId: entry.id,
      candidateId: suggestion.candidateId,
      episodeKey: suggestion.episodeKey,
      calculationVersion: suggestion.calculationVersion,
      episodeStart: suggestion.episodeStart,
      peakAt: suggestion.peakAt,
      attachmentWindowStart: suggestion.attachmentWindowStart,
      attachmentWindowEnd: suggestion.attachmentWindowEnd,
      occurredAt: entry.occurredAt,
    );
    return _writer.saveContextAttachment(entry: entry, fact: fact);
  }
}

typedef ContextAttachmentIdFactory = String Function();

var _nextContextAttachmentId = 0;

String _newContextAttachmentId() {
  _nextContextAttachmentId++;
  return 'context-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_nextContextAttachmentId';
}

String _requiredId(String value) {
  if (value.trim().isEmpty) {
    throw StateError('Local context ID factory returned an empty ID.');
  }
  return value;
}
