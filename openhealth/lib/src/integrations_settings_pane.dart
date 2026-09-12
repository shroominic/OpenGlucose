import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'apple_health_context_import.dart';
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
    this.healthContextImport,
    required this.controller,
  });

  final HealthExportController healthExport;
  final AppleHealthContextImportController? healthContextImport;
  final CgmAppController controller;

  List<CgmReading> get _readings => controller.visibleHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        healthExport,
        if (healthContextImport != null) healthContextImport!,
      ]),
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              'Integrations',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Send your glucose readings to other apps you control. Nothing '
              'leaves your device unless you turn it on.',
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
            if (healthContextImport != null) ...<Widget>[
              const SizedBox(height: 16),
              _AppleHealthContextImportCard(controller: healthContextImport!),
            ],
          ],
        );
      },
    );
  }
}

class _AppleHealthContextImportCard extends StatelessWidget {
  const _AppleHealthContextImportCard({required this.controller});

  final AppleHealthContextImportController controller;

  String get _lastSyncedText {
    final last = controller.lastSyncedAt;
    if (last == null) {
      return 'Never imported';
    }
    return 'Last imported ${DateFormat('MMM d, HH:mm').format(last.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supported = controller.isSupported;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.bedtime_outlined, color: Color(0xFF0B6E69)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Apple Health context',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'When you opt in and tap Import now, OpenGlucose reads sleep, '
              'workout, and heart-rate context from the last 30 days. It does '
              'not import glucose, start background delivery, or share this data.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 8),
            if (!supported)
              Text(
                Platform.isAndroid
                    ? 'Apple Health context import is only available on iOS.'
                    : 'Apple Health context import is unavailable on this platform.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF8A6D3B),
                ),
              )
            else if (!controller.readsAllowed)
              Text(
                'Apple Health context import is disabled while using simulated '
                'or mock sensor data.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF8A6D3B),
                ),
              )
            else ...<Widget>[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Import Apple Health context'),
                subtitle: Text(_lastSyncedText),
                value: controller.enabled,
                onChanged: controller.busy
                    ? null
                    : (value) => controller.setEnabled(enabled: value),
              ),
              Text(
                'Apple does not disclose read permission. “No accessible data” '
                'can mean that there are no matching records or that access is '
                'not available.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF5B6E6A),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: controller.busy || !controller.enabled
                    ? null
                    : controller.syncNow,
                icon: controller.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded, size: 18),
                label: const Text('Import now'),
              ),
              if (controller.statusMessage != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  controller.statusMessage!,
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

class _AppleHealthCard extends StatelessWidget {
  const _AppleHealthCard({
    required this.healthExport,
    required this.readingsCount,
    required this.onSyncNow,
  });

  final HealthExportController healthExport;
  final int readingsCount;
  final Future<void> Function() onSyncNow;

  String get _lastSyncedText {
    final last = healthExport.lastSyncedAt;
    if (last == null) {
      return 'Never synced';
    }
    return 'Last synced ${DateFormat('MMM d, HH:mm').format(last.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                    'Apple Health',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'When you opt in and tap Sync now, glucose values and timestamps '
              'are written to Apple Health as blood glucose samples. An '
              'interrupted sync may write a duplicate when retried.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF5B6E6A),
              ),
            ),
            const SizedBox(height: 8),
            if (!supported)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  Platform.isAndroid
                      ? 'Apple Health is only available on iOS.'
                      : 'Apple Health export is only available on iOS.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8A6D3B),
                  ),
                ),
              )
            else ...<Widget>[
              if (!healthExport.writesAllowed) ...<Widget>[
                Text(
                  'Apple Health export is disabled while using simulated or '
                  'mock sensor data.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8A6D3B),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Export to Apple Health'),
                subtitle: Text(_lastSyncedText),
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
                    label: const Text('Sync now'),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$readingsCount reading(s)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF5B6E6A),
                    ),
                  ),
                ],
              ),
              if (healthExport.statusMessage != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  healthExport.statusMessage!,
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
