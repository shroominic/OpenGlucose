import 'package:flutter/widgets.dart';

import '../app_localizations_extension.dart';
import 'app_message.dart';
import 'message_context.dart';

/// The default catalog of contextual messages.
///
/// This is intentionally small — it demonstrates the engine with one info box
/// and one tip. The real content lands in follow-ups:
///   * TASK-005 (tips) will add more [AppMessageKind.tip] entries.
///   * TASK-006 (temporary info boxes) will add more [AppMessageKind.info]
///     entries.
/// Both plug in here (or via a merged list) without touching the controller or
/// host. Content is wellness-framed and honest: no medical/treatment claims.
const List<AppMessage> defaultMessageCatalog = <AppMessage>[
  // Info box shown only during the sensor warmup window. Disappears
  // automatically once warmup ends (trigger stops matching). Dismissing it
  // persists — once you've read the explanation you won't see it again.
  AppMessage(
    id: 'info.warmup',
    kind: AppMessageKind.info,
    title: 'Warming up',
    body:
        'Your sensor is settling in. Readings begin after about an hour — '
        'no action needed.',
    priority: 100,
    persistence: AppMessagePersistence.showUntilDismissed,
    trigger: _whileWarmingUp,
  ),
  // Onboarding tip shown once the dashboard has live readings. Shown until the
  // user dismisses it, then it stays gone.
  AppMessage(
    id: 'tip.tapReading',
    kind: AppMessageKind.tip,
    title: 'Tip',
    body: 'Tap a point on the chart to see the exact reading and time.',
    priority: 10,
    persistence: AppMessagePersistence.showUntilDismissed,
    trigger: _whenReadingsAvailable,
  ),
];

/// Returns localized presentation copy for messages owned by this catalog.
///
/// IDs remain the durable controller and dismissal contract; copy is resolved
/// only when the host renders the message. This lets a manual language change
/// immediately update a currently visible card without changing dismissal
/// state or the generic [AppMessage] model.
({String title, String body}) localizedCatalogMessageText(
  BuildContext context,
  AppMessage message,
) {
  final l10n = context.l10n;
  return switch (message.id) {
    'info.warmup' => (
      title: l10n.messageWarmupTitle,
      body: l10n.messageWarmupBody,
    ),
    'tip.tapReading' => (
      title: l10n.messageTapReadingTitle,
      body: l10n.messageTapReadingBody,
    ),
    _ => (title: message.title, body: message.body),
  };
}

bool _whileWarmingUp(MessageContext context) => context.isWarmingUp;

bool _whenReadingsAvailable(MessageContext context) =>
    context.hasSession && context.hasReadings;
