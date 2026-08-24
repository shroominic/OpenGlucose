import 'package:flutter_test/flutter_test.dart';
import 'package:openglucose/src/context_bridge/context_attachment_fact.dart';
import 'package:openglucose/src/context_bridge/context_attachment_writer.dart';
import 'package:openglucose/src/context_bridge/context_bridge_models.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';
import 'package:openglucose/src/journal/fast_journal_store.dart';

void main() {
  final start = DateTime.utc(2026, 8, 24, 11);
  final suggestion = ContextBridgeAttachmentSuggestion(
    candidateId: ContextBridgeCandidateId(
      'ctx-candidate-aaaaaaaaaaaaaaaaaaaaaaaa',
    ),
    episodeKey: ContextBridgeEpisodeKey('ctx-episode-bbbbbbbbbbbbbbbbbbbbbbbb'),
    calculationVersion: 'recent-observed-rise-v1',
    episodeStart: start,
    peakAt: start.add(const Duration(minutes: 30)),
    attachmentWindowStart: start.subtract(const Duration(minutes: 20)),
    attachmentWindowEnd: start.add(const Duration(minutes: 45)),
    safetyBoundary:
        'A recent observed glucose rise does not identify its cause and is not medical advice.',
  );

  test('fails before writing when the selected time is outside the bound', () {
    final writer = _Writer();
    final controller = ContextAttachmentController(
      writer: writer,
      entryIdFactory: () => 'entry',
      factIdFactory: () => 'fact',
    );

    expect(
      () => controller.save(
        draft: FastJournalDraft(
          kind: FastJournalKind.activity,
          startedAt: start.add(const Duration(hours: 2)),
        ),
        suggestion: suggestion,
      ),
      throwsFormatException,
    );
    expect(writer.calls, 0);
  });

  test(
    'keeps the user-selected occurrence time in a safe local fact',
    () async {
      final writer = _Writer();
      final controller = ContextAttachmentController(
        writer: writer,
        entryIdFactory: () => 'entry',
        factIdFactory: () => 'fact',
      );
      final selected = start.subtract(const Duration(minutes: 10));

      final result = await controller.save(
        draft: FastJournalDraft(
          kind: FastJournalKind.note,
          startedAt: selected,
          label: 'private note',
        ),
        suggestion: suggestion,
      );

      expect(result.status, ContextAttachmentSaveStatus.saved);
      expect(writer.calls, 1);
      expect(writer.entry?.occurredAt, selected);
      expect(writer.fact?.occurredAt, selected);
      expect(writer.fact?.episodeKey.value, suggestion.episodeKey.value);
      expect(writer.entry?.riseReference, isNull);
    },
  );

  test('allows both disclosed attachment-window endpoints', () async {
    final writer = _Writer();
    final controller = ContextAttachmentController(
      writer: writer,
      entryIdFactory: () => 'entry-${writer.calls}',
      factIdFactory: () => 'fact-${writer.calls}',
    );

    for (final selected in <DateTime>[
      suggestion.attachmentWindowStart,
      suggestion.attachmentWindowEnd,
    ]) {
      final result = await controller.save(
        draft: FastJournalDraft(
          kind: FastJournalKind.meal,
          startedAt: selected,
        ),
        suggestion: suggestion,
      );
      expect(result.status, ContextAttachmentSaveStatus.saved);
      expect(writer.fact?.occurredAt, selected);
    }
    expect(writer.calls, 2);
  });

  test(
    'passes through a one-time claim collision without saving a second entry',
    () async {
      final writer = _Writer(
        result: const ContextAttachmentSaveResult.alreadyClaimed(),
      );
      final controller = ContextAttachmentController(
        writer: writer,
        entryIdFactory: () => 'entry',
        factIdFactory: () => 'fact',
      );

      final result = await controller.save(
        draft: FastJournalDraft(
          kind: FastJournalKind.meal,
          startedAt: start,
        ),
        suggestion: suggestion,
      );

      expect(result.status, ContextAttachmentSaveStatus.alreadyClaimed);
      expect(writer.calls, 1);
    },
  );
}

class _Writer with ContextAttachmentWriter {
  _Writer({this.result});

  final ContextAttachmentSaveResult? result;
  int calls = 0;
  FastJournalEntry? entry;
  ContextAttachmentFact? fact;

  @override
  Future<ContextAttachmentSaveResult> saveContextAttachment({
    required FastJournalEntry entry,
    required ContextAttachmentFact fact,
  }) async {
    calls++;
    this.entry = entry;
    this.fact = fact;
    return result ?? ContextAttachmentSaveResult.saved(entry);
  }
}
