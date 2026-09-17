import 'dart:async';
import 'dart:convert';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations_extension.dart';
import 'app_controller.dart';
import 'health_context_import.dart';
import 'healthkit_export.dart';
import 'persistence/health_store.dart';

/// Lazily creates the importer used by the manual context sync action.
///
/// Keeping the factory at the UI boundary means tests can inject an in-memory
/// repository and reader, while production opens the protected local store
/// only after the user explicitly taps "Sync context".
typedef HealthContextImporterFactory = Future<HealthContextImporter> Function();
typedef HealthContextSyncCompleted = Future<void> Function();

const _healthContextSettingsKey = 'openHealth.healthContextImportSettings';
const _healthContextSyncWindow = Duration(days: 7);

/// Integrations tab of the settings sheet (TASK-016).
///
/// Currently exposes the Apple Health export: an opt-in toggle, a "Sync now"
/// action, and the last-synced state. The actual HealthKit write is gated
/// behind the toggle / explicit sync, and is iOS-only — on other platforms the
/// section renders an unavailable note instead of the controls.
class IntegrationsSettingsPane extends StatelessWidget {
  const IntegrationsSettingsPane({
    super.key,
    required this.healthExport,
    required this.controller,
    this.healthContextImporterFactory,
    this.healthContextNow,
    this.onHealthContextSyncCompleted,
  });

  final HealthExportController healthExport;
  final CgmAppController controller;
  final HealthContextImporterFactory? healthContextImporterFactory;
  final DateTime Function()? healthContextNow;
  final HealthContextSyncCompleted? onHealthContextSyncCompleted;

  List<CgmReading> get _readings => controller.visibleHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: healthExport,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              l10n.integrations,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.integrationsIntro,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 16),
            _AppleHealthCard(
              healthExport: healthExport,
              readingsCount: _readings.length,
              onSyncNow: () => healthExport.syncNow(_readings),
            ),
            const SizedBox(height: 12),
            HealthContextSettingsCard(
              importerFactory: healthContextImporterFactory,
              now: healthContextNow,
              onSyncCompleted: onHealthContextSyncCompleted,
            ),
          ],
        );
      },
    );
  }
}

/// Manual, local-first import controls for activity, sleep, and heart-rate
/// context. No background delivery or automatic sync is configured here.
class HealthContextSettingsCard extends StatefulWidget {
  const HealthContextSettingsCard({
    super.key,
    this.importerFactory,
    this.now,
    this.onSyncCompleted,
  });

  /// Optional seam for deterministic widget tests and demo surfaces.
  final HealthContextImporterFactory? importerFactory;

  /// Optional clock seam; production uses the device clock in UTC.
  final DateTime Function()? now;

  /// Called after the bounded import completes so the foreground timeline can
  /// reload local records. It is deliberately not a background callback.
  final HealthContextSyncCompleted? onSyncCompleted;

  @override
  State<HealthContextSettingsCard> createState() =>
      _HealthContextSettingsCardState();
}

class _HealthContextSettingsCardState extends State<HealthContextSettingsCard> {
  HealthContextImportSettings _settings = const HealthContextImportSettings();
  SharedPreferences? _preferences;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_healthContextSettingsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        if (decoded is Map<String, Object?>) {
          _settings = HealthContextImportSettings.fromJson(decoded);
        }
      });
    } on Object {
      // Preferences are a convenience for switches, not a reason to block
      // the integration surface. Defaults remain fully usable.
    }
  }

  Future<void> _persistSettings() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setString(
      _healthContextSettingsKey,
      jsonEncode(_settings.toJson()),
    );
  }

  void _updateSettings(HealthContextImportSettings next) {
    setState(() => _settings = next);
    unawaited(_persistSettings());
  }

  Future<void> _sync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    HealthContextImporter? importer;
    var didSync = false;
    try {
      importer = await (widget.importerFactory ?? _defaultImporterFactory)();
      final end = (widget.now ?? DateTime.now)().toUtc();
      final result = await importer.sync(
        start: end.subtract(_healthContextSyncWindow),
        end: end,
        settings: _settings,
      );
      didSync = true;
      if (mounted) {
        setState(() => _status = _statusForResult(result));
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status =
              'Health data could not be connected. Check that Apple Health '
              'or Health Connect is available, then try again.',
        );
      }
    } finally {
      try {
        await importer?.repository.close();
      } on Object {
        // Closing is best-effort after a bounded foreground operation.
      }
      if (didSync) {
        try {
          await widget.onSyncCompleted?.call();
        } on Object {
          // A timeline refresh is best-effort and must not turn a completed
          // import into a misleading health-sync failure.
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusForResult(HealthContextImportResult result) {
    switch (result.status) {
      case HealthContextImportStatus.ok:
        return 'Imported ${result.imported} context records from the last '
            '7 days.';
      case HealthContextImportStatus.noData:
        return 'No context data found for the selected categories in the '
            'last 7 days.';
      case HealthContextImportStatus.notSupported:
        return 'Apple Health or Health Connect is unavailable on this '
            'platform.';
      case HealthContextImportStatus.notAuthorized:
        return '${result.message ?? 'Health data access was not granted.'} '
            'Allow health access in your device settings, then try again.';
      case HealthContextImportStatus.failed:
        return result.message ??
            'Health data could not be imported. Check permissions and try '
                'again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.insights_rounded, color: Color(0xFF0B6E69)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Health context',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Bring selected activity, sleep, and heart-rate context into '
              'your local timeline. Sync is manual and limited to the last '
              '7 days.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'If nothing appears, allow Health access in your device '
              'settings (Health on iPhone or Health Connect on Android).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF8A6D3B),
              ),
            ),
            const SizedBox(height: 8),
            _switchTile(
              key: const ValueKey<String>('contextStepsSwitch'),
              title: 'Steps',
              value: _settings.steps,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(steps: value)),
            ),
            _switchTile(
              key: const ValueKey<String>('contextWorkoutsSwitch'),
              title: 'Workouts',
              value: _settings.workouts,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(workouts: value)),
            ),
            _switchTile(
              key: const ValueKey<String>('contextSleepSwitch'),
              title: 'Sleep',
              value: _settings.sleep,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(sleep: value)),
            ),
            _switchTile(
              key: const ValueKey<String>('contextHeartRateSwitch'),
              title: 'Heart rate',
              value: _settings.heartRate,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(heartRate: value)),
            ),
            _switchTile(
              key: const ValueKey<String>('contextActiveEnergySwitch'),
              title: 'Active energy',
              value: _settings.activeEnergy,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(activeEnergy: value)),
            ),
            _switchTile(
              key: const ValueKey<String>('contextDistanceSwitch'),
              title: 'Walking distance',
              value: _settings.distance,
              onChanged: (value) =>
                  _updateSettings(_settings.copyWith(distance: value)),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey<String>('healthContextSyncButton'),
              onPressed: _busy ? null : _sync,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(_busy ? 'Syncing…' : 'Sync context'),
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _status!,
                key: const ValueKey<String>('healthContextStatus'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _switchTile({
    required Key key,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile.adaptive(
    key: key,
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title),
    value: value,
    onChanged: _busy ? null : onChanged,
  );
}

Future<HealthContextImporter> _defaultImporterFactory() async {
  final repository = await openHealthRepository();
  return HealthContextImporter(
    reader: HealthPackageContextReader(),
    repository: repository,
  );
}

class _AppleHealthCard extends StatelessWidget {
  const _AppleHealthCard({
    required this.healthExport,
    required this.readingsCount,
    required this.onSyncNow,
  });

  final HealthExportController healthExport;
  final int readingsCount;
  final Future<void> Function() onSyncNow;

  String _lastSyncedText(BuildContext context) {
    final l10n = context.l10n;
    final last = healthExport.lastSyncedAt;
    if (last == null) {
      return l10n.neverSynced;
    }
    final locale = Localizations.localeOf(context).languageCode;
    final formatted = DateFormat.MMMd(locale).add_Hm().format(last.toLocal());
    return l10n.lastSyncedAt(formatted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final supported = healthExport.isSupported;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.favorite_rounded, color: Color(0xFFE0537A)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appleHealth,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.appleHealthExportDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 8),
            if (!supported)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.appleHealthOnlyOnIos,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8A6D3B),
                  ),
                ),
              )
            else ...<Widget>[
              if (!healthExport.writesAllowed) ...<Widget>[
                Text(
                  l10n.appleHealthDisabledWithSimulatedData,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8A6D3B),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.exportToAppleHealth),
                subtitle: Text(_lastSyncedText(context)),
                value: healthExport.enabled,
                onChanged: healthExport.busy || !healthExport.writesAllowed
                    ? null
                    : (value) => healthExport.setEnabled(enabled: value),
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed:
                        healthExport.busy ||
                            !healthExport.writesAllowed ||
                            !healthExport.enabled
                        ? null
                        : onSyncNow,
                    icon: healthExport.busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(l10n.syncNow),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.readingCount(readingsCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF5B6E6A),
                    ),
                  ),
                ],
              ),
              if (healthExport.statusMessage != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _localizedHealthExportStatusMessage(
                    context,
                    healthExport.statusMessage!,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF0B6E69),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _localizedHealthExportStatusMessage(
  BuildContext context,
  String message,
) {
  final l10n = context.l10n;
  const exactMessages = <String, _LocalizedHealthExportStatus>{
    'Apple Health export is unavailable in this mode.':
        _LocalizedHealthExportStatus.unavailableInThisMode,
    'Apple Health is only available on iOS.':
        _LocalizedHealthExportStatus.onlyOnIos,
    'Apple Health access was not granted.':
        _LocalizedHealthExportStatus.accessNotGranted,
    'Turn on Apple Health export before syncing.':
        _LocalizedHealthExportStatus.turnOnBeforeSyncing,
    'Already up to date.': _LocalizedHealthExportStatus.alreadyUpToDate,
    'Export failed.': _LocalizedHealthExportStatus.exportFailed,
    'HealthKit rejected a glucose sample.':
        _LocalizedHealthExportStatus.sampleRejected,
    'Apple Health could not save a glucose sample.':
        _LocalizedHealthExportStatus.couldNotSaveSample,
    'Apple Health export could not be completed.':
        _LocalizedHealthExportStatus.couldNotComplete,
    'Apple Health writes are disabled for this mode.':
        _LocalizedHealthExportStatus.writesDisabled,
  };
  final exact = exactMessages[message];
  if (exact != null) {
    return switch (exact) {
      _LocalizedHealthExportStatus.unavailableInThisMode =>
        l10n.appleHealthExportUnavailableInThisMode,
      _LocalizedHealthExportStatus.onlyOnIos => l10n.appleHealthOnlyOnIos,
      _LocalizedHealthExportStatus.accessNotGranted =>
        l10n.appleHealthAccessNotGranted,
      _LocalizedHealthExportStatus.turnOnBeforeSyncing =>
        l10n.turnOnAppleHealthBeforeSyncing,
      _LocalizedHealthExportStatus.alreadyUpToDate =>
        l10n.appleHealthAlreadyUpToDate,
      _LocalizedHealthExportStatus.exportFailed => l10n.appleHealthExportFailed,
      _LocalizedHealthExportStatus.sampleRejected =>
        l10n.appleHealthSampleRejected,
      _LocalizedHealthExportStatus.couldNotSaveSample =>
        l10n.appleHealthCouldNotSaveSample,
      _LocalizedHealthExportStatus.couldNotComplete =>
        l10n.appleHealthExportCouldNotComplete,
      _LocalizedHealthExportStatus.writesDisabled =>
        l10n.appleHealthWritesDisabled,
    };
  }

  final completed = RegExp(
    r'^Synced (\d+) reading\(s\)\.$',
  ).firstMatch(message);
  if (completed != null) {
    return l10n.appleHealthSyncedReadings(int.parse(completed.group(1)!));
  }
  final partial = RegExp(
    r'^Synced (\d+) reading\(s\), then export stopped\.$',
  ).firstMatch(message);
  if (partial != null) {
    return l10n.appleHealthSyncPartial(int.parse(partial.group(1)!));
  }
  final partialWithReason = RegExp(
    r'^Synced (\d+) reading\(s\), then export stopped: (.+)$',
  ).firstMatch(message);
  if (partialWithReason != null) {
    return l10n.appleHealthSyncPartialWithReason(
      int.parse(partialWithReason.group(1)!),
      _localizedHealthExportStatusMessage(context, partialWithReason.group(2)!),
    );
  }
  // Do not surface an unexpected implementation message verbatim. It may be
  // untranslated or include provider details; known controller states above
  // retain their precise, localized recovery copy.
  return l10n.appleHealthExportCouldNotComplete;
}

enum _LocalizedHealthExportStatus {
  unavailableInThisMode,
  onlyOnIos,
  accessNotGranted,
  turnOnBeforeSyncing,
  alreadyUpToDate,
  exportFailed,
  sampleRejected,
  couldNotSaveSample,
  couldNotComplete,
  writesDisabled,
}
