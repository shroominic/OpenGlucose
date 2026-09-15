import 'package:cgm_core/cgm_core.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'libre_nfc_history_pane.dart';
import 'libre_nfc_history_tools.dart';

/// Only the button starts NFC. The route owns its pane until cleanup and BLE
/// resume finish, even if importing readings removes the dashboard prompt.
class LibreHistorySyncPrompt extends StatelessWidget {
  const LibreHistorySyncPrompt({
    super.key,
    required this.controller,
    required this.sensor,
    required this.tools,
    this.dark = false,
  });

  final CgmAppController controller;
  final DiscoveredSensor sensor;
  final LibreNfcHistoryTools tools;
  final bool dark;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Scan your Libre 2 with NFC to sync missing history',
    child: OutlinedButton.icon(
      key: const ValueKey('openLibreHistorySyncButton'),
      icon: const Icon(Icons.nfc_rounded),
      label: const Text('Sync history'),
      style: dark
          ? OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFD6ECE7),
              side: const BorderSide(color: Color(0xFF9CC9C1)),
            )
          : null,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        useSafeArea: true,
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final current = controller.snapshot?.sensor;
                final targetChanged =
                    current?.driverId != sensor.driverId ||
                    current?.deviceId != sensor.deviceId ||
                    current?.storageKey != sensor.storageKey;
                return LibreNfcHistoryPane(
                  sensor: sensor,
                  tools: tools,
                  startImmediately: true,
                  cleanupBlocked:
                      targetChanged ||
                      controller.sensorConnectionCleanupUnconfirmed,
                  onClose: () => Navigator.of(sheetContext).pop(),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
