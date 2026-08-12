import 'package:flutter/foundation.dart';

import 'message_context.dart';

/// The visual/semantic kind of an [AppMessage]. Drives the host's styling and
/// (later) lets tips vs. info-boxes vs. alerts be filtered or prioritised
/// independently.
///
/// - [tip]: a gentle, educational nudge (TASK-005). Low urgency.
/// - [info]: a temporary, contextual info box (TASK-006), e.g. "warming up".
/// - [alert]: an attention-grabbing, higher-urgency notice.
enum AppMessageKind { tip, info, alert }

/// How long a message should keep showing once its trigger matches.
enum AppMessagePersistence {
  /// Show every time the trigger matches; dismissal only hides it for the
  /// current surfacing (it can reappear on a later launch/context).
  recurring,

  /// Show until the user dismisses it once, then never again (persisted via
  /// shared_preferences). Good for one-time onboarding tips.
  showOnce,

  /// Show whenever the trigger matches *unless* the user has dismissed it,
  /// in which case it stays hidden permanently (persisted). Good for
  /// dismissible info boxes the user has acknowledged.
  showUntilDismissed,
}

/// Predicate deciding whether a message is relevant for the current
/// [MessageContext]. Kept as a typedef (not a subclass) so message definitions
/// stay declarative and trivial to unit-test.
typedef MessageTrigger = bool Function(MessageContext context);

/// A single contextual in-app message.
///
/// This is the shared substrate that tips (TASK-005) and temporary info boxes
/// (TASK-006) both build on: they are just [AppMessage]s with a particular
/// its kind, trigger, and persistence. The engine is
/// content-agnostic — new messages are added by appending [AppMessage]s, no
/// controller changes required.
@immutable
class AppMessage {
  const AppMessage({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.trigger,
    this.dismissible = true,
    this.priority = 0,
    this.persistence = AppMessagePersistence.showUntilDismissed,
  });

  /// Stable, unique identifier. Used as the persistence key for dismissals, so
  /// it must remain stable across releases for a given logical message.
  final String id;

  final AppMessageKind kind;
  final String title;
  final String body;

  /// When non-null, the message is only eligible while this returns true for
  /// the current [MessageContext]. A null trigger means "always eligible".
  final MessageTrigger? trigger;

  /// Whether the host renders a dismiss affordance. Non-dismissible messages
  /// can still be retired by their [trigger] no longer matching.
  final bool dismissible;

  /// Higher wins when multiple messages are eligible at once. Ties break on a
  /// stable kind ordering (alert > info > tip) and then [id].
  final int priority;

  /// Show-once / show-until-dismissed semantics. See [AppMessagePersistence].
  final AppMessagePersistence persistence;

  /// Whether this message is eligible to surface in [context], ignoring
  /// dismissal state (which the controller layers on top).
  bool matches(MessageContext context) => trigger?.call(context) ?? true;
}
