import 'dart:async';

import 'package:flutter/material.dart';

import 'app_message.dart';
import 'message_controller.dart';

/// Renders the current top contextual message (if any) as a clean, dismissible
/// banner card. Designed as a thin, self-contained widget that drops into the
/// dashboard with a single line — it owns all of its own styling and listens to
/// the [MessageController] directly, so the surrounding layout stays untouched.
///
/// Shows nothing (zero-height) when there is no message, so it is safe to leave
/// permanently in the tree.
class MessageHost extends StatelessWidget {
  const MessageHost({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 0),
  });

  final MessageController controller;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final message = controller.topMessage;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              axisAlignment: -1,
              child: child,
            ),
          ),
          child: message == null
              ? const SizedBox.shrink(key: ValueKey<String>('messageHostEmpty'))
              : Padding(
                  key: ValueKey<String>('messageHost-${message.id}'),
                  padding: padding,
                  child: _MessageCard(
                    message: message,
                    onDismiss: () =>
                        unawaited(controller.dismiss(message)),
                  ),
                ),
        );
      },
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, required this.onDismiss});

  final AppMessage message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _paletteFor(message.kind);

    return DecoratedBox(
      key: ValueKey<String>('messageCard-${message.id}'),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 12),
              child: Icon(palette.icon, size: 20, color: palette.accent),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    message.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: palette.foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message.body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: palette.foreground,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (message.dismissible)
              IconButton(
                key: ValueKey<String>('messageDismiss-${message.id}'),
                onPressed: onDismiss,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: palette.accent,
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close_rounded),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _MessagePalette {
  const _MessagePalette({
    required this.background,
    required this.border,
    required this.foreground,
    required this.accent,
    required this.icon,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final Color accent;
  final IconData icon;
}

_MessagePalette _paletteFor(AppMessageKind kind) {
  return switch (kind) {
    AppMessageKind.tip => const _MessagePalette(
      background: Color(0xFFEFF5F2),
      border: Color(0xFFD8E3DE),
      foreground: Color(0xFF24443F),
      accent: Color(0xFF0B6E69),
      icon: Icons.lightbulb_outline_rounded,
    ),
    AppMessageKind.info => const _MessagePalette(
      background: Color(0xFFEAF1FB),
      border: Color(0xFFC9DBF3),
      foreground: Color(0xFF1F3A57),
      accent: Color(0xFF2C5F94),
      icon: Icons.info_outline_rounded,
    ),
    AppMessageKind.alert => const _MessagePalette(
      background: Color(0xFFFCEDE9),
      border: Color(0xFFF4C9BD),
      foreground: Color(0xFF7A2E1E),
      accent: Color(0xFFC2502F),
      icon: Icons.warning_amber_rounded,
    ),
  };
}
