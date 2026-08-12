import 'dart:io';

import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

  List<CgmReading> get _readings =>
      controller.snapshot?.history ?? const <CgmReading>[];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: healthExport,
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
              'Write your readings to Apple Health as blood glucose samples.',
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
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Export to Apple Health'),
                subtitle: Text(_lastSyncedText),
                value: healthExport.enabled,
                onChanged: healthExport.busy
                    ? null
                    : (value) => healthExport.setEnabled(value),
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: healthExport.busy
                        ? null
                        : () => onSyncNow(),
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
