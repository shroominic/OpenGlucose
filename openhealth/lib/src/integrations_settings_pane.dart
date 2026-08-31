import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_localizations_extension.dart';
import 'app_controller.dart';
import 'healthkit_export.dart';

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
  });

  final HealthExportController healthExport;
  final CgmAppController controller;

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
          ],
        );
      },
    );
  }
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
