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

bool _whileWarmingUp(MessageContext context) => context.isWarmingUp;

bool _whenReadingsAvailable(MessageContext context) =>
    context.hasSession && context.hasReadings;
