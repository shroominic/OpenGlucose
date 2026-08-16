import 'package:flutter/material.dart';

bool shouldShowMacosPreviewNotice({
  required TargetPlatform platform,
  required bool isWeb,
}) {
  return !isWeb && platform == TargetPlatform.macOS;
}

bool shouldDisableMacosSecureStorage({
  required TargetPlatform platform,
  required bool isWeb,
}) {
  return !isWeb && platform == TargetPlatform.macOS;
}

/// Makes the unverified hardware boundary visible inside the macOS build.
class MacosPreviewNotice extends StatelessWidget {
  const MacosPreviewNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'macOS preview limitations',
      child: Card(
        key: const ValueKey<String>('macosPreviewNotice'),
        color: const Color(0xFFFFF3D6),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'macOS transport preview',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF704C00),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Real AiDEX pairing, reconnect, and live readings are not '
                'verified on Mac hardware. This build cannot remove a system '
                'Bluetooth bond or run Move sensor. Use the Move sensor action '
                'on the current Android phone before a controlled Mac test.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF704C00),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Replaces API-key settings that cannot work in this ad-hoc-signed preview.
class MacosPreviewUnavailableAiPane extends StatelessWidget {
  const MacosPreviewUnavailableAiPane({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text(
          'AI unavailable in macOS preview',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'This ad-hoc-signed preview cannot supply the macOS Keychain '
          'capability required to store an API key. Cloud AI remains disabled. '
          'Do not paste a key into this preview.',
        ),
      ],
    );
  }
}
