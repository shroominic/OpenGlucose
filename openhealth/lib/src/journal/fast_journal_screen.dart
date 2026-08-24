import 'dart:async';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:openglucose/src/journal/fast_journal_controller.dart';
import 'package:openglucose/src/persistence/health_store.dart';

/// Opens the app's private local event store.
typedef HealthRepositoryOpener = Future<HealthRepository> Function();

/// A compact, optional local diary for manual meal, activity, and sleep logs.
///
/// It is intentionally a Settings destination rather than a dashboard card.
/// The glucose-reader view stays focused on current readings.
class FastJournalScreen extends StatefulWidget {
  const FastJournalScreen({
    super.key,
    this.recentRise = noRecentGlucoseRise,
    this.repositoryOpener = openHealthRepository,
  });

  final FastJournalRecentRiseProvider recentRise;
  final HealthRepositoryOpener repositoryOpener;

  @override
  State<FastJournalScreen> createState() => _FastJournalScreenState();
}

class _FastJournalScreenState extends State<FastJournalScreen> {
  HealthRepository? _repository;
  FastJournalController? _journal;
  Object? _loadError;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final repository = _repository;
    if (repository != null) {
      unawaited(_closeRepository(repository));
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    HealthRepository? openedRepository;
    try {
      final repository = await widget.repositoryOpener();
      openedRepository = repository;
      final journal = FastJournalController(
        repository: repository,
        recentRise: widget.recentRise,
      );
      await journal.load();
      if (!mounted) {
        await _closeRepository(repository);
        return;
      }
      setState(() {
        _repository = repository;
        _journal = journal;
        _loading = false;
      });
    } catch (error) {
      if (openedRepository != null) {
        await _closeRepository(openedRepository);
      }
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _closeRepository(HealthRepository repository) async {
    try {
      await repository.close();
    } catch (_) {
      // Closing local storage must not block route disposal.
    }
  }

  Future<void> _openQuickAdd() async {
    final journal = _journal;
    if (journal == null) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _QuickJournalSheet(journal: journal),
    );
    if (saved == true && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.lock_outline_rounded, size: 36),
              const SizedBox(height: 12),
              const Text(
                'Your local diary could not open.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final journal = _journal!;
    return RefreshIndicator(
      onRefresh: () async {
        await journal.load();
        if (mounted) setState(() {});
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: <Widget>[
          const _JournalIntro(),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey<String>('fastJournalQuickAdd'),
            onPressed: _openQuickAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Quick add'),
          ),
          const SizedBox(height: 24),
          Text(
            'Recent entries',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          if (journal.entries.isEmpty)
            const _EmptyDiary()
          else
            _JournalEntries(entries: journal.entries),
          const SizedBox(height: 20),
          const Text(
            'This diary records timing and observations. It does not identify '
            'causes or give treatment or dosing guidance.',
            style: TextStyle(color: Color(0xFF5B6E6A), height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _JournalIntro extends StatelessWidget {
  const _JournalIntro();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE6EFEA),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Private local diary',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            Text(
              'Record a meal, activity, or sleep note. Entries stay on this '
              'device.',
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDiary extends StatelessWidget {
  const _EmptyDiary();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Text('No diary entries yet.'),
      ),
    );
  }
}

class _JournalEntries extends StatelessWidget {
  const _JournalEntries({required this.entries});

  final List<HealthEvent> entries;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var index = 0; index < entries.length; index++) ...<Widget>[
            _JournalEntryTile(entry: entries[index]),
            if (index != entries.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _JournalEntryTile extends StatelessWidget {
  const _JournalEntryTile({required this.entry});

  final HealthEvent entry;

  @override
  Widget build(BuildContext context) {
    final payload = entry.payload;
    final label = switch (payload) {
      MealPayload(:final description?) => description,
      ExercisePayload(:final activity?) => activity,
      SleepPayload(:final description?) => description,
      _ => null,
    };
    final duration = switch (payload) {
      ExercisePayload(:final duration?) => duration,
      SleepPayload(:final duration?) => duration,
      _ => null,
    };
    final date = DateFormat('MMM d · HH:mm').format(entry.timestamp.toLocal());
    final subtitle = <String>[
      date,
      if (duration != null) _formatDuration(duration),
      if (entry.riseReference != null) 'Near a recorded rise',
    ].join(' · ');
    return ListTile(
      leading: Icon(_iconFor(entry.type), color: const Color(0xFF0B6E69)),
      title: Text(label ?? _labelFor(entry.type)),
      subtitle: Text(subtitle),
    );
  }
}

class _QuickJournalSheet extends StatefulWidget {
  const _QuickJournalSheet({required this.journal});

  final FastJournalController journal;

  @override
  State<_QuickJournalSheet> createState() => _QuickJournalSheetState();
}

class _QuickJournalSheetState extends State<_QuickJournalSheet> {
  final _labelController = TextEditingController();
  late DateTime _startedAt = DateTime.now();
  FastJournalKind _kind = FastJournalKind.meal;
  var _attachToLatestRise = false;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _chooseStartTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startedAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startedAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _startedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.journal.save(
        FastJournalDraft(
          kind: _kind,
          startedAt: _startedAt,
          label: _labelController.text,
        ),
        attachToLatestRise: _attachToLatestRise,
      );
      if (mounted) Navigator.of(context).pop(true);
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
        _error = 'This entry could not be saved locally.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rise = widget.journal.latestEligibleRise;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Quick add',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: FastJournalKind.values
                    .map(
                      (kind) => ChoiceChip(
                        label: Text(kind.label),
                        selected: _kind == kind,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _kind = kind),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _labelController,
                enabled: !_saving,
                maxLength: 160,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Optional label',
                  hintText: _kind == FastJournalKind.meal
                      ? 'For example, breakfast'
                      : _kind == FastJournalKind.activity
                      ? 'For example, walk'
                      : 'For example, early night',
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _chooseStartTime,
                icon: const Icon(Icons.schedule_rounded),
                label: Text(
                  'When: ${DateFormat('MMM d · HH:mm').format(_startedAt)}',
                ),
              ),
              if (rise != null) ...<Widget>[
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Link near the latest observed rise'),
                  subtitle: const Text(
                    'This records timing only. It does not identify a cause.',
                  ),
                  value: _attachToLatestRise,
                  onChanged: _saving
                      ? null
                      : (value) => setState(
                          () => _attachToLatestRise = value,
                        ),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB24A3B)),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(
                    _saving ? 'Saving…' : 'Save ${_kind.label.toLowerCase()}',
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

IconData _iconFor(HealthEventType type) => switch (type) {
  HealthEventType.meal => Icons.restaurant_rounded,
  HealthEventType.exercise => Icons.directions_walk_rounded,
  HealthEventType.sleep => Icons.bedtime_rounded,
  HealthEventType.note => Icons.notes_rounded,
  HealthEventType.insulin => Icons.medication_rounded,
  HealthEventType.medication => Icons.medication_rounded,
  HealthEventType.custom => Icons.bookmark_outline_rounded,
};

String _labelFor(HealthEventType type) => switch (type) {
  HealthEventType.meal => 'Meal',
  HealthEventType.exercise => 'Activity',
  HealthEventType.sleep => 'Sleep',
  HealthEventType.note => 'Note',
  HealthEventType.insulin => 'Insulin',
  HealthEventType.medication => 'Medication',
  HealthEventType.custom => 'Entry',
};

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '${duration.inMinutes} min';
  if (minutes == 0) return '$hours h';
  return '$hours h $minutes min';
}
