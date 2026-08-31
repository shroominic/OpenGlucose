import 'package:flutter/material.dart';

import 'app_localizations_extension.dart';

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
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.macosPreviewLimitations,
      child: Card(
        key: const ValueKey<String>('macosPreviewNotice'),
        color: const Color(0xFFFFF3D6),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.macosTransportPreview,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF704C00),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.macosTransportPreviewDescription,
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
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text(
          l10n.aiUnavailableInMacosPreview,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 12),
        Text(l10n.macosPreviewAiUnavailableDescription),
      ],
    );
  }
}
