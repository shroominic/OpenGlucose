import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'context_bridge/context_attachment_writer.dart';
import 'context_bridge/context_bridge.dart';
import 'context_bridge/context_bridge_models.dart';
import 'context_timeline/compact_context_timeline.dart';
import 'context_timeline/context_bridge_timeline_adapter.dart';
import 'journal/fast_journal_controller.dart';
import 'journal/fast_journal_store.dart';

/// Full-height, opt-in local context reader.
///
/// The route reads only the bridge cache. It does not start an Apple Health
/// import, background work, an AI request, or a direct repository query.
class ContextViewScreen extends StatelessWidget {
  const ContextViewScreen({super.key, required this.bridge});

  final ContextBridge bridge;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: bridge,
    builder: (context, _) {
      final snapshot = bridge.snapshot;
      final now = snapshot.refreshedAt ?? snapshot.window.end;
      return Scaffold(
        appBar: AppBar(title: const Text('Glucose with context')),
        body: SafeArea(
          top: false,
          child: ListView(
            key: const ValueKey<String>('contextViewScroll'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: <Widget>[
              if (snapshot.loadState == ContextBridgeLoadState.loading)
                Semantics(
                  liveRegion: true,
                  label: 'Refreshing local context',
                  child: LinearProgressIndicator(),
                ),
              if (snapshot.loadState == ContextBridgeLoadState.loading)
                const SizedBox(height: 12),
              CompactContextTimeline(
                key: const ValueKey<String>('contextViewTimeline'),
                source: ContextBridgeTimelineAdapter(snapshot).call,
                now: now,
                initiallyExpanded: true,
                presentation: ContextTimelinePresentation.fullScreen,
                // Heart-rate context is deliberately held for a later, focused
                // visual surface. It does not take space in this first lane.
                showHeartRate: false,
              ),
              const SizedBox(height: 20),
              Text(
                'Events show timing and observations only. They do not identify a cause or provide medical guidance.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF5B6E6A),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens the bounded local add flow for one bridge-qualified observation.
///
/// `true` means an entry and its one-time observation link were saved in the
/// same local transaction. It returns `false` for cancellation or an already
/// claimed episode, and never starts a platform import.
Future<bool> showContextAttachmentSheet({
  required BuildContext context,
  required ContextBridgeAttachmentSuggestion suggestion,
  required Future<ContextBridgeAttachmentPreparation> Function(
    ContextBridgeAttachmentSuggestion expected,
  )
  prepareContextAttachmentSave,
  required Future<void> Function() refreshContext,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ContextAttachmentSheet(
      suggestion: suggestion,
      prepareContextAttachmentSave: prepareContextAttachmentSave,
      refreshContext: refreshContext,
    ),
  );
  return saved ?? false;
}

class _ContextAttachmentSheet extends StatefulWidget {
  const _ContextAttachmentSheet({
    required this.suggestion,
    required this.prepareContextAttachmentSave,
    required this.refreshContext,
  });

  final ContextBridgeAttachmentSuggestion suggestion;
  final Future<ContextBridgeAttachmentPreparation> Function(
    ContextBridgeAttachmentSuggestion expected,
  )
  prepareContextAttachmentSave;
  final Future<void> Function() refreshContext;

  @override
  State<_ContextAttachmentSheet> createState() =>
      _ContextAttachmentSheetState();
}

class _ContextAttachmentSheetState extends State<_ContextAttachmentSheet> {
  final TextEditingController _labelController = TextEditingController();
  late DateTime _occurredAt = widget.suggestion.episodeStart.toLocal();
  FastJournalKind _kind = FastJournalKind.meal;
  var _saving = false;
  String? _error;

  bool get _canAttach => widget.suggestion.canAttachAt(_occurredAt);

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _chooseTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      // Keep exactly the time the user selects. Never snap it to an observed
      // glucose time; crossing the disclosed bounds simply detaches it.
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _error = null;
    });
  }

  Future<void> _save() async {
    if (!_canAttach || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final preparation = await widget.prepareContextAttachmentSave(
        widget.suggestion,
      );
      if (!mounted) return;
      if (preparation.status ==
          ContextBridgeAttachmentPreparationStatus.alreadyClaimed) {
        await _refreshAfterLocalDecision();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Context was already added for this recent observation.',
            ),
          ),
        );
        Navigator.of(context).pop(false);
        return;
      }
      if (preparation.status ==
          ContextBridgeAttachmentPreparationStatus.staleOrSuperseded) {
        await _refreshAfterLocalDecision();
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error =
              'This recent observation is no longer current. No diary entry was saved.';
        });
        return;
      }
      final save = preparation.save;
      if (!preparation.isReady ||
          save == null ||
          preparation.suggestion == null) {
        throw StateError('Local context attachment is unavailable.');
      }
      final result = await save(
        FastJournalDraft(
          kind: _kind,
          startedAt: _occurredAt,
          label: _labelController.text,
        ),
      );
      // The local entry/fact transaction is authoritative. A later cache
      // refresh must not turn a completed save into a false failure message.
      await _refreshAfterLocalDecision();
      if (!mounted) return;
      if (result.status == ContextAttachmentSaveStatus.alreadyClaimed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Context was already added for this recent observation.',
            ),
          ),
        );
        Navigator.of(context).pop(false);
        return;
      }
      Navigator.of(context).pop(true);
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message.toString();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'This local context could not be saved. Your diary was not changed.';
      });
    }
  }

  Future<void> _refreshAfterLocalDecision() async {
    try {
      await widget.refreshContext();
    } catch (_) {
      // The bridge owns its unavailable state. A completed local decision
      // remains truthful even when a later cache refresh cannot complete.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final limit = _formatWindow(
      widget.suggestion.attachmentWindowStart,
      widget.suggestion.attachmentWindowEnd,
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottomInset),
        child: SingleChildScrollView(
          key: const ValueKey<String>('contextAttachmentScroll'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Add context to recent rise',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Record a meal or activity in the time window around this observation.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF5B6E6A),
                ),
              ),
              const SizedBox(height: 14),
              Semantics(
                container: true,
                label: 'Allowed local time range: $limit',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      'Allowed time: $limit',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _KindPicker(
                selected: _kind,
                enabled: !_saving,
                onChanged: (kind) => setState(() => _kind = kind),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _labelController,
                enabled: !_saving,
                maxLength: 160,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Optional private label',
                  hintText: 'Saved only in your local diary',
                ),
              ),
              TextButton.icon(
                key: const ValueKey<String>('contextAttachmentChooseTime'),
                onPressed: _saving ? null : _chooseTime,
                icon: const Icon(Icons.schedule_rounded),
                label: Text(
                  'When: ${DateFormat('MMM d · HH:mm').format(_occurredAt)}',
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.suggestion.safetyBoundary,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF5B6E6A),
                ),
              ),
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _canAttach
                        ? 'This time is within the allowed local range.'
                        : 'This time is outside the allowed range. It is not linked to this observation. Move it back into range or add it from Diary.',
                    style: TextStyle(
                      color: _canAttach
                          ? const Color(0xFF365951)
                          : const Color(0xFF8A3D31),
                    ),
                  ),
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFB24A3B)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _saving || !_canAttach ? null : _save,
                  child: Text(
                    _saving
                        ? 'Saving…'
                        : _canAttach
                        ? 'Save context'
                        : 'Time outside allowed range',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindPicker extends StatelessWidget {
  const _KindPicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final FastJournalKind selected;
  final bool enabled;
  final ValueChanged<FastJournalKind> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children:
        <FastJournalKind>[
              FastJournalKind.meal,
              FastJournalKind.activity,
            ]
            .map(
              (kind) => ChoiceChip(
                key: ValueKey<String>('contextAttachmentKind-${kind.name}'),
                label: Text(kind.label),
                selected: selected == kind,
                onSelected: enabled ? (_) => onChanged(kind) : null,
              ),
            )
            .toList(growable: false),
  );
}

String _formatWindow(DateTime start, DateTime end) {
  final formatter = DateFormat('d MMM · HH:mm');
  final first = formatter.format(start.toLocal());
  final last = formatter.format(end.toLocal());
  return start.toUtc().isAtSameMomentAs(end.toUtc()) ? first : '$first – $last';
}
