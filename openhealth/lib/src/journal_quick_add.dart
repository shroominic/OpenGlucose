import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'persistence/health_store.dart';

/// Lazily creates a local journal service for one foreground save.
///
/// The app opens the protected repository only after the user taps Save. Tests
/// inject an in-memory repository through this seam; no network client or
/// background delivery is involved.
typedef JournalServiceFactory = Future<JournalService> Function();

/// Creates the production journal service backed by the protected local store.
Future<JournalService> defaultJournalServiceFactory() async {
  final repository = await openHealthRepository();
  return JournalService(repository: repository);
}

/// Small state holder shared by the quick-add sheet and Today cockpit.
///
/// A controller owns one bounded foreground operation at a time, exposes a
/// local today count after a save, and never retains a repository connection.
class JournalQuickAddController extends ChangeNotifier {
  JournalQuickAddController({
    required JournalServiceFactory serviceFactory,
    DateTime Function()? now,
  }) : _serviceFactory = serviceFactory,
       _now = now ?? DateTime.now;

  final JournalServiceFactory _serviceFactory;
  final DateTime Function() _now;

  bool _busy = false;
  int? _todayEventCount;
  String? _latestSummary;
  String? _error;

  bool get busy => _busy;
  int? get todayEventCount => _todayEventCount;
  String? get latestSummary => _latestSummary;
  String? get error => _error;

  String? get summaryText {
    final count = _todayEventCount;
    if (count == null) return null;
    return '$count ${count == 1 ? 'journal entry' : 'journal entries'} today';
  }

  Future<HealthEvent?> saveMeal({
    required String description,
    double? carbsGrams,
  }) => _run(
    (service, at) => service.logMeal(
      at: at,
      description: description,
      carbsGrams: carbsGrams,
    ),
  );

  Future<HealthEvent?> saveExercise({
    required String activity,
    Duration? duration,
  }) => _run(
    (service, at) => service.logExercise(
      at: at,
      activity: activity,
      duration: duration,
    ),
  );

  Future<HealthEvent?> saveNote({required String text}) =>
      _run((service, at) => service.logNote(at: at, text: text));

  Future<HealthEvent?> _run(
    Future<HealthEvent> Function(JournalService service, DateTime at) save,
  ) async {
    if (_busy) return null;
    _busy = true;
    _error = null;
    notifyListeners();
    JournalService? service;
    try {
      service = await _serviceFactory();
      await service.init();
      final at = _now().toUtc();
      final event = await save(service, at);
      final context = await service.loadContextForDay(at);
      _todayEventCount = context.events.length;
      _latestSummary = journalEventSummary(event);
      notifyListeners();
      return event;
    } on Object catch (error) {
      _error = error is FormatException
          ? error.message
          : 'Could not save this entry locally. Try again.';
      notifyListeners();
      return null;
    } finally {
      try {
        await service?.close();
      } on Object {
        // A failed close must not turn a completed local save into a UI error.
      }
      _busy = false;
      notifyListeners();
    }
  }
}

String journalEventSummary(HealthEvent event) {
  return switch (event.payload) {
    MealPayload(:final description?) when description.trim().isNotEmpty =>
      'Meal: ${description.trim()}',
    ExercisePayload(:final activity?) when activity.trim().isNotEmpty =>
      'Exercise: ${activity.trim()}',
    NotePayload(:final text) => 'Note: ${text.trim()}',
    MealPayload() => 'Meal',
    ExercisePayload() => 'Exercise',
    _ => event.type.name,
  };
}

enum _JournalQuickAddKind { meal, exercise, note }

/// Compact sheet for the three user-authored context types supported today.
class JournalQuickAddSheet extends StatefulWidget {
  const JournalQuickAddSheet({
    super.key,
    this.controller,
    this.serviceFactory,
    this.now,
    this.onSaved,
    this.closeOnSave = false,
  });

  /// A controller may be shared with Today cockpit for the local count.
  final JournalQuickAddController? controller;

  /// Convenience injection seam when no controller is supplied.
  final JournalServiceFactory? serviceFactory;
  final DateTime Function()? now;
  final ValueChanged<HealthEvent>? onSaved;
  final bool closeOnSave;

  @override
  State<JournalQuickAddSheet> createState() => _JournalQuickAddSheetState();
}

class _JournalQuickAddSheetState extends State<JournalQuickAddSheet> {
  late final JournalQuickAddController _controller;
  late final bool _ownsController;
  _JournalQuickAddKind _kind = _JournalQuickAddKind.meal;
  String? _validationError;
  String? _savedMessage;

  final _mealDescription = TextEditingController();
  final _mealCarbs = TextEditingController();
  final _exerciseActivity = TextEditingController();
  final _exerciseDuration = TextEditingController();
  final _noteText = TextEditingController();

  @override
  void initState() {
    super.initState();
    final provided = widget.controller;
    _ownsController = provided == null;
    _controller =
        provided ??
        JournalQuickAddController(
          serviceFactory: widget.serviceFactory ?? defaultJournalServiceFactory,
          now: widget.now,
        );
  }

  @override
  void dispose() {
    _mealDescription.dispose();
    _mealCarbs.dispose();
    _exerciseActivity.dispose();
    _exerciseDuration.dispose();
    _noteText.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _validationError = null;
      _savedMessage = null;
    });
    final HealthEvent? event;
    switch (_kind) {
      case _JournalQuickAddKind.meal:
        final description = _mealDescription.text.trim();
        if (description.isEmpty) {
          _showValidation('Add a meal description before saving.');
          return;
        }
        final carbs = _parseOptionalNumber(_mealCarbs.text, 'Carbs');
        if (carbs == null && _mealCarbs.text.trim().isNotEmpty) return;
        event = await _controller.saveMeal(
          description: description,
          carbsGrams: carbs,
        );
      case _JournalQuickAddKind.exercise:
        final activity = _exerciseActivity.text.trim();
        if (activity.isEmpty) {
          _showValidation('Add an exercise before saving.');
          return;
        }
        final duration = _parseDuration(_exerciseDuration.text);
        if (duration == null && _exerciseDuration.text.trim().isNotEmpty) {
          return;
        }
        event = await _controller.saveExercise(
          activity: activity,
          duration: duration,
        );
      case _JournalQuickAddKind.note:
        final text = _noteText.text.trim();
        if (text.isEmpty) {
          _showValidation('Add a note before saving.');
          return;
        }
        event = await _controller.saveNote(text: text);
    }
    if (!mounted) return;
    if (event == null) {
      setState(() => _validationError = _controller.error);
      return;
    }
    widget.onSaved?.call(event);
    if (widget.closeOnSave) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _savedMessage = 'Saved locally');
  }

  double? _parseOptionalNumber(String raw, String label) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final value = double.tryParse(trimmed);
    if (value == null || !value.isFinite || value < 0) {
      _showValidation('$label must be a non-negative number.');
      return null;
    }
    return value;
  }

  Duration? _parseDuration(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final minutes = int.tryParse(trimmed);
    if (minutes == null || minutes <= 0) {
      _showValidation('Duration must be a positive number of minutes.');
      return null;
    }
    return Duration(minutes: minutes);
  }

  void _showValidation(String message) {
    if (mounted) setState(() => _validationError = message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Add context',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    _kindChip(
                      key: const ValueKey<String>('journalMealChip'),
                      label: 'Meal',
                      kind: _JournalQuickAddKind.meal,
                      icon: Icons.restaurant_rounded,
                    ),
                    _kindChip(
                      key: const ValueKey<String>('journalExerciseChip'),
                      label: 'Exercise',
                      kind: _JournalQuickAddKind.exercise,
                      icon: Icons.directions_run_rounded,
                    ),
                    _kindChip(
                      key: const ValueKey<String>('journalNoteChip'),
                      label: 'Note',
                      kind: _JournalQuickAddKind.note,
                      icon: Icons.edit_note_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ..._fields(theme),
                if (_validationError != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _validationError!,
                    key: const ValueKey<String>('journalQuickAddError'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                if (_savedMessage != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _savedMessage!,
                    key: const ValueKey<String>('journalQuickAddSaved'),
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ],
                if (_controller.summaryText != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    _controller.summaryText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF5B6E6A),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey<String>('journalSaveButton'),
                    onPressed: _controller.busy ? null : _save,
                    icon: _controller.busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(
                      _controller.busy ? 'Saving…' : 'Save locally',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _kindChip({
    required Key key,
    required String label,
    required _JournalQuickAddKind kind,
    required IconData icon,
  }) => ChoiceChip(
    key: key,
    avatar: Icon(icon, size: 18),
    label: Text(label),
    selected: _kind == kind,
    onSelected: _controller.busy
        ? null
        : (_) => setState(() {
            _kind = kind;
            _validationError = null;
            _savedMessage = null;
          }),
  );

  List<Widget> _fields(ThemeData theme) {
    switch (_kind) {
      case _JournalQuickAddKind.meal:
        return <Widget>[
          TextField(
            key: const ValueKey<String>('journalMealDescriptionField'),
            controller: _mealDescription,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'What did you eat?',
              hintText: 'e.g. oats and berries',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('journalMealCarbsField'),
            controller: _mealCarbs,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Carbs (g), optional',
            ),
          ),
        ];
      case _JournalQuickAddKind.exercise:
        return <Widget>[
          TextField(
            key: const ValueKey<String>('journalExerciseActivityField'),
            controller: _exerciseActivity,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'What did you do?',
              hintText: 'e.g. walk, strength training',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('journalExerciseDurationField'),
            controller: _exerciseDuration,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Duration (minutes), optional',
            ),
          ),
        ];
      case _JournalQuickAddKind.note:
        return <Widget>[
          TextField(
            key: const ValueKey<String>('journalNoteField'),
            controller: _noteText,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Note',
              hintText: 'What did you notice?',
            ),
          ),
        ];
    }
  }
}

/// Opens the quick-add sheet and returns the locally saved event, if any.
Future<HealthEvent?> showJournalQuickAddSheet(
  BuildContext context, {
  JournalQuickAddController? controller,
  JournalServiceFactory? serviceFactory,
  DateTime Function()? now,
}) async {
  final ownedController = controller == null
      ? JournalQuickAddController(
          serviceFactory: serviceFactory ?? defaultJournalServiceFactory,
          now: now,
        )
      : null;
  final effectiveController = controller ?? ownedController!;
  HealthEvent? saved;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (_) => JournalQuickAddSheet(
        controller: effectiveController,
        closeOnSave: true,
        onSaved: (event) => saved = event,
      ),
    );
    return saved;
  } finally {
    ownedController?.dispose();
  }
}
