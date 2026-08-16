import 'package:flutter/material.dart';

/// Windows opens an explicit pairing flow because an AiDEX sensor can keep one
/// Bluetooth bond. Demo data never needs that warning.
bool requiresWindowsSensorTransferWarning({
  required TargetPlatform platform,
  required bool isMockDriver,
}) {
  return platform == TargetPlatform.windows && !isMockDriver;
}

/// Platforms whose BLE adapter can verify and explicitly remove a local bond.
///
/// The protocol and controller still decide whether the connected session
/// exposes the confirmed transfer contract. This helper only controls whether
/// the app can present that public action on the current platform.
bool supportsConfirmedSensorTransfer(TargetPlatform platform) {
  return platform == TargetPlatform.android ||
      platform == TargetPlatform.windows;
}

String confirmedSensorTransferLabel(TargetPlatform platform) {
  return platform == TargetPlatform.windows
      ? 'Move sensor to another device'
      : 'Move sensor to another phone';
}

/// Confirms that the user understands the single-bond transfer requirement.
///
/// This dialog does not change either bond. The currently connected device
/// must complete its explicit Move sensor action before Windows can pair.
Future<bool> confirmWindowsSensorTransfer(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const WindowsSensorTransferDialog(),
      ) ??
      false;
}

class WindowsSensorTransferDialog extends StatelessWidget {
  const WindowsSensorTransferDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('windowsSensorTransferDialog'),
      icon: const Icon(Icons.phonelink_ring_rounded),
      title: const Text('Move sensor to this computer?'),
      content: const Text(
        'An AiDEX sensor can keep one Bluetooth bond. If it is paired to '
        'another device, first use Move sensor to another phone or computer '
        'on that device. Closing the app or ordinary Disconnect does not move '
        'the bond.\n\nKeep the other device disconnected and the sensor close. '
        'Continuing opens Windows pairing. It does not reset or restart the '
        'active sensor.',
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('cancelWindowsSensorTransfer'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('confirmWindowsSensorTransfer'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue to pairing'),
        ),
      ],
    );
  }
}
